"""Web previews: a dev server Claude runs on this machine (Vite, Next, a
static page on localhost) opened in the app's built-in browser.

Each preview gets its own port on the daemon's address, forwarding to
localhost:<port>, so the page's absolute paths and live-reload websockets work
unchanged. Only the app can use it: it opens /__margin/auth?k=<secret> first,
which sets a cookie every later request must carry. One request per
connection, so every request is checked.
"""
from __future__ import annotations

import asyncio
import functools
import hmac
import logging
import os
import re
import secrets
import ssl
import subprocess
import sys
from dataclasses import dataclass, field
from http.cookies import SimpleCookie
from urllib.parse import parse_qs, urlsplit

from .config import WorkspaceConfig

log = logging.getLogger("margind.preview")

# lsof and ps on macOS/Linux; psutil on Windows, which has neither (psutil's
# connection list needs root on macOS, so it isn't used there).
WINDOWS = sys.platform == "win32"

HEAD_LIMIT = 64 * 1024
AUTH_PATH = "/__margin/auth"


class PreviewError(Exception):
    pass


@dataclass
class Preview:
    target_port: int
    listen_port: int
    secret: str
    tls: bool = False
    server: asyncio.base_events.Server | None = None
    connections: set[asyncio.Task] = field(default_factory=set)

    @property
    def cookie(self) -> str:
        return f"margin_preview_{self.listen_port}"

    def public(self) -> dict[str, object]:
        return {"target_port": self.target_port, "listen_port": self.listen_port,
                "scheme": "https" if self.tls else "http",
                "auth_path": f"{AUTH_PATH}?k={self.secret}&next=/"}


class PreviewProxy:
    def __init__(self, ws: WorkspaceConfig, upstream_host: str = "localhost",
                 tls: ssl.SSLContext | None = None) -> None:
        self.ws = ws
        self.upstream_host = upstream_host
        self.tls = tls
        self.items: dict[int, Preview] = {}          # by target port
        self._lock = asyncio.Lock()

    def _ports(self) -> range:
        lo, hi = self.ws.preview_ports
        return range(lo, hi + 1)

    async def open(self, target_port: int) -> Preview:
        if not 1 <= target_port <= 65535 or target_port == self.ws.port or target_port in self._ports():
            raise PreviewError("not a port that can be previewed")
        async with self._lock:
            if p := self.items.get(target_port):
                return p
            used = {p.listen_port for p in self.items.values()}
            for port in self._ports():
                if port in used:
                    continue
                p = Preview(target_port, port, secrets.token_urlsafe(18), tls=self.tls is not None)
                try:
                    p.server = await asyncio.start_server(lambda r, w, p=p: self._accept(p, r, w),
                                                          self.ws.bind, port, ssl=self.tls,
                                                          ssl_handshake_timeout=15 if self.tls else None)
                except OSError:
                    continue
                self.items[target_port] = p
                log.info("preview of localhost:%d on %s:%d", target_port, self.ws.bind, port)
                return p
        raise PreviewError("no free preview port (preview_ports in the workspace TOML)")

    async def close(self, target_port: int) -> None:
        p = self.items.pop(target_port, None)
        if p and p.server:
            p.server.close()
            for t in list(p.connections):
                t.cancel()

    async def shutdown(self) -> None:
        for port in list(self.items):
            await self.close(port)

    # -- one connection ----------------------------------------------------
    async def _accept(self, p: Preview, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        # Tracked so closing a preview drops its open connections (live-reload sockets).
        t = asyncio.current_task()
        if t:
            p.connections.add(t)
            t.add_done_callback(p.connections.discard)
        await self._serve(p, reader, writer)

    async def _serve(self, p: Preview, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        try:
            head = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 30)
        except (asyncio.IncompleteReadError, asyncio.LimitOverrunError, asyncio.TimeoutError, ConnectionError):
            writer.close()
            return
        try:
            request_line, headers = _parse_head(head)
            method, target, _version = request_line.split(" ", 2)
        except ValueError:
            await _respond(writer, 400, "Bad request")
            return

        if urlsplit(target).path == AUTH_PATH:
            q = parse_qs(urlsplit(target).query)
            nxt = (q.get("next") or ["/"])[0]
            if not nxt.startswith("/") or nxt.startswith("//"):
                nxt = "/"
            if hmac.compare_digest((q.get("k") or [""])[0], p.secret):
                await _respond(writer, 302, "", extra=[
                    ("Location", nxt),
                    ("Set-Cookie", f"{p.cookie}={p.secret}; Path=/; HttpOnly; SameSite=Lax"
                                   + ("; Secure" if p.tls else ""))])
            else:
                await _respond(writer, 403, "Open this preview from Margin.")
            return

        cookies = SimpleCookie()
        for k, v in headers:
            if k.lower() == "cookie":
                try:
                    cookies.load(v)
                except Exception:
                    pass
        got = cookies.get(p.cookie)
        if got is None or not hmac.compare_digest(got.value, p.secret):
            await _respond(writer, 403, "Open this preview from Margin.")
            return

        upgrade = any(k.lower() == "upgrade" for k, _ in headers)
        origin = f"localhost:{p.target_port}"
        out: list[tuple[str, str]] = []
        for k, v in headers:
            lk = k.lower()
            if lk == "host":
                v = origin                      # dev servers check Host (Vite's allowed hosts)
            elif lk in ("origin", "referer"):
                v = re.sub(r"^https?://[^/]+", f"http://{origin}", v)
            elif lk == "cookie":
                v = "; ".join(f"{m.key}={m.coded_value}" for m in cookies.values() if m.key != p.cookie)
                if not v:
                    continue
            elif lk in ("connection", "keep-alive", "proxy-connection") and not upgrade:
                continue
            out.append((k, v))
        if not upgrade:
            out.append(("Connection", "close"))   # one request per connection: each one is checked

        try:
            up_r, up_w = await asyncio.wait_for(self._connect(p.target_port), 10)
        except (OSError, asyncio.TimeoutError):
            await _respond(writer, 502, f"Nothing is answering on localhost:{p.target_port}. Is the dev server running?")
            return
        up_w.write(_head(request_line, out))
        await up_w.drain()

        async def pump_request() -> None:
            try:
                while data := await reader.read(65536):
                    up_w.write(data)
                    await up_w.drain()
            except (ConnectionError, asyncio.CancelledError):
                pass
            finally:
                if up_w.can_write_eof():
                    try:
                        up_w.write_eof()
                    except OSError:
                        pass

        async def pump_response() -> None:
            try:
                rhead = await up_r.readuntil(b"\r\n\r\n")
                status, rheaders = _parse_head(rhead)
                rheaders = [(k, _local_redirect(v, p.target_port) if k.lower() == "location" else v)
                            for k, v in rheaders]
                writer.write(_head(status, rheaders))
                while data := await up_r.read(65536):
                    writer.write(data)
                    await writer.drain()
            except (ConnectionError, asyncio.IncompleteReadError, asyncio.LimitOverrunError, ValueError):
                pass

        req = asyncio.create_task(pump_request())
        try:
            await pump_response()
        finally:
            req.cancel()
            for w in (writer, up_w):
                try:
                    w.close()
                except Exception:
                    pass

    async def _connect(self, port: int) -> tuple[asyncio.StreamReader, asyncio.StreamWriter]:
        # Dev servers bind "localhost" as 127.0.0.1 or ::1 depending on the tool.
        last: Exception | None = None
        for host in ("127.0.0.1", "::1"):
            try:
                return await asyncio.open_connection(host, port, limit=HEAD_LIMIT)
            except OSError as e:
                last = e
        raise last or OSError("connect failed")


def _parse_head(head: bytes) -> tuple[str, list[tuple[str, str]]]:
    lines = head.decode("latin-1").split("\r\n")
    headers = []
    for line in lines[1:]:
        if not line:
            continue
        k, _, v = line.partition(":")
        if not _:
            raise ValueError("bad header")
        headers.append((k.strip(), v.strip()))
    return lines[0], headers


def _head(first: str, headers: list[tuple[str, str]]) -> bytes:
    return (first + "\r\n" + "".join(f"{k}: {v}\r\n" for k, v in headers) + "\r\n").encode("latin-1")


def _local_redirect(location: str, port: int) -> str:
    """A redirect to http://localhost:<port>/x stays inside the preview."""
    return re.sub(rf"^https?://(?:localhost|127\.0\.0\.1|\[::1\]):{port}(?=/|$)", "", location) or "/"


async def _respond(writer: asyncio.StreamWriter, status: int, body: str,
                   extra: list[tuple[str, str]] | None = None) -> None:
    reason = {302: "Found", 400: "Bad Request", 403: "Forbidden", 502: "Bad Gateway"}.get(status, "")
    data = body.encode()
    headers = [("Content-Type", "text/plain; charset=utf-8"), ("Content-Length", str(len(data))),
               ("Connection", "close"), *(extra or [])]
    try:
        writer.write(_head(f"HTTP/1.1 {status} {reason}", headers) + data)
        await writer.drain()
    except ConnectionError:
        pass
    finally:
        writer.close()


# -- what's running ----------------------------------------------------------

def listening(ws: WorkspaceConfig) -> list[dict[str, object]]:
    """Servers listening on this machine that look like something to preview:
    yours, not the daemon's own ports, with the folder they run in."""
    found = _listening_windows() if WINDOWS else _listening_lsof()
    if not found:
        return []
    skip = {ws.port, *range(ws.preview_ports[0], ws.preview_ports[1] + 1)}
    procs = _processes()
    roots = [(pr.name, os.path.realpath(os.path.expanduser(pr.path))) for pr in ws.projects]
    items = []
    for port, it in sorted(found.items()):
        if port in skip:
            continue
        cwd = _cwd_of(int(it["pid"]))  # type: ignore[arg-type]
        if not cwd or _not_a_folder(cwd):
            continue                    # apps (Control Center, editors), not something started in a folder
        it["cwd"] = cwd
        it["project"] = next((n for n, r in roots if cwd and _inside(cwd, r)), None)
        it.update(_started_by_claude(int(it["pid"]), procs))  # type: ignore[arg-type]
        items.append(it)
    items.sort(key=lambda i: (i["project"] is None, i["port"]))
    return items


def _inside(path: str, root: str) -> bool:
    if WINDOWS:
        path, root = os.path.normcase(path), os.path.normcase(root)
        return path == root or path.startswith(root.rstrip(os.sep) + os.sep)
    return path == root or path.startswith(root + "/")


def _not_a_folder(cwd: str) -> bool:
    """Where apps sit rather than a folder something was started in."""
    if not WINDOWS:
        return cwd == "/"
    places = [os.environ.get(v) for v in ("SystemRoot", "ProgramFiles", "ProgramFiles(x86)", "LOCALAPPDATA")]
    return os.path.dirname(cwd) == cwd or any(p and _inside(cwd, p) for p in places)


def _listening_lsof() -> dict[int, dict[str, object]]:
    try:
        out = subprocess.run(["lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-u", str(os.getuid()), "-a", "-F", "pcn"],
                             capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.TimeoutExpired):
        return {}
    found: dict[int, dict[str, object]] = {}
    pid, cmd = 0, ""
    for line in out.splitlines():
        tag, val = line[:1], line[1:]
        if tag == "p":
            pid = int(val)
        elif tag == "c":
            cmd = val
        elif tag == "n":
            m = re.search(r"^(\*|127\.0\.0\.1|\[::1\]|\[::\]|0\.0\.0\.0|localhost):(\d+)$", val)
            if m:
                port = int(m.group(2))
                found.setdefault(port, {"port": port, "pid": pid, "command": cmd})
    return found


LOCAL_ADDRS = {"", "0.0.0.0", "127.0.0.1", "::", "::1", "localhost"}


def _listening_windows() -> dict[int, dict[str, object]]:
    """Like lsof: TCP ports listening on a local or wildcard address, owned by
    this user (processes we can't look into are someone else's)."""
    if (psutil := _psutil()) is None:
        return {}
    try:
        conns = psutil.net_connections(kind="tcp")
    except (psutil.Error, OSError):
        return {}
    me = _user(psutil, os.getpid())
    found: dict[int, dict[str, object]] = {}
    for c in conns:
        if c.status != psutil.CONN_LISTEN or not c.pid or not c.laddr or c.laddr.ip not in LOCAL_ADDRS:
            continue
        port = c.laddr.port
        if port in found or me is None or _user(psutil, c.pid) != me:
            continue
        try:
            name = psutil.Process(c.pid).name()
        except (psutil.Error, OSError):
            continue
        found[port] = {"port": port, "pid": c.pid, "command": name.removesuffix(".exe")}
    return found


@functools.cache
def _psutil():
    try:
        import psutil
    except ImportError:
        log.warning("install psutil to list dev servers on this machine")
        return None
    return psutil


def _user(psutil, pid: int) -> str | None:
    try:
        return psutil.Process(pid).username()
    except (psutil.Error, OSError):
        return None


CLAUDE_SESSION = re.compile(r"--(?:resume|session-id)[= ]([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})")
EVAL = re.compile(r"&& eval '((?:[^']|'\\'')*)'")


def _processes() -> dict[int, tuple[int, str]]:
    """pid -> (parent pid, command line), for every process."""
    if WINDOWS:
        if (psutil := _psutil()) is None:
            return {}
        # argv joined by spaces, as ps shows it
        return {p.pid: (p.info["ppid"] or 0, " ".join(p.info["cmdline"] or []))
                for p in psutil.process_iter(["ppid", "cmdline"])}
    try:
        out = subprocess.run(["ps", "-axww", "-o", "pid=,ppid=,command="], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.TimeoutExpired):
        return {}
    procs = {}
    for line in out.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) >= 2 and parts[0].isdigit() and parts[1].isdigit():
            procs[int(parts[0])] = (int(parts[1]), parts[2] if len(parts) > 2 else "")
    return procs


def _started_by_claude(pid: int, procs: dict[int, tuple[int, str]]) -> dict[str, str]:
    """Claude Code runs each Bash command as `zsh -c '… && eval '<command>' …'`
    under its own process, which names the chat (--resume <id>). Walk up from
    the server to find both."""
    found: dict[str, str] = {}
    seen = set()
    while pid in procs and pid not in seen and pid > 1:
        seen.add(pid)
        ppid, cmd = procs[pid]
        if "claude_command" not in found and (m := EVAL.search(cmd)):
            found["claude_command"] = m.group(1).replace("'\\''", "'")
        if ("/claude" in cmd or WINDOWS and "\\claude" in cmd) and (m := CLAUDE_SESSION.search(cmd)):
            found["claude_session"] = m.group(1)
            break
        pid = ppid
    return found if "claude_session" in found else {}


def _cwd_of(pid: int) -> str | None:
    if WINDOWS:
        if (psutil := _psutil()) is None:
            return None
        try:
            return os.path.realpath(psutil.Process(pid).cwd())
        except (psutil.Error, OSError):
            return None
    try:
        out = subprocess.run(["lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn"],
                             capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.TimeoutExpired):
        return None
    for line in out.splitlines():
        if line.startswith("n"):
            return os.path.realpath(line[1:])
    return None
