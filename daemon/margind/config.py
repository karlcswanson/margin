"""Workspace configuration.

One daemon process serves exactly one workspace (one account / client).
Run several processes on one machine for several workspaces; each gets its
own port, token, CLAUDE_CONFIG_DIR and environment, so nothing can leak
between clients inside a single process.
"""
from __future__ import annotations

import os
import secrets
import tomllib
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class Project:
    name: str
    path: str


@dataclass
class ApnsConfig:
    team_id: str
    key_id: str
    key_path: str
    bundle_id: str
    sandbox: bool = True


@dataclass
class WorkspaceConfig:
    name: str
    # What the app calls this computer; the Mac's own name (System Settings >
    # General > Sharing) if unset.
    machine: str | None = None
    color: str = "#4F7CFF"
    bind: str = "127.0.0.1"
    port: int = 8787
    # Bearer tokens accepted by this workspace (one per device is a good habit).
    tokens: list[str] = field(default_factory=list)
    # None => normal ~/.claude. Set for client workspaces that have their own login.
    claude_config_dir: str | None = None
    # Name of an environment variable holding an API key (optional). When set,
    # the key is passed to Claude Code as ANTHROPIC_API_KEY for this workspace only.
    api_key_env: str | None = None
    model: str | None = None
    default_permission_mode: str = "default"
    # How an approved plan is carried out: "auto" (Claude Code's classifier lets
    # routine actions through and stops risky ones) or "acceptEdits".
    approved_mode: str = "auto"
    # Ports for web previews (a dev server on localhost opened in the app), inclusive.
    preview_ports: tuple[int, int] = (8800, 8819)
    # Serve previews over HTTPS (the daemon's own CA, see tls.py) so pages are secure contexts.
    preview_tls: bool = True
    # Host names the iPad uses for this computer (e.g. its ZeroTier DNS name), for HTTPS.
    tls_names: tuple[str, ...] = ()
    # Run app shells inside GNU screen (if installed) so they outlive the daemon.
    terminal_screen: bool = True
    projects: list[Project] = field(default_factory=list)
    idle_disconnect_minutes: int = 30
    apns: ApnsConfig | None = None
    state_dir: str = "~/.margin"
    # Path to kicad-cli for rendering schematics/boards; found automatically if unset.
    kicad_cli: str | None = None
    # Python that can `import OCP` (cadquery-ocp), for STEP models; found in
    # this interpreter or ~/.venvs/* if unset.
    cad_python: str | None = None

    # ---- derived -------------------------------------------------------
    @property
    def slug(self) -> str:
        return "".join(c if c.isalnum() else "-" for c in self.name.lower()).strip("-")

    @property
    def state_path(self) -> Path:
        p = Path(os.path.expanduser(self.state_dir)) / self.slug
        p.mkdir(parents=True, exist_ok=True)
        return p

    def project(self, name: str) -> Project:
        for p in self.projects:
            if p.name == name:
                return p
        raise KeyError(name)

    def project_for_cwd(self, cwd: str | None) -> str | None:
        if not cwd:
            return None
        # normcase: Windows paths compare case-insensitively (a no-op elsewhere)
        cwd_r = os.path.normcase(os.path.realpath(cwd))
        best: tuple[int, str] | None = None
        for p in self.projects:
            root = os.path.normcase(os.path.realpath(os.path.expanduser(p.path)))
            if cwd_r == root or cwd_r.startswith(root + os.sep):
                if best is None or len(root) > best[0]:
                    best = (len(root), p.name)
        return best[1] if best else None

    def sdk_env(self) -> dict[str, str]:
        """Environment passed to the Claude Code subprocess."""
        env: dict[str, str] = {}
        if self.claude_config_dir:
            env["CLAUDE_CONFIG_DIR"] = os.path.expanduser(self.claude_config_dir)
        if self.api_key_env:
            key = os.environ.get(self.api_key_env)
            if not key:
                raise RuntimeError(
                    f"workspace {self.name!r}: environment variable {self.api_key_env} is not set"
                )
            env["ANTHROPIC_API_KEY"] = key
        return env


def load(path: str | os.PathLike) -> WorkspaceConfig:
    with open(path, "rb") as f:
        raw = tomllib.load(f)
    ws = raw.get("workspace", {})
    projects = [Project(name=p["name"], path=os.path.expanduser(p["path"])) for p in raw.get("project", [])]
    apns_raw = raw.get("apns")
    tokens = list(ws.get("tokens", []))
    token_file = ws.get("token_file")
    if token_file:
        tf = Path(os.path.expanduser(token_file))
        if tf.exists():
            tokens += [t.strip() for t in tf.read_text().splitlines() if t.strip()]
    cfg = WorkspaceConfig(
        name=ws["name"],
        machine=ws.get("machine"),
        color=ws.get("color", "#4F7CFF"),
        bind=ws.get("bind", "127.0.0.1"),
        port=int(ws.get("port", 8787)),
        tokens=tokens,
        claude_config_dir=ws.get("claude_config_dir"),
        api_key_env=ws.get("api_key_env"),
        model=ws.get("model"),
        default_permission_mode=ws.get("default_permission_mode", "default"),
        approved_mode=ws.get("approved_mode", "auto"),
        preview_ports=tuple(ws.get("preview_ports", (8800, 8819))),  # type: ignore[arg-type]
        preview_tls=bool(ws.get("preview_tls", True)),
        tls_names=tuple(ws.get("tls_names", ())),
        terminal_screen=bool(ws.get("terminal_screen", True)),
        projects=projects,
        idle_disconnect_minutes=int(ws.get("idle_disconnect_minutes", 30)),
        apns=ApnsConfig(**apns_raw) if apns_raw else None,
        state_dir=ws.get("state_dir", "~/.margin"),
        kicad_cli=ws.get("kicad_cli"),
        cad_python=ws.get("cad_python"),
    )
    if not cfg.tokens:
        raise SystemExit(
            f"No tokens configured for workspace {cfg.name!r}. "
            f"Run `python -m margind token` and add it to `tokens` or `token_file`."
        )
    return cfg


def new_token() -> str:
    return "mgn_" + secrets.token_urlsafe(32)
