import { expect, test } from "@playwright/test";

test.beforeEach(async ({ page }) => {
  await page.addInitScript(() => {
    window.localStorage.clear();
  });
});

async function expectReady(page: import("@playwright/test").Page) {
  await expect(page.getByTestId("sprite-regression-ready")).toHaveText("ready");
}

test("player body overlays stay aligned", async ({ page }) => {
  await page.goto("/playwright/sprites");
  await expectReady(page);

  await expect(page.getByTestId("body-1-head-1-sword-shield-helmet")).toHaveScreenshot(
    "body-1-head-1-sword-shield-helmet.png",
    { animations: "disabled" }
  );

  await expect(page.getByTestId("body-5-head-1-dagger-shield-helmet")).toHaveScreenshot(
    "body-5-head-1-dagger-shield-helmet.png",
    { animations: "disabled" }
  );
});

test("common NPC raw bodies keep their sheet mappings", async ({ page }) => {
  await page.goto("/playwright/sprites");
  await expectReady(page);

  await expect(page.getByTestId("npc-604")).toHaveScreenshot("npc-604.png", {
    animations: "disabled"
  });

  await expect(page.getByTestId("npc-634")).toHaveScreenshot("npc-634.png", {
    animations: "disabled"
  });

  await expect(page.getByTestId("npc-645")).toHaveScreenshot("npc-645.png", {
    animations: "disabled"
  });
});

test("body mapping regressions keep the right direction frames", async ({ page }) => {
  await page.goto("/playwright/sprites");
  await expectReady(page);

  await expect(page.getByTestId("body-1")).toHaveScreenshot("body-1.png", {
    animations: "disabled"
  });

  await expect(page.getByTestId("body-5")).toHaveScreenshot("body-5.png", {
    animations: "disabled"
  });
});
