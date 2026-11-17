import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';

const theme = readFileSync(new URL('./theme.css', import.meta.url), 'utf8');

// The body of the first rule that opens with this selector; token blocks hold no nested braces.
function block(css: string, selector: string): string {
  const at = css.indexOf(selector + ' {');
  if (at < 0) throw new Error(`no "${selector}" block`);
  const open = css.indexOf('{', at);
  return css.slice(open + 1, css.indexOf('}', open));
}

function vars(body: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const m of body.replace(/\/\*[\s\S]*?\*\//g, '').matchAll(/--([\w-]+)\s*:\s*([^;]+?)\s*(?:;|$)/g)) {
    out[m[1]!] = m[2]!;
  }
  return out;
}

const light = vars(block(theme, ':root'));
const dark = vars(block(theme, ':root[data-theme="dark"]'));
const fallback = vars(block(theme, ':root:not([data-theme])'));

describe('theme.css', () => {
  it('gives every colour token a dark value', () => {
    expect(Object.keys(light).length).toBeGreaterThan(50);
    expect(Object.keys(dark).filter((k) => !(k in light))).toEqual([]);
    for (const k of ['bg', 'panel', 'ink', 'dim', 'line', 'ok', 'warn', 'bad', 'info', 'link']) expect(dark[k], k).toBeTruthy();
  });

  it('keeps the no-script dark fallback equal to the data-theme dark block', () => {
    expect(fallback).toEqual(dark);
  });

  it('maps each Tailwind key to a token that exists', () => {
    const refs = [...block(theme, '@theme inline reference').matchAll(/var\(--([\w-]+)\)/g)].map((m) => m[1]!);
    expect(refs.length).toBeGreaterThan(60);
    expect(refs.filter((r) => !(r in light))).toEqual([]);
  });
});

// On a phone a tap leaves :hover on, so each hover rule sits in @media (hover: hover).
it('guards every :hover rule for touch screens', async () => {
  const { globSync } = await import('node:fs');
  const bad = globSync('src/**/*.css').flatMap((f) =>
    readFileSync(f, 'utf8').split('\n').filter((l) => l.includes(':hover') && !l.trimStart().startsWith('@media (hover: hover)')).map((l) => `${f}: ${l}`));
  expect(bad).toEqual([]);
});
