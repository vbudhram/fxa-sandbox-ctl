import { afterEach, expect, test, vi } from 'vitest';
import { ago, days, jiraHref, mdHtml, modelName, plainMd, plural, prUrl, short, ttyLine, usd } from './index';

afterEach(() => { vi.useRealTimers(); });

test('ago, short and days', () => {
  expect([null, 5, 90, 7200, 200000].map(ago)).toEqual(['never', '5s ago', '2m ago', '2h ago', '2d ago']);
  expect(ago(30 * 86400)).not.toMatch(/ago/);
  expect([plural(1, 'run'), plural(2, 'run'), plural(1, 'person', 'people'), plural(0, 'person', 'people')]).toEqual(['1 run', '2 runs', '1 person', '0 people']);
  expect([null, 5, 90, 5400, 4622400].map(short)).toEqual(['', '5s', '2m', '1.5h', '54d']);
  vi.useFakeTimers({ toFake: ['Date'] }); vi.setSystemTime(Date.parse('2026-11-03T00:00:00Z'));
  expect(days('2026-11-01T00:00:00Z')).toBe(2);
  expect(days(null)).toBeNull();
});

test('usd and modelName', () => {
  expect([null, 0, 1.25, 12, 1284.5, 1530863.08, -42.5].map(usd)).toEqual(['—', '$0.00', '$1.25', '$12.00', '$1,284.50', '$1,530,863', '-$42.50']);
  expect(modelName('claude-opus-4-5-20251101[1m]')).toBe('Opus 4.5 (1M)');
  expect(modelName('claude-haiku-5')).toBe('Haiku 5');
  expect(modelName(undefined)).toBe('Unknown');
});

test('jiraHref and prUrl fail closed', () => {
  expect(jiraHref('EX-1', 'https://jira.example.com/')).toBe('https://jira.example.com/browse/EX-1');
  expect(jiraHref('EX-1', 'javascript:alert(1)')).toBe('');
  expect(jiraHref('ex-1', 'https://jira.example.com')).toBe('');
  expect(prUrl(12, 'example/repo')).toBe('https://github.com/example/repo/pull/12');
  expect(prUrl('12"><x', 'example/repo')).toBe('');
  expect(prUrl(12, 'example/../repo')).toBe('');
});

test('plainMd keeps the link text', () => {
  expect(plainMd('Read [README.md](/workspace/README.md:15) `now` **done**')).toBe('Read README.md now done');
});

test('mdHtml escapes first, then allows the safe subset', () => {
  expect(mdHtml('<script>x</script>')).toBe('<p>&lt;script&gt;x&lt;/script&gt;</p>');
  expect(mdHtml('**b** and `c` and _i_')).toBe('<p><b>b</b> and <code>c</code> and <i>i</i></p>');
  expect(mdHtml('[ok](https://example.com/a)')).toBe('<p><a href="https://example.com/a" target="_blank" rel="noopener">ok</a></p>');
  expect(mdHtml('[x](javascript:alert(1))')).toBe('<p>[x](javascript:alert(1))</p>');
  // A link inside a link's text cannot break out of the href.
  expect(mdHtml('<https://example.com/a"x|t>')).toBe('<p>&lt;https://example.com/a&quot;x|t&gt;</p>');
  expect(mdHtml('- a\n  - b\n\n1. c')).toBe('<ul><li>a</li><li class="sub">b</li></ul><ol><li>c</li></ol>');
  expect(mdHtml('```\n<b>\n```')).toBe('<pre><code>&lt;b&gt;</code></pre>');
  expect(mdHtml('| a | b |\n| <c> | d |')).toBe('<pre>| a | b |\n| &lt;c&gt; | d |</pre>');
  expect(mdHtml('# Head')).toBe('<span class="h">Head</span>');
});

test('ttyLine: commands get a prompt, only real results a colour', () => {
  expect(ttyLine('[tool] Bash npm test')).toEqual({ kind: 'p', head: '$', text: 'npm test' });
  expect(ttyLine('[tool] Read src/a.ts')).toEqual({ kind: 't', head: 'Read', text: 'src/a.ts' });
  expect(ttyLine('FAIL src/a.test.ts').kind).toBe('bad');
  expect(ttyLine('Tests: 3 passed').kind).toBe('ok');
  expect(ttyLine('The build failed earlier').kind).toBe('');
  expect(ttyLine('OPTION: retry').kind).toBe('opt');
  expect(ttyLine('status: done').kind).toBe('dim');
});
