import { test, expect } from "@playwright/test";
import path from "node:path";

const fixture = path.resolve("../api/tests/fixtures/_NOT_ACTUAL_TEST.dng");

test("local folders, offline autosave, rename, move, reopen and Trash", async ({
  page,
}) => {
  const errors: string[] = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.goto("/");
  await expect(
    page.getByRole("heading", { name: "Start with the original image." }),
  ).toBeVisible();
  await page
    .getByRole("button", { name: "Equations and versions", exact: true })
    .click();
  await expect(
    page.getByRole("heading", { name: "Equations and versions", exact: true }),
  ).toBeVisible();
  await expect(page.getByText(/Predicted G3\+ when p ≥ 0\.305/)).toBeVisible();
  await expect(page.getByText(/a\*b\* only \(2026-10-12\)/)).toBeVisible();
  await page.getByRole("button", { name: "Back", exact: true }).click();
  await expect(
    page.getByRole("heading", { name: "Start with the original image." }),
  ).toBeVisible();
  await page.getByRole("button", { name: "Settings", exact: true }).click();
  await expect(
    page.getByRole("heading", { name: "Settings", exact: true }),
  ).toBeVisible();
  await expect(
    page.getByLabel("Include debug images in new exports by default"),
  ).toBeChecked();
  await page.getByRole("button", { name: "Settings", exact: true }).click();
  await expect(
    page.getByRole("heading", { name: "Start with the original image." }),
  ).toBeVisible();
  const toggle = page.getByRole("button", { name: "Toggle sidebar" });
  await toggle.click();
  await expect(page.locator("#library-sidebar")).toBeHidden();
  await expect(toggle).toHaveAttribute("aria-expanded", "false");
  await page.keyboard.press("ControlOrMeta+Backslash");
  await expect(page.locator("#library-sidebar")).toBeVisible();
  const folder = `Experiment ${Date.now()}`;
  const title = `Offline save ${Date.now()}`;
  const renamed = `Renamed sample ${Date.now()}`;
  await page
    .getByRole("button", { name: "Create folder", exact: true })
    .click();
  await page.getByLabel("New folder name").fill(folder);
  await page.keyboard.press("Enter");
  await expect(
    page.getByRole("button", { name: `Options for ${folder}`, exact: true }),
  ).toBeVisible();
  await page.getByLabel("RAW image file").setInputFiles(fixture);
  await expect(
    page.getByRole("button", { name: "Draw white-balance area", exact: true }),
  ).toBeEnabled();
  const id = page.url().split("#")[1];
  const document = await (await page.request.get(`/api/analyses/${id}`)).json();
  expect(document.project_path).toContain(`${folder}/`);
  await page.evaluate(() => {
    Object.defineProperty(navigator, "onLine", {
      get: () => false,
      configurable: true,
    });
    window.dispatchEvent(new Event("offline"));
  });
  await page.getByRole("button", { name: "Image", exact: true }).click();
  await page.getByLabel("Analysis name").fill(title);
  await expect
    .poll(
      async () =>
        (await (await page.request.get(`/api/analyses/${id}`)).json()).draft
          .title,
    )
    .toBe(title);
  await page
    .getByRole("button", { name: `Options for ${title}`, exact: true })
    .click();
  await page.getByRole("menuitem", { name: "Rename…" }).click();
  await page.getByLabel(`Rename ${title}`).fill(renamed);
  await page.keyboard.press("Enter");
  await expect.poll(() => page.url().split("#")[1]).not.toBe(id);
  await expect(page.locator(".header-title")).toHaveText(renamed);
  const renamedId = page.url().split("#")[1];
  await page
    .getByRole("button", { name: `Options for ${renamed}`, exact: true })
    .click();
  await page.getByRole("menuitem", { name: "Move to…" }).click();
  await page.getByRole("menuitem", { name: "Workspace folder" }).click();
  await expect.poll(() => page.url().split("#")[1]).not.toBe(renamedId);
  const movedId = page.url().split("#")[1];
  const moved = await (
    await page.request.get(`/api/analyses/${movedId}`)
  ).json();
  expect(moved.project_path).toBe(renamed);
  expect(moved.draft.title).toBe(renamed);
  expect(moved.analysis_id).toBe(document.analysis_id);
  await page.reload();
  await expect(page.locator(".header-title")).toHaveText(renamed);
  await page
    .getByRole("button", { name: renamed, exact: true })
    .click({ button: "right" });
  await page.getByRole("menuitem", { name: "Duplicate" }).click();
  await expect(page.locator(".header-title")).toHaveText(`${renamed} copy`);
  const copyId = page.url().split("#")[1];
  await page
    .getByRole("button", { name: `${renamed} copy`, exact: true })
    .dragTo(page.getByRole("button", { name: folder, exact: true }));
  await expect.poll(() => page.url().split("#")[1]).not.toBe(copyId);
  const dropped = await (
    await page.request.get(`/api/analyses/${page.url().split("#")[1]}`)
  ).json();
  expect(dropped.project_path).toBe(`${folder}/${renamed} copy`);
  await expect(page.locator(".header-title")).toHaveText(`${renamed} copy`);
  const copy = await (
    await page.request.get(`/api/analyses/${page.url().split("#")[1]}`)
  ).json();
  expect(copy.analysis_id).not.toBe(document.analysis_id);
  expect(copy.copied_from.analysis_id).toBe(document.analysis_id);
  await page.getByRole("button", { name: renamed, exact: true }).click();
  await expect(page.locator(".header-title")).toHaveText(renamed);
  await page
    .getByRole("button", { name: `Options for ${folder}`, exact: true })
    .click();
  await page.getByRole("menuitem", { name: "Move to Trash…" }).click();
  await page
    .getByRole("dialog")
    .getByRole("button", { name: "Move to Trash", exact: true })
    .click();
  await expect(page.getByRole("dialog")).toHaveCount(0);
  await expect(
    page.getByRole("button", { name: `Options for ${folder}`, exact: true }),
  ).toHaveCount(0);
  await expect(page.locator(".header-title")).toHaveText(renamed);
  const current = await (await page.request.get("/api/workspace")).json();
  const workspace = await (
    await page.request.post("/api/workspace", { data: { path: current.root } })
  ).json();
  await page.getByRole("button", { name: "Open workspace", exact: true }).click();
  const recent = page.locator(".recent-workspaces li").first();
  await expect(recent.locator(".recent-name")).toHaveText(
    workspace.root.split("/").pop(),
  );
  await expect(recent.locator(".recent-path")).toContainText(
    workspace.root.startsWith(`${workspace.home}/`)
      ? `~${workspace.root.slice(workspace.home.length)}`
      : workspace.root,
  );
  await page
    .getByRole("button", { name: "Return to current workspace", exact: true })
    .click();
  await page.screenshot({
    path: "/tmp/ckd-desktop-folders.png",
    fullPage: true,
  });
  expect(errors).toEqual([]);
});
