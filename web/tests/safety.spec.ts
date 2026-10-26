import { test, expect } from "@playwright/test";
import path from "node:path";

const fixtures = path.resolve("../api/tests/fixtures");

test("destructive edits confirm, undo restores results and conflicts can be discarded", async ({
  page,
}) => {
  const errors: string[] = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.goto("/");
  await page
    .getByLabel("RAW image file")
    .setInputFiles(path.join(fixtures, "_NOT_ACTUAL_TEST.dng"));
  await expect(
    page.getByRole("button", { name: "Draw white-balance area", exact: true }),
  ).toBeEnabled();
  const id = page.url().split("#")[1];
  await page
    .getByLabel("Coordinate package file")
    .setInputFiles(path.join(fixtures, "synthetic-flower-coordinates.json"));
  await page
    .getByRole("button", { name: "Apply white balance", exact: true })
    .click();
  await page.getByRole("button", { name: "Calibrate", exact: true }).click();
  await page.getByRole("button", { name: "Analyze ROIs", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Results & review" })).toBeVisible();

  await page
    .getByRole("navigation", { name: "Analysis steps" })
    .getByRole("button", { name: /Calibration/ })
    .click();
  const marker = page.getByLabel("Marker type");
  const mode = await marker.inputValue();
  await marker.selectOption("standard_24_grid");
  const dialog = page.getByRole("dialog", { name: "Change the marker type?" });
  await expect(dialog).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(dialog).toHaveCount(0);
  await expect(marker).toHaveValue(mode);

  await marker.selectOption("standard_24_grid");
  await page.getByRole("button", { name: "Change marker type", exact: true }).click();
  await expect
    .poll(async () => (await (await page.request.get(`/api/analyses/${id}`)).json()).results)
    .toBeNull();
  await page.getByRole("button", { name: "Undo", exact: true }).click();
  await expect(marker).toHaveValue(mode);
  await expect
    .poll(async () => {
      const doc = await (await page.request.get(`/api/analyses/${id}`)).json();
      return doc.results !== null && doc.calibration !== null;
    })
    .toBe(true);

  const reset = page.getByRole("button", { name: "Reset analysis", exact: true });
  await reset.click();
  const resetDialog = page.getByRole("dialog", { name: "Reset this analysis?" });
  await expect(resetDialog).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(resetDialog).toHaveCount(0);
  await reset.click();
  await resetDialog.getByRole("button", { name: "Reset analysis", exact: true }).click();
  await expect(page.getByRole("heading", { name: "White balance", exact: true })).toBeVisible();
  await expect
    .poll(async () => {
      const doc = await (await page.request.get(`/api/analyses/${id}`)).json();
      return [doc.white_balance, doc.calibration, doc.results, doc.draft.rois.length,
        doc.draft.white_balance.length, doc.draft.mode, doc.draft.reservoirs.length];
    })
    .toEqual([null, null, null, 0, 0, "flower_9_manual", 6]);
  await expect(reset).toBeDisabled();
  await page.getByRole("button", { name: "Undo", exact: true }).click();
  await expect
    .poll(async () => {
      const doc = await (await page.request.get(`/api/analyses/${id}`)).json();
      return doc.results !== null && doc.calibration !== null && doc.draft.rois.length > 0;
    })
    .toBe(true);

  await page.getByRole("button", { name: "Redraw white-balance area", exact: true }).click();
  await page
    .getByRole("dialog", { name: "Redraw the white-balance area?" })
    .getByRole("button", { name: "Redraw", exact: true })
    .click();
  await expect(page.getByText("Click two opposite corners · 0 of 2 placed")).toBeVisible();
  await expect
    .poll(async () => {
      const doc = await (await page.request.get(`/api/analyses/${id}`)).json();
      return [doc.draft.white_balance.length, doc.draft.corners.length, doc.draft.manual_patches.length,
        doc.white_balance, doc.calibration, doc.results, doc.draft.rois.length,
        doc.draft.reservoirs.some((r: { roi_ids: number[] }) => r.roi_ids.length)];
    })
    .toEqual([0, 0, 0, null, null, null, 0, false]);
  await page.getByRole("button", { name: "Cancel drawing", exact: true }).click();
  await page.getByRole("button", { name: "Undo", exact: true }).click();
  await expect
    .poll(async () => (await (await page.request.get(`/api/analyses/${id}`)).json()).results !== null)
    .toBe(true);

  const current = await (await page.request.get(`/api/analyses/${id}`)).json();
  await page.request.put(`/api/analyses/${id}`, {
    data: { revision: current.revision, draft: { ...current.draft, title: "Changed on disk" } },
  });
  await page.getByRole("button", { name: "Image", exact: true }).click();
  await page.getByLabel("Analysis name").fill("Edited here");
  await expect(page.getByRole("alert")).toContainText("changed on disk");
  await page.getByRole("button", { name: "Discard changes", exact: true }).click();
  await expect(page.getByLabel("Analysis name")).toHaveValue("Changed on disk");
  await expect(page.getByRole("alert")).toHaveCount(0);
  expect(errors).toEqual([]);
});
