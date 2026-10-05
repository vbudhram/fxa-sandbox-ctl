// One cold load of the email-first page in a new Firefox, as one JSON line on stdout:
// {shell, fcp, form, submit, next} in ms from navigation (null when a mark never came).
//   node load.js <flow: first|email> [video dir]
// first: until the email form shows. email: also type an email, submit, and wait for the
// next step's password or code field.
const { firefox } = require('/workspace/node_modules/playwright');
const [flow = 'first', videoDir] = process.argv.slice(2);
const EMAIL = process.env.PERF_EMAIL || 'perf-signin@restmail.net';
// Marks taken in the page each frame: what a person sees, not just load events.
const MARKS = `(() => {
  const t = (window.__perfMarks = {}), now = () => Math.round(performance.now());
  const mark = (k) => { if (!(k in t)) t[k] = now(); };
  const vis = (s) => { const e = document.querySelector(s); return e && e.getBoundingClientRect().height > 0; };
  const tick = () => {
    if (vis('#fxa-shell')) mark('shell');
    if (vis('input[name="email"]')) mark('form');
    if (vis('input[type="password"], input[inputmode="numeric"]')) mark('next');
    requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);
  document.addEventListener('submit', () => mark('submit'), true);
})();`;

(async () => {
  const browser = await firefox.launch();
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 },
    ...(videoDir ? { recordVideo: { dir: videoDir, size: { width: 640, height: 400 } } } : {}) });
  await ctx.addInitScript(MARKS);
  const page = await ctx.newPage();
  try {
    await page.goto('http://localhost:3000/', { waitUntil: 'commit' });
    await page.locator('input[name="email"]').waitFor({ timeout: 30000 });
    if (flow === 'email') {
      await page.locator('input[name="email"]').pressSequentially(EMAIL, { delay: 40 });
      await page.locator('button[type="submit"]').first().click();
      await page.locator('input[type="password"], input[inputmode="numeric"]').first().waitFor({ timeout: 30000 });
    }
    if (videoDir) await page.waitForTimeout(1500);
    const m = await page.evaluate(() => ({ ...window.__perfMarks,
      fcp: Math.round((performance.getEntriesByName('first-contentful-paint')[0] || {}).startTime || 0) || null }));
    const v = videoDir && page.video();
    await ctx.close();
    console.log(JSON.stringify({ shell: m.shell ?? null, fcp: m.fcp, form: m.form ?? null, submit: m.submit ?? null, next: m.next ?? null,
      ...(v ? { video: await v.path() } : {}) }));
  } finally {
    await browser.close();
  }
})().catch((e) => { console.error(e.message.split('\n')[0]); process.exit(1); });
