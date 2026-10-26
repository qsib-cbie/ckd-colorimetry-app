import json
import os
import subprocess
import sys
import time
from pathlib import Path

import httpx


def test_runtime_launches_on_dynamic_port_and_exits_with_parent(tmp_path):
    root = Path(__file__).resolve().parents[2]
    ui = tmp_path / "ui"
    ui.mkdir()
    (ui / "index.html").write_text("<h1>CKD</h1>")
    env = {**os.environ, "PYTHONPATH": str(root / "api"), "CKD_DESKTOP_TOKEN": "runtime-test"}
    child = subprocess.Popen([sys.executable, "-m", "ckd.runtime", "--static-dir", str(ui), "--state-dir", str(tmp_path / "state"), "--parent-pipe"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, text=True)
    try:
        started = json.loads(child.stdout.readline())
        url = started["url"]
        assert url.startswith("http://127.0.0.1:")
        assert started["pid"] == child.pid
        with httpx.Client() as client:
            for _ in range(100):
                try:
                    response = client.get(url, follow_redirects=True, timeout=1)
                    break
                except httpx.TransportError:
                    time.sleep(0.05)
            assert response.status_code == 200
            assert "CKD" in response.text
            assert client.get(str(response.url) + "api/ready").json()["mode"] == "desktop"
        child.stdin.close()
        assert child.wait(timeout=10) == 0
    finally:
        if child.poll() is None:
            child.terminate()
            child.wait(timeout=10)
