import argparse
import json
import os
import secrets
import socket
import sys
import threading
from pathlib import Path

import uvicorn

from ..desktop import create_desktop_app
from ..local import LocalAnalysisService


def main():
    parser = argparse.ArgumentParser(description="CKD local desktop engine")
    parser.add_argument("--workspace", type=Path)
    parser.add_argument("--state-dir", type=Path)
    parser.add_argument("--static-dir", type=Path)
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--parent-pipe", action="store_true")
    args = parser.parse_args()
    token = os.environ.pop("CKD_DESKTOP_TOKEN", None) or secrets.token_urlsafe(32)
    bundled = Path(getattr(sys, "_MEIPASS", "")) / "web"
    static = args.static_dir or (bundled if getattr(sys, "frozen", False) else Path(__file__).resolve().parents[3] / "web/dist")
    if not static.is_dir():
        raise SystemExit("Build the interface before starting the engine.")
    service = LocalAnalysisService(args.workspace) if args.workspace else None
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", args.port))
        listener.listen(128)
        port = listener.getsockname()[1]
        origin = f"http://127.0.0.1:{port}"
        app = create_desktop_app(service=service, token=token, state_dir=args.state_dir, static_dir=static, origin=origin)
        server = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=port, access_log=False, log_level="warning", loop="asyncio", http="h11"))
        if args.parent_pipe:
            threading.Thread(target=wait_for_parent, args=(server,), daemon=True).start()
        print(json.dumps({"url": f"{origin}/launch/{token}", "pid": os.getpid()}), flush=True)
        try:
            server.run(sockets=[listener])
        finally:
            app.state.runtime.close()


def wait_for_parent(server):
    sys.stdin.buffer.read()
    server.should_exit = True
