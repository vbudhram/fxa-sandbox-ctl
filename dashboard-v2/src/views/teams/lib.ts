// The Teams rules of the retired v1 dashboard with no React: the side list, the cells, the banner, and the record forms.
import type { SideGroup, SideItem } from '../../app/store';
import { ago, usd } from '../../format';
import { ERRS, type J, memo, TEAMS, TEAM_RE } from '../../model/base';
import { localDay } from '../../model/stats';
import { APP_FAIL, errOpen, teamAccess, teamLevel, teamName, teamNeeds, teamReason, teamUse } from '../../model/teams';
import type { Store } from '../../store/types';

export { TEAM_RE };
export const NO_USE = { n: 0, live: 0, usd: 0, last: 0 };
export const GOAL_MAX = 2560;
// The keys a runner reads: on an active team a change to one needs a new test (lib/teams.sh _teams_runner_keys).
export const RUNNER_KEYS = ['repos', 'stack', 'runner', 'egress', 'mcp', 'skills', 'boot', 'secrets'];
// FxA stays active, so the operator changes the keys a runner reads with the CLI.
export const FXA_RO = ['repos', 'goal', 'tools', 'skills', 'runner', 'egress', 'boot', 'secrets'];

const now = () => Date.now() / 1000;
// "5 min ago" for an epoch in seconds, and whole minutes since one.
export const sinceAgo = (t: number) => ago(Math.round(now() - t));
export const minsSince = (t: number) => Math.max(0, Math.floor((now() - t) / 60));
export const plural = (n: number, one: string, many = `${one}s`) => `${n} ${n === 1 ? one : many}`;

export const teamDraftOf = (t: J) => !!(t?.access?.record && t.access.status !== 'active');
export const teamCap = (n: string) => n.split('-').map((w) => (w ? w[0]!.toUpperCase() + w.slice(1) : w)).join(' ');
// The server counts bytes: near the limit, the count says so.
export function textSize(s: string | null | undefined, max: number) {
  const n = new TextEncoder().encode(s ?? '').length;
  return n >= 0.9 * max ? `${n} of ${max} bytes, ${max - n} left` : `${n} of ${max}`;
}
export const teamTools = (m: unknown, short?: boolean) =>
  m == null ? (short ? 'bot default' : "the bot's default tools") : Array.isArray(m) && m.length ? m.join(', ') : 'none';
// [tone, short word, full text] for a work repo's shipping.
export const repoShip = (r: J): [string, string, string] =>
  r.why === APP_FAIL ? ['info', 'write unknown', 'GitHub App check failed; write unknown'] : r.write ? ['ok', '', 'opens a draft PR'] : ['warn', 'diff', 'ships as a diff'];

// The text that the side search matches (v1 teamMatch).
export const teamFind = (t: J) => [t.profile, t.label, ...(t.repos ?? []).map((r: J) => r.slug), ...(t.mcp ?? []), ...(t.access?.jira ?? [])].join(' ');
export const teamSort = (a: J, b: J) => Number(!!teamLevel(b)) - Number(!!teamLevel(a)) || teamName(a).localeCompare(teamName(b));

export function teamItem(s: Store, t: J, use: Record<string, J> | null): SideItem {
  if (t.load_error) return { id: t.profile, d: 'bad', t: t.profile, m: ['profile.conf did not load'], find: teamFind(t) };
  const x = use?.[t.profile] ?? NO_USE, needs = teamNeeds(s, t);
  return {
    id: t.profile, d: needs ? teamLevel(t) || 'warn' : x.live ? 'live' : 'ok', t: teamName(t), find: teamFind(t),
    m: needs ? [teamReason(s, t)] : [teamAccess(t)[0], t.read_only ? 'read-only' : '', t.budget ? usd(t.budget.month_usd) : '', use ? (x.last ? sinceAgo(x.last) : 'never used') : ''],
  };
}

// The side list: All teams, then the teams that need attention, then the rest.
export function teamSide(s: Store): SideGroup[] | null {
  const T = TEAMS(s);
  if (!T) return null;
  const ts: J[] = T.teams, use = teamUse(s), errs = ERRS(s), er = errs ? errs.filter(errOpen).length : null, bt = ts.filter((t) => t.budget);
  const rows = [...ts].sort(teamSort);
  const all: SideItem = { id: '__all', d: 'ok', t: 'All teams', m: [plural(ts.length, 'team'), bt.length ? `${usd(bt.reduce((n, t) => n + t.budget.month_usd, 0))} this month` : '', er == null ? '' : plural(er, 'open error')] };
  return [{ items: [all] }, { group: 'Needs attention', items: rows.filter((t) => t.load_error || teamNeeds(s, t)).map((t) => teamItem(s, t, use)) },
    { group: 'Teams', items: rows.filter((t) => !t.load_error && !teamNeeds(s, t)).map((t) => teamItem(s, t, use)) }].filter((g) => g.items.length);
}

// The test state of a team: an active team keeps its pass after edits that a runner never reads.
export function teamTestState(t: J, data?: J): 'running' | 'failed' | 'passed' | 'none' {
  const x = data ?? t.test;
  if (!x) return 'none';
  if (x.result === 'running' || x.result === 'failed') return x.result;
  if (x.result === 'passed' || (x.tested != null && (x.tested === x.generation || t.access?.status === 'active'))) return 'passed';
  return 'none';
}
// Who can start a record team, from the loaded record or the feed's counts. A channel lets nobody start it.
export function teamWho(t: J, rec?: J) {
  const a = rec?.access ?? null;
  if (t.access?.open === 'built-in') return 'Everyone';
  if (a ? a.open : t.access?.open === true) return 'Anyone the bot allows';
  // The old access.users list and the people marked Can start.
  const n = a ? new Set([...(a.users ?? []), ...(rec?.people ?? []).filter((p: J) => p.start === true).map((p: J) => p.slack)]).size : t.access?.listed ?? t.access?.users ?? 0;
  return n ? `${n} ${n === 1 ? 'person' : 'people'}` : 'Nobody';
}

export type Budget = { kind: 'error' } | { kind: 'none' } | { kind: 'cap'; spent: number; cap: number; pct: number; tone: 'ok' | 'warn' | 'bad' } | { kind: 'nocap'; spent: number };
export function budgetOf(t: J): Budget {
  const b = t.budget;
  if (t.budget_error) return { kind: 'error' };
  if (!b) return { kind: 'none' };
  if (!b.month_cap) return { kind: 'nocap', spent: b.month_usd };
  return { kind: 'cap', spent: b.month_usd, cap: b.month_cap, pct: (100 * b.month_usd) / b.month_cap,
    tone: b.month_usd >= b.month_cap ? 'bad' : b.month_usd >= 0.9 * b.month_cap ? 'warn' : 'ok' };
}

// The first problem of a team, short; a draft's "nobody can start it" is its step left, not a problem.
export function teamProblem(t: J): null | { tag: string; tone: 'warn' | 'bad'; text: string; mono?: boolean } {
  const app = (x: J) => /^(\S+): the agent's GitHub App is not installed/.exec(x.text);
  const is = (t.issues ?? []).filter((x: J) => !(teamDraftOf(t) && x.text === 'nobody can start it'));
  const i = is.find((x: J) => x.level === 'bad') ?? is.find((x: J) => x.level === 'warn') ?? is.find(app);
  if (!i) return null;
  const m = app(i);
  return m ? { tag: 'App missing', tone: 'warn', text: m[1]!, mono: true } : { tag: i.level === 'bad' ? 'problem' : 'check', tone: i.level === 'bad' ? 'bad' : 'warn', text: i.text };
}

// The All teams tiles, once per change of the teams, the routine summary and the viewer.
export const allTeams = memo((s) => [s.feeds.teams, s.teamsUi.summary, s.viewer], (s: Store) => {
  const ts: J[] = TEAMS(s)?.teams ?? [], ok = ts.filter((t) => !t.load_error), drafts = ok.filter(teamDraftOf), act = ok.filter((t) => !teamDraftOf(t));
  const bt = ok.filter((t) => t.budget), spent = bt.reduce((n, t) => n + t.budget.month_usd, 0);
  const top = [...bt].sort((a, b) => b.budget.month_usd - a.budget.month_usd)[0];
  const needs = ts.filter((t) => t.load_error || (teamNeeds(s, t) && !teamDraftOf(t))).length;
  const rec = act.filter((t) => t.access?.record), passed = rec.filter((t) => teamTestState(t) === 'passed').length;
  return { ts, ok, drafts, act, bt, spent, top, needs, rec: rec.length, passed };
});

// The team's banner: the first of the problems that stop work, with its action.
export function teamBanner(t: J, admin: boolean, r: J): { head: string; why: string; act: [string, string, boolean?] | null; more: number } | null {
  const base = `#teams/${t.profile}`, has = (re: RegExp) => (t.issues ?? []).some((i: J) => re.test(i.text));
  const out: [string, string, [string, string, boolean?] | null][] = [];
  if (has(/spend cap reached/)) out.push(['The team reached its spend cap', 'Every new session and routine run of the team is refused until the cap resets or the operator raises it.', null]);
  if (t.access?.record && t.access.status !== 'active') out.push([`The team is ${t.access.status}`, 'Nobody can start it until it is tested and active.', [`${base}/settings`, 'Test and activate', true]]);
  else if (has(/nobody can start it/)) out.push(['Nobody can start this team', 'It has no users and no channel rules, and it is not open.', [`${base}/settings`, 'Add people']]);
  if (admin && r?.routines && has(/spend cannot be read/)) out.push(['Routines are skipped', "The team's spend cannot be read, so each run is refused (fail closed).", null]);
  if (admin && r?.failed) out.push([`${plural(r.failed, 'routine')} failed`, r.last_failed ? `${r.last_failed.name ?? ''}: ${r.last_failed.reason ?? 'no reason recorded'}` : '', [`${base}/routines`, 'Open Routines']]);
  const f = out[0];
  return f ? { head: f[0], why: f[1], act: f[2], more: out.length - 1 } : null;
}

export function teamReadiness(t: J): [string, 'good' | 'required' | 'unknown', string][] {
  const has = (re: RegExp) => (t.issues ?? []).some((i: J) => re.test(i.text)), work = (t.repos ?? []).filter((r: J) => r.role === 'work');
  const access = t.access?.open === 'built-in' ? 'good' : !t.access ? 'unknown' : (t.access.record && t.access.status !== 'active') || has(/nobody can start it/) ? 'required' : 'good';
  return [['Config', t.load_error ? 'required' : 'good', 'profile.conf loads'], ['Access', access, teamAccess(t)[1]],
    ['Repos', work.length ? 'good' : 'required', work.map((r: J) => r.slug).join(', ') || 'no work repo']];
}

const rowT = (r: J) => r.t0 ?? (r.ms ?? Date.parse(r.at)) / 1000;
const isPipe = (r: J) => r.src === 'pipeline' || r.src === 'pass';
// 30 days of one team's stats rows, oldest first, in v1's 24 h steps back from now: the count and the cost by source.
export function teamDays(rows: J[] | null | undefined, p: string, at = Date.now()) {
  const out = [...Array(30)].map((_, i) => ({ day: localDay(at - (29 - i) * 86400000), n: 0, slack: 0, pipe: 0 }));
  for (const r of rows ?? []) {
    if ((r.profile || 'fxa') !== p) continue;
    const d = Math.floor((at / 1000 - rowT(r)) / 86400), x = out[29 - d];
    if (!(d >= 0 && d < 30) || !x) continue;
    x.n++;
    if (isPipe(r)) x.pipe += r.usd || 0;
    else x.slack += r.usd || 0;
  }
  return out;
}
// The daily counts of every team in one pass over the rows: All teams has a sparkline per team.
// The same days as teamDays, without its day labels.
export function teamDaysBy(rows: J[] | null | undefined, at = Date.now()): (p: string) => number[] {
  const by = new Map<string, number[]>();
  for (const r of rows ?? []) {
    const d = Math.floor((at / 1000 - rowT(r)) / 86400), p = r.profile || 'fxa';
    if (!(d >= 0 && d < 30)) continue;
    const n = by.get(p) ?? by.set(p, Array(30).fill(0)).get(p)!;
    n[29 - d] = n[29 - d]! + 1;
  }
  return (p) => by.get(p) ?? Array(30).fill(0);
}
// This month's spend by day, and the straight-line projection to the month end.
export function teamBurn(rows: J[] | null | undefined, p: string, monthUsd: number, at = Date.now()) {
  const d0 = new Date(at), first = new Date(d0.getFullYear(), d0.getMonth(), 1).getTime(), ndays = new Date(d0.getFullYear(), d0.getMonth() + 1, 0).getDate();
  const today = d0.getDate(), per = Array(ndays).fill(0) as number[];
  for (const r of rows ?? []) {
    if ((r.profile || 'fxa') !== p) continue;
    const t = rowT(r) * 1000;
    if (t >= first && t < at + 1) per[new Date(t).getDate() - 1]! += r.usd || 0;
  }
  let run = 0;
  const cum = per.slice(0, today).map((v) => (run += v));
  // The budget is the spend of record: the line ends on it, and the projection starts there.
  return { ndays, today, cum: cum.map((v, i) => (i === today - 1 ? Math.max(v, monthUsd) : v)), projected: (monthUsd / today) * ndays };
}

// The draft values of one item's form, from the record as loaded.
export function teamItemDraft(item: string, rec: J): J {
  const a = rec.access ?? {}, j = rec.jira ?? {}, c = rec.caps ?? {}, p = rec.pr ?? {};
  const strip = (x: unknown) => String(x ?? '').replace(/^fxa-team-[a-z0-9-]+--/, '');
  const d: Record<string, () => J> = {
    repos: () => ({ repos: (rec.repos ?? []).map((r: J) => ({ ...r })) }),
    goal: () => ({ goal: rec.prompts?.goal_md ?? '' }),
    access: () => ({ open: !!a.open, chans: [...(a.channels ?? [])], other: '', prefixes: (a.jira_prefixes ?? []).join(', ') }),
    name: () => ({ label: rec.label ?? '' }),
    admins: () => ({ admins: (rec.admins ?? []).map((x: J) => ({ slack: x.slack ?? '', email: x.email ?? '' })) }),
    runner: () => ({ kind: rec.stack?.kind ?? 'none', srepo: rec.stack?.repo ?? (rec.repos ?? []).find((r: J) => r.slug.toLowerCase() === 'mozilla/fxa')?.slug ?? (rec.repos ?? [])[0]?.slug ?? '',
      backend: rec.runner?.backend ?? 'gce', android: !!rec.runner?.android, desktop_url: rec.runner?.desktop_url ?? '' }),
    egress: () => ({ approved: (rec.egress?.approved ?? []).join('\n'), requested: [...(rec.egress?.requested ?? [])] }),
    skills: () => ({ skills: [...(rec.skills ?? [])] }),
    boot: () => ({ script: rec.boot?.script ?? '' }),
    secrets: () => ({ jira: strip(rec.secrets?.jira), runtime: (rec.secrets?.runtime ?? []).map((r: J) => ({ what: strip(r.secret), path: r.path })) }),
    jira: () => ({ project: j.project ?? '', queue: !!j.queue, secret: !!j.secret, usage: j.usage !== false, launches_per_day: c.launches_per_day ?? '', board: j.board ?? '', sprint: j.sprint ?? '' }),
    tools: () => ({ mcp: (rec.mcp ?? []).join(', '), dflt: !('mcp' in rec) }),
    caps: () => ({ usd_per_day: c.usd_per_day ?? '', usd_per_month: c.usd_per_month ?? '', runners: c.runners ?? '' }),
    pr: () => ({ open: p.open !== false, reviewers: (p.reviewers ?? []).join(', '), labels: (p.labels ?? []).join(', '),
      infra: (p.infra_checks ?? []).join(', '), review_rounds: p.review_rounds ?? '', admin_review_rounds: p.admin_review_rounds ?? '', review_quiet_minutes: p.review_quiet_minutes ?? '' }),
  };
  return d[item]?.() ?? {};
}

// The record with a patch applied: a key set to undefined is removed.
export function teamApply(rec: J, patch: J): J {
  const out = structuredClone(rec);
  for (const [k, v] of Object.entries(patch)) {
    if (v === undefined) delete out[k];
    else out[k] = v;
  }
  return out;
}
// A repo's commits mode is read on the host only, so it needs no new test (as _teams_runner_keys).
const runnerView = (r: J, k: string) => (k === 'repos' && Array.isArray(r[k]) ? r[k].map((x: J) => ({ ...x, commits: undefined })) : r[k]);
export const teamRetest = (a: J, b: J) => RUNNER_KEYS.some((k) => JSON.stringify(runnerView(a, k)) !== JSON.stringify(runnerView(b, k)));
export const list0 = (v: unknown) => [...new Set(String(v ?? '').split(/[\s,]+/).map((x) => x.trim()).filter(Boolean))];

// The record keys an item form changes, {key: value}; undefined removes the key. opts is /api/teams/options.
export function teamPatch(f: { item: string; d: J }, rec: J, team: string, opts?: J): J {
  const d = f.d, list = list0, num = (v: unknown) => (v === '' || v == null ? undefined : Number(v));
  const drop = (o: J) => Object.fromEntries(Object.entries(o).filter(([, v]) => v !== undefined && v !== ''));
  const some = (o: J) => (Object.keys(o).length ? o : undefined), many = <T>(l: T[]) => (l.length ? l : undefined);
  const commas = (v: unknown) => [...new Set(String(v ?? '').split(',').map((x) => x.trim()).filter(Boolean))];
  // The Jira and Budget forms share caps: each replaces only its own keys.
  const caps = (o: J) => some(drop({ ...(rec.caps ?? {}), ...o }));
  const pre = `fxa-team-${team}--`;
  switch (f.item) {
    case 'repos': return { repos: d.repos.filter((r: J) => String(r.slug).trim()).map((r: J) => drop({ ...r, slug: String(r.slug).trim(), commits: r.commits === 'append' ? 'append' : undefined })) };
    case 'goal': return { prompts: { ...(rec.prompts ?? {}), goal_md: d.goal } };
    case 'access': return { access: { ...(rec.access ?? {}), open: !!d.open,
      channels: d.open ? rec.access?.channels ?? [] : [...new Set([...d.chans, ...list(d.other)])], jira_prefixes: list(d.prefixes) } };
    case 'jira': {
      // From the record's jira, so a key with no input survives a save.
      const j = drop({ ...(rec.jira ?? {}), project: d.project.trim(), queue: d.queue || undefined, secret: (d.queue && d.secret) || undefined, usage: d.usage ? undefined : false,
        board: String(d.board ?? '').trim() || undefined, sprint: d.sprint || undefined });
      // A secret team cannot be open or list Jira keys (lib/team_record.py), so the save clears both.
      return { jira: some(j), caps: caps({ launches_per_day: num(d.launches_per_day) }), ...(j.secret ? { access: { ...(rec.access ?? {}), open: false, jira_prefixes: [] } } : {}) };
    }
    case 'tools': return { mcp: d.dflt ? undefined : list(d.mcp) };
    case 'caps': return { caps: caps({ usd_per_day: num(d.usd_per_day), usd_per_month: num(d.usd_per_month), runners: num(d.runners) }) };
    case 'name': return { label: d.label.trim() || undefined };
    case 'admins': return { admins: many(d.admins.map((x: J) => ({ slack: x.slack.trim(), email: x.email.trim() })).filter((x: J) => x.slack || x.email)) };
    case 'runner': {
      const st = d.kind === 'fxa' ? { kind: 'fxa', ...(d.srepo && (d.srepo.toLowerCase() !== 'mozilla/fxa' || rec.stack?.repo) ? { repo: d.srepo } : {}) } : rec.stack ? { kind: 'none' } : undefined;
      return { stack: st, runner: some(drop({ backend: d.backend !== 'gce' || rec.runner?.backend ? d.backend : undefined, android: d.android || undefined, desktop_url: d.desktop_url.trim() || undefined })) };
    }
    case 'egress': return { egress: some(drop({ requested: many(d.requested), approved: many(list(d.approved)) })) };
    case 'skills': return { skills: many(d.skills) };
    case 'boot': return { boot: d.script ? { script: d.script, sha256: (opts?.boot ?? []).find((b: J) => b.script === d.script)?.sha256 ?? rec.boot?.sha256 ?? '' } : undefined };
    case 'secrets': {
      const rt = d.runtime.filter((r: J) => r.what.trim() || r.path.trim()).map((r: J) => ({ secret: pre + r.what.trim(), path: r.path.trim() }));
      return { secrets: some(drop({ jira: d.jira.trim() ? pre + d.jira.trim() : undefined, runtime: many(rt) })) };
    }
    case 'pr': return { pr: drop({ ...(rec.pr ?? {}), open: d.open, reviewers: many(list(d.reviewers)),
      // A label can hold a space and a rule has no comma, so both split on commas only.
      labels: many(commas(d.labels)), infra_checks: many(commas(d.infra)), review_rounds: num(d.review_rounds),
      admin_review_rounds: num(d.admin_review_rounds), review_quiet_minutes: num(d.review_quiet_minutes) }) };
  }
  return {};
}

// New team: the record it starts with, open to anyone the bot allows.
export type NewTeam = { name: string; repo: string; stack: string; goal: string };
export function newTeamRecord(d: NewTeam): J {
  const slug = d.repo.trim(), repos: J[] = [{ slug, role: 'work', default: true }];
  if (d.stack === 'fxa' && slug.toLowerCase() !== 'mozilla/fxa') repos.push({ slug: 'mozilla/fxa', role: 'dep' });
  return { schema: 1, name: d.name.trim(), label: teamCap(d.name.trim()), status: 'draft', repos, stack: { kind: d.stack || 'none' },
    access: { open: true, users: [], channels: [], jira_prefixes: [] }, prompts: { goal_md: d.goal } };
}
export function newTeamCheck(d: NewTeam): Record<string, string> {
  const e: Record<string, string> = {};
  if (!TEAM_RE.test(d.name.trim())) e.name = 'Use lowercase letters, digits and -, 2 to 31 characters, starting with a letter.';
  if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(d.repo.trim())) e.repo = 'Use owner/name, such as mozilla/fx-private-relay.';
  if (!d.stack) e.stack = 'Pick a stack.';
  return e;
}
// The validator's lines mapped to the fields; the rest is the summary.
export function newTeamErrs(text: unknown): { errs: Record<string, string>; summary: string } {
  const errs: Record<string, string> = {}, other: string[] = [];
  for (const l of String(text || '').split('\n').map((x) => x.replace(/^ERROR: /, '').replace(/^\S+\.json: /, '').trim()).filter(Boolean)) {
    const k = /^name\b|team name|reserved|already exists/.test(l) ? 'name' : /^repos/.test(l) ? 'repo' : /^stack/.test(l) ? 'stack' : /goal_md|^prompts/.test(l) ? 'goal' : '';
    if (k) errs[k] ??= l;
    else other.push(l);
  }
  return { errs, summary: other.join(' ') || (Object.keys(errs).length ? 'Check the marked fields.' : '') };
}
export const newTeamReadback = (d: NewTeam) =>
  `Creates ${d.name ? teamCap(d.name) : 'a team'} as a draft, on ${d.repo || 'its work repo'}, with ${d.stack === 'fxa' ? 'the FxA stack' : d.stack === 'none' ? 'no FxA stack' : 'a stack you pick'}. Next, you test it, and it turns on when the test passes.`;
