import { expect, test } from "@playwright/test";

test("landing page exposes the smoke routes", async ({ page }) => {
  await page.goto("/playwright");

  await expect(page.getByRole("heading", { name: "Browser smoke harness" })).toBeVisible();
  const nav = page.getByRole("navigation", { name: "Playwright smoke navigation" });
  await expect(nav.getByRole("link", { name: "Session + spellbook" })).toBeVisible();
  await expect(nav.getByRole("link", { name: "Trade" })).toBeVisible();
  await expect(nav.getByRole("link", { name: "Social" })).toBeVisible();
});
