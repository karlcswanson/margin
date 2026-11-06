"""Web previews: a localhost dev server reached through the daemon's proxy."""
import asyncio

import httpx
import websockets

from margind.config import Project, WorkspaceConfig
from margind.preview import PreviewProxy, _local_redirect


async def _dev_server():
    """A stand-in dev server: echoes the Host it saw, redirects, and has a
    live-reload websocket."""
    async def http(reader, writer):
        head = (await reader.readuntil(b"\r\n\r\n")).decode()
        path = head.split(" ")[1]
        host = next(l.split(": ", 1)[1] for l in head.split("\r\n") if l.lower().startswith("host:"))
        if path == "/old":
            writer.write(b"HTTP/1.1 302 Found\r\nLocation: http://localhost:%d/new\r\nContent-Length: 0\r\n\r\n" % port)
        else:
            body = f"page {path} for {host}; cookie={'margin_preview' in head}".encode()
            writer.write(b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\r\n" % len(body) + body)
        await writer.drain()
        writer.close()

    async def ws_echo(sock):
        async for m in sock:
            await sock.send("reload:" + m)

    srv = await asyncio.start_server(http, "127.0.0.1", 0)
    port = srv.sockets[0].getsockname()[1]
    ws_srv = await websockets.serve(ws_echo, "127.0.0.1", 0)
    return srv, port, ws_srv, ws_srv.sockets[0].getsockname()[1]


def test_proxy_needs_the_apps_cookie_then_forwards_everything(tmp_path):
    async def run():
        srv, port, ws_srv, ws_port = await _dev_server()
        ws = WorkspaceConfig(name="P", tokens=["t"], projects=[Project("p", str(tmp_path))],
                             state_dir=str(tmp_path / "st"), preview_ports=(18800, 18809))
        proxy = PreviewProxy(ws)
        p = await proxy.open(port)
        assert (await proxy.open(port)) is p                    # one preview per server
        base = f"http://127.0.0.1:{p.listen_port}"
        async with httpx.AsyncClient(base_url=base) as c:
            assert (await c.get("/")).status_code == 403          # not from the app
            assert (await c.get(f"/__margin/auth?k=wrong")).status_code == 403
            r = await c.get(p.public()["auth_path"])
            assert r.status_code == 302 and r.headers["location"] == "/"
            r = await c.get("/app/")
            assert r.status_code == 200
            # Host rewritten for the dev server; our cookie isn't passed on
            assert r.text == f"page /app/ for localhost:{port}; cookie=False"
            r = await c.get("/old")
            assert r.status_code == 302 and r.headers["location"] == "/new"
            assert (await c.get("/again")).status_code == 200    # a new connection is checked too

        # live reload: websockets through the proxy
        q = await proxy.open(ws_port)
        async with httpx.AsyncClient() as c:
            r = await c.get(f"http://127.0.0.1:{q.listen_port}{q.public()['auth_path']}")
            cookie = r.headers["set-cookie"].split(";")[0]
        async with websockets.connect(f"ws://127.0.0.1:{q.listen_port}/hmr",
                                      additional_headers={"Cookie": cookie}) as sock:
            await sock.send("x")
            assert await sock.recv() == "reload:x"

        await proxy.shutdown()
        srv.close()
        ws_srv.close()
    asyncio.run(run())


def test_proxy_refuses_its_own_ports(tmp_path):
    async def run():
        ws = WorkspaceConfig(name="P", tokens=["t"], projects=[], state_dir=str(tmp_path), preview_ports=(18810, 18811))
        proxy = PreviewProxy(ws)
        for bad in (ws.port, 18810, 0):
            try:
                await proxy.open(bad)
                raise AssertionError(bad)
            except Exception as e:
                assert "port" in str(e)
    asyncio.run(run())


def test_nothing_running_gives_a_clear_error(tmp_path):
    async def run():
        ws = WorkspaceConfig(name="P", tokens=["t"], projects=[], state_dir=str(tmp_path), preview_ports=(18812, 18813))
        proxy = PreviewProxy(ws)
        p = await proxy.open(1)   # nothing listens on port 1
        async with httpx.AsyncClient(base_url=f"http://127.0.0.1:{p.listen_port}") as c:
            await c.get(p.public()["auth_path"])
            r = await c.get("/")
            assert r.status_code == 502 and "Is the dev server running" in r.text
        await proxy.shutdown()
    asyncio.run(run())


def test_redirects_to_the_dev_server_stay_in_the_preview():
    assert _local_redirect("http://localhost:5173/login", 5173) == "/login"
    assert _local_redirect("http://127.0.0.1:5173", 5173) == "/"
    assert _local_redirect("https://example.com/x", 5173) == "https://example.com/x"


def test_https_preview_verifies_against_the_daemons_ca(tmp_path):
    import plistlib
    import ssl

    from cryptography import x509

    from margind import tls

    async def run():
        srv, port, ws_srv, ws_port = await _dev_server()
        ws = WorkspaceConfig(name="P", tokens=["t"], projects=[Project("p", str(tmp_path))],
                             state_dir=str(tmp_path / "st"), preview_ports=(18830, 18839),
                             tls_names=("mac.zt.example.com",))
        certs = tls.ensure(ws)
        assert tls.ensure(ws).ca_sha256 == certs.ca_sha256       # made once, then reused
        ca = x509.load_pem_x509_certificate(certs.ca_pem)
        nc = ca.extensions.get_extension_for_class(x509.NameConstraints).value
        assert x509.DNSName("mac.zt.example.com") in nc.permitted_subtrees
        leaf = x509.load_pem_x509_certificate(certs.cert_path.read_bytes())
        san = leaf.extensions.get_extension_for_class(x509.SubjectAlternativeName).value
        assert "mac.zt.example.com" in san.get_values_for_type(x509.DNSName)

        proxy = PreviewProxy(ws, tls=certs.server_context())
        p = await proxy.open(port)
        assert p.public()["scheme"] == "https"
        client = ssl.create_default_context(cadata=certs.ca_pem.decode())
        async with httpx.AsyncClient(base_url=f"https://localhost:{p.listen_port}", verify=client) as c:
            r = await c.get(p.public()["auth_path"])
            assert r.status_code == 302 and "Secure" in r.headers["set-cookie"]
            assert (await c.get("/x")).text == f"page /x for localhost:{port}; cookie=False"
        # Something that doesn't trust the CA can't talk to it.
        async with httpx.AsyncClient(base_url=f"https://localhost:{p.listen_port}") as c:
            try:
                await c.get("/")
                raise AssertionError("trusted without the CA")
            except httpx.ConnectError:
                pass
        await proxy.shutdown()
        srv.close()
        ws_srv.close()

        profile = plistlib.loads(tls.mobileconfig(certs, ws))
        assert profile["PayloadContent"][0]["PayloadContent"] == certs.ca_der
    asyncio.run(run())


def test_finds_the_claude_chat_that_started_a_server():
    from margind.preview import _started_by_claude

    sid = "d2e5aaa2-7376-412b-8e78-91b42c93f389"
    procs = {
        100: (1, f"/x/claude --output-format stream-json --resume={sid} --input-format stream-json"),
        200: (100, "/bin/zsh -c source snap.sh 2>/dev/null || true && eval 'npm run dev -- --host '\\''0.0.0.0'\\''' "
                   "< /dev/null && pwd -P >| /tmp/cwd"),
        300: (200, "node vite"),
        400: (1, "node vite"),                         # started by hand: not Claude's
    }
    assert _started_by_claude(300, procs) == {"claude_command": "npm run dev -- --host '0.0.0.0'", "claude_session": sid}
    assert _started_by_claude(400, procs) == {}
