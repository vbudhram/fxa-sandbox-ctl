// The Stats filters: the saved filter (localStorage.statsFilter) and the filter for the visit that an Overview link sets.
import { create } from 'zustand';
import { STATS_RANGES } from '../../model/stats';
import { setPref, store, useApp } from '../../store';
import { SF_DEFAULT } from '../../store/prefs';
import type { StatsFilter } from '../../store/types';

export type Tab = 'spend' | 'prs' | 'runners' | 'pipeline';
export const TABS: Tab[] = ['spend', 'prs', 'runners', 'pipeline'];
export const TAB_TITLE: Record<Tab, string> = { spend: 'Spend', prs: 'Pull requests', runners: 'Runners and LLM', pipeline: 'Pipeline' };
// The filters each tab reads; the range applies to every tab.
export const STATS_USES: Record<Tab, (keyof StatsFilter)[]> = { spend: ['src', 'kind', 'team', 'model', 'q'], prs: ['src', 'team', 'q'], runners: ['team'], pipeline: [] };
export const SF_SRC: Record<string, string> = { pipeline: 'Pipeline runs', slack: 'Slack sessions', answer: 'Quick answers', pass: 'Passes and triage', depfix: 'Dependency fixes' };
export const KIND: Record<string, string> = { fix: 'Fix', feedback: 'Review feedback', rebase: 'Rebase', pass: 'Pass', triage: 'Triage', session: 'Session', answered: 'Answered', upgraded: 'Upgraded', 'not recorded': 'Not recorded' };
export const tabOf = (t: string): Tab => (TABS.includes(t as Tab) ? (t as Tab) : 'spend');

// tmp is the filter an Overview link set: no change saves it until the person picks Keep these.
export const useTmp = create<{ tmp: StatsFilter | null }>(() => ({ tmp: null }));

export function useFilter(): StatsFilter {
  const saved = useApp((s) => s.prefs.statsFilter);
  const tmp = useTmp((s) => s.tmp);
  return tmp ?? saved;
}

export function setFilter(patch: Partial<StatsFilter>) {
  const tmp = useTmp.getState().tmp;
  if (tmp) useTmp.setState({ tmp: { ...tmp, ...patch } });
  else setPref('statsFilter', { ...store.getState().prefs.statsFilter, ...patch });
}
export const restoreFilter = () => useTmp.setState({ tmp: null });
export function keepFilter() {
  const tmp = useTmp.getState().tmp;
  if (tmp) setPref('statsFilter', tmp);
  useTmp.setState({ tmp: null });
}

// #stats/<tab>?range=<r>&src=<s> from Overview: a bad value does nothing, as in v1.
export function filterFromQuery(q: { range?: string; src?: string }): boolean {
  if (q.range == null && q.src == null) return false;
  const range = q.range ?? SF_DEFAULT.range, src = q.src ?? 'all';
  if (!STATS_RANGES.some(([k]) => k === range) || !(src === 'all' || Object.hasOwn(SF_SRC, src))) return false;
  useTmp.setState({ tmp: { ...SF_DEFAULT, range, src } });
  return true;
}

export const isFiltered = (sf: StatsFilter) => (Object.keys(SF_DEFAULT) as (keyof StatsFilter)[]).some((k) => sf[k] !== SF_DEFAULT[k]);
export const isOn = (tab: Tab, sf: StatsFilter) => (f: keyof StatsFilter) => STATS_USES[tab].includes(f) && sf[f] !== SF_DEFAULT[f];
