import { expect, test } from "@playwright/test";

test("trade smoke path can offer an item and accept it", async ({ page }) => {
  await page.goto("/playwright/trade");

  await page.locator(".merchant-inventory-grid .inventory-slot").first().click();
  await page.locator('input[type="number"]').fill("2");
  await page.getByRole("button", { name: "Ofrecer" }).click();

  const offeredRow = page.locator(".trade-offer-grid .trade-row").filter({ hasText: "#101" }).first();
  await expect(offeredRow).toContainText("x2");

  await page.getByRole("button", { name: "Aceptar" }).click();
  await expect(page.getByTestId("playwright-trade-summary")).toContainText("accepted");
  await expect(page.getByTestId("trade-transcript")).toContainText("Accepted the local offer");
});
