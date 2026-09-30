#!/usr/bin/env node
// Screenshot a live page on the local FxA stack, or split a video into frames. See SKILL.md.
//   node page-shot.mjs shot <route> [--account none|verified|unverified|2fa] [--viewport WxH]...
//                      [--locale xx] [--dark] [--selector css] [--wait-for css]
//   node page-shot.mjs frames <video> [--every N]
//   node page-shot.mjs --self-test
import { execFileSync } from 'node:child_process';
import { createRequire } from 'node:module';
import crypto from 'node:crypto';
import dns from 'node:dns';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';

const ROOT = process.env.FXA_ROOT || '/workspace';
const FT = path.join(ROOT, 'packages/functional-tests');
const MEDIA = path.join(ROOT, '.fxa-auto-media');
const HERE = path.dirname(new URL(import.meta.url).pathname);
const ACCOUNTS = ['none', 'verified', 'unverified', '2fa'];

export function parseArgs(argv) {
  const [cmd, target, ...rest] = argv;
  if (cmd !== 'shot' && cmd !== 'frames') throw new Error('usage: page-shot.mjs shot <route> ... | frames <video> [--every N]');
  if (!target || target.startsWith('--')) throw new Error(`${cmd} needs a ${cmd === 'shot' ? 'route' : 'video'}`);
  const o = { cmd, target, account: 'none', viewports: [], locale: undefined, dark: false, selector: undefined, waitFor: undefined, every: 1 };
  for (let i = 0; i < rest.length; i++) {
    const a = rest[i];
    const val = () => { if (rest[i + 1] === undefined) throw new Error(`${a} needs a value`); return rest[++i]; };
    if (a === '--account') o.account = val();
    else if (a === '--viewport') {
      const m = /^(\d+)x(\d+)$/.exec(val());
      if (!m) throw new Error('--viewport takes WxH, for example 390x844');
      o.viewports.push({ width: +m[1], height: +m[2] });
    } else if (a === '--locale') o.locale = val();
    else if (a === '--dark') o.dark = true;
    else if (a === '--selector') o.selector = val();
    else if (a === '--wait-for') o.waitFor = val();
    else if (a === '--every') o.every = Number(val());
    else throw new Error(`unknown argument: ${a}`);
  }
  if (!ACCOUNTS.includes(o.account)) throw new Error(`--account is one of ${ACCOUNTS.join('|')}`);
  if (!(o.every > 0)) throw new Error('--every takes a number of seconds above 0');
  if (!o.viewports.length) o.viewports.push({ width: 1280, height: 720 }); // playwright.config.ts default
  return o;
}

// "/signin?x=1" -> { path: "/signin", params: URLSearchParams(x=1) }
export function splitRoute(route) {
  const [p, q = ''] = route.split('?');
  return { path: p.startsWith('/') ? p : `/${p}`, params: new URLSearchParams(q) };
}

export function shotName(o, vp) {
  const slug = splitRoute(o.target).path.replace(/[^a-zA-Z0-9]+/g, '-').replace(/^-|-$/g, '') || 'root';
  return [slug, o.account, `${vp.width}x${vp.height}`, o.locale, o.dark && 'dark'].filter(Boolean).join('-') + '.png';
}

// Load the functional-tests TypeScript helpers the way Playwright does: transpile on require.
function fxaHelpers() {
  const req = createRequire(path.join(FT, 'package.json'));
  const ts = req('typescript');
  req.extensions['.ts'] = (m, file) => {
    const out = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
      fileName: file,
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, esModuleInterop: true, experimentalDecorators: true },
    });
    m._compile(out.outputText, file);
  };
  return {
    firefox: req('@playwright/test').firefox,
    createTarget: req('./lib/targets/index.ts').create, // index first, as lib/fixtures/standard.ts does: base.ts and index.ts import each other
    getFirefoxUserPrefs: req('./lib/targets/firefoxUserPrefs.ts').getFirefoxUserPrefs,
    getReactFeatureFlagUrl: req('./lib/react-flag.ts').getReactFeatureFlagUrl,
    getTotpCode: req('./lib/totp.ts').getTotpCode,
  };
}

async function signIn(page, target, h, o) {
  const email = `pageshot-${crypto.randomBytes(6).toString('hex')}@restmail.net`;
  const password = crypto.randomBytes(10).toString('hex');
  const creds = await target.createAccount(email, password, { lang: 'en', preVerified: o.account === 'unverified' ? 'false' : 'true' });
  let secret;
  if (o.account === '2fa') { // same calls as enableTotpOnAccount in lib/pairing-helpers.ts
    ({ secret } = await target.authClient.createTotpToken(creds.sessionToken, {}));
    await target.authClient.verifyTotpSetupCode(creds.sessionToken, await h.getTotpCode(secret));
    await target.authClient.completeTotpSetup(creds.sessionToken);
  }
  console.log(`account: ${email} / ${password}${secret ? ` / totp secret ${secret}` : ''}`);

  // Same steps and locators as pages/signin.ts fillOutEmailFirstForm and fillOutPasswordForm.
  const submit = page.locator('form button[type="submit"]');
  await page.goto(target.contentServerUrl);
  for (let i = 0; ; i++) { // an l10n re-mount can drop the first fill
    await page.getByRole('textbox', { name: 'Email' }).fill(email);
    if (await submit.isEnabled()) break;
    if (i > 15) throw new Error('the email submit button stays disabled');
    await page.waitForTimeout(1000);
  }
  await submit.click();
  await page.getByRole('textbox', { name: 'password' }).fill(password);
  await submit.click();
  if (o.account === 'unverified') return page.waitForURL(/confirm_signup_code/);
  if (o.account === '2fa') {
    await page.waitForURL(/signin_totp_code/);
    await page.getByTestId('totp-input-field').fill(await h.getTotpCode(secret));
    await submit.click();
  }
  await page.waitForURL(/\/settings/);
}

async function shot(o) {
  dns.setDefaultResultOrder('ipv4first'); // the functional-tests scripts set this too
  execFileSync('bash', [path.join(HERE, '../fxa-stack/stack.sh'), 'ensure'], { stdio: ['ignore', process.stderr, process.stderr] });
  const h = fxaHelpers();
  const target = h.createTarget('local');
  const browser = await h.firefox.launch({ firefoxUserPrefs: h.getFirefoxUserPrefs('local') });
  const context = await browser.newContext({ viewport: o.viewports[0], locale: o.locale, colorScheme: o.dark ? 'dark' : 'light' });
  const page = await context.newPage();
  fs.mkdirSync(MEDIA, { recursive: true });
  let file = path.join(MEDIA, shotName(o, o.viewports[0]));
  try {
    if (o.account !== 'none') await signIn(page, target, h, o);
    let url = o.target;
    if (!/^https?:/.test(url)) { // same flags as SigninPage.goto in pages/signin.ts
      const { path: p, params } = splitRoute(url);
      params.set('forceExperiment', 'generalizedReactApp');
      params.set('forceExperimentGroup', 'react');
      if (!params.get('force_passwordless')) params.set('force_passwordless', 'false');
      url = h.getReactFeatureFlagUrl(target, p, params.toString());
    }
    await page.goto(url, { waitUntil: 'load' });
    for (const vp of o.viewports) {
      file = path.join(MEDIA, shotName(o, vp));
      await page.setViewportSize(vp);
      const wait = o.waitFor || o.selector;
      if (wait) await page.locator(wait).first().waitFor({ state: 'visible', timeout: 30000 });
      await page.waitForLoadState('networkidle', { timeout: 10000 }).catch(() => {});
      if (o.selector) await page.locator(o.selector).first().screenshot({ path: file });
      else await page.screenshot({ path: file, fullPage: true });
      console.log(file);
    }
  } catch (e) {
    const failed = file.replace(/\.png$/, '-FAILED.png');
    await page.screenshot({ path: failed, fullPage: true }).catch(() => {});
    console.error(`FAILED: ${e.message.split('\n')[0]}\ncurrent URL: ${page.url()}\nfailure screenshot: ${failed}`);
    process.exitCode = 1;
  }
  await browser.close();
  process.exit(process.exitCode ?? 0); // LocalTarget holds a Redis connection open
}

function frames(o) {
  const video = path.resolve(o.target);
  if (!fs.existsSync(video)) throw new Error(`no video at ${video}`);
  const dir = path.join(os.tmpdir(), 'fxa-page-shot', path.basename(video).replace(/\.[^.]+$/, ''));
  fs.rmSync(dir, { recursive: true, force: true });
  fs.mkdirSync(dir, { recursive: true });
  const ff = (args) => execFileSync('ffmpeg', ['-v', 'error', '-y', ...args], { stdio: 'inherit' });
  const fps = `fps=1/${o.every}`;
  try {
    ff(['-i', video, '-vf', `${fps},drawtext=text='%{pts\\:hms}':x=8:y=8:fontsize=28:fontcolor=white:box=1:boxcolor=black@0.7`, `${dir}/frame-%03d.png`]);
  } catch { // drawtext needs a font; frames without a time label still help
    ff(['-i', video, '-vf', fps, `${dir}/frame-%03d.png`]);
  }
  const n = fs.readdirSync(dir).filter((f) => f.startsWith('frame-')).length;
  if (!n) throw new Error('ffmpeg wrote no frames; is the video empty?');
  ff(['-framerate', '1', '-i', `${dir}/frame-%03d.png`, '-vf', 'scale=400:-2,tile=4x4:padding=4:color=gray', `${dir}/sheet-%02d.png`]);
  for (const f of fs.readdirSync(dir).filter((f) => f.startsWith('sheet-')).sort()) console.log(path.join(dir, f));
  console.log(`${n} frames, one every ${o.every}s, 16 per sheet: ${dir}/frame-NNN.png`);
}

function selfTest() {
  const bad = (argv) => assert.throws(() => parseArgs(argv));
  const o = parseArgs(['shot', '/settings', '--account', '2fa', '--viewport', '390x844', '--viewport', '1280x800', '--locale', 'de', '--dark', '--selector', '#x']);
  assert.deepEqual(o.viewports, [{ width: 390, height: 844 }, { width: 1280, height: 800 }]);
  assert.equal(shotName(o, o.viewports[0]), 'settings-2fa-390x844-de-dark.png');
  assert.equal(shotName(parseArgs(['shot', '/']), { width: 1280, height: 720 }), 'root-none-1280x720.png');
  assert.equal(shotName(parseArgs(['shot', 'settings/two_step_authentication?x=1']), { width: 1, height: 2 }), 'settings-two-step-authentication-none-1x2.png');
  assert.deepEqual(parseArgs(['shot', '/signin']).viewports, [{ width: 1280, height: 720 }]);
  const r = splitRoute('signin?force_passwordless=true');
  assert.equal(r.path, '/signin');
  assert.equal(r.params.get('force_passwordless'), 'true');
  assert.equal(parseArgs(['frames', 'a.webm', '--every', '0.5']).every, 0.5);
  bad(['shot']); bad(['shot', '--dark']); bad(['nope', 'x']); bad(['shot', '/', '--account', 'admin']);
  bad(['shot', '/', '--viewport', '390']); bad(['shot', '/', '--locale']); bad(['shot', '/', '--zoom', '2']);
  bad(['frames', 'a.webm', '--every', '0']);
  console.log('self-test ok');
}

const argv = process.argv.slice(2);
try {
  if (argv[0] === '--self-test') selfTest();
  else {
    const o = parseArgs(argv);
    if (o.cmd === 'frames') frames(o);
    else await shot(o);
  }
} catch (e) {
  console.error(e.message);
  process.exit(2);
}
