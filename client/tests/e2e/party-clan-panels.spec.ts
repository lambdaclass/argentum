import { expect, test } from "@playwright/test";

test.describe("party and clan browser panels", () => {
  test("party roster and safe mode stay tied to client state", async ({ page }) => {
    await page.goto("/playwright/social");

    await expect(page.getByTestId("playwright-social-summary")).toContainText("party unsafe");
    await page.getByRole("button", { name: "Seguro: OFF" }).click();
    await expect(page.getByRole("button", { name: "Seguro: ON" })).toBeVisible();
    await expect(page.getByTestId("social-transcript")).toContainText("Party safe mode turned on");
  });

  test("clan create flow remains usable without backend guesses", async ({ page }) => {
    await page.goto("/playwright/social");

    await page.getByPlaceholder("Nombre del clan").fill("Noche Azul");
    await page.getByRole("button", { name: "Crear Clan" }).click();

    await expect(page.getByRole("heading", { name: "Noche Azul" })).toBeVisible();
    await expect(page.getByTestId("playwright-social-summary")).toContainText("Noche Azul");
    await expect(page.getByTestId("social-transcript")).toContainText("/CREARCLAN Noche Azul");
  });
});
