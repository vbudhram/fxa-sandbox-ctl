// The pipeline: the snapshot per team, runner cards, the board, belts and the queue, ported from the retired v1 dashboard.
import { REPO_RE, days, plainMd, short } from '../format';
import type { FeedName, Store } from '../store/types';
import { AGENTS, type J, LANE_ST, PIPE_LISTS, SS, STATE, TEAM_ADMIN, memo } from './base';
import { chainOf, ownerName, sessHeads, sessRoutine } from './sessions';

// The snapshot feeds: the full one and each team's. Not s.feeds, which changes on each errors delta and stats frame.
const snapFeeds = (s: Store) => [s.feeds.full, ...Object.keys(s.feeds).filter((n) => n.startsWith('team:')).map((n) => s.feeds[n as FeedName])];

// The picked team's snapshot, or for All teams every team's lists joined, each item tagged with its team.
export const pipe = memo((s) => [s.prefs.pipeTeam, ...snapFeeds(s)], (s) => {
  const f = s.feeds.full, snaps: Record<string, J> = { fxa: { snapshot: f?.data ?? null, error: f?.error ?? null, age_seconds: f?.ageSeconds ?? null } };
  for (const [n, t] of Object.entries(s.feeds)) if (n.startsWith('team:') && t) snaps[n.slice(5)] = { snapshot: t.data ?? null, error: t.error, age_seconds: t.ageSeconds };
  const keyTeam: Record<string, string> = {}, PIPE_TEAM = s.prefs.pipeTeam;
  const full = Object.entries(snaps).filter(([, t]) => t?.snapshot && !t.snapshot.redacted);
  const tag = (team: string, xs: J) => (Array.isArray(xs) ? xs.map((i: J) => { if (i?.key && !(i.key in keyTeam)) keyTeam[i.key] = team; return { ...i, team }; }) : []);
  full.forEach(([team, t]) => { PIPE_LISTS.forEach((l) => tag(team, t.snapshot[l])); Object.values(t.snapshot.queue ?? {}).forEach((v) => tag(team, v)); });
  // Two teams on one repo list the same PRs and tickets: All teams shows each once, under the first team.
  const once = (xs: J[]) => { const seen = new Set<string>(); return xs.filter((i) => { const id = i?.key || (i?.number != null ? `#${i.number}` : ''); if (!id) return true; if (seen.has(id)) return false; seen.add(id); return true; }); };
  let snap: J;
  const base = f?.data as J;
  if (PIPE_TEAM && snaps[PIPE_TEAM]) snap = full.some(([team]) => team === PIPE_TEAM) ? snaps[PIPE_TEAM].snapshot : null;
  else if (!base || full.length < 2) snap = base ?? null;
  else {
    snap = { ...base, queue: { ...(base.queue ?? {}) } };
    PIPE_LISTS.forEach((l) => { snap[l] = base[l] == null ? null : once(full.flatMap(([team, t]) => tag(team, t.snapshot[l]))); });
    ['ready', 'skipped'].forEach((l) => { if (Array.isArray(base.queue?.[l])) snap.queue[l] = once(full.flatMap(([team, t]) => tag(team, t.snapshot.queue?.[l]))); });
  }
  return { snap, snaps, keyTeam };
});
export const SNAP = (s: Store): J => pipe(s).snap;
// A ticket's own team's snapshot, so each row links to its own repo and Jira site; else the shown one.
export const keySnap = (s: Store, k: string): J => pipe(s).snaps[pipe(s).keyTeam[k] ?? '']?.snapshot ?? SNAP(s);
export function teamRepo(s: Store, k: string): string { const x = keySnap(s, k), r = x?.team?.repo ?? x?.repo ?? ''; return REPO_RE.test(r) ? r : ''; }
export const jiraSite = (s: Store, k: string): string => String(keySnap(s, k)?.team?.jira_site ?? '');

export const merged = memo((s) => [pipe(s), s.feeds.agents], (s): { cards: J[]; waiting: J[] } => {
  // runners from the fast feed, decorated with the ticket row from the slow feed
  const inflight: J[] = SNAP(s)?.inflight ?? [], runners: J[] = AGENTS(s)?.runners ?? [];
  const byKey = Object.fromEntries(inflight.map((t) => [t.key, t]));
  const cards = runners.map((r) => {
    const t = byKey[r.key] || {};
    return { ...t, ...r, live: r.agent_alive && r.stage !== 'pr', summary: t.summary, attempts: t.attempts, pr: t.pr, ok: t.ok, fail: t.fail, running: t.running };
  });
  const seen = new Set(runners.map((r) => r.key));
  // At the PR stage the runner is gone by design and CI is the live phase, so the ticket keeps its card.
  const waiting = inflight.filter((t) => !seen.has(t.key));
  const ciCards = waiting.filter((t) => t.stage === 'pr').map((t) => ({ ...t, live: false, ci: true,
    name: '', slot: '', agent: null, agent_alive: false, elapsed_seconds: t.elapsed_seconds }));
  // A launch creates its runner first, so a young start with no runner yet is booting, not a fault.
  const booting = (t: J) => t.stage === 'starting' && (t.elapsed_seconds ?? Infinity) < 600;
  const bootCards = waiting.filter(booting).map((t) => ({ ...t, live: false, name: '', slot: '', agent: null, agent_alive: false }));
  return { cards: cards.concat(ciCards, bootCards), waiting: waiting.filter((t) => t.stage !== 'pr' && !booting(t)) };
});

// A slot or runner name a person may copy into a stop command, else null.
export const stopName = (n: unknown): string | null => (/^[a-z0-9][a-z0-9-]{0,62}$/.test(String(n ?? '')) ? (n as string) : null);
// A stray instance's run name: the agent- prefix goes only from a name in the runner pattern.
export const strayRun = (n: unknown): string | null => (/^agent-[a-z0-9][a-z0-9-]{0,56}$/.test(String(n ?? '')) ? (n as string).slice(6) : null);
// Instances up for 2 min with no run or session behind them.
export const strays = memo((s) => [merged(s), s.sessions, s.feeds.agents], (s): J[] => {
  const known = new Set(merged(s).cards.map((c) => c.name));
  SS(s).forEach((x) => known.add(x.key));
  return (AGENTS(s)?.instances ?? []).filter((v: J) => !known.has(strayRun(v.name) ?? v.name) && v.age_seconds > 120);
});

export const hasChecks = (r: J) => ((r.ok ?? 0) + (r.fail ?? 0) + (r.running ?? 0)) > 0;
export type VerdictTone = '' | 'ok' | 'warn' | 'bad' | 'info' | 'merged';
export function verdictTag(r: J): { label: string; tone: VerdictTone; run?: true; title?: string } {
  if (r.pr == null) return { label: 'no PR', tone: 'warn' };
  if (r.state === 'MERGED') return { label: 'merged', tone: 'merged' };
  if (r.state === 'CLOSED') return { label: 'closed', tone: 'warn' };
  if (r.draft) return { label: 'draft', tone: '' };
  if (r.review === 'CHANGES_REQUESTED') return { label: 'changes requested', tone: 'bad' };
  if (r.fail > 0 && r.infra) return { label: 'infra red', tone: 'warn', title: String(r.infra) };
  if (r.fail > 0) return { label: `${r.fail} failing`, tone: 'bad' };
  if (r.running > 0) return { label: `${r.running} running`, tone: 'info', run: true };
  if (!hasChecks(r)) return { label: 'no checks yet', tone: '' };
  if (r.mergeable === 'CONFLICTING') return { label: 'conflicts', tone: 'bad' };
  if (r.review === 'APPROVED') return { label: 'approved', tone: 'ok' };
  return { label: 'green', tone: 'ok' };
}
export const isWaitingOnHuman = (r: J): boolean => !!(r.pr && r.state === 'OPEN' && !r.draft && r.fail === 0 && r.running === 0 &&
  hasChecks(r) && r.mergeable !== 'CONFLICTING' && r.review !== 'APPROVED' && r.review !== 'CHANGES_REQUESTED');

// One fixed next step per kind: a step from free text could carry a ticket's own words.
export const NEXT_STEP: Record<string, string> = {
  stalled: 'The run stalled twice. Read fxa-sandbox-ctl tail KEY, then relaunch it or label it rejected.',
  dead_vm: 'The sandbox died twice. Check the runner host, then relaunch the ticket.',
  attempts: 'Fix the PR by hand, or remove ai-fixme-blocked to give the agent a new try.',
  rounds: 'The agent used its review rounds. Fix the PR by hand, or a team admin comments on the PR or gives it one more round here.',
  rebases: 'The PR conflicted with the base 5 times. Resolve the conflict by hand, or remove ai-fixme-blocked after main settles.',
  refused_ship: 'The change edits CI or Yarn or npm config. A human relaunches with FXA_ALLOW_TOOLING_EDITS=1 if the ticket asks for it.',
  frozen: 'The fix needs a frozen path. A human unfreezes it in _scripts/check-frozen.ts or fixes the ticket by hand.',
  launch_error: 'The launch failed with the error in the reason. Read fxa-sandbox-ctl progress KEY, fix the cause, then relaunch the ticket.',
  operator: 'Do what the reason says, then remove ai-fixme-blocked.',
  jira: 'Read the Jira history for who added the label.',
  other: 'Read the Jira history for who added the label.',
  needs_decision: 'Answer the open question in the ticket. The next pass reads it again.',
  underspecified: 'Add acceptance criteria to the ticket. The next pass reads it again.',
  already_done: 'Close the ticket if the change is in, or say in it what is still missing.',
  depends_on: 'Nothing to do now: a pass looks again when the blocker merges.',
  ci_red: 'Nothing to do now: the agent fixes CI on its next pass.',
  changes: 'Nothing to do now: the agent answers the review on its next pass.',
  conflicts: 'Nothing to do now: the next pass rebases the PR.',
  relock: 'Run fxa-sandbox-ctl relock KEY on the manager: the automatic yarn.lock fix failed, and no pass retries it.',
  infra: 'Rerun the failed CI job: the failure is in CI, not in the change.',
  fault: "Read the run's log, then relaunch the ticket or label it blocked.",
  ready: 'Nothing to do: the next pass offers it when it reaches the front and a slot is free.',
  running: 'Nothing to do: the belt shows its progress.',
};
export const KIND_LABEL: Record<string, string> = {
  stalled: 'stalled', dead_vm: 'dead VM', attempts: 'attempts', rounds: 'rounds', rebases: 'rebases', refused_ship: 'refused ship', frozen: 'frozen path', launch_error: 'launch error', operator: 'operator',
  jira: 'blocked in Jira', other: 'other', needs_decision: 'needs a decision', underspecified: 'underspecified', already_done: 'already done',
  depends_on: 'depends on', ci_red: 'CI red', changes: 'changes requested', conflicts: 'conflicts', relock: 'relock failed', infra: 'infra red', fault: 'fault',
};
const WHO: Record<string, string> = {
  stalled: 'the operator', dead_vm: 'the operator', attempts: 'the operator', rounds: 'the operator', rebases: 'the operator', refused_ship: 'the operator', frozen: 'the operator', launch_error: 'the operator',
  operator: 'the operator', jira: 'the operator', other: 'the operator', needs_decision: 'the reporter', underspecified: 'the reporter',
  already_done: 'the operator', infra: 'the operator', fault: 'the operator', ci_red: 'the agent, next pass', changes: 'the agent, next pass',
  conflicts: 'the agent, next pass', relock: 'the operator',
};
// The old skip records have no kind: the reason's first words decide.
export const skipKindOf = (k: J) => k.kind ?? (k.held_by ? 'depends_on' : /^underspecified/i.test(k.reason ?? '') ? 'underspecified' : /^already satisfied/i.test(k.reason ?? '') ? 'already_done' : 'needs_decision');
export const boardAge = (x: number | null | undefined) => (x == null ? '' : x >= 2 * 86400 ? `${Math.round(x / 86400)}d` : short(x));
export const secsSince = (t: unknown): number | null => (t == null ? null : Math.max(0, Math.round(Date.now() / 1000 - (typeof t === 'number' ? t : Date.parse(String(t)) / 1000))));

// Who acts and the next step, from the column and the kind.
export function classify(i: J): J {
  const who = WHO[i.kind];
  const waitsOn = i.kind === 'depends_on' ? (i.held_by ?? null) : null;
  const person = i.column === 'blocked' ? (waitsOn ? `waits on ${waitsOn}` : who ?? 'the operator') : i.column === 'running' && i.fault ? 'the operator' : who ?? null;
  // A reporter's answer is in Jira, not a person here: it waits, and Queue still lists it.
  const group = i.column !== 'blocked' ? null : waitsOn || /^the agent/.test(person ?? '') || person === 'the reporter' ? 'wait' : 'act';
  const step = (NEXT_STEP[i.kind] ?? NEXT_STEP[i.column === 'next' ? 'ready' : i.column === 'running' ? 'running' : 'other'] ?? '').replace('KEY', i.key);
  return { ...i, person, waitsOn, group, next: step };
}

// Each key once: its first place in this order wins, so the groups, the tab count and Needs you agree.
export const boardItems = memo((s) => [merged(s), pipe(s)], (s): J[] => {
  const out: J[] = [], seen = new Set<string>(), add = (i: J) => { if (!i.key || seen.has(i.key)) return; seen.add(i.key); out.push(classify(i)); };
  const { cards, waiting } = merged(s), snap = SNAP(s);
  // An agent that exited with no handoff is a fault.
  const exited = (c: J) => !c.ci && !c.agent_alive && c.stage === 'watching' && !c.handoff;
  cards.forEach((c) => add({ key: c.key, title: c.summary || c.branch || '', column: 'running', fault: c.stage === 'stalled' || c.stage === 'error' || exited(c),
    kind: c.stage === 'stalled' || c.stage === 'error' || exited(c) ? 'fault' : null, stage: c.ci ? (c.fail > 0 ? 'CI red' : c.running > 0 ? 'CI running' : 'CI green') : c.stage,
    why: c.stage === 'stalled' ? `stalled ${c.detail ?? ''}`.trim() : c.stage === 'error' ? 'the run failed' : exited(c) ? 'exited without a handoff' : '', age: c.elapsed_seconds ?? null, belt: true, ci: !!c.ci }));
  (snap?.blocked ?? []).forEach((b: J) => { const r = b.blocked_reason ?? { kind: 'jira', text: 'blocked in Jira', at: null };
    add({ key: b.key, title: b.summary ?? '', column: 'blocked', kind: r.kind || 'other', why: r.text || (r.kind === 'jira' ? 'blocked in Jira' : ''), since: r.at ?? null, age: secsSince(r.at) }); });
  (snap?.review ?? []).forEach((r: J) => {
    const kind = r.mergeable === 'CONFLICTING' ? (r.relock_failed ? 'relock' : 'conflicts') : r.fail > 0 ? (r.infra ? 'infra' : 'ci_red') : r.review === 'CHANGES_REQUESTED' ? 'changes' : null;
    if (kind) add({ key: r.key, title: r.title ?? '', column: 'blocked', kind, why: kind === 'infra' ? `infra red: ${r.infra}` : kind === 'ci_red' ? `CI red: ${r.fail} failing` : KIND_LABEL[kind], age: secsSince(r.created), pr: r.pr, belt: true });
    else if (!seen.has(r.key) && r.state !== 'MERGED' && r.state !== 'CLOSED') { seen.add(r.key); out.push({ key: r.key, column: 'review' }); }
  });
  waiting.forEach((t) => add({ key: t.key, title: t.summary ?? '', column: 'running', fault: true, kind: 'fault', stage: t.stage, why: 'no sandbox is up for this run', age: t.elapsed_seconds ?? null }));
  (snap?.queue?.skipped ?? []).filter((k: J) => k.in_queue !== false).forEach((k: J) => add({ key: k.key, title: k.summary ?? '', column: 'blocked', kind: skipKindOf(k),
    // The age is how long the ticket waits (first queued), not the last pass that skipped it.
    why: k.reason ?? '', held_by: k.held_by ?? null, since: k.queued_at ?? null, age: secsSince(k.queued_at ?? null), passes: k.passes }));
  (snap?.queue?.ready ?? []).forEach((k: J, n: number) => add({ key: k.key, title: k.summary ?? '', column: 'next', pos: n + 1, queued_at: k.queued_at ?? null, age: secsSince(k.queued_at ?? null) }));
  return out;
});
export const boardAct = (items: J[]) => items.filter((i) => i.column === 'blocked' && i.group === 'act').length + items.filter((i) => i.column === 'running' && i.fault).length;

// Why a column cannot be read, or "": a column that cannot be read says so, never a zero.
export function boardState(s: Store, col: string): string {
  const snap = SNAP(s), st = STATE(s), g = AGENTS(s);
  if (!snap) return 'Loading the pipeline…';
  // An old snapshot is history: every count from it is unknown.
  if (st.age_seconds != null && st.interval && st.age_seconds > 3 * st.interval) return `unknown, the snapshot is ${Math.round(st.age_seconds / 60)} min old`;
  if (col !== 'running' && (snap.queue?.fetch_failed || snap.blocked == null)) return 'unknown, Jira fetch failed';
  if (col === 'running') {
    if (!g || st.agents_error) return 'unknown, agents feed fetch failed';
    if (st.agents_age_seconds != null && st.agents_interval && st.agents_age_seconds > 3 * st.agents_interval) return `unknown, agents feed ${Math.round(st.agents_age_seconds / 60)} min old`;
  }
  return '';
}

export const laneRows = memo((s) => [merged(s), pipe(s), s.sessions, s.viewer, s.feeds.teams], (s): J[] => {
  const { cards } = merged(s), snap = SNAP(s), med = snap?.telemetry?.median_minutes, rows: J[] = [], seen = new Set<string>();
  cards.forEach((t) => {
    seen.add(t.key);
    const a = t.agent || {}, min = Math.round((t.elapsed_seconds ?? 0) / 60);
    if (t.ci) {
      const kind = t.fail > 0 ? (t.infra ? 'warn' : 'fix') : t.running > 0 ? 'live' : 'wait';
      rows.push({ t, st: 6, kind, l1: t.fail > 0 ? `${t.fail} failing` : t.running > 0 ? `CI ${t.running} running` : 'CI green', l2: '', checks: true });
      return;
    }
    const st = ({ starting: 1, watching: 2, stalled: 2, error: 2, squashing: 3, pushed: 4, pr: 5 } as Record<string, number>)[t.stage] ?? 2;
    const kind = t.stage === 'stalled' || t.stage === 'error' ? 'fix' : 'live';
    const l1 = t.stage === 'starting' ? `Boot: ${t.detail || 'starting'}` : t.stage === 'stalled' ? `Stalled · ${(t.detail || '').split(' ')[0]}`
      : t.stage === 'error' ? 'Run failed' : t.stage === 'squashing' ? 'Squashing' : t.stage === 'pushed' ? 'Pushing' : t.stage === 'pr' ? 'Opening PR'
      : plainMd(a.last_tool || a.last_text || 'Working');
    const l2 = st === 2 && kind === 'live' ? `${min}m${med ? ` of a ${med}m median` : ''} · ${t.files_changed ?? 0} files` : `${min}m`;
    rows.push({ t, st, kind, l1, l2, runner: t.agent_alive, late: med && st === 2 && min > med });
  });
  (snap?.review ?? []).filter((r: J) => !seen.has(r.key)).forEach((r: J) => {
    const d = Math.round(days(r.last_human_review?.at ?? r.created) ?? 0);
    let st = 7, kind = 'wait', l1 = `Waiting ${d} day${d === 1 ? '' : 's'}`, l2 = r.last_human_review ? `${r.last_human_review.login} reviewed` : 'no human review';
    if (r.state === 'MERGED') { st = 8; kind = 'done'; l1 = 'Merged'; l2 = 'drain pending'; }
    else if (r.state === 'CLOSED') { st = 8; kind = 'wait'; l1 = 'Closed'; l2 = 'not merged'; }
    else if (r.mergeable === 'CONFLICTING') { st = 6; kind = 'fix'; l1 = r.fail > 0 && r.infra ? 'Conflicts + infra red' : 'Conflicts'; l2 = r.relock_failed ? `relock failed: run relock ${r.key}` : `${d}d open`; }
    else if (r.fail > 0) { st = 6; kind = r.infra ? 'warn' : 'fix'; l1 = r.infra ? 'Infra red' : `${r.fail} failing`; l2 = r.infra ? r.infra : `${d}d open`; }
    else if (r.running > 0) { st = 6; kind = 'live'; l1 = `CI ${r.running} running`; }
    else if (r.review === 'CHANGES_REQUESTED') { kind = 'fix'; l1 = 'Changes requested'; }
    else if (r.review === 'APPROVED') { l1 = 'Approved'; }
    else if (d >= 3) kind = 'warn';
    rows.push({ t: { ...r, summary: r.title }, st, kind, l1, l2, checks: true, age: d });
  });
  // Open PRs with the pipeline label that no row shows yet.
  (snap?.open_prs ?? []).filter((p: J) => p.key && !rows.some((r) => r.t.key === p.key)).forEach((p: J) => {
    const blocked = (snap?.blocked ?? []).some((b: J) => b.key === p.key), d = Math.round(days(p.created) ?? 0);
    // "Not in the pipeline" only when every feed that could claim the key was read; else the state is unknown.
    const known = snap.review != null && snap.blocked != null && !snap.inflight_fetch_failed;
    const l1 = blocked ? 'Blocked: needs a person' : (snap?.inflight ?? []).some((i: J) => i.key === p.key) ? 'In flight: no agent running' : known ? 'Not in the pipeline' : 'State unknown';
    rows.push({ t: { key: p.key, pr: p.number, summary: p.title }, st: blocked ? 7 : 5, kind: blocked ? 'warn' : 'wait', l1, l2: `${d}d open`, age: d, outside: l1 === 'Not in the pipeline' || l1 === 'State unknown' });
  });
  // Open PRs that no ticket owns: a Slack session opened them from its branch.
  const ss = SS(s);
  (snap?.open_prs ?? []).filter((p: J) => !p.key).forEach((p: J) => {
    const d = Math.round(days(p.created) ?? 0), x = sessHeads(ss).find((h) => chainOf(h, ss).some((y) => y.branch === p.branch || y.key === p.branch));
    const owner = x ? (sessRoutine(s, x) ? (TEAM_ADMIN(s).admin ? sessRoutine(s, x) : 'scheduled run') : ownerName(s, x)) : '';
    rows.push({ t: { key: p.branch, pr: p.number, summary: p.title, slack: true, routine: !!x?.routine_run, owner, sess: x }, st: 7, kind: d >= 3 ? 'warn' : 'wait', outside: true,
      l1: `Waiting ${d} day${d === 1 ? '' : 's'}`, l2: owner ? (x?.routine_run ? owner : `${owner}'s session`) : 'Slack session', age: d });
  });
  const order: Record<string, number> = { live: 0, fix: 1, warn: 2, wait: 3, done: 4 };
  return rows.sort((x, y) => (order[x.kind] ?? 0) - (order[y.kind] ?? 0) || (y.age ?? 0) - (x.age ?? 0));
});

// "refactor(content-server): retire X" reads as "Retire X" with a content-server tag.
export function laneTitle(raw: unknown): { text: string; tag: string } {
  const m = String(raw ?? '').match(/^(\w+)(?:\(([^)]+)\))?!?:\s*(.+)$/);
  if (!m) return { text: (raw as string) ?? '', tag: '' };
  const t = m[3] ?? '';
  return { text: t.charAt(0).toUpperCase() + t.slice(1), tag: m[2] || m[1] || '' };
}
// "7 open PRs labelled auto: 4 in review · 2 in flight · 1 blocked", as GitHub counts them.
export function openPrCounts(s: Store): { total: number; parts: string } | null {
  const snap = SNAP(s), open = snap?.open_prs;
  if (!snap || open == null) return null;
  const stateOf = (k: string) => !k ? 'Slack or by hand' : snap.review == null ? 'state unknown' : snap.review.some((r: J) => r.key === k) ? 'in review'
    : (snap.inflight ?? []).some((r: J) => r.key === k) ? 'in flight' : (snap.blocked ?? []).some((r: J) => r.key === k) ? 'blocked'
    : snap.blocked == null || snap.inflight_fetch_failed ? 'state unknown' : 'not in the pipeline';
  const n: Record<string, number> = {};
  open.forEach((p: J) => { const k = stateOf(p.key); n[k] = (n[k] ?? 0) + 1; });
  return { total: open.length, parts: Object.entries(n).map(([k, c]) => `${c} ${k}`).join(' · ') || 'none' };
}

export const BELT_GROUPS = [['working', 'Working now', 'an agent runs in a sandbox', 'k-live', 'No agent works now.'], ['needs', 'Needs you', 'only a person can move these', 'k-warn', 'Nobody needs to act.'],
  ['fixes', 'The agent fixes it', 'on the next pass', 'k-bad', 'Nothing for the agent to fix.'], ['review', 'Waits on review', 'oldest first', 'k-wait', 'No PR waits on review.']];
// Kinds where something is broken (red), not waiting on a decision (amber).
export const BROKEN = new Set(['stalled', 'dead_vm', 'attempts', 'rounds', 'infra', 'fault', 'ci_red', 'conflicts', 'relock', 'launch_error']);
// Each key goes to one group, from classify() through boardItems(), so the groups, the tab count and Needs you agree.
export const beltGroups = memo((s) => [boardItems(s), laneRows(s), pipe(s), STATE(s), AGENTS(s), s.viewer], (s): J => {
  const snap = SNAP(s), items: J[] = snap ? boardItems(s) : [], byKey = Object.fromEntries(items.map((i) => [i.key, i]));
  // A ticket blocked for rounds used all of them, so its tag needs no count from the stats feed.
  const cap = snap?.limits?.feedback_rounds ?? 2, rl1 = (i: J) => (i.kind === 'rounds' ? { l1: `Review rounds ${cap} of ${cap}` } : {});
  const g: J = { working: [], needs: [], fixes: [], review: [], outside: [] }, placed = new Set<string>(), admin = TEAM_ADMIN(s).admin;
  const add = (to: string, r: J) => { placed.add(r.t.key); g[to].push({ ...r, group: to, item: r.item ?? byKey[r.t.key] }); };
  laneRows(s).forEach((r) => {
    const i = byKey[r.t.key];
    if (r.outside && !i) return add('outside', { ...r, tone: r.age >= 3 ? 'k-warn' : 'k-wait',
      l1: r.t.slack ? (r.t.routine ? `Routine · ${admin && r.t.owner ? r.t.owner : 'scheduled run'}` : `Slack · ${r.t.owner ? `${r.t.owner}'s session` : 'a session'}`) : r.l1, l2: `open ${r.age} day${r.age === 1 ? '' : 's'}` });
    if (!i) return; // a merged or closed review row, a hold or a ready ticket has no belt
    if (i.column === 'running') {
      if (i.fault) return add('needs', { ...r, tone: 'k-bad' });
      if (i.ci) return r.t.fail > 0 ? add('fixes', { ...r, tone: 'k-bad' }) : add('review', { ...r, tone: r.t.running > 0 ? 'k-live' : 'k-ok', l1: r.t.running > 0 ? 'CI running' : r.l1 });
      const min = Math.round((r.t.elapsed_seconds ?? 0) / 60), a = r.t.agent || {};
      return add('working', { ...r, tone: 'k-live', l1: `${LANE_ST[r.st]} · ${min} min`, l2: r.st === 1 ? r.t.detail || 'the sandbox boots' : plainMd(a.last_tool || a.last_text || '') || r.l2 });
    }
    if (i.column === 'blocked') return i.group === 'act' ? add('needs', { ...r, tone: BROKEN.has(i.kind) ? 'k-bad' : 'k-warn', l2: i.why || r.l2, ...rl1(i) }) : /^the agent/.test(i.person ?? '') ? add('fixes', { ...r, tone: 'k-bad', l2: i.next || r.l2 }) : undefined;
    if (i.column === 'review') add('review', { ...r, tone: r.kind === 'live' ? 'k-live' : 'k-ok' });
  });
  // Needs you items with no PR or run get a row at the Queue stop, so the group equals boardAct().
  items.filter((i) => !placed.has(i.key) && ((i.column === 'blocked' && i.group === 'act') || (i.column === 'running' && i.fault))).forEach((i) =>
    add('needs', { t: { key: i.key, summary: i.title, pr: i.pr }, st: i.column === 'running' ? 2 : 0, tone: i.fault || BROKEN.has(i.kind) ? 'k-bad' : 'k-warn',
      l1: i.fault ? 'Run fault' : ({ needs_decision: 'Needs a decision', underspecified: 'Needs detail', already_done: 'Maybe done' } as Record<string, string>)[i.kind] ?? 'Blocked', l2: i.why || i.next || '', ageText: boardAge(i.age), ...rl1(i) }));
  g.review.sort((x: J, y: J) => (y.age ?? 0) - (x.age ?? 0));
  // A failed read of the review list or of the in-flight PR states is unknown, never a confident count.
  const gh = !snap ? 'Loading the pipeline…' : snap.review == null || snap.inflight_prs_failed ? `unknown, ${snap.done_fetch_failed || (snap.review != null && snap.inflight_fetch_failed) ? 'Jira' : 'GitHub'} fetch failed` : '';
  g.unknown = { working: boardState(s, 'running'), needs: boardState(s, 'blocked'), fixes: gh, review: gh };
  return g;
});
export const beltCount = (g: J): number | null => (Object.values(g.unknown).some(Boolean) ? null : g.working.length + g.needs.length + g.fixes.length + g.review.length);

// The queue tickets that wait on a person: skipped, still labelled, not held by another ticket.
export const queueWaits = (s: Store): J[] => (SNAP(s)?.queue?.skipped ?? []).filter((k: J) => k.in_queue !== false && !k.held_by);
// The skips the Queue tab lists: a skip that has a belt (Decide on Belts) shows there only, unless Needs you is unknown and lists nothing.
export const queueOnly = (s: Store): J[] => {
  const g = beltGroups(s), on = new Set(g.unknown.needs ? [] : ['working', 'needs', 'fixes', 'review'].flatMap((k) => (g[k] ?? []).map((r: J) => r.t.key)));
  return queueWaits(s).filter((k) => !on.has(k.key));
};
// Skips by their reason's first word; most passes first in each.
export function skipGroups(ks: J[]): [string, J[]][] {
  const kind = (k: J) => /^blocked/i.test(k.reason ?? '') ? 'Blocked' : /^underspecified/i.test(k.reason ?? '') ? 'Underspecified' : /^already satisfied/i.test(k.reason ?? '') ? 'Already done' : 'Needs a decision';
  const g = new Map<string, J[]>();
  ks.slice().sort((a, b) => b.passes - a.passes).forEach((k) => g.set(kind(k), [...(g.get(kind(k)) ?? []), k]));
  return ['Needs a decision', 'Underspecified', 'Blocked', 'Already done'].filter((n) => g.has(n)).map((n) => [n, g.get(n)!]);
}

// Never green on a fact it cannot read; launchcap only, since GCE free_slots can read 0 while a launch is possible.
export function gateLine(s: Store, now = Date.now() / 1000): { ok: boolean; text: string; room?: number } {
  const snap = SNAP(s), g = AGENTS(s), STATE_ = STATE(s), h = snap?.health ?? {}, mins = (x: number) => Math.max(1, Math.round(x / 60));
  const hm = (e: number) => new Date(e * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  const stop = (text: string) => ({ ok: false, text }), stale = (age: J, every: J) => age != null && every && age > 3 * every;
  if (!snap) return stop('Loading the pipeline…');
  if (snap.queue?.fetch_failed) return stop('Cannot tell: Jira could not be read. The next snapshot tries again.');
  if (stale(STATE_.age_seconds, STATE_.interval)) return stop(`Cannot tell: the tickets feed is ${mins(STATE_.age_seconds)} min old.`);
  if (!g || STATE_.agents_error) return stop('Cannot tell: the agents feed could not be read.');
  if (stale(STATE_.agents_age_seconds, STATE_.agents_interval)) return stop(`Cannot tell: the agents feed is ${mins(STATE_.agents_age_seconds)} min old.`);
  if (h.paused) return stop(`Passes are paused: ${h.paused}. Run fxa-sandbox-ctl resume to start them again.`);
  const lockStale = h.lock_stale_seconds ?? 1800;
  if (h.lock_age_seconds != null && h.lock_age_seconds > lockStale) return stop(`A pass lock is ${mins(h.lock_age_seconds)} min old. The next pass clears it after ${mins(lockStale)} min, or run fxa-sandbox-ctl unlock.`);
  if (snap.mode?.newtickets === 'off') return stop('Intake is off: passes work on open PRs only. Run fxa-sandbox-ctl newtickets on to launch from the queue.');
  if (h.free_gb != null && h.min_free_gb && h.free_gb < h.min_free_gb) return stop(`Only ${h.free_gb} GB is free, and a launch needs ${h.min_free_gb} GB. Free space on the host.`);
  if (h.launches_24h == null || h.max_launches_per_day == null) return stop('Cannot tell: this snapshot has no launch budget. The next snapshot adds it.');
  if (h.launches_24h >= h.max_launches_per_day) return stop(`The 24 h launch budget is used: ${h.launches_24h} of ${h.max_launches_per_day}.${h.launch_frees_at ? ` The next launch is allowed at ${hm(h.launch_frees_at)}.` : ''}`);
  if (g.launchcap == null) return stop('Slots unknown: the Jira inflight read failed, so no slot counts as free.');
  if (g.launchcap <= 0) return stop('No slot is free. A slot frees when a run ends, and feedback rounds take free slots first.');
  if (h.pass_timer === 'off') return stop('The pass timer is off, so no pass runs. Start fxa-pass.timer on the manager.');
  const np = h.next_pass_epoch;
  if (np != null && np - now > 65 * 60) return stop(`Outside pass hours: the next pass is at ${hm(np)} (in ${short(Math.round(np - now))}).`);
  const ready = snap.queue?.ready ?? [];
  if (!ready.length) return stop('Nothing is ready: the queue is empty, or every queued ticket is skipped or held.');
  const when = h.lock_age_seconds != null ? 'a pass runs now' : np == null ? 'next pass time unknown' : np <= now ? `a pass is due now (the snapshot is ${mins(STATE_.age_seconds ?? 0)} min old)` : `the next pass (${hm(np)}, in ${mins(np - now)} min)`;
  const lead = when.startsWith('the next') ? `The next pass (${hm(np)}, in ${mins(np - now)} min)` : when.charAt(0).toUpperCase() + when.slice(1) + ';';
  // The budget can allow fewer launches than there are slots.
  const room = Math.min(g.launchcap, h.max_launches_per_day - h.launches_24h);
  return { ok: true, room, text: `${lead} ${when.startsWith('the next') ? 'offers' : 'the pass offers'} ${ready[0].key} first. Up to ${room} can launch. Feedback and rebase rounds use slots first, and the pass can still skip a ticket.` };
}
