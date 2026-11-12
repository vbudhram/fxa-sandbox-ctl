// Each target on the Sandboxes and Teams pages is at least 24 px tall at 375 px (WCAG 2.5.8), and team memory text is 13 px.
import { expect, test } from '@playwright/test';

test.use({ viewport: { width: 375, height: 900 } });

for (const hash of ['#runners/all', '#teams', '#teams/fxa', '#teams/example/settings', '#teams/fxa/memory']) {
  test(`${hash}: no target under 24 px`, async ({ page }) => {
    await page.goto(`/v2/${hash}`);
    await expect(page.locator('#conn')).toHaveAttribute('data-mode', 'live');
    await page.waitForTimeout(500);
    const small = await page.evaluate(() =>
      [...document.querySelectorAll('main a, main button, main summary, main label')]
        .map((e) => [e.textContent?.trim().slice(0, 30), e.getBoundingClientRect().height] as const)
        .filter(([, h]) => h > 0 && h < 23.5),
    );
    expect(small).toEqual([]);
    if (hash.endsWith('/memory')) expect(await page.locator('main p').evaluateAll((ps) => ps.filter((p) => getComputedStyle(p).fontSize === '14px').length)).toBe(0);
  });
}

test('#runners/all: the summary cards use the StatTile label and figure', async ({ page }) => {
  await page.goto('/v2/#runners/all');
  await expect(page.locator('#conn')).toHaveAttribute('data-mode', 'live');
  const style = (sel: string) => page.locator(sel).first().evaluate((e) => { const s = getComputedStyle(e); return `${s.fontSize}/${s.fontWeight}/${s.textTransform}`; });
  expect(await style('#sb-cards .lbl')).toBe('12px/600/uppercase');
  expect(await style('#sb-cards .big')).toBe('28px/700/none');
});
