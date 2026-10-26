import json
import re
import tomllib
from pathlib import Path

from ckd import __version__

ROOT = Path(__file__).resolve().parents[2]


def test_every_manifest_uses_the_app_version():
    lock = json.loads((ROOT / "web/package-lock.json").read_text())
    cargo_lock = (ROOT / "desktop/src-tauri/Cargo.lock").read_text()
    versions = {
        "pyproject.toml": tomllib.loads((ROOT / "pyproject.toml").read_text())["project"]["version"],
        "web/package.json": json.loads((ROOT / "web/package.json").read_text())["version"],
        "web/package-lock.json": lock["version"],
        "web/package-lock.json root package": lock["packages"][""]["version"],
        "Cargo.toml": tomllib.loads((ROOT / "desktop/src-tauri/Cargo.toml").read_text())["package"]["version"],
        "Cargo.lock": re.search(r'name = "ckd-colorimetry-desktop"\nversion = "([^"]+)"', cargo_lock)[1],
        "tauri.conf.json": json.loads((ROOT / "desktop/src-tauri/tauri.conf.json").read_text())["version"],
    }
    assert versions == dict.fromkeys(versions, __version__)
    assert f"CKD Colorimetry_{__version__}_aarch64.dmg" in (ROOT / "desktop/README.md").read_text()


def test_frozen_swift_references_match_their_recorded_generator():
    import hashlib

    tools = ROOT / "api/tests/swift_reference"
    provenance = json.loads((ROOT / "api/tests/fixtures/swift_core/provenance.json").read_text())
    assert hashlib.sha256((tools / "utils.py").read_bytes()).hexdigest() == provenance["generator_sha256"]
    assert hashlib.sha256((tools / "Harness.swift").read_bytes()).hexdigest() == provenance["harness_sha256"]
