import { expect, test } from "@playwright/test";

test("dead state disables obvious combat and inventory actions", async ({ page }) => {
  await page.goto("/?demo=1&demoState=dead");
  await page.getByRole("button", { name: "HUD" }).click();

  await expect(page.getByTestId("world-overlay-state")).toHaveCount(0);
  await expect(page.getByTestId("hud-dead-banner")).toHaveCount(0);
  await expect(page.getByTestId("character-dead-callout")).toHaveCount(0);

  await expect(page.getByRole("button", { name: "Atacar" })).toBeDisabled();
  await expect(page.getByRole("button", { name: "Comercio" })).toBeDisabled();
  await expect(page.getByRole("button", { name: "Banco" })).toBeDisabled();
  await expect(page.getByRole("button", { name: "Seguro OFF" })).toBeDisabled();

  await page.getByRole("button", { name: "Hechizos" }).click();
  await expect(page.getByTestId("spellbook-panel")).toContainText("Detectar Invisibilidad");
  await expect(page.getByRole("button", { name: "Lanzar" })).toBeDisabled();
});

test("reconnect and loading overlays stay explicit", async ({ page }) => {
  await page.goto("/?demo=1&demoState=reconnect");
  await page.getByRole("button", { name: "Sesion" }).click();
  await expect(page.getByRole("heading", { name: "Reconectar" })).toBeVisible();
  await expect(page.getByText("Saved reconnect ready")).toBeVisible();

  await page.goto("/?demo=1&demoState=map-loading");
  await expect(page.getByTestId("world-overlay-state")).toContainText("Loading Map");
});

for (const [scenario, title] of [
  ["error-banned", "Account banned"],
  ["error-muted", "Chat muted"],
  ["error-server-full", "Server full"],
  ["error-maintenance", "Maintenance mode"],
  ["error-token-expired", "Session expired"]
] as const) {
  test(`session errors are classified explicitly: ${scenario}`, async ({ page }) => {
    await page.goto(`/?demo=1&demoState=${scenario}`);
    await page.getByRole("button", { name: "Sesion" }).click();

    await expect(page.getByTestId("session-error-banner")).toContainText(title);
  });
}
