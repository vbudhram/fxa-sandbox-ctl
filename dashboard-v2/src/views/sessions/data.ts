// The Sessions view's rules over the store, ported from renderSess, sideGroups, outcomeHtml, threadHtml and sessionDetails.
import type { SideGroup } from '../../app/store';
import { prHref, REPO_RE, stamp, usd } from '../../format';
import { pipeSnap, sessHeads, statsBounds } from '../../model';
import { AGENTS, type J, LIVE_SESSION, memo, SS, STATS, TEAMS } from '../../model/base';
import { pipe } from '../../model/pipeline';
import {
  ageOf, answerRows, bootFailed, chainOf, convTitle, fixGated, isFix, ownerName, SESS_STATES, sessDay, sessRoutine, sessStatus, sessUsd,
} from '../../model/sessions';
import { TEAM_RE } from '../../router';
import type { Session, Store } from '../../store/types';
import type { Tone } from '../../ui';

export const isLive = (x: J) => LIVE_SESSION.includes(x?.state);
// sessStatus gives the v1 dot class; done is the merged pair.
export const TONE_OF: Record<string, Tone> = { info: 'info', done: 'merged', dim: 'dim', bad: 'bad' };
export const num = (v: unknown): number | null => (v == null || v === '' || !Number.isFinite(Number(v)) ? null : Number(v));
const parse = (t: unknown): J => { try { return JSON.parse(String(t || '{}')); } catch { return {}; } };
export const summaryOf = (x: J): J => parse(x.summary);

// The Team chip: #sessions/<tab>?team=<profile>, set by a team's "Its sessions" link.
export const teamOf = (s: Store) => (TEAM_RE.test(s.route.query.team ?? '') ? s.route.query.team! : '');
// The Person select keeps an owner id; a v1 value is a name, so both match.
const ownerHit = (s: Store, x: J, o: string) => !o || x.owner === o || ownerName(s, x) === o;

const inTab = (x: J, tab: string) => (SESS_STATES[tab] ?? []).includes(x.state);
// The heads of the tab, with the Person and Team filters.
export function tabList(s: Store): Session[] {
  const tab = s.route.tab, team = teamOf(s), o = s.prefs.sowner;
  return sessHeads(SS(s)).filter((x) => inTab(x, tab) && ownerHit(s, x, o) && (!team || (x.profile || 'fxa') === team));
}
// The shown session: the hash's when it is in the tab, else the first head. The frame and the details read the same one.
export function pick(s: Store): Session | null {
  const sel = s.route.sel;
  return (sel && SS(s).find((x) => x.key === sel && inTab(x, s.route.tab))) || tabList(s)[0] || null;
}

// The owners on the current tab, by id, with the name as the label.
export function owners(s: Store): { id: string; name: string }[] {
  const by = new Map<string, string>();
  for (const x of sessHeads(SS(s)).filter((y) => inTab(y, s.route.tab))) if (x.owner) by.set(String(x.owner), ownerName(s, x) || String(x.owner));
  return [...by].map(([id, name]) => ({ id, name })).sort((a, b) => a.name.localeCompare(b.name));
}

// The repo of the shown pipeline team, for PR states and branch links.
export const repoOf = (s: Store): string => {
  const sn = pipeSnap(s) as J, r = sn?.team?.repo ?? sn?.repo ?? '';
  return REPO_RE.test(r) ? r : '';
};
export const branchHref = (repo: string, b: unknown) => (repo && b ? `https://github.com/${repo}/tree/${b}` : '');

// A conversation's PR, from any of its sessions, with its state when this repo's lists know it.
export function convPr(s: Store, x: J): { url: string; n: number; state: string } | null {
  const url = chainOf(x, SS(s)).map((y) => y.pr_url).find(Boolean);
  if (!prHref(url)) return null;
  const repo = repoOf(s), n = Number(String(url).match(/\/pull\/(\d+)/)?.[1]), mine = !!repo && String(url).includes(`/${repo}/`);
  const p = n && mine ? (STATS(s)?.prs ?? []).find((y: J) => y.n === n) : null;
  return { url: String(url), n, state: p?.state ?? (mine && ((pipeSnap(s) as J)?.open_prs ?? []).some((o: J) => o.number === n) ? 'OPEN' : '') };
}

export type Outcome = {
  result: { pr: { url: string; text: string; state: string } } | { branch: string; href: string } | { text: string } | null;
  diff: string; media: number; sessions: number; notes: string;
};
// What the conversation produced: the PR and its state, the branch or the diff, the media and the notes. null shows no card.
export function outcome(s: Store, x: J): Outcome | null {
  const ch = chainOf(x, SS(s)), first = (f: (y: J) => unknown) => ch.map(f).find(Boolean);
  const pr = convPr(s, x), pushed = first((y) => y.pushed_branch), diff = String(first((y) => summaryOf(y).diff) ?? ''), notes = String(first((y) => y.finish_notes) ?? '');
  const media = ch.reduce((n, y) => n + (Array.isArray(y.media) ? y.media.length : 0), 0), repo = repoOf(s);
  const ro = (TEAMS(s)?.teams ?? []).find((t: J) => t.profile === (x.profile || 'fxa'))?.read_only;
  const result: Outcome['result'] = pr ? { pr: { url: pr.url, text: pr.url.replace(/.*github\.com\//, '').replace('/pull/', ' #'), state: pr.state } }
    : pushed ? { branch: String(pushed), href: branchHref(repo, pushed) }
    : diff ? { text: ro ? 'diff posted in Slack (read-only team)' : 'changed files, not pushed' } : null;
  if (!result && !media && !notes && ch.length < 2) return null;
  return { result, diff, media, sessions: ch.length, notes };
}

// The bar's link: the branch, when the outcome card does not show the result already.
export function barLink(s: Store, x: J): { href: string; text: string } | null {
  if (outcome(s, x)?.result) return null;
  if (x.pr_url) return prHref(x.pr_url) ? { href: x.pr_url, text: `${String(x.pr_url).replace(/.*\/pull\//, 'PR #')} ↗` } : { href: '', text: String(x.pr_url) };
  if (x.pushed_branch) { const h = branchHref(repoOf(s), x.pushed_branch); return { href: h, text: h ? `${x.pushed_branch} ↗` : String(x.pushed_branch) }; }
  return null;
}

// The agents feed values that time a live session.
const agentNum = (s: Store, k: string) => num((AGENTS(s) as J)?.[k]);
export function pauseIn(s: Store, x: J, now: number): number | null {
  const idle = agentNum(s, 'session_idle_seconds');
  return x.state === 'active' && !x.agent_alive && x.turn_open !== '1' && x.last_activity && idle != null ? Math.max(0, Math.round(idle - (now - x.last_activity))) : null;
}
export function endsIn(s: Store, x: J, now: number): number | null {
  const max = agentNum(s, 'session_max_run_seconds');
  return isLive(x) && x.booted_at && max != null ? Math.max(0, Math.round(max - (now - x.booted_at))) : null;
}
export const modelOf = (s: Store, x: J): string => {
  const a: J = x.agent || {}, m: J = (AGENTS(s) as J)?.session_models ?? {};
  return (x.runtime || 'claude') === 'claude' ? a.model || m.claude || '' : m.codex || '';
};

// The side list: the tab's heads in day groups.
// memo: the shell asks on each of its repaints; the ages and the day groups move once a minute.
export const sideGroups = memo((s) => [s.sessions, s.feeds.agents, s.feeds.stats, s.feeds.teams, pipe(s), s.viewer, s.route.tab, s.route.query.team, s.prefs.sowner, Math.floor(Date.now() / 60000)], (s): SideGroup[] | null => {
  if (!AGENTS(s)) return null;
  const all = SS(s), tab = s.route.tab, o = s.prefs.sowner;
  const items = tabList(s).map((x) => {
    const [st] = sessStatus(x), c = chainOf(x, all).reduce((n, y) => n + (sessUsd(s, y) || 0), 0), pr = convPr(s, x), gate = fixGated(s, x);
    return {
      day: sessDay(x.created), id: x.key, d: isLive(x) ? 'live' : bootFailed(x) ? 'bad' : '', t: isFix(x) ? sessRoutine(s, x) : convTitle(s, x), tip: stamp(x.created),
      m: [c && !gate ? usd(c) : '', isFix(x) ? '' : sessRoutine(s, x) || (o ? '' : ownerName(s, x)), ageOf(x.created), tab === 'live' ? st : bootFailed(x) ? 'boot failed' : '',
        pr && !gate ? `PR ${pr.state ? pr.state.toLowerCase() : '#' + pr.n}` : ''],
      // A gated fix is found by its key only: its request is a team admin's.
      find: gate ? x.key : `${x.key} ${ownerName(s, x)} ${chainOf(x, all).map((y) => y.request ?? '').join(' ')}`,
    };
  });
  return ['Today', 'Yesterday', 'This week', 'Older'].map((g) => ({ group: g, items: items.filter((i) => i.day === g) })).filter((g) => g.items.length);
});

export type HistMsg = { key: string; role: string; at?: number; text?: string; name?: string; image?: string };
export type ThreadItem = { id: string; key: string; at: number; sep: string } & ({ role: 'media'; files: string[] } | { role: 'agent' | 'action' | 'person'; text: string; name?: string; image?: string });

// The thread: messages and the media of every session in the chain. A turn's files show under the reply that closes it.
export function threadItems(h: HistMsg[], sessions: Session[]): ThreadItem[] {
  const keys = [...new Set(h.map((m) => m.key))], byKey = new Map(sessions.map((x) => [x.key, x]));
  const replyAfter = (k: string, t: number) => h.find((m) => m.key === k && m.role === 'agent' && (m.at ?? 0) >= t)?.at;
  type Row = { m?: HistMsg; files?: string[]; key: string; at: number; sortAt: number };
  const rows: Row[] = h.map((m) => ({ m, key: m.key, at: m.at ?? 0, sortAt: m.at ?? 0 }));
  for (const k of keys) for (const f of ((byKey.get(k)?.media ?? []) as J[])) {
    const r = replyAfter(k, f.at);
    rows.push({ files: [String(f.name)], key: k, at: f.at, sortAt: r != null ? r + 0.001 : f.at });
  }
  rows.sort((a, b) => a.sortAt - b.sortAt || a.at - b.at);
  const merged: Row[] = [];
  for (const r of rows) {
    const p = merged[merged.length - 1];
    if (r.files && p?.files && p.key === r.key) p.files.push(...r.files);
    else merged.push(r.files ? { ...r, files: [...r.files] } : r);
  }
  let last: string | null = null;
  const seen = new Map<string, number>();
  return merged.map((r) => {
    const sep = r.key !== last ? `${last ? `Resumed as ${r.key}` : r.key} · ${stamp(r.at)}` : '';
    last = r.key;
    // Two messages can share a key and a time: a count keeps each id unique.
    const base = `${r.key}:${r.at}:${r.files ? 'media' : r.m!.role}`, n = seen.get(base) ?? 0;
    seen.set(base, n + 1);
    const id = `${base}:${n}`;
    if (r.files) return { id, key: r.key, at: r.at, sep, role: 'media', files: r.files };
    const m = r.m!, role = m.role === 'agent' || m.role === 'action' ? m.role : 'person';
    return { id, key: r.key, at: r.at, sep, role, text: String(m.text ?? ''), name: m.name, image: m.image };
  });
}
export const isVideo = (n: string) => /\.(mp4|webm)$/i.test(n);
export const mediaUrl = (k: string, n: string) => `/api/media?key=${encodeURIComponent(k)}&name=${encodeURIComponent(n)}`;
export function sharedWhat(files: string[]): string {
  const what = files.every(isVideo) ? 'video' : files.some(isVideo) ? 'screenshots and videos' : 'screenshot';
  return files.length > 1 ? `${files.length} ${what === 'screenshot' ? 'screenshots' : what === 'video' ? 'videos' : what}` : `a ${what}`;
}

// Quick answers in the Stats range, newest first by parsed time.
export function answersIn(s: Store, now = Date.now()): J[] {
  const f = s.prefs.statsFilter, [lo, hi] = statsBounds(f.range, now, { from: f.from, to: f.to });
  return answerRows(s).map((r: J) => ({ r, t: typeof r.ms === 'number' ? r.ms : Date.parse(r.at) }))
    .filter(({ t }) => t >= lo && t < hi).sort((a, b) => b.t - a.t).map(({ r }) => r);
}
