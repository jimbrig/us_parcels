import { test, expect } from "@playwright/test";

test.describe("Proxy endpoints (requires full docker stack)", () => {
  test("Martin catalog is reachable via proxy", async ({ page }) => {
    const res = await page.goto("/tiles/catalog");
    expect(res?.status()).toBe(200);
    const body = await res?.json();
    expect(body).toBeDefined();
  });

  test("pg_featureserv collections reachable via proxy", async ({
    page,
  }) => {
    const res = await page.goto("/features/collections.json");
    expect(res?.status()).toBe(200);
    const body = await res?.json();
    expect(body?.collections).toBeDefined();
  });

  test("pg_tileserv index reachable via proxy", async ({ page }) => {
    const res = await page.goto("/tileserv/index.json");
    expect(res?.status()).toBe(200);
    const body = await res?.json();
    expect(body).toBeDefined();
  });

  test("Maputnik loads via proxy", async ({ page }) => {
    const res = await page.goto("/maputnik/");
    expect(res?.status()).toBe(200);
  });
});
