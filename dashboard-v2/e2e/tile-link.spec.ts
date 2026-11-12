import { expect, test } from '@playwright/test';

// The shell's link rule sat outside a layer, so it beat Tailwind's rounded-lg on a tile that is a link.
test('a stat tile that is a link has the same corners as the other tiles', async ({ page }) => {
  await page.goto('/v2/#pipeline/belts');
  const tiles = page.locator('.ptiles [data-stat] > *');
  await expect(tiles.first()).toBeVisible();
  const radii = await tiles.evaluateAll((els) => els.map((e) => `${e.tagName} ${getComputedStyle(e).borderRadius}`));
  expect(new Set(radii.map((r) => r.split(' ')[1])).size, radii.join(', ')).toBe(1);
});
