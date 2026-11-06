"""margind command line.

    python -m margind serve  -c workspaces/main.toml
    python -m margind token                      # make a new device token
    python -m margind pair   -c workspaces/main.toml --url http://192.168.1.20:8787
"""
from __future__ import annotations

import argparse
import logging
import sys
from urllib.parse import urlencode

from . import config


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser(prog="margind")
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("serve", help="run the daemon for one workspace")
    s.add_argument("-c", "--config", required=True)
    s.add_argument("--log-level", default="info")

    sub.add_parser("token", help="print a new random device token")

    p = sub.add_parser("pair", help="print a margin:// link that adds this workspace to the app")
    p.add_argument("-c", "--config", required=True)
    p.add_argument("--url", required=True, help="the URL the app will use, e.g. http://192.168.1.20:8787 (LAN or VPN address) or https://mac.example.com:8787")
    p.add_argument("--token", help="which token to embed (default: the first one)")

    args = ap.parse_args(argv)

    if args.cmd == "token":
        print(config.new_token())
        return

    ws = config.load(args.config)

    if args.cmd == "pair":
        token = args.token or ws.tokens[0]
        link = "margin://add?" + urlencode({"url": args.url.rstrip("/"), "token": token, "name": ws.name})
        print(link)
        try:
            import qrcode  # optional
            qr = qrcode.QRCode(border=1)
            qr.add_data(link)
            qr.print_ascii(invert=True)
        except ImportError:
            print("\n(pip install qrcode to show a scannable QR code here)", file=sys.stderr)
        return

    logging.basicConfig(level=args.log_level.upper(), format="%(asctime)s %(name)s %(levelname)s %(message)s")
    from .sessions import apply_workspace_env
    apply_workspace_env(ws)

    import uvicorn
    from .server import create_app

    uvicorn.run(create_app(ws), host=ws.bind, port=ws.port, log_level=args.log_level,
                proxy_headers=True, ws_ping_interval=None)


if __name__ == "__main__":
    main()
