import { expect, test, type Page } from "@playwright/test";

test.beforeEach(async ({ page }) => {
  await page.addInitScript(() => {
    window.localStorage.clear();
  });
});

async function activateSpellRowByKeyboard(page: Page, name: RegExp) {
  const row = page.getByTestId("spellbook-panel").getByRole("button", { name }).first();
  await row.focus();
  await row.press("Enter");
}

test("spellbook surfaces requirement, cooldown, and area hints", async ({ page }) => {
  await page.goto("/?demo=1");

  await page.locator(".sidebar-tabs-ao").getByRole("button", { name: "Hechizos" }).click();

  const spellbook = page.getByTestId("spellbook-panel");
  await expect(spellbook).toBeVisible();
  await expect(page.getByTestId("spellbook-summary")).toContainText("Cooldown 2s");
  await expect(page.getByTestId("spellbook-summary")).toContainText("Area 22");
  await expect(page.getByTestId("spellbook-detail")).toContainText("Detectar Invisibilidad");

  await activateSpellRowByKeyboard(page, /Invocar Elemental de Fuego/);
  await expect(page.getByTestId("spellbook-summary")).toContainText("Requiere baston");
  await expect(page.getByTestId("spellbook-detail")).toContainText("Invocar Elemental de Fuego");

  await activateSpellRowByKeyboard(page, /Resucitar/);
  await expect(page.getByTestId("spellbook-summary")).toContainText("Funciona en muertos");
});

test("trade panel exposes offer metadata", async ({ page }) => {
  await page.goto("/?demo=1");

  const tradePanel = page.getByTestId("trade-panel");
  await expect(tradePanel).toBeVisible();
  await expect(tradePanel).toContainText("Comercio entre jugadores");
  await expect(page.getByTestId("trade-selection-meta")).toContainText("ID #501");
  await expect(page.getByTestId("trade-selection-meta")).toContainText("Valor 240");
  await expect(page.getByTestId("trade-selection-meta")).toContainText("Uso 0x1F");
  await expect(tradePanel).toContainText("ID #501 · x3 · GRH 231");
  await expect(tradePanel).toContainText("Tags elementales 0x3");
  await expect(tradePanel).toContainText("ID #777 · x1 · GRH 512");
});

test("world status clarifies global weather state", async ({ page }) => {
  await page.goto("/playwright/weather");

  const worldPanel = page.getByTestId("world-status-panel");
  await expect(worldPanel).toBeVisible();
  await expect(worldPanel).toContainText("Playwright Harbor");
  await expect(worldPanel).toContainText("Lluvia y nieve activas");
  await expect(worldPanel).toContainText("Global state, not just one tile.");
  await expect(page.getByTestId("world-canvas")).toHaveAttribute("data-raining", "1");
  await expect(page.getByTestId("world-canvas")).toHaveAttribute("data-snowing", "1");

  await page.getByRole("button", { name: "Toggle snow" }).click();
  await expect(worldPanel).toContainText("Lluvia global activa");
  await expect(page.getByTestId("world-canvas")).toHaveAttribute("data-snowing", "0");

  await page.getByRole("button", { name: "Toggle rain" }).click();
  await expect(worldPanel).toContainText("Cielo despejado");
  await expect(page.getByTestId("world-canvas")).toHaveAttribute("data-raining", "0");
});
