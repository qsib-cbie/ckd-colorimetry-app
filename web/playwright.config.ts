import { defineConfig, devices } from "@playwright/test";
export default defineConfig({
  testDir: "tests",
  timeout: 180000,
  expect: { timeout: 30000 },
  fullyParallel: false,
  workers: 1,
  outputDir: process.env.CKD_TEST_ARTIFACTS || "/tmp/ckd-browser-tests",
  reporter: "list",
  use: {
    baseURL: process.env.CKD_BASE_URL || "http://127.0.0.1:8080",
    storageState: {
      cookies: [{ name: "ckd_desktop", value: process.env.CKD_TEST_TOKEN || "ckd-browser-test", domain: "127.0.0.1", path: "/", expires: -1, httpOnly: true, secure: false, sameSite: "Strict" }],
      origins: [],
    },
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
  },
  projects: [
    {
      name: "desktop-chromium",
      use: {
        ...devices["Desktop Chrome"],
        viewport: { width: 1440, height: 1000 },
      },
    },
    {
      name: "desktop-webkit",
      use: {
        ...devices["Desktop Safari"],
        viewport: { width: 1440, height: 1000 },
      },
    },
  ],
});
