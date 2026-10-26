import json
import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
DESKTOP = ROOT / "desktop"


def run(arguments, cwd=ROOT):
    subprocess.run([str(value) for value in arguments], cwd=cwd, check=True, env={**os.environ, "CARGO_TARGET_DIR": str(DESKTOP / "target"), "MACOSX_DEPLOYMENT_TARGET": "14.0"})


def build(engine_only=False, skip_engine=False):
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise SystemExit("This build targets Apple Silicon Macs.")
    run(["npm", "--prefix", "web", "run", "build"])
    python = DESKTOP / ".venv-build/bin/python"
    if not skip_engine:
        if not python.exists():
            run([sys.executable, "-m", "venv", DESKTOP / ".venv-build"])
        run([python, "-m", "pip", "install", "-r", ROOT / "requirements.lock"])
        output = DESKTOP / "engine/ckd-engine"
        if output.exists():
            from send2trash import send2trash
            send2trash(str(output))
        run([python, "-m", "PyInstaller", "--noconfirm", "--onedir", "--name", "ckd-engine",
             "--distpath", DESKTOP / "engine", "--workpath", DESKTOP / "build", "--specpath", DESKTOP / "build",
             "--paths", ROOT / "api", "--add-data", str(ROOT / "web/dist") + ":web", "--collect-all", "rawpy",
             "--collect-data", "skimage", "--collect-submodules", "send2trash",
             "--hidden-import", "uvicorn.logging", "--hidden-import", "uvicorn.protocols.http.h11_impl",
             "--hidden-import", "uvicorn.lifespan.on", "--exclude-module", "tkinter", "--exclude-module", "pytest",
             DESKTOP / "engine.py"])
    if skip_engine:
        shutil.copytree(ROOT / "web/dist", DESKTOP / "engine/ckd-engine/_internal/web", dirs_exist_ok=True)
    if not engine_only:
        run([ROOT / "web/node_modules/.bin/tauri", "build"], cwd=DESKTOP)
        version = json.loads((DESKTOP / "src-tauri/tauri.conf.json").read_text())["version"]
        dmg = DESKTOP / f"target/release/bundle/dmg/CKD Colorimetry_{version}_aarch64.dmg"
        run(["open", "-R", dmg])
