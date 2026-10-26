import { test, expect } from "@playwright/test";
import fs from "node:fs";
import path from "node:path";
import type { Page } from "@playwright/test";

const fixtures = path.resolve("../api/tests/fixtures");

async function checkNoOverflow(page: Page) {
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= window.innerWidth,
    ),
  ).toBeTruthy();
}

test("RAW image, imported geometry, WB, calibration, results, export and reopen", async ({
  page,
}, testInfo) => {
  const errors: string[] = [];
  page.on("pageerror", (e) => errors.push(e.message));
  page.on("console", (msg) => {
    if (msg.type() === "error") errors.push(msg.text());
  });
  await page.goto("/");
  await expect(page).toHaveTitle("CKD Colorimetry");
  await expect(
    page.getByRole("heading", { name: "Start with the original image." }),
  ).toBeVisible();
  await checkNoOverflow(page);
  await page.screenshot({
    path: `/tmp/ckd-${testInfo.project.name}-start.png`,
    fullPage: true,
  });
  await page
    .getByLabel("RAW image file")
    .setInputFiles(path.join(fixtures, "iPhoneRAW.DNG"));
  await expect(
    page.getByRole("button", { name: "Draw white-balance area", exact: true }),
  ).toBeEnabled();
  const id = page.url().split("#")[1];
  const ref = JSON.parse(
    fs.readFileSync(
      path.join(fixtures, "iPhoneRAW.DNG_full_color_analyzed_run.json"),
      "utf8",
    ),
  );
  const valid = ref.roi_measurements.filter(
    (r: any) => r.lab_stats && r.geometry,
  );
  const coordinates = {
    schema_name: "qdaq_ckd_coordinate_package",
    schema_version: 2,
    coordinate_system: "top_left_image_pixels",
    source_image_sha256: ref.source_image.sha256,
    image_dimensions: ref.source_image.dimensions,
    calibration_marker_kind: "standard_24",
    calibration_mode: "standard_24_grid",
    white_balance_polygon: { points: ref.white_balance.manual_wb_polygon },
    color_calibration_corners: Object.values(ref.color_checker.corners),
    reservoirs: [],
    rois: valid.map((r: any, i: number) => ({
      roi_id: i + 1,
      roi_label: `ROI ${i + 1}`,
      polygon: { points: r.geometry.polygon },
    })),
  };
  await page
    .getByLabel("Coordinate package file")
    .setInputFiles({
      name: "coordinates.json",
      mimeType: "application/json",
      buffer: Buffer.from(JSON.stringify(coordinates)),
    });
  await expect(
    page.getByText(
      "Coordinates imported. Apply white balance, then calibrate and analyze.",
    ),
  ).toBeVisible();
  await page
    .getByRole("button", { name: "Apply white balance", exact: true })
    .click();
  await expect(
    page.getByRole("heading", { name: "Calibration", exact: true }),
  ).toBeVisible();
  await expect(page.getByLabel("Marker type")).toHaveValue("standard_24_grid");
  await page.getByRole("button", { name: "Calibrate", exact: true }).click();
  await expect(
    page.getByRole("heading", { name: "Reservoirs", exact: true }),
  ).toBeVisible();
  await expect(page.getByLabel("Active reservoir")).toHaveCount(0);
  await page.getByRole("button", { name: "Add reservoir", exact: true }).click();
  await page.getByLabel("Assign ROI 1", { exact: true }).selectOption("1");
  await page.getByLabel("Reservoir analyte").selectOption("ph");
  await page.getByRole("button", { name: "Analyze ROIs", exact: true }).click();
  await expect(
    page.getByRole("heading", { name: "Results & review" }),
  ).toBeVisible();
  await expect(page.getByLabel("Review reservoir 1", { exact: true })).toBeEnabled();
  await expect(page.getByText(/^Outside calibration range \(a\)$/).first()).toBeVisible();
  await expect(page.getByLabel("Age (years)", { exact: true })).toBeVisible();
  await expect(page.getByRole("row")).toHaveCount(valid.length + 1);
  const download = page.waitForEvent("download");
  await page.getByRole("link", { name: "Export ZIP" }).click();
  expect((await download).suggestedFilename()).toMatch(
    /^iPhoneRAW_\d{4}-\d{2}-\d{2}_\d{6}\.zip$/,
  );
  await page.reload();
  await expect(
    page.getByRole("heading", { name: "Results & review" }),
  ).toBeVisible();
  expect(page.url()).toContain(`#${id}`);
  await checkNoOverflow(page);
  await page.screenshot({
    path: `/tmp/ckd-${testInfo.project.name}-results.png`,
    fullPage: true,
  });
  await expect(page.getByRole("button", { name: "Analyses", exact: true })).toHaveCount(0);
  expect(errors).toEqual([]);
});

test("Flower concentrations, demographic prediction, review invalidation and canvas drawing", async ({
  page,
}, testInfo) => {
  const errors: string[] = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.goto("/");
  await page
    .getByLabel("RAW image file")
    .setInputFiles(path.join(fixtures, "_NOT_ACTUAL_TEST.dng"));
  await expect(
    page.getByRole("button", { name: "Draw white-balance area", exact: true }),
  ).toBeEnabled();
  await page
    .getByLabel("Coordinate package file")
    .setInputFiles(path.join(fixtures, "synthetic-flower-coordinates.json"));
  await expect(
    page.getByText(
      "Coordinates imported. Apply white balance, then calibrate and analyze.",
    ),
  ).toBeVisible();
  await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
  await page.keyboard.press("Enter");
  await expect(
    page.getByRole("heading", { name: "Calibration", exact: true }),
  ).toBeVisible();
  await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
  await page.keyboard.press("Enter");
  await expect(
    page.getByRole("heading", { name: "Reservoirs", exact: true }),
  ).toBeVisible();
  await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
  await page.keyboard.press("Enter");
  const calibrated = await (
    await page.request.get(`/api/analyses/${page.url().split("#")[1]}`)
  ).json();
  expect(calibrated.job.action).toBe("calibrate");
  await page.getByRole("button", { name: "Analyze ROIs", exact: true }).click();
  await expect(
    page.getByRole("heading", { name: "Results & review" }),
  ).toBeVisible();
  await expect(
    page.getByText("automatically included", { exact: true }),
  ).toHaveCount(3);
  await page
    .locator(".workspace")
    .evaluate((main) => main.scrollTo(0, main.scrollHeight));
  await expect(
    page.getByRole("button", { name: "Equations and versions", exact: true }),
  ).toBeInViewport();
  await expect(page.getByRole("button", { name: "Settings", exact: true })).toBeInViewport();
  await page.getByLabel("Age (years)", { exact: true }).fill("50");
  await page.getByLabel("Sex used by research model").selectOption("female");
  await expect(
    page.getByRole("heading", { name: "Predicted G3+", exact: true }),
  ).toBeVisible();
  await expect(
    page.getByText("Model: Urea + creatinine + age + sex (chosen automatically)"),
  ).toBeVisible();
  await page
    .getByLabel("Review reservoir 1", { exact: true })
    .selectOption("excluded");
  await expect(
    page.getByText("Model: Creatinine + age + sex (chosen automatically)"),
  ).toBeVisible();
  await expect(page.getByText(/Threshold 57\.9% · AUC 0\.923/)).toBeVisible();
  await page.getByLabel("Prediction model").selectOption("full");
  await expect(
    page.getByRole("heading", {
      name: "Prediction not calculated",
      exact: true,
    }),
  ).toBeVisible();
  await page.getByLabel("Prediction model").selectOption("");
  await expect(page.locator(".summary-card .not-final").first()).toBeVisible();
  await expect(page.getByText("Not final").first()).toBeVisible();
  await page
    .getByLabel("Review reservoir 1", { exact: true })
    .selectOption("included");
  await expect(
    page.getByRole("heading", { name: "Predicted G3+", exact: true }),
  ).toBeVisible();
  const ureaModel = page.getByLabel("Urea pH model");
  await expect(ureaModel.locator("option").first()).toHaveText(
    /Automatic \(nearest to measured pH: \d\.\d\)/,
  );
  await ureaModel.selectOption("pH_7.0");
  await expect
    .poll(async () => {
      const doc = await (
        await page.request.get(`/api/analyses/${page.url().split("#")[1]}`)
      ).json();
      return doc.results?.urea_ph_model?.source;
    })
    .toBe("manual");
  await ureaModel.selectOption("");
  const ureaCalibration = page.getByLabel("Urea calibration");
  await expect(ureaCalibration).toHaveValue("lab");
  await ureaCalibration.selectOption("ab");
  await expect
    .poll(async () => {
      const doc = await (
        await page.request.get(`/api/analyses/${page.url().split("#")[1]}`)
      ).json();
      return doc.results?.urea_calibration;
    })
    .toBe("ab");
  await ureaCalibration.selectOption("lab");
  await expect
    .poll(async () => {
      const doc = await (
        await page.request.get(`/api/analyses/${page.url().split("#")[1]}`)
      ).json();
      return doc.results?.urea_ph_model?.source;
    })
    .not.toBe("manual");
  await page
    .getByRole("navigation", { name: "Analysis steps" })
    .getByRole("button", { name: /Reservoirs/ })
    .click();
  await page.getByLabel("Active reservoir").selectOption("1");
  await expect(page.getByLabel("Reservoir analyte")).not.toHaveValue("urea");
  await expect(page.getByLabel("Urea pH model")).toHaveCount(0);
  const ureaReservoir = await page.evaluate(async (id) => {
    const doc = await (await fetch(`/api/analyses/${id}`)).json();
    return String(doc.draft.reservoirs.find((r: { analyte: string }) => r.analyte === "urea").id);
  }, page.url().split("#")[1]);
  await page.getByLabel("Active reservoir").selectOption(ureaReservoir);
  await expect(page.getByLabel("Urea calibration")).toHaveCount(0);
  await expect(page.getByLabel("Urea pH model")).toHaveCount(0);
  await page.getByLabel("Active reservoir").selectOption("4");
  const canvas = page.getByTestId("canvas-surface");
  const box = await canvas.boundingBox();
  expect(box).not.toBeNull();
  const click = (fx: number, fy: number) =>
    page.mouse.click(box!.x + box!.width * fx, box!.y + box!.height * fy);
  const drawRoi = async (dy: number) => {
    await page
      .getByRole("button", { name: "Add ROI", exact: true })
      .click();
    await click(0.48, 0.45 + dy);
    await expect(
      page.getByText("Click two opposite corners · 1 of 2 placed"),
    ).toBeVisible();
    await click(0.53, 0.5 + dy);
  };
  const removeRoi = (id: number) =>
    page.getByRole("button", { name: `Remove ROI ${id}`, exact: true });
  await drawRoi(0);
  await expect(removeRoi(4)).toBeVisible();
  await expect(page.getByText("4 vertices").first()).toBeVisible();
  await expect(page.getByText("Click two opposite corners · 0 of 2 placed")).toBeVisible();
  await page
    .getByRole("button", { name: "Add ROI", exact: true })
    .click();
  await click(0.48, 0.45);
  await page.keyboard.press("ControlOrMeta+z");
  await expect(page.getByText("Click two opposite corners · 0 of 2 placed")).toBeVisible();
  await expect(removeRoi(4)).toBeVisible();
  await click(0.48, 0.45);
  await expect(page.getByText("Click two opposite corners · 1 of 2 placed")).toBeVisible();
  await page.keyboard.down("Space");
  await page.mouse.move(box!.x + box!.width * 0.6, box!.y + box!.height * 0.6);
  await page.mouse.down();
  await page.mouse.move(box!.x + box!.width * 0.65, box!.y + box!.height * 0.65, { steps: 5 });
  await page.mouse.up();
  await page.keyboard.up("Space");
  await expect(page.getByText("Click two opposite corners · 0 of 2 placed")).toBeVisible();
  await page.getByRole("button", { name: "Fit", exact: true }).click();
  await page.keyboard.press("ControlOrMeta+z");
  await expect(removeRoi(4)).toHaveCount(0);
  await page.keyboard.press("ControlOrMeta+Shift+z");
  await expect(removeRoi(4)).toBeVisible();
  await page.getByRole("button", { name: "Add ROI", exact: true }).click();
  await page.getByRole("button", { name: "Undo", exact: true }).click();
  await expect(removeRoi(4)).toHaveCount(0);
  await page.getByRole("button", { name: "Redo", exact: true }).click();
  await expect(removeRoi(4)).toBeVisible();
  const activeReservoir = page.getByLabel("Active reservoir");
  const before = await activeReservoir.inputValue();
  await activeReservoir.selectOption("add");
  const added = await activeReservoir.inputValue();
  await drawRoi(0.3);
  await expect(removeRoi(5)).toBeVisible();
  await page.getByRole("button", { name: `Remove reservoir ${added}`, exact: true }).click();
  await page.getByRole("dialog").getByRole("button", { name: "Remove reservoir", exact: true }).click();
  await expect(removeRoi(5)).toHaveCount(0);
  await expect(activeReservoir.locator(`option[value="${added}"]`)).toHaveCount(0);
  await activeReservoir.selectOption(before);
  await expect(removeRoi(4)).toBeVisible();
  await page.getByRole("button", { name: "Shortcuts", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Shortcuts", exact: true })).toBeVisible();
  await expect(page.getByText("Show or hide the sidebar")).toBeVisible();
  await page.getByRole("button", { name: "Shortcuts", exact: true }).click();
  await page.getByRole("button", { name: "Polygon", exact: true }).click();
  await expect(page.getByText(/Polygon for this analysis only/)).toBeVisible();
  await expect(page.getByRole("button", { name: "Open Settings", exact: true })).toBeVisible();
  await page
    .getByRole("button", { name: "Add ROI", exact: true })
    .click();
  for (const [fx, fy] of [
    [0.48, 0.53],
    [0.53, 0.53],
    [0.55, 0.56],
    [0.53, 0.58],
    [0.48, 0.58],
  ])
    await click(fx, fy);
  await expect(page.getByText("Click to add vertices · 5 placed")).toBeVisible();
  await page.keyboard.press("Enter");
  await expect(page.getByText("5 vertices")).toBeVisible();
  await removeRoi(5).click();
  for (const [fx, fy] of [
    [0.48, 0.53],
    [0.53, 0.53],
    [0.5, 0.58],
    [0.48, 0.53],
  ])
    await click(fx, fy);
  await expect(page.getByText("3 vertices")).toBeVisible();
  await removeRoi(5).click();
  await page.getByRole("button", { name: "Rectangle · 2 clicks", exact: true }).click();
  await expect(page.getByText(/for this analysis only/)).toHaveCount(0);
  await expect(page.locator(".canvas-context")).toContainText("Reservoir");
  await page.keyboard.press("t");
  await expect(page.getByRole("button", { name: "Polygon", exact: true })).toHaveAttribute("aria-pressed", "true");
  await page.keyboard.press("t");
  await expect(page.getByRole("button", { name: "Rectangle · 2 clicks", exact: true })).toHaveAttribute("aria-pressed", "true");
  await expect(page.getByText(/for this analysis only/)).toHaveCount(0);
  await drawRoi(0.08);
  await expect(removeRoi(5)).toBeVisible();
  const settingsLink = page.getByRole("button", { name: "Settings", exact: true });
  const defaultShape = page.getByRole("radiogroup", { name: "Default drawing shape" });
  await settingsLink.click();
  await defaultShape.getByRole("radio", { name: "Polygon" }).click();
  await expect(defaultShape.getByRole("radio", { name: "Polygon" })).toHaveAttribute("aria-checked", "true");
  await settingsLink.click();
  await expect(page.getByRole("button", { name: "Polygon", exact: true })).toHaveAttribute("aria-pressed", "true");
  await expect(page.getByText(/for this analysis only/)).toHaveCount(0);
  await settingsLink.click();
  await defaultShape.getByRole("radio", { name: "Rectangle · 2 clicks" }).click();
  await settingsLink.click();
  await expect(page.getByRole("button", { name: "Rectangle · 2 clicks", exact: true })).toHaveAttribute("aria-pressed", "true");
  await removeRoi(4).click();
  await expect(removeRoi(4)).toHaveCount(0);
  await drawRoi(0);
  await expect(removeRoi(4)).toBeVisible();
  await expect(removeRoi(5)).toBeVisible();
  await page.getByLabel("Reservoir analyte").selectOption("urea");
  await expect(page.getByLabel("Active reservoir")).toHaveValue("4");
  await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
  await page.keyboard.press("n");
  await expect(page.getByLabel("Active reservoir")).toHaveValue("5");
  await page.getByLabel("Active reservoir").selectOption("add");
  await expect(page.getByLabel("Active reservoir")).toHaveValue("7");
  await drawRoi(0.16);
  await page.getByLabel("Reservoir analyte").selectOption("urea");
  await page.getByLabel("Active reservoir").selectOption("add");
  await expect(page.getByLabel("Active reservoir")).toHaveValue("8");
  await drawRoi(0.24);
  await page.getByLabel("Custom biomarker", { exact: true }).fill("Lactate");
  await expect(page.getByLabel("Reservoir analyte")).toHaveValue("custom");
  await page.getByLabel("Notes", { exact: true }).fill("10 mM");
  await expect(page.getByLabel("Replicate", { exact: true })).toHaveCount(0);
  await expect(page.getByLabel("Active reservoir")).toHaveValue("8");
  await page.getByRole("button", { name: "Analyze ROIs", exact: true }).click();
  await expect(
    page.getByRole("heading", { name: "Results & review" }),
  ).toBeVisible();
  await expect(page.getByLabel("Review reservoir 7", { exact: true })).toBeVisible();
  const phCard = page.locator(".review-card").first();
  await expect(phCard.locator(".result-value")).toContainText("±");
  await expect(phCard.getByText(/SD from the ROI's pixel color spread/)).toBeVisible();
  const ureaSummary = page.locator(".summary-card", { hasText: "Urea" });
  await expect(ureaSummary.getByText(/^Mean of \d reservoirs, range/)).toBeVisible();
  await expect(ureaSummary.locator(".summary-values li").first()).toContainText("Reservoir 2");
  await expect(phCard.getByText("In average", { exact: true })).toBeVisible();
  const lactate = page.locator(".review-card", { hasText: "Lactate" });
  await expect(lactate.getByText("10 mM", { exact: true })).toBeVisible();
  await expect(lactate.getByText(/No calibration equation/)).toBeVisible();
  await expect(page.getByLabel("Review reservoir 8", { exact: true })).toHaveCount(0);
  await expect(
    page.getByText(/SD across 2 ROIs|2 ROIs; an SD needs/),
  ).toBeVisible();
  await page
    .getByRole("navigation", { name: "Analysis steps" })
    .getByRole("button", { name: /Calibration/ })
    .click();
  await page.getByRole("button", { name: "Fit", exact: true }).click();
  await page.getByRole("button", { name: "Zoom in", exact: true }).click();
  const zoom = await page.locator(".zoom-controls span").innerText();
  await page.getByRole("button", { name: "Redraw marker boundary", exact: true }).click();
  await page
    .getByRole("dialog", { name: "Redraw the marker boundary?" })
    .getByRole("button", { name: "Redraw", exact: true })
    .click();
  await expect(page.getByText("Click two opposite corners · 0 of 2 placed")).toBeVisible();
  await expect
    .poll(async () => (await (await page.request.get(`/api/analyses/${page.url().split("#")[1]}`)).json()).draft.rois.length)
    .toBe(0);
  await expect(page.locator(".zoom-controls span")).toHaveText(zoom);
  await page.keyboard.press("p");
  await expect(page.getByRole("button", { name: "Pan", exact: true })).toHaveAttribute("aria-pressed", "true");
  await page.keyboard.press("d");
  await expect(page.getByRole("button", { name: "Draw", exact: true })).toHaveAttribute("aria-pressed", "true");
  await page.getByRole("button", { name: "Cancel drawing", exact: true }).click();
  await expect(page.locator(".zoom-controls span")).toHaveText(zoom);
  await page.getByRole("button", { name: "Undo", exact: true }).click();
  await expect
    .poll(async () => {
      const doc = await (await page.request.get(`/api/analyses/${page.url().split("#")[1]}`)).json();
      return doc.draft.corners.length === 4 && doc.calibration !== null && doc.results !== null && doc.draft.rois.length > 0;
    })
    .toBe(true);
  await page
    .getByRole("navigation", { name: "Analysis steps" })
    .getByRole("button", { name: /White balance/ })
    .click();
  await page.getByRole("button", { name: "Redraw white-balance area", exact: true }).click();
  await expect(page.getByRole("dialog", { name: "Redraw the white-balance area?" })).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(page.getByText(/Click two opposite corners/)).toHaveCount(0);
  await checkNoOverflow(page);
  await page.screenshot({
    path: `/tmp/ckd-${testInfo.project.name}-editor.png`,
    fullPage: true,
  });
  const workspace = await (await page.request.get("/api/workspace")).json();
  const current = await (
    await page.request.get(`/api/analyses/${page.url().split("#")[1]}`)
  ).json();
  const file = path.join(workspace.root, current.project_path, "analysis.ckd.json");
  const saved = JSON.parse(fs.readFileSync(file, "utf8"));
  saved.results.versions.configuration = "older_equations";
  fs.writeFileSync(file, JSON.stringify(saved, null, 2));
  await page.reload();
  await expect(page.getByText(/Calculated with CKD/)).toBeVisible();
  await expect(page.getByLabel("Review reservoir 1", { exact: true })).toBeDisabled();
  await page.getByRole("button", { name: "Differences", exact: true }).click();
  await expect(
    page.getByRole("heading", { name: "Differences", exact: true }),
  ).toBeVisible();
  await expect(page.getByRole("cell", { name: "older_equations" })).toBeVisible();
  await page.getByRole("button", { name: "Recompute", exact: true }).click();
  await expect(
    page.getByRole("heading", { name: "Results & review" }),
  ).toBeVisible();
  await expect(page.getByText(/Calculated with CKD/)).toHaveCount(0);
  await expect(page.getByLabel("Review reservoir 1", { exact: true })).toBeEnabled();
  const recomputed = JSON.parse(fs.readFileSync(file, "utf8"));
  for (const key of ["python", "rawpy", "numpy", "scikit_image"]) delete recomputed.results.versions[key];
  recomputed.results.versions.platform = "ios";
  fs.writeFileSync(file, JSON.stringify(recomputed, null, 2));
  await page.reload();
  await expect(page.getByText(/Calculated on iPad or iPhone with CKD/)).toBeVisible();
  await expect(page.getByLabel("Review reservoir 1", { exact: true })).toBeEnabled();
  await page.getByRole("button", { name: "Differences", exact: true }).click();
  await expect(page.getByRole("cell", { name: "Not used on iPad or iPhone" }).first()).toBeVisible();
  expect(errors).toEqual([]);
});

test("invalid RAW errors are visible and can be retried", async ({ page }) => {
  await page.goto("/");
  await page
    .getByLabel("RAW image file")
    .setInputFiles({
      name: "bad.dng",
      mimeType: "application/octet-stream",
      buffer: Buffer.from("not raw"),
    });
  await expect(page.getByRole("alert")).toBeVisible();
  await expect(
    page.getByRole("button", { name: "Retry rendering" }),
  ).toBeEnabled();
  await page.getByRole("button", { name: "Retry rendering" }).click();
  await expect(page.getByRole("alert")).toBeVisible();
  await expect(
    page.getByRole("button", { name: "Retry rendering" }),
  ).toBeEnabled();
});

test("Standard 24 marker takes a two-click rectangle and keeps six reservoirs", async ({ page }) => {
  await page.goto("/");
  await page.getByLabel("RAW image file").setInputFiles(path.join(fixtures, "iPhoneRAW.DNG"));
  await expect(page.getByRole("button", { name: "Draw white-balance area", exact: true })).toBeEnabled();
  const id = page.url().split("#")[1];
  await page
    .getByRole("navigation", { name: "Analysis steps" })
    .getByRole("button", { name: /Calibration/ })
    .click();
  const marker = page.getByLabel("Marker type");
  await expect(marker.locator('option[value="flower_9"]')).toHaveCount(0);
  await marker.selectOption("standard_24_grid");
  await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
  await page.keyboard.press("d");
  await expect(page.getByText("Click two opposite corners · 0 of 2 placed")).toBeVisible();
  const box = (await page.getByTestId("canvas-surface").boundingBox())!;
  await page.mouse.click(box.x + box.width * 0.3, box.y + box.height * 0.3);
  await page.mouse.click(box.x + box.width * 0.6, box.y + box.height * 0.6);
  await expect
    .poll(async () => {
      const doc = await (await page.request.get(`/api/analyses/${id}`)).json();
      return [doc.draft.mode, doc.draft.corners.length, doc.draft.reservoirs.length];
    })
    .toEqual(["standard_24_grid", 4, 6]);
  const redraw = page.getByRole("button", { name: "Redraw marker boundary", exact: true });
  await expect(redraw).toBeVisible();
  await redraw.click();
  await expect(page.getByText("Click two opposite corners · 0 of 2 placed")).toBeVisible();
  await expect
    .poll(async () => (await (await page.request.get(`/api/analyses/${id}`)).json()).draft.corners.length)
    .toBe(0);
});
