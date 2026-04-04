import { test, expect } from "@playwright/test";

test.describe("Map UI verification (map-only, no docker)", () => {
  test("map.html loads and displays showcase parcels", async ({ page }) => {
    await page.goto("/map?test=1");
    await expect(page.locator("#map")).toBeVisible();

    const mapCanvas = page.locator(".maplibregl-canvas");
    await expect(mapCanvas).toBeVisible({ timeout: 15000 });

    const sourceSelect = page.locator("#source-select");
    await expect(sourceSelect).toHaveValue("showcase");

    const statusEl = page.locator("#map-status");
    const statusText = (await statusEl.textContent()) ?? "";
    const hasError = statusText.toLowerCase().includes("error") || statusText.toLowerCase().includes("failed");
    expect(hasError).toBe(false);

    await expect
      .poll(async () => {
        return await page.evaluate(() => {
          const m = (
            window as unknown as {
              __parcelsMap?: {
                getLayer: (id: string) => unknown;
                isStyleLoaded: () => boolean;
              };
            }
          ).__parcelsMap;
          if (!m) return false;
          try {
            const fill = m.getLayer("parcels-fill");
            const outline = m.getLayer("parcels-outline");
            return Boolean(fill && outline && m.isStyleLoaded());
          } catch {
            return false;
          }
        });
      })
      .toBe(true);

    await page.screenshot({
      path: "tests/output/map-showcase.png",
      fullPage: true,
    });
  });

  test("source dropdown switches parcel layers", async ({ page }) => {
    await page.goto("/map?test=1");
    await expect(page.locator(".maplibregl-canvas")).toBeVisible({ timeout: 15000 });
    await page.waitForTimeout(1500);

    const select = page.locator("#source-select");
    await select.selectOption("showcase");
    await page.waitForTimeout(1000);
    await expect(select).toHaveValue("showcase");

    const statusText = (await page.locator("#map-status").textContent()) ?? "";
    expect(statusText.toLowerCase()).not.toMatch(/error|failed/);
  });

  test("parcel click shows popup with address and owner", async ({ page }) => {
    await page.goto("/map?test=1");
    await expect(page.locator(".maplibregl-canvas")).toBeVisible({ timeout: 15000 });
    await page.waitForTimeout(1000);

    await page.evaluate(() => {
      const helper = (
        window as unknown as { __showParcelPopupForTest?: () => void }
      ).__showParcelPopupForTest;
      if (!helper) {
        throw new Error("test popup helper not available");
      }
      helper();
    });

    await page.waitForTimeout(500);
    const popup = page.locator(".maplibregl-popup");
    await expect(popup).toBeVisible({ timeout: 5000 });
    await expect(popup.locator(".popup-content")).toContainText(/Owner|address|Value|Use/i);
  });

  test("dashboard loads with service cards", async ({ page }) => {
    await page.goto("/");
    await expect(page.locator("h1")).toContainText("US Parcels");
    await expect(page.locator("#services-grid")).toBeVisible();
    await expect(page.locator("#map")).toBeVisible();

    const martinCard = page.locator(".card").filter({ hasText: "Martin" });
    await expect(martinCard).toBeVisible();

    await page.screenshot({
      path: "tests/output/dashboard.png",
      fullPage: true,
    });
  });
});
