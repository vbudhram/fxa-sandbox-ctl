// A chart's "Show as table" on a phone scrolls inside its card, not the page.
import { expect, test } from "@playwright/test";

test.use({ viewport: { width: 375, height: 800 } });

for (const hash of ["#runners/all", "#stats/spend"]) {
  test(`${hash}: each chart table scrolls in its own region at 375 px`, async ({
    page,
  }) => {
    await page.goto(`/v2/${hash}`);
    await expect(page.locator("#conn")).toHaveAttribute("data-mode", "live");
    const shows = page.getByText("Show as table", { exact: true });
    await expect(shows.first()).toBeVisible();
    for (const s of await shows.all()) await s.click();
    const regions = page.getByRole("region", { name: / as a table$/ });
    expect(await regions.count()).toBeGreaterThan(0);
    expect(
      await page.evaluate(
        () => document.documentElement.scrollWidth - window.innerWidth,
      ),
    ).toBeLessThanOrEqual(0);
  });
}
