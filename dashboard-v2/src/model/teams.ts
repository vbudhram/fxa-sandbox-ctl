// Teams, routines facts and errors per team, ported from the retired v1 dashboard.
import type { Store } from '../store/types';
import { ERRS, type J, RTSUM, SS, STATS, TEAMS, TEAM_ADMIN, memo } from './base';

export const APP_FAIL = 'the GitHub App check failed';
export const teamName = (t: J): string => t.label || t.profile;
export const teamLabel = (s: Store, p: string): string => { const t = (TEAMS(s)?.teams ?? []).find((x: J) => x.profile === p); return t ? teamName(t) : p; };
export const teamLevel = (t: J): 'bad' | 'warn' | undefined => (['bad', 'warn'] as const).find((l) => (t.issues ?? []).some((i: J) => i.level === l));

// Routine facts come only from the admin routes; a non-admin sees none.
export const rtSum = (s: Store, p: string): J => (TEAM_ADMIN(s).admin ? RTSUM(s)?.teams?.[p] ?? null : null);
// Who manages a team's routines: TEAM_ADMINS, and the admins the team's record names.
export const rtAdmin = (s: Store, p: string) => !!TEAM_ADMIN(s).admin || (TEAM_ADMIN(s).teams ?? []).includes(p);
// Routines are skipped when the team's spend cannot be read (fail closed): for an admin that needs attention.
export const spendSkip = (s: Store, t: J) => !!(rtSum(s, t.profile)?.routines && (t.issues ?? []).some((i: J) => i.text === 'spend cannot be read'));
// A team needs attention for a bad or warn issue, or (admins) a failed routine.
export const teamNeeds = (s: Store, t: J) => !!(teamLevel(t) || rtSum(s, t.profile)?.failed || spendSkip(s, t));
// The rail badge: bad for a bad issue, warn for a warn issue, a failed routine or a skipped spend read.
export const teamBadge = (s: Store, ts: J[]): '' | 'warn' | 'bad' => ts.some((t) => t.load_error || teamLevel(t) === 'bad') ? 'bad'
  : ts.some((t) => teamLevel(t) === 'warn' || rtSum(s, t.profile)?.failed || spendSkip(s, t)) ? 'warn' : '';
export function teamReason(s: Store, t: J): string {
  const i = (t.issues ?? []).find((x: J) => x.level === 'bad') ?? (t.issues ?? []).find((x: J) => x.level === 'warn'), r = rtSum(s, t.profile);
  // A record team that is not active leads with its status.
  const st = t.access?.record && t.access.status !== 'active' ? t.access.status : '';
  return [st || i?.text || (spendSkip(s, t) ? "routines are skipped: the team's spend cannot be read" : ''),
    r?.routines ? `${r.routines} routine${r.routines === 1 ? '' : 's'}` : '', r?.failed ? `${r.failed} failed` : ''].filter(Boolean).join(' · ');
}
// [short for the table, full for its title].
export const teamAccess = (t: J): [string, string] => t.access?.open === 'built-in' ? ['everyone', 'everyone (built into the bot)'] : !t.access ? ['unknown', 'access unknown (bot env not readable)']
  : t.access.record && t.access.status !== 'active' ? [t.access.status, 'a team record that is not active: nobody can start it']
  : t.access.open === true ? ['open', 'open to anyone allowed here'] : [`${t.access.users} user${t.access.users === 1 ? '' : 's'}`, 'only the users PROFILE_USERS names'];

// Open or reopened: a quiet signature counts as fixed.
export const errOpen = (e: J) => e.status === 'open' || e.status === 'reopened';
// Per team: the open errors through their sessions; null while the errors are unknown.
export const teamErrs = memo((s) => [s.feeds.errors, s.sessions], (s): Record<string, number> | null => {
  const errs = ERRS(s);
  if (!errs) return null;
  const prof = new Map(SS(s).map((x) => [x.key, x.profile || 'fxa'])), out: Record<string, number> = {};
  errs.filter(errOpen).forEach((e) => { new Set((e.keys ?? []).map((k: string) => prof.get(k)).filter(Boolean)).forEach((p) => { out[p as string] = (out[p as string] ?? 0) + 1; }); });
  return out;
});

const rowT = (r: J) => r.t0 ?? (r.ms ?? Date.parse(r.at)) / 1000;
// Per-team use in 30 days from the stats rows: cost and last use from every source, the count is Slack conversations.
export const teamUse = memo((s) => [STATS(s)], (s): Record<string, J> | null => {
  const st = STATS(s);
  if (!st?.rows) return null;
  const cut = Date.now() / 1000 - 30 * 86400, u: Record<string, J> = {};
  for (const r of st.rows) {
    const t = rowT(r); if (!(t >= cut)) continue;
    const x = u[r.profile || 'fxa'] ??= { n: 0, live: 0, usd: 0, last: 0, slack_usd: 0, pipe_usd: 0 };
    x.usd += r.usd || 0; x.last = Math.max(x.last, t);
    if (r.src === 'pipeline' || r.src === 'pass') x.pipe_usd += r.usd || 0; else x.slack_usd += r.usd || 0;
    if (r.src === 'pipeline') x.runs = (x.runs ?? 0) + 1;
    if (r.src !== 'slack') continue;
    (x.convs ??= new Set()).add(r.conv ?? r.key); x.n = x.convs.size; x.live += r.live ? 1 : 0;
  }
  return u;
});
// Per team: runs and PRs in 7 days from the stats rows.
export const teamWeek = memo((s) => [STATS(s)], (s): Record<string, { runs: number; prs: Set<unknown> }> | null => {
  const st = STATS(s);
  if (!st?.rows) return null;
  const cut = Date.now() / 1000 - 7 * 86400, out: Record<string, { runs: number; prs: Set<unknown> }> = {};
  st.rows.forEach((r: J) => { if (!(rowT(r) >= cut)) return; const x = out[r.profile || 'fxa'] ??= { runs: 0, prs: new Set() }; x.runs++; if (r.pr) x.prs.add(r.pr); });
  return out;
});
