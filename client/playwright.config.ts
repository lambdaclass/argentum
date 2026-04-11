import { defineConfig, devices } from "@playwright/test";

const baseURL = "http://127.0.0.1:4173";
const skipWebServer = process.env.PW_SKIP_WEBSERVER === "1";

export default defineConfig({
  testDir: "./tests/e2e",
  fullyParallel: true,
  reporter: process.env.CI ? [["dot"]] : [["list"]],
  timeout: 30_000,
  expect: {
    timeout: 5_000
  },
  use: {
    baseURL,
    trace: "on-first-retry"
  },
  webServer: skipWebServer
    ? undefined
    : {
        command: "npm run dev:ui",
        url: baseURL,
        reuseExistingServer: !process.env.CI,
        timeout: 120_000
      },
  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] }
    }
  ]
});
