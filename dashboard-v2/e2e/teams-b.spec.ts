// Teams part B: the Routines and Memory tabs, on the v1 page fixtures. Most checks port
// skills/fxa-ctl-dev/page-routine-link.check.sh and page-depfix-routine.check.sh, with the same fixture and the same expected text.
import { readFileSync } from 'node:fs';
import { expect, test, type Page } from '@playwright/test';

// The harness is in the dev build only: playwright.config.ts runs this spec in the ds project, on the Vite dev server.
const HARNESS = '/v2/e2e/teams-b.html';
type Fx = Record<string, unknown>;
type Post = { url: string; body: Record<string, unknown> };
type Answer = (p: Post) => { status?: number; body: unknown } | Promise<{ status?: number; body: unknown }>;

// The fixture time rule: "@iso-3600" is an ISO time an hour ago, "@epoch+600" an epoch 10 min ahead.
const now = Date.now() / 1000;
const rel = (v: unknown): unknown => {
  if (Array.isArray(v)) return v.map(rel);
  if (v && typeof v === 'object') return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, rel(x)]));
  const m = typeof v === 'string' ? v.match(/^@(iso|epoch)([+-]\d+)$/) : null;
  if (!m) return v;
  const t = now + Number(m[2]);
  return m[1] === 'epoch' ? Math.floor(t) : new Date(t * 1000).toISOString().replace(/\.\d+Z$/, 'Z');
};
const fixture = (name: string): Fx => rel(JSON.parse(readFileSync(new URL(`../../skills/fxa-ctl-dev/page-fixture-${name}.json`, import.meta.url), 'utf8'))) as Fx;

// GETs answer from the fixture, as serve.py --fixture does; each POST is recorded and answered by `post`.
async function open(page: Page, hash: string, fx: Fx, post: Answer = () => ({ body: { ok: true, out: '' } })) {
  const sent: Post[] = [];
  await page.route('**/api/**', async (r) => {
    const u = new URL(r.request().url());
    if (r.request().method() === 'POST') {
      const p = { url: u.pathname, body: JSON.parse(r.request().postData() || '{}') };
      sent.push(p);
      const a = await post(p);
      return r.fulfill({ status: a.status ?? 200, json: a.body });
    }
    const miss = /routines|errors/.test(u.pathname) ? [] : {};
    return r.fulfill({ json: u.pathname in fx ? fx[u.pathname] : miss });
  });
  await page.goto(`${HARNESS}${hash}`);
  return sent;
}

test.describe('routines: links, list and create (page-fixture-routines)', () => {
  const F = fixture('routines');
  for (const then of [false, true]) {
    test(`${then ? 'Create and run now posts the routine, then its run' : 'Create posts the draft the start and the buttons made'}`, async ({ page }) => {
      const sent = await open(page, '#teams/example/routines', F, () => ({ body: { out: 'created routine 7' } }));
      await page.locator('[data-rt-new]').click();
      await expect(page.locator('#rt-form-h')).toBeFocused();
      await page.locator('[data-rt-tpl="code-review"]').click();
      await expect(page.locator('#rt-form-h')).toBeFocused();
      await page.locator('[data-rt-kind="weekly"]').click();
      await page.locator('[data-rt-day="fri"]').click();
      await page.locator('#rt-name').fill('Friday review');
      await expect(page.locator('[data-rt-readback]')).toHaveText(/^Friday review runs every Friday at 09:00 /);
      await page.locator(then ? '[data-rt-then="run"]' : '[data-rt-save]:not([data-rt-then])').click();
      await expect.poll(() => sent.length).toBe(then ? 2 : 1);
      const r = sent[0]!.body.routine as Fx;
      expect([sent[0]!.url, r.template, r.schedule, r.repos]).toEqual(['/api/teams/example/routines', 'code-review', 'weekly fri 09:00', ['example/app']]);
      if (then) expect(sent[1]!.url).toBe('/api/teams/example/routines/7/run');
    });
  }
  test('Create posts the picked model and effort', async ({ page }) => {
    const sent = await open(page, '#teams/example/routines', F, () => ({ body: { out: 'created routine 7' } }));
    await page.locator('[data-rt-new]').click();
    await page.locator('[data-rt-tpl="code-review"]').click();
    await page.locator('#rt-name').fill('Cheap review');
    await expect(page.locator('#rt-model option[value="claude-fable-5-2"]')).toHaveText('Fable 5.2');
    await page.locator('#rt-model').selectOption('claude-sonnet-5-5');
    await page.locator('#rt-effort').selectOption('low');

    await page.locator('[data-rt-save]:not([data-rt-then])').click();
    await expect.poll(() => sent.length).toBe(1);
    expect(sent[0]!.body.routine).toMatchObject({ model: 'claude-sonnet-5-5', effort: 'low' });
    await expect(page.locator('#rt-runtime')).toHaveCount(0);
  });
  test('Where the host runs Codex: Runtime shows, a switch clears the picks, and Create posts Codex', async ({ page }) => {
    const ch = '/api/teams/example/routine-channels', fx = { ...F, [ch]: { channels: [], ...(F[ch] as Fx), runtimes: ['claude', 'codex'] } };
    const sent = await open(page, '#teams/example/routines', fx, () => ({ body: { out: 'created routine 7' } }));
    await page.locator('[data-rt-new]').click();
    await page.locator('[data-rt-tpl="code-review"]').click();
    await page.locator('#rt-name').fill('Codex review');
    await page.locator('#rt-effort').selectOption('max');
    await page.locator('#rt-runtime').selectOption('codex');
    await expect(page.locator('#rt-effort')).toHaveValue('');
    await expect(page.locator('#rt-effort option[value="max"]')).toHaveCount(0);
    await page.locator('#rt-effort').selectOption('high');
    await page.locator('[data-rt-save]:not([data-rt-then])').click();
    await expect.poll(() => sent.length).toBe(1);
    expect(sent[0]!.body.routine).toMatchObject({ runtime: 'codex', effort: 'high' });
    expect('model' in (sent[0]!.body.routine as Fx)).toBe(false);
  });
});

test.describe('routines: a dependency PR routine (page-fixture-depfix-routine)', () => {
  const F = fixture('depfix-routine');
  test('The routine page names its model and effort: the defaults', async ({ page }) => {
    await open(page, '#teams/example/routines/1', F, () => ({ body: {} }));
    await expect(page.getByText('Default (Opus 5.5)')).toBeVisible();
    await expect(page.getByText('Default (Medium)')).toBeVisible();
  });
  test('The routine page names a picked model and effort: Fable 5.2 at high', async ({ page }) => {
    const key = '/api/teams/example/routines', rows = (F[key] as Fx[]).map((x) => ({ ...x, data: { ...(x.data as Fx), model: 'claude-fable-5-2', effort: 'high' } }));
    await open(page, '#teams/example/routines/1', { ...F, [key]: rows }, () => ({ body: {} }));
    await expect(page.getByText('Fable 5.2', { exact: true })).toBeVisible();
    await expect(page.getByText('High', { exact: true })).toBeVisible();
  });
  test('Run now asks for a PR URL, shows Checking the PR, ties the refusal to the field, then says Queued', async ({ page }) => {
    let n = 0;
    const sent = await open(page, '#teams/example/routines/1', F, async () => {
      await new Promise((r) => setTimeout(r, 300));
      return n++ ? { body: { ok: true, out: 'queued run 31: Queued for #90010. The PR comment shows its state.' } }
        : { status: 400, body: { error: 'ERROR: A run on 1111111 already ended. A new commit allows a new run.' } };
    });
    await page.locator('.rtd [data-rt-act="run"][data-rt-id="1"]').first().click();
    const ask = page.locator('[data-rt-ask]');
    await expect(page.getByLabel('PR URL')).toBeVisible();
    await expect(ask).toBeFocused();
    await ask.fill('https://github.com/example/app/pull/90001');
    await page.locator('[data-rt-act="runpr"]').click();
    await expect(page.locator('[data-rt-act="runpr"]')).toHaveText('Checking the PR…');
    await expect(page.locator('[data-rt-act="runpr"]')).toBeDisabled();
    await expect(ask).toHaveAccessibleDescription('A run on 1111111 already ended. A new commit allows a new run.');
    await expect(ask).toHaveAttribute('aria-invalid', 'true');
    await ask.fill('https://github.com/example/app/pull/90010');
    await ask.press('Enter');
    await expect(page.locator('[data-rt-msg]')).toHaveText('Queued for #90010. The PR comment shows its state.');
    await expect(ask).toHaveCount(0);
    expect(sent.map((s) => `${s.url} ${JSON.stringify(s.body)}`)).toEqual([
      '/api/teams/example/routines/1/run {"pr":"https://github.com/example/app/pull/90001"}',
      '/api/teams/example/routines/1/run {"pr":"https://github.com/example/app/pull/90010"}',
    ]);
  });
});

const MEM = {
  on: true, dep: ['example/lib'],
  entries: [
    { id: 'mem-0000aaaa', v: 'aaaaaaaaaaaa', scope: 'team', kind: 'trap', text: 'Run the auth tests with the stack up.', why: 'They time out.', path: '', terms: '', confirmed: '2026-10-30', cites: [{ cite: 'example/app:test/auth.js:4', anchor: 'beforeAll' }] },
    { id: 'mem-0000bbbb', v: 'bbbbbbbbbbbb', scope: 'example/app', kind: 'command', text: 'Use yarn workspace to run one package.', why: '', path: '', terms: '', confirmed: '2025-01-02', person: true, cites: [{ cite: 'example/app:package.json:2', anchor: 'workspaces' }] },
    { id: 'mem-0000cccc', v: 'cccccccccccc', scope: 'example/lib', kind: 'convention', text: 'The lib exports ESM only.', why: '', path: '', terms: '', confirmed: '2026-10-01', dep: true, cites: [{ cite: 'example/lib:package.json:3', anchor: 'type' }] },
  ],
};
test.describe('memory', () => {
  const F = { ...fixture('routines'), '/api/teams/example/memory': MEM };
  test('Save posts the entry; the errors go to their fields; a 409 takes the new version', async ({ page }) => {
    let n = 0;
    const sent = await open(page, '#teams/example/memory', F, () => (n++ === 0
      ? { status: 400, body: { error: 'ERROR: text: The fact is empty\ncite1: no such file' } }
      : n === 2 ? { status: 409, body: { error: 'the entry changed' } } : { body: { out: 'saved mem-0000aaaa\nWARN: push failed' } }));
    await page.locator('[data-mem-edit="mem-0000aaaa"]').click();
    await page.locator('#mem-text').fill('');
    await page.locator('[data-mem-save]').click();
    await expect(page.locator('#mem-text')).toBeFocused();
    await expect(page.locator('#mem-text')).toHaveAccessibleDescription('The fact is empty');
    await expect(page.locator('#mem-cite1')).toHaveAccessibleDescription('no such file');
    await expect(page.getByRole('alert')).toHaveText('Fix the marked fields.');
    await page.locator('#mem-text').fill('Run the auth tests with the stack up, always.');
    await page.locator('[data-mem-save]').click();
    await expect(page.getByRole('alert')).toHaveText('the entry changed');
    await page.locator('[data-mem-save]').click();
    await expect(page.locator('[data-mem-msg]')).toHaveText('Saved mem-0000aaaa. The push to GitHub failed; the next save pushes it.');
    expect(sent.map((s) => [s.url, s.body.v])).toEqual([['/api/teams/example/memory/mem-0000aaaa', 'aaaaaaaaaaaa'], ['/api/teams/example/memory/mem-0000aaaa', 'aaaaaaaaaaaa'], ['/api/teams/example/memory/mem-0000aaaa', 'aaaaaaaaaaaa']]);
  });
});

