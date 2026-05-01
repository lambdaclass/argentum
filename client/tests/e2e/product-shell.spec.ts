import { expect, test } from "@playwright/test";

test("browser product shell can register, create, and launch a character", async ({ page }) => {
  await page.goto("/playwright/product");

  await expect(page.getByTestId("product-lobby-panel")).toBeVisible();
  await expect(page.getByRole("heading", { name: "Entrar o registrarse" })).toBeVisible();

  await page.getByRole("button", { name: "Registro" }).click();
  await page.getByLabel("Cuenta").fill("playwright");
  await page.getByLabel(/^Clave$/).fill("delta");
  await page.getByLabel("Confirmar clave").fill("delta");
  await page.getByRole("button", { name: "Crear cuenta" }).click();

  await expect(page.getByRole("heading", { name: "Seleccion de personaje" })).toBeVisible();
  await page.getByRole("button", { name: "Crear primer personaje" }).click();
  await expect(page.getByTestId("product-create-panel")).toBeVisible();

  await page.getByLabel("Nombre").fill("Nerea");
  await page.getByTestId("product-create-panel").getByRole("button", { name: "Crear personaje" }).click();

  await expect(page.getByTestId("product-lobby-panel")).toContainText("Nerea");
  await page.getByRole("button", { name: "Jugar con este personaje" }).click();
  await expect(page.getByTestId("playwright-product-launch-summary")).toContainText("Launched Nerea");
  await expect(page.getByTestId("product-transcript")).toContainText("Launched Nerea");
});

test("browser product shell exposes ranking without backend calls", async ({ page }) => {
  await page.goto("/playwright/product");

  await page.getByRole("button", { name: "Ranking" }).click();
  await expect(page.getByTestId("product-ranking-panel")).toBeVisible();
  await expect(page.getByTestId("product-ranking-panel")).toContainText("Sirena");
  await expect(page.getByTestId("product-ranking-panel")).toContainText("Fulgor");
});
