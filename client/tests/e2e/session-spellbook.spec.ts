import { expect, test } from "@playwright/test";

test("session smoke path can connect and cast a spell", async ({ page }) => {
  await page.goto("/playwright/session");

  await page.getByLabel("Account or Character Name").fill("Rook");
  await page.getByLabel("Password").fill("delta");
  await page.getByRole("button", { name: "Entrar" }).click();

  await expect(page.getByRole("heading", { name: "Sesion activa" })).toBeVisible();
  await expect(page.getByTestId("playwright-connection-state")).toHaveText("connected");
  await expect(page.getByTestId("playwright-session-summary")).toContainText("Playwright Harbor");

  const spellRow = page
    .locator(".spellbook-list .spellbook-row")
    .filter({ hasText: "Dardo Mágico" })
    .first();
  await spellRow.click();

  const hotkeyOne = page.locator(".spellbook-hotkey-button").first();
  await hotkeyOne.click();
  await expect(hotkeyOne).toContainText("Dardo Mágico");

  await page.getByRole("button", { name: "Lanzar" }).click();
  await expect(page.getByTestId("playwright-last-cast")).toHaveText(/Dardo Mágico/);
  await expect(page.getByTestId("session-transcript")).toContainText("Cast Dardo Mágico");
});
