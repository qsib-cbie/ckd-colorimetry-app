import { expect, test } from "@playwright/test";

test("appearance follows the system until light or dark is chosen", async ({ page }) => {
  await page.emulateMedia({ colorScheme: "light" });
  await page.goto("/");
  const html = page.locator("html");
  await page.getByRole("button", { name: "Settings", exact: true }).click();
  const appearance = page.getByRole("radiogroup", { name: "Appearance" });
  await expect(appearance.getByRole("radio", { name: "System" })).toHaveAttribute("aria-checked", "true");
  await expect(html).toHaveAttribute("data-theme", "light");

  await page.emulateMedia({ colorScheme: "dark" });
  await expect(html).toHaveAttribute("data-theme", "dark");
  const background = () => page.evaluate(() => getComputedStyle(document.documentElement).backgroundColor);
  expect(await background()).toBe("rgb(15, 20, 26)");
  await page.screenshot({ path: test.info().outputPath("settings-dark.png") });

  await appearance.getByRole("radio", { name: "Light" }).click();
  await expect(html).toHaveAttribute("data-theme", "light");
  expect(await background()).toBe("rgb(247, 249, 252)");
  await page.reload();
  await expect(html).toHaveAttribute("data-theme", "light");

  await page.emulateMedia({ colorScheme: "light" });
  await page.getByRole("button", { name: "Settings", exact: true }).click();
  await expect(appearance.getByRole("radio", { name: "Light" })).toHaveAttribute("aria-checked", "true");
  await appearance.getByRole("radio", { name: "Dark" }).click();
  await expect(html).toHaveAttribute("data-theme", "dark");
  await page.screenshot({ path: test.info().outputPath("settings-dark-chosen.png") });
  await appearance.getByRole("radio", { name: "System" }).click();
  await expect(html).toHaveAttribute("data-theme", "light");
});
