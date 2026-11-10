// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterAll, expect, test, vi } from 'vitest';
import { dispatch } from '../../../store';
import MemoryTab from './index';

// Each table row paints a Tag, so the Tag calls count the table repaints.
const tags = vi.hoisted(() => ({ n: 0 }));
vi.mock('../../../ui', async (orig) => {
  const ui = await orig<typeof import('../../../ui')>();
  return { ...ui, Tag: (p: Parameters<typeof ui.Tag>[0]) => { tags.n++; return ui.Tag(p); } };
});
afterAll(() => { cleanup(); vi.unstubAllGlobals(); });

test('a keystroke in the fact form does not repaint the facts table', async () => {
  const entries = [1, 2, 3].map((i) => ({ id: `mem-0000000${i}`, v: '1', scope: 'team', kind: 'trap', text: `Fact ${i}`, why: '', path: '', terms: '', confirmed: '2026-11-01', cites: [{ cite: `example/app:a.ts:${i}`, anchor: 'x' }] }));
  vi.stubGlobal('ResizeObserver', class { observe() {} unobserve() {} disconnect() {} });
  vi.stubGlobal('fetch', async () => ({ ok: true, status: 200, headers: { get: () => null }, json: async () => ({ on: true, entries }) }));
  dispatch({ event: 'viewer', data: { user: 'user@example.com', admin: true, teams: ['example'] } });
  render(<MemoryTab team={{ profile: 'example', repos: [{ slug: 'example/app', role: 'work' }] }} />);
  fireEvent.click(await screen.findByText('Add a fact'));
  const text = document.querySelector('[data-mem-f="text"]') as HTMLInputElement;
  tags.n = 0;
  await act(async () => { fireEvent.change(text, { target: { value: 'a new fact' } }); });
  expect(text.value).toBe('a new fact');
  expect(tags.n).toBe(0);
  // The filter still repaints the table.
  await act(async () => { fireEvent.change(document.querySelector('[data-mem-q]')!, { target: { value: 'Fact 2' } }); });
  expect(tags.n).toBeGreaterThan(0);
  expect(document.querySelectorAll('[data-mem]').length).toBe(1);
});
