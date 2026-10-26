# 1. Development Setup

## 1.1 Layout

| Path | Contents |
| --- | --- |
| `api/ckd/` | Python engine: science (`utils.py`), analysis jobs (`service.py`, `local.py`), private loopback API (`desktop.py`), runtime launcher |
| `api/ckd/projects/` | Portable folder store, atomic saves, history, Trash and export ZIP import |
| `api/tests/` | Python tests, frozen Swift references and RAW fixtures |
| `web/` | React/Konva interface, unit tests and Chromium/WebKit integration tests |
| `desktop/src-tauri/` | Tauri wrapper: window, engine lifecycle, native dialogs and downloads |
| `desktop/scripts/` | Builder for the frozen engine, app and DMG |
| `ios/` | iPad and iPhone app; see [its README](../ios/README.md) |

The wrapper starts the engine on a private loopback port with a one-time token and stops it on quit. Shared Python helpers live in each package's `utils.py`. See [the architecture document](../documents/architecture.md) for processes, the API, jobs and storage.

## 1.2 Dependencies

Use an Apple Silicon Mac with Python 3.12, Node.js 24, Rust 1.91.1 or later, and Xcode command-line tools. Run these commands once from the repository root; repeat dependency installation after changing the lockfiles:

```sh
python3.12 -m venv .venv
.venv/bin/python -m pip install -r requirements.lock
npm --prefix web ci
npm --prefix web exec -- playwright install chromium webkit
```

All commands below run from the repository root. No Docker or separately managed server is needed.

# 2. Run All Tests

This block refreshes the bundled engine and UI, then runs every Python, frontend, browser integration and Rust test. It stops at the first failure.

```sh
(
  set -e
  .venv/bin/python desktop/scripts/build.py --engine-only
  export CKD_ENGINE_EXECUTABLE="$PWD/desktop/engine/ckd-engine/ckd-engine"
  desktop/.venv-build/bin/python -m pytest -q
  npm --prefix web test
  npm --prefix web run test:e2e
  CARGO_TARGET_DIR="$PWD/desktop/target" cargo test --locked --manifest-path desktop/src-tauri/Cargo.toml
)
```

# 3. Package for macOS

## 3.1 Build

```sh
.venv/bin/python desktop/scripts/build.py
codesign --verify --deep --strict "desktop/target/release/bundle/macos/CKD Colorimetry.app"
```

This builds React, bundles Python with PyInstaller, compiles the Tauri wrapper, and creates:

- `desktop/target/release/bundle/macos/CKD Colorimetry.app`
- `desktop/target/release/bundle/dmg/CKD Colorimetry_2.2.0_aarch64.dmg`

When packaging succeeds, the DMG is selected in Finder. The build is ad-hoc signed, not notarized. Packaging does not run tests. If only React or Rust changed, `--skip-engine` reuses the existing Python bundle while updating the UI and wrapper. Use the full build after Python/dependency changes. Release builds do not strip build scripts and procedural macros, because the macOS 27 linker otherwise produces invalid procedural-macro string pools.

To verify the engine inside the final `.app`, run:

```sh
(
  set -e
  export CKD_ENGINE_EXECUTABLE="$PWD/desktop/target/release/bundle/macos/CKD Colorimetry.app/Contents/Resources/engine/ckd-engine/ckd-engine"
  desktop/.venv-build/bin/python -m pytest -q api/tests/test_pipeline_reference.py
  npm --prefix web run test:e2e
)
```

## 3.2 Share a build

Zip the app with `ditto` so the signature survives:

```sh
ditto -c -k --keepParent "desktop/target/release/bundle/macos/CKD Colorimetry.app" "$HOME/Desktop/CKD Colorimetry.zip"
```

# 4. Run and Debug

## 4.1 Run the packaged Mac app

```sh
open "$PWD/desktop/target/release/bundle/macos/CKD Colorimetry.app"
```

Choose a workspace folder. Quit with Cmd+Q. The app starts and stops its engine itself.

## 4.2 Debug Python and the UI in a browser

```sh
npm --prefix web run build
PYTHONPATH=api .venv/bin/python -m ckd.runtime --workspace "$PWD/tmp/debug-workspace" --state-dir "$PWD/tmp/debug-settings"
```

Open the complete `url` printed in the terminal, including `/launch/...`. Use browser developer tools for the UI/API and the terminal for engine output. Stop with Ctrl+C. After React edits, rebuild and refresh; after Python edits, restart the engine. This mode uses the compiled interface without hot reload. Choosing another workspace folder or importing an export ZIP needs the native window.

## 4.3 Debug the native window and dialogs

```sh
.venv/bin/python desktop/scripts/build.py --engine-only
RUST_BACKTRACE=1 CARGO_TARGET_DIR="$PWD/desktop/target" cargo run --locked --manifest-path desktop/src-tauri/Cargo.toml
```

This runs the Rust debug build with the bundled engine. Quit normally with Cmd+Q. Repeat the engine build after Python or React changes. Engine logs:

```sh
tail -f "$HOME/Library/Logs/edu.northwestern.qsib.ckd-colorimetry/engine.log"
```

# 5. Manual Test Data

Fixtures are in `api/tests/fixtures/`. For Flower, import `_NOT_ACTUAL_TEST.dng`, then `synthetic-flower-coordinates.json` through **Import coordinates**. This is a synthetic fixture. Real RAW examples are `iPhoneRAW.DNG` and `SampleImg1.CR2`.

# 6. Releasing

The app version appears in `api/ckd/__init__.py`, `pyproject.toml`, `web/package.json` and its lock, `Cargo.toml` and its lock, and `tauri.conf.json`; `api/tests/test_release.py` fails if they differ. Bump the engine or configuration version whenever pixel or equation code changes, so **Differences** can detect it.
