import { expect, test } from 'vitest';
import type { Store } from '../store/types';
import { teamUse } from './teams';

test('a team used only by the pipeline or a routine has a last use, so it does not read as never used', () => {
  const at = new Date(Date.now() - 3600_000).toISOString();
  const s = { feeds: { stats: { data: { rows: [{ at, src: 'pipeline', profile: 'example', key: 'EX-1', usd: 2 }, { at, src: 'routine', profile: 'example', key: 'agent-a', usd: 1 }] } } } } as unknown as Store;
  const u = teamUse(s)!.example;
  expect(u.last).toBeGreaterThan(0);
  expect(u.n).toBe(0);
});
