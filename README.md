# 1. CKD Colorimetry

CKD Colorimetry analyzes RAW photos of CKD sweat-sensor patches. It white-balances the image, calibrates it against a Flower 9 or Standard 24 marker, measures the reservoirs you draw, converts them to pH, urea and creatinine concentrations, and combines those with age and sex for a CKD prediction.

- It runs on a Mac, and on an iPad or iPhone.
- Everything is processed on your device. There is no account, server or internet requirement.
- Analyses are ordinary folders that you can copy, back up and send like any other folder.
- It is research software. Results have not been validated for assay accuracy or clinical use.

# 2. Install

## 2.1 Mac

Requires a Mac with Apple Silicon and macOS 14 or later.

1. Download the latest `CKD.Colorimetry_<version>_aarch64.dmg` from the Releases page of this repository, or use the ZIP someone shared with you.
2. Open the DMG (or unzip the ZIP) and drag **CKD Colorimetry** to Applications.
3. Open the app. macOS blocks it the first time because the app is not notarized.
4. Open **System Settings → Privacy & Security**, click **Open Anyway** next to the CKD Colorimetry message, and confirm.

The **Open Anyway** button appears only for about an hour after the block. Repeat these steps after installing each new version. Managed Macs may not allow **Open Anyway**; ask your IT administrator.

To update, replace the app in Applications. Your analyses are not affected. An older app refuses an analysis saved by a newer version and asks you to update.

## 2.2 iPad and iPhone

Requires iPadOS or iOS 18 or later. The app is an in-house Northwestern build for lab members, and no device registration is needed.

1. Download `CKD-Colorimetry-<version>-ios.ipa` from the iOS release on the Releases page of this repository.
2. Connect the iPad or iPhone to a Mac, select it in the Finder sidebar, and drag the `.ipa` onto its window. Apple Configurator also works: select the device, then **Add → Apps → Choose from my Mac**.
3. The first time, the app will not open until you go to **Settings → General → VPN & Device Management → Northwestern University → Trust**.

The app replaces the lab's QCam app on a device that has it. Each build stops opening on a fixed date (2 June 2027 for version 1.0); install an updated build before then.

# 3. Use

## 3.1 Workspace and library

On first launch, choose a workspace folder. Recent folders are listed by name with their path; folders that no longer exist are marked, and any entry can be removed from the list.

Every analysis is a folder inside the workspace. The sidebar shows the workspace as a library, with **Settings**, **Equations and versions** and **Shortcuts** at the bottom. The menu button at the top left (or `Cmd+\`) hides and shows the sidebar.

- The **⋯** button, or a right-click on a folder, analysis or the workspace, opens its options: Open, Rename, Move to, Duplicate, Reveal in Finder, Move to Trash, New folder and Import export ZIP.
- Drag folders and analyses onto a folder or the workspace row to move them.
- **Rename** changes an analysis title and its folder name together.
- **Duplicate** copies an analysis with a new ID. A copy made in Finder keeps the original ID; the library flags it and offers **Give this copy its own ID**.
- **Import export ZIP** adds an analysis exported from another copy of the app. The ZIP itself is left unchanged.
- **Move to Trash** uses the Mac Trash; restore items through Finder.
- **Settings** holds the workspace actions, the appearance (System, Light or Dark), the default drawing shape (rectangle or polygon), whether exports include debug images, and version information. **Equations and versions** shows the equations, coefficients, review ranges and versions in use. **Shortcuts** lists every keyboard and mouse shortcut.

## 3.2 Analysis steps

Open a DNG or CR2 file of up to 100 MB and 50 megapixels. For iPhone ProRAW, choose the most compatible ProRAW format in the Camera settings; compressed (JPEG XL) ProRAW cannot be read. Then work through the five steps:

| Step | What to do |
| --- | --- |
| Image | The original renders at full resolution |
| White balance | Draw a neutral area and apply white balance |
| Calibration | Choose **Flower 9 · manual patches** (the default) or **Standard 24 · legacy 24-patch**, place the marker, and calibrate |
| Reservoirs | Add reservoirs and draw ROIs in each: a rectangle takes two clicks, or switch to **Polygon** (T) for irregular shapes. Assign pH, urea, creatinine or a **Custom…** biomarker, and add optional **Notes**. Press N to move to the next reservoir |
| Results | Review flagged values, enter age and sex, and read each concentration as value ± SD and the prediction |

An analysis can have up to 1,000 reservoirs and 5,000 ROIs.

## 3.3 Results and review

Values inside the review range are included automatically; flagged values need a review decision. The review ranges are pH 6 to 7, urea 0 to 500 mM and creatinine 0 to 200 µM. A value outside its valid domain, or a negative value, stays out unless you choose **Include anyway**; it is then marked as included by the reviewer.

- **Urea pH model.** Urea uses a pH 6.0, 6.5 or 7.0 model. Automatic picks the one nearest the final pH, which needs every eligible pH reviewed and at least one included. Choosing a model yourself also lets urea be calculated without a pH reservoir.
- **Urea calibration.** L\*a\*b\* is the default; **a\*b\* only** removes the lightness term to reduce sensitivity to uneven lighting.
- **Prediction model.** Automatic uses urea + creatinine + age + sex when both analytes are final, otherwise creatinine + age + sex or urea + age + sex. You can choose any model whose inputs exist; the card names the model, threshold and AUC.
- **Calibration range.** An ROI whose calibrated color is outside the range of the calibration patches by more than the calibration RMSE is marked **Outside calibration range**, and its reservoir needs review.
- **Uncertainty.** Value ± SD is the spread across a reservoir's ROIs, or the pixel spread when it has one ROI. Analyte summaries use the spread across included reservoirs.
- **Averages.** An analyte's final value is the mean of its included reservoirs. The summary card lists each reservoir in the average.
- **Custom biomarkers** have no equation. Their card shows the average calibrated L\*a\*b\* ± SD; they are exported but not reviewed or used for prediction.

**Download coordinates JSON** and **Import coordinates** copy the drawn geometry between analyses of the same image. Importing resets calculations and reviews.

## 3.4 Undo and safety

Undo and Redo cover every edit. **Reset analysis**, next to Undo and Redo, starts the image over. Destructive actions ask for confirmation. If a save fails, you can discard the unsaved changes. An analysis that cannot be read offers **Restore last saved version**. Quitting waits for pending saves and warns about running calculations.

## 3.5 Keyboard shortcuts (Mac)

| Key | Action |
| --- | --- |
| D | Start drawing |
| T | Switch between rectangle and polygon |
| Click the first point, E or Enter | Finish a polygon (at least three points) |
| Enter | Apply white balance or calibrate on those steps |
| N | Next reservoir on the Reservoirs step |
| P | Toggle pan while drawing; D resumes drawing |
| Space or Cmd, then drag | Pan temporarily |
| Scroll | Zoom |
| Cmd+Z / Cmd+Shift+Z | Remove the last point while drawing; otherwise undo / redo |
| `Cmd+\` | Show or hide the sidebar |

## 3.6 iPad and iPhone

The steps, equations, reviews and export files are the same as on the Mac. The main differences:

- **Import:** tap **+ → Import from Photos…** for a ProRAW or RAW photo, or **Import RAW…** for a DNG or CR2 in Files.
- **Drawing:** drag a rectangle with a finger or the Pencil. For a polygon, tap each point, then tap the first point or **Finish**. Pinch to zoom.
- **Menus:** export, coordinates, Differences and run history are in the **⋯** menu at the top right. Export ZIPs go through the share sheet.
- **Workspace:** **On My iPad (or iPhone) → CKD Colorimetry** by default; **Settings → Choose Folder…** uses another folder in Files. Deleted analyses go to **Recently Deleted** in the library.
- **Debug images** in exports are off by default to save space.
- **Keyboard:** with a hardware keyboard, hold ⌘ to see the shortcuts.

See the [iPad and iPhone guide](documents/ipad-iphone-guide.pdf) for details.

# 4. Files and Sharing

## 4.1 Analysis folders

| Path | Contents |
| --- | --- |
| `analysis.ckd.json` | Settings, drawn geometry, reviews, results and versions |
| `original/` | The original RAW, unchanged |
| `runs/` | A small snapshot of the results of each run |
| `.cache/` | Rendered images on the Mac, rebuilt when needed |
| `.history/` | The last 20 versions, used by Undo and Restore |

To share an analysis, send its folder (Finder, AirDrop, Files) while nothing is processing, or send an export ZIP. The Mac and the iPad and iPhone app open each other's analyses. Only one app should edit a workspace at a time; avoid editing the same folder through cloud-synced or network folders at once.

## 4.2 Export ZIP

**Export ZIP** saves an archive where you choose, named after the analysis title and time. It contains:

- the original image, coordinates, the analysis and results, `results.csv` and an ROI overlay;
- tables 03 to 08: patch and ROI measurements, reservoirs, analytes, prediction and notes;
- `09_roi_results.csv` to `12_prediction_details.csv`: one row per ROI, per reservoir and per analyte, and the prediction details;
- with **Include debug images**, the rendered and white-balanced images;
- a manifest with every file's SHA-256 and the versions used.

Every CSV starts with the analysis ID, title and original filename.

## 4.3 Versions and Recompute

Results record the app, engine and equation versions. When an analysis was calculated with a different version, a banner shows **Calculated with CKD <version>**. **Differences** previews what would change and **Recompute** applies it; reservoirs whose value or status changes return to review. Results calculated on the other platform count as current when the engine, equations, Flower references and LibRaw versions match.

## 4.4 Troubleshooting

If the Mac app reports an engine problem, quit and reopen it. The engine log is at `~/Library/Logs/edu.northwestern.qsib.ckd-colorimetry/engine.log`; include it when reporting a problem.
