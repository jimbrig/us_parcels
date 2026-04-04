import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  testDir: "./tests",
  fullyParallel: false,
  forbidOnly: !!process.env.CI,
  retries: 0,
  workers: 1,
  reporter: "list",
  use: {
    baseURL: "http://127.0.0.1:8080",
    trace: "on-first-retry",
    screenshot: "only-on-failure",
    video: "off",
  },
  projects: [
    { name: "chromium", use: { ...devices["Desktop Chrome"] }, testMatch: /map-proxy\.spec/ },
    {
      name: "map-only",
      use: {
        ...devices["Desktop Chrome"],
        baseURL: "http://127.0.0.1:8081",
      },
      testMatch: /map-visual\.spec/,
    },
    { name: "full", use: { ...devices["Desktop Chrome"] }, testMatch: /map-proxy\.spec|map-visual\.spec/, dependencies: [] },
  ],
  timeout: 30000,
  expect: { timeout: 10000 },
});
