"""Apple Push Notifications, sent directly from each workspace daemon.

Payloads carry only a short title/body and ids; the app fetches content over
ZeroTier when opened. Needs an APNs auth key (.p8) from your developer
account and `pip install "margind[push]"`.
"""
from __future__ import annotations

import json
import logging
import threading
import time
from pathlib import Path
from typing import Any

from .config import WorkspaceConfig

log = logging.getLogger("margind.push")


class DeviceStore:
    def __init__(self, ws: WorkspaceConfig) -> None:
        self.path = ws.state_path / "devices.json"
        self._lock = threading.Lock()

    def all(self) -> dict[str, dict[str, Any]]:
        if not self.path.exists():
            return {}
        try:
            return json.loads(self.path.read_text())
        except Exception:
            return {}

    def add(self, token: str, name: str | None, environment: str) -> None:
        with self._lock:
            d = self.all()
            d[token] = {"name": name, "environment": environment, "added": time.time()}
            self.path.write_text(json.dumps(d, indent=2))

    def remove(self, token: str) -> None:
        with self._lock:
            d = self.all()
            if d.pop(token, None) is not None:
                self.path.write_text(json.dumps(d, indent=2))


class ApnsPusher:
    def __init__(self, ws: WorkspaceConfig, devices: DeviceStore) -> None:
        if ws.apns is None:
            raise ValueError("apns not configured")
        import httpx  # noqa: F401  (optional dependency)
        import jwt  # noqa: F401

        self.ws = ws
        self.cfg = ws.apns
        self.devices = devices
        self._key = Path(self.cfg.key_path).expanduser().read_text()
        self._jwt: tuple[str, float] | None = None
        self._clients: dict[bool, Any] = {}

    def _token(self) -> str:
        import jwt

        if self._jwt and time.time() - self._jwt[1] < 40 * 60:
            return self._jwt[0]
        tok = jwt.encode({"iss": self.cfg.team_id, "iat": int(time.time())}, self._key,
                         algorithm="ES256", headers={"kid": self.cfg.key_id})
        self._jwt = (tok, time.time())
        return tok

    def _client(self, sandbox: bool):
        import httpx

        if sandbox not in self._clients:
            host = "https://api.sandbox.push.apple.com" if sandbox else "https://api.push.apple.com"
            self._clients[sandbox] = httpx.AsyncClient(http2=True, base_url=host, timeout=10)
        return self._clients[sandbox]

    async def __call__(self, payload: dict[str, Any]) -> None:
        category = {"permission": "APPROVAL", "result": "RESULT", "proposal": "PROPOSAL"}.get(
            payload.get("kind", ""), "GENERAL")
        body = {
            "aps": {
                "alert": {"title": payload.get("title", self.ws.name), "body": payload.get("body", "")},
                "sound": "default",
                "category": category,
                "thread-id": f"{self.ws.slug}:{payload.get('session_id', '')}",
                "interruption-level": "time-sensitive" if payload.get("kind") in ("permission", "proposal")
                                      else "active",
            },
            "workspace": self.ws.slug,
            "session_id": payload.get("session_id"),
            "request_id": payload.get("request_id"),
            "proposal_id": payload.get("proposal_id"),
        }
        headers = {
            "authorization": f"bearer {self._token()}",
            "apns-topic": self.cfg.bundle_id,
            "apns-push-type": "alert",
        }
        for token, meta in self.devices.all().items():
            sandbox = meta.get("environment", "development") == "development"
            try:
                r = await self._client(sandbox).post(f"/3/device/{token}", json=body, headers=headers)
                if r.status_code == 410 or (r.status_code == 400 and "BadDeviceToken" in r.text):
                    self.devices.remove(token)
                elif r.status_code >= 300:
                    log.warning("APNs %s: %s", r.status_code, r.text)
            except Exception:
                log.exception("APNs send failed")
