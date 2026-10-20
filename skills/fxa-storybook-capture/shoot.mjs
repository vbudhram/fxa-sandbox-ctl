// Screenshot Storybook stories into /workspace/.fxa-auto-media. See SKILL.md Step 4.
//   node shoot.mjs <story-id>:<slug>... [--viewport WxH] [--dry-run]
// SB_PORT (6008) is the Storybook port. --dry-run prints the shots and exits.
import fs from 'fs';
import { createRequire } from 'module';

const OUT = '/workspace/.fxa-auto-media';
const PORT = process.env.SB_PORT ?? '6008';
const args = process.argv.slice(2);
const usage = (msg) => { console.error(`shoot: ${msg}\nusage: node shoot.mjs <story-id>:<slug>... [--viewport WxH] [--dry-run]`); process.exit(2); };

let width = 900, height = 700, dry = false;
const SHOTS = [];
for (let i = 0; i < args.length; i++) {
  const a = args[i];
  if (a === '--dry-run') dry = true;
  else if (a === '--viewport') {
    const m = /^(\d+)x(\d+)$/.exec(args[++i] ?? '');
    if (!m) usage('--viewport needs WxH, for example 900x700');
    [width, height] = [Number(m[1]), Number(m[2])];
  } else {
    // Keep a numeric prefix on the slug so the files sort.
    const m = /^([a-z0-9-]+):([A-Za-z0-9._-]+)$/.exec(a);
    if (!m) usage(`not <story-id>:<slug>: ${a}`);
    SHOTS.push([m[1], m[2]]);
  }
}
if (SHOTS.length === 0) usage('give at least one <story-id>:<slug>');
if (dry) {
  for (const [id, slug] of SHOTS) console.log(`${id} -> ${OUT}/${slug}.png (${width}x${height})`);
  process.exit(0);
}

// This file lives outside the repo, so resolve playwright from the repo root.
const { firefox } = createRequire(`${process.env.FXA_ROOT ?? '/workspace'}/package.json`)('playwright');
fs.mkdirSync(OUT, { recursive: true });
const browser = await firefox.launch();
const page = await browser.newPage({ viewport: { width, height } });

for (const [id, slug] of SHOTS) {
  // Not 'networkidle': the dev server keeps HMR traffic open and the first
  // preview compile can hold the request past 30 s. Wait for load, then for
  // the story to put something in the root.
  await page.goto(`http://localhost:${PORT}/iframe.html?id=${id}&viewMode=story`,
                  { waitUntil: 'load', timeout: 180000 });
  const root = page.locator('#storybook-root');
  if ((await root.count()) === 0) throw new Error(`story ${id} has no #storybook-root`);
  await root.locator(':scope > *').first().waitFor({ timeout: 60000 });

  // A failed bundle still returns 200 and paints an error box. Refuse to
  // screenshot that: it would reach the reviewer looking like evidence.
  // Storybook 8 always renders the box and hides it, so test visibility,
  // never presence.
  if (await page.locator('#error-message').isVisible())
    throw new Error(`story ${id} rendered a Storybook error box`);
  if ((await root.innerHTML()).trim() === '') throw new Error(`story ${id} rendered empty`);

  // Shoot the root, not the viewport: the card is a small island in an empty page.
  await root.screenshot({ path: `${OUT}/${slug}.png` });
  console.log(`captured ${slug}.png`);
}

await browser.close();
