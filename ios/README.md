# 1. CKD Colorimetry for iPad and iPhone

Developer notes for the iPad and iPhone app. Installation and use are in the [main README](../README.md) and the [iPad and iPhone guide](../documents/ipad-iphone-guide.pdf).

| Path | Contents |
| --- | --- |
| `CKDKit/` | Swift package. `CKDRaw` wraps LibRaw; `CKDImage` holds the image pipeline taken from QDAQ (`user/amey/ckd-cam`, f94e4a7): RAW render, two-pass white balance, marker calibration, ROI LAB statistics |
| `CKDKit/Sources/CKDResults` | Results layer matching the Mac engine: equations, review rules, classifiers and CSV tables 05 to 12 |
| `CKDKit/Sources/CKDDocument` | Mac-compatible analysis folders (`ckd_project` v1): draft model, edit rules, memory checks (`MemoryBudget`), calibration, pipeline records, coordinates JSON, tables 03 and 04, ROI overlay, and export ZIP writing and import |
| `CKDKit/Sources/CKDContract` | `ckd-contract`: writes an iOS analysis folder and export ZIP for the Mac contract test; `--run <Mac analysis JSON> --raw <RAW> --output <dir>` runs any fixture with stage timings for `scripts/stats` |
| `App/` | The SwiftUI app (XcodeGen `project.yml`, bundle `edu.northwestern.bioelectronics.qsib.QCam`, team 823S57WQK3) and its XCUITests |
| `Benchmark/` | Device benchmark app (XcodeGen `project.yml`): render, white balance, preview and ROI timing and peak memory |
| `scripts/make_upscaled_dng.py` | Writes a 2x (48.8 MP) copy of the iPhone ProRAW fixture to `tmp/large/ProRAW48.DNG` for the large-image benchmark and UI test; LibRaw decodes it to exactly the upscaled original |
| `scripts/stats/` | `run_all.sh <output> [previous tag]` runs every pipeline fixture three times through CKDKit, the current Mac engine and a previous Mac release, and `compare.py` reports rasters, calibration, values, CSV cells, timings and peak memory |
| `scripts/device_ui_tests.sh <UDID> [xcodebuild options]` | Runs the UI tests on a connected iPhone or iPad: builds with development signing, installs the app, copies the test fixtures (and `tmp/large/ProRAW48.DNG` when present) into its container and runs the tests. Two tests that build files for the app skip on a device. `CONFIG=Release` for timings |
| `scripts/build_libraw.sh` | Builds `CKDKit/Frameworks/LibRaw.xcframework` (LibRaw 0.22.1, pinned commit) for iPhone, the simulator and the Mac. The output is not committed |

# 2. Build and Test

## 2.1 Package

```sh
ios/scripts/build_libraw.sh
swift test -c release --package-path ios/CKDKit
```

The tests read `api/tests/fixtures`:

- rasters match the frozen Swift references by SHA-256, and white balance to 1e-12;
- LAB uses scikit-image's RGB-to-LAB constants, like the Mac engine, and matches the legacy Python ROI statistics to 1e-10 with identical pixel counts;
- calibration and ROI values stay within the Mac's 0.01 budget for QDAQ's Swift LAB;
- `CKDResults` reproduces the 17 frozen Mac engine cases in `api/tests/fixtures/ios_results` (results JSON to 1e-9, CSV tables cell by cell). Regenerate them only by hand, into a candidate folder, with `api/tests/ios_reference/generate.py`, and review before replacing; `api/tests/test_ios_reference.py` fails when the Mac engine stops matching them;
- `CKDDocument` reproduces the four Mac pipeline references in `api/tests/fixtures/mac_reference` (rasters exactly, calibration and results within 1e-13 relative), opens the frozen Mac folder, imports the Mac export ZIP, and writes tables that match the Mac's byte for byte.

The Mac side of the contract is `api/tests/test_ios_contract.py`, which validates, lists, imports and re-runs the iOS folder and ZIP in `api/tests/fixtures/ios_contract`. Regenerate that fixture into a candidate folder and review it before replacing:

```sh
swift run -c release --package-path ios/CKDKit ckd-contract --output "$PWD/tmp/ios-contract-candidate"
```

## 2.2 App

```sh
cd ios/App && xcodegen generate
xcodebuild -project CKDColorimetry.xcodeproj -scheme CKDColorimetry -destination 'platform=iOS Simulator,name=iPad Air 11-inch (M4)' test
```

The UI tests import RAW fixtures, coordinates, export ZIPs and Mac folders through launch environment variables, run every step through the interface, and compare the displayed results with CKDKit and the Mac references.

The 48 MP test needs the generated file and a Release build:

```bash
.venv/bin/python -I ios/scripts/make_upscaled_dng.py api/tests/fixtures/iPhoneRAW.DNG tmp/large/ProRAW48.DNG
cd ios/App && xcodebuild -project CKDColorimetry.xcodeproj -scheme CKDColorimetry -configuration Release -destination 'platform=iOS Simulator,name=iPad Air 11-inch (M4)' -only-testing:CKDColorimetryUITests/LargeImageUITests test
```
