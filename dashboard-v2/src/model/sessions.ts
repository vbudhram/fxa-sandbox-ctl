// Sessions and quick answers, ported from the retired v1 dashboard.
import { ago } from '../format';
import type { Session, Store } from '../store/types';
import { type J, LIVE_SESSION, SS, STATS, TEAM_ADMIN, memo } from './base';
import { teamLabel } from './teams';

// Slack markup as a person reads it: <url|label> is the label, any other link its PR, ticket or host, :emoji: and <@U1> go.
export function slackText(t: unknown): string {
  const label = (u: string) => {
    const g = u.match(/github\.com\/([^/]+\/[^/]+)\/(?:pull|issues)\/(\d+)/), j = u.match(/\/browse\/([A-Z][A-Z0-9]+-\d+)/);
    if (g) return `${g[1]}#${g[2]}`;
    if (j) return j[1] ?? u;
    try { return new URL(u).host; } catch { return u; }
  };
  // A label that is the URL itself (Slack writes those) reads as the short form too.
  return String(t ?? '').replace(/<(https?:\/\/[^\s>|]+)(?:\|([^>]*))?>?/g, (_, u: string, l?: string) => (l && !u.endsWith(l.replace(/^https?:\/\//, '')) ? l : label(u)))
    .replace(/https?:\/\/[^\s<>]+/g, label).replace(/<[@#!][^>]*>/g, '').replace(/(^|\s):[a-z0-9_+-]+:(?=\s|$|[,.!?])/g, '$1').replace(/\s{2,}/g, ' ').trim();
}

// The first line of a request, as a title.
export function firstLine(t: unknown): string {
  const [head = '', ctx = ''] = String(t ?? '').split('\n\nEarlier messages');
  const owner = (ctx.match(/^> owner: (.+)$/m)?.[1] ?? '').replace(/^(@\S+\s+)+/, '');
  const ci = head.match(/^CI failed on the PR: ([^\n]+)/), ans = head.match(/^My answer: (.+)$/m);
  let line = ci ? `CI failed: ${ci[1]}` : /^Copilot reviewed the PR/.test(head) ? 'Copilot review round'
    : /^The engineer tapped Open PR/.test(head) ? 'Open PR' : ans ? (ans[1] ?? '')
    : /^\(From someone else/.test(head) ? head.split('\n')[1] ?? ''
    : /^Messages in the thread that were not for you/.test(head) ? 'Reply in the thread' : head.split('\n')[0] ?? '';
  if (!/\w/.test(line) || /^The host uses these drafts/.test(line)) line = owner || line;
  return slackText(line).slice(0, 160) || '(no request)';
}

// A short age for list meta: "5m", "3h", "2d"; e is an epoch in seconds.
export const ageOf = (e: unknown): string => (e ? ago(Math.max(0, Math.round(Date.now() / 1000 - Number(e)))).replace(' ago', '') : '');

// The Stats cost of each Slack and dependency fix row, by key.
const statUsd = memo((s) => [STATS(s)], (s) => new Map<string, J>((STATS(s)?.rows ?? []).filter((r: J) => r.src === 'slack' || r.src === 'depfix').map((r: J) => [r.key, r.usd])));
// One cost per session on every view: the live runner's (the proxy's total so far), else the Stats row's.
export function sessUsd(s: Store, x: Session): J {
  const a: J = x.agent || {};
  let sm: J = {};
  try { sm = JSON.parse((x.summary as string) || '{}'); } catch { /* not JSON */ }
  return a.cost_usd ?? a.cost_so_far ?? statUsd(s).get(x.key) ?? sm.cost;
}

// One row per Slack conversation: a resume's newer session stands for the ones it resumed.
export function sessHeads(ss: Session[]): Session[] {
  const older = new Set(ss.map((x) => x.resume_from).filter(Boolean));
  return ss.filter((x) => !older.has(x.key));
}
// A head and the sessions behind it, newest first.
// One key map per list: SS(s) keeps its array until the sessions change, and the floor asks once per live session.
const BY = new WeakMap<Session[], Map<string, Session>>();
export function chainOf(x: Session, ss: Session[]): Session[] {
  let by = BY.get(ss);
  if (!by) BY.set(ss, (by = new Map(ss.map((y) => [y.key, y]))));
  const out: Session[] = [];
  for (let y: Session | undefined = x; y && out.length < 50; y = by.get(y.resume_from as string)) out.push(y);
  return out;
}

// A team admin's feed has fix_pr; others get only fix_run (redact_fix in server.py).
export const isFix = (x: J): boolean => !!(x?.fix_pr || x?.fix_run);
export function fixLabel(x: J, admin: boolean): string {
  const n = String(x.fix_pr ?? ''), t = x.fix_trigger, a = x.fix_actor || '';
  const by = t === 'blender' ? 'BLEnder' : t === 'label' ? (a ? `label by ${a}` : 'label') : t === 'manual' ? (a ? `Run now by ${a}` : 'Run now') : '';
  return admin && /^\d+$/.test(n) ? `Dependency fix: #${n}${by ? ` (${by})` : ''}` : 'Dependency fix';
}
export const fixGated = (s: Store, x: J) => isFix(x) && !TEAM_ADMIN(s).admin;
export const sessRoutine = (s: Store, x: J): string => isFix(x) ? fixLabel(x, !!TEAM_ADMIN(s).admin)
  : x.routine_run ? `Routine: ${x.routine_name || `run ${x.routine_run}`} (${teamLabel(s, x.profile || 'fxa')})` : '';

// A conversation's title: what the person first asked; a routine run's title is the routine's name.
export const convTitle = (s: Store, x: J): string => {
  if (x.routine_run && !isFix(x)) return `${x.routine_name || 'Routine'} run`;
  const ch = chainOf(x, SS(s));
  return firstLine(ch[ch.length - 1]?.request);
};
// The first recorded name of each Slack user, in list order, as the v1 find gives it.
const NAMES = memo((s) => [SS(s)], (s) => {
  const m = new Map<unknown, string>();
  for (const y of SS(s)) if (y.owner_name && !m.has(y.owner)) m.set(y.owner, y.owner_name as string);
  return m;
});
// A session's owner: its own name, else the name another session of the same Slack user recorded.
export function ownerName(s: Store, x: J): string {
  if (x.owner_name) return x.owner_name;
  return NAMES(s).get(x.owner) || x.owner || '';
}

export const sessTabOf = (x: J) => (x.state === 'paused' ? 'paused' : LIVE_SESSION.includes(x.state) ? 'live' : 'stopped');
export const sessHref = (k: unknown) => (/^agent-[a-z0-9]{4,12}$/.test(String(k || '')) ? `#sessions/stopped/${k}` : '');
// The list's day groups, from a session's start (seconds).
export function sessDay(c: unknown): string {
  const d = new Date().setHours(0, 0, 0, 0) / 1000 - Number(c || 0);
  return d <= 0 ? 'Today' : d <= 86400 ? 'Yesterday' : d <= 6 * 86400 ? 'This week' : 'Older';
}

export const SESS_STATES: Record<string, string[]> = { live: ['starting', 'active', 'wrapping'], paused: ['paused'], stopped: ['stopped', 'failed', 'pr_open'], answers: [] };
// A boot failure: the record says failed for one poll, then stopped with this reason.
export const bootFailed = (x: J) => x.state === 'failed' || x.stop_reason === 'boot failed';
export function sessStatus(x: J): [string, string] {
  return x.state === 'starting' ? ['booting', 'info'] : x.state === 'wrapping' ? [x.wrap_mode === 'push' ? 'pushing branch' : 'opening PR', 'info']
    : x.state === 'pr_open' ? ['PR open', 'done'] : x.state === 'paused' ? ['paused · a reply resumes', 'dim'] : bootFailed(x) ? ['boot failed', 'bad']
    : x.state === 'stopped' ? ['stopped', 'dim'] : x.agent_alive ? ['working', 'info'] : x.turn_open === '1' ? ['turn died', 'bad'] : ['waiting on owner', 'info'];
}

// Quick answers (no sandbox) from the Stats rows, newest first.
export const answerRows = memo((s) => [STATS(s)], (s): J[] => (STATS(s)?.rows ?? []).filter((r: J) => r.src === 'answer')
  .sort((a: J, b: J) => Number(b.at > a.at) - Number(b.at < a.at)));
// The Slack link of a thread "C123:1700000000.0001", with the workspace host from a session in the same channel.
// The workspace host of each channel, from the first session in it: one pass, not one per answer row.
const HOSTS = memo((s) => [SS(s)], (s) => {
  const m = new Map<string, string>();
  for (const x of SS(s)) {
    const g = /^https:\/\/([a-z0-9.-]+\.slack\.com)\/archives\/([A-Z0-9]+)\//.exec(String(x.slack_url || ''));
    if (g && !m.has(g[2]!)) m.set(g[2]!, g[1]!);
  }
  return m;
});
export function threadUrl(s: Store, th: unknown): string {
  const [c, ts] = String(th || '').split(':');
  if (!c || !ts) return '';
  const h = HOSTS(s).get(c);
  return h ? `https://${h}/archives/${c}/p${ts.replace('.', '')}` : '';
}
