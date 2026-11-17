// The critical path: each view and its main tabs render on the live fixture, with no failed section and no page error.
import { expect, test } from '@playwright/test';

const VIEWS: [h1: string, hashes: string[]][] = [
  ['Overview', ['#overview', '#overview?range=7d&metric=runs']],
  ['Pipeline', ['#pipeline/belts', '#pipeline/belts/EX-101', '#pipeline/queue', '#pipeline/done']],
  ['Sessions', ['#sessions/live', '#sessions/live/agent-ex0001', '#sessions/stopped', '#sessions/answers']],
  ['Stats', ['#stats/spend', '#stats/prs', '#stats/runners', '#stats/pipeline']],
  ['Errors', ['#errors/open', '#errors/all/a1b2c3d4e5']],
  ['Sandboxes', ['#runners/all', '#runners/routines']],
  ['Teams', ['#teams', '#teams/new', '#teams/fxa', '#teams/example/settings', '#teams/example/routines', '#teams/fxa/memory']],
];

for (const [h1, hashes] of VIEWS) {
  test(`${h1} renders each tab`, async ({ page }) => {
    const errors: string[] = [];
    page.on('pageerror', (e) => errors.push(e.message));
    for (const hash of hashes) {
      await page.goto(`/v2/${hash}`);
      await expect(page.getByRole('heading', { level: 1 })).toHaveText(h1);
      await expect(page.locator('#conn')).toHaveAttribute('data-mode', 'live');
      await expect(page.locator('#main')).not.toContainText('did not render');
      expect(errors, hash).toEqual([]);
    }
  });
}

test('the Terminal button opens the live terminal in its own window', async ({ page, context }) => {
  await page.goto('/v2/#sessions/live/agent-ex0001');
  const [win] = await Promise.all([context.waitForEvent('page'), page.getByRole('link', { name: /^Terminal/ }).click()]);
  await expect(win).toHaveURL(/#term\/agent-ex0001$/);
  await expect(win.getByRole('heading', { level: 1 })).toBeVisible();
  await expect(win.locator('.ttyw')).toContainText('agent@sandbox: agent-ex0001');
});

// One heading, card and title style on every view, so a view's own CSS cannot drift from the others.
test('every view uses the shared heading, card padding and title position', async ({ page }) => {
  const bad: string[] = [];
  const tops = new Set<number>();
  for (const hash of VIEWS.flatMap(([, h]) => h)) {
    await page.goto(`/v2/${hash}`);
    await expect(page.locator('#conn')).toHaveAttribute('data-mode', 'live');
    const r = await page.evaluate(() => {
      const out: string[] = [], px = (v: string) => Math.round(parseFloat(v));
      const vis = (e: Element) => (e as HTMLElement).offsetParent && !e.closest('.sr-only,[hidden],dialog,[role=dialog]');
      // A column head inside a frame (Pipeline belts, Answers) is an h2 at the card-head size.
      const ok: Record<string, string[]> = { H2: ['16/700', '13/600'], H3: ['13/600'] };
      for (const e of document.querySelectorAll('#main h2, #main h3')) {
        if (!vis(e)) continue;
        const s = getComputedStyle(e), v = `${px(s.fontSize)}/${s.fontWeight}`;
        if (!ok[e.tagName]?.includes(v)) out.push(`${e.tagName} "${e.textContent?.trim().slice(0, 24)}" ${v}`);
      }
      for (const e of document.querySelectorAll('#main *')) {
        const s = getComputedStyle(e);
        if (!vis(e) || s.borderTopWidth === '0px' || px(s.borderRadius) !== 14 || e.getBoundingClientRect().height <= 90) continue;
        if (!['16px', '12px 16px', '0px'].includes(s.padding)) out.push(`card .${String((e as HTMLElement).className).split(' ')[0]} padding ${s.padding}`);
      }
      return { out, top: Math.round(document.querySelector('.mh h1')!.getBoundingClientRect().top) };
    });
    bad.push(...r.out.map((x) => `${hash}: ${x}`));
    tops.add(r.top);
  }
  expect(bad).toEqual([]);
  expect([...tops]).toHaveLength(1);
});

test('on a phone the belt legend spans the track, and no two stop names cross', async ({ page }) => {
  await page.setViewportSize({ width: 375, height: 812 });
  await page.goto('/v2/#pipeline/belts');
  await expect(page.locator('.blegend .stops > span').first()).toBeAttached();
  const r = await page.evaluate(() => {
    const st = [...document.querySelectorAll('.blegend .stops > span')].map((c) => c.getBoundingClientRect());
    const trk = document.querySelector('.belt .trk')!.getBoundingClientRect();
    return { cross: st.some((a, i) => i > 0 && a.left < st[i - 1]!.right), gap: Math.abs(st.at(-1)!.right - trk.right) };
  });
  expect(r.cross).toBe(false);
  expect(r.gap).toBeLessThan(8);
});
