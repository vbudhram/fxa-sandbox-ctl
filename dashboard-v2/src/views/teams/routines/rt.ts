// Routine logic ported from the retired v1 dashboard (rtDraft to rtCostHint). Pure: no store, no DOM.
import { REPO_RE, sentence, usd } from '../../../format';
import type { J } from '../../../model/base';
import type { Tone } from '../../../ui';

// Q11: client copies of server limits, in one place until the server sends them.
export const RT_LIMIT = 8;
export const RT_WITHIN_MIN = 60;
export const RT_STALE_S = 300;
export const RT_CHANS_S = 300;
export const RT_PROMPT_MAX = 4096;

export const RT_DAYS = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
export const RT_DAY_NAMES = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
export const RT_MODES: [string, string, string][] = [
  ['report', 'Report', 'A summary in Slack and History. Changes no code.'],
  ['tickets', 'Jira tickets', "Files each finding as a ticket in the team's Jira project, for a person to triage, at most 5 new tickets a run. A finding already in a ticket is not filed again. Changes no code."],
  ['pr', 'Draft PR', 'Opens a draft PR with the fixes. Nothing merges by itself.'],
  ['pr+notes', 'Draft PR with notes', 'The draft PR, plus every finding it did not fix, in the PR description.'],
];
export const RT_FIELDS = ['template', 'name', 'prompt', 'schedule', 'zone', 'repos', 'branch', 'watch', 'channel', 'mode', 'draft', 'max_usd', 'runtime', 'model', 'effort', 'skip_no_commits', 'pr_repo', 'pr_authors', 'pr_label', 'pr_mention', 'pr'];
// As lib/routine.py MODELS and EFFORTS; '' is the host's default.
export const RT_MODELS: [string, string][] = [['', 'Default (Opus 5.5)'], ['claude-opus-5-5', 'Opus 5.5'], ['claude-sonnet-5-5', 'Sonnet 5.5'], ['claude-haiku-5-5', 'Haiku 5.5']];
export const RT_EFFORTS: [string, string][] = [['', 'Default'], ['low', 'Low'], ['medium', 'Medium'], ['high', 'High'], ['xhigh', 'Extra high'], ['max', 'Max']];
// As lib/routine.py RUNTIMES: each runtime's models and efforts; no runtime is Claude.
export const RT_RUNTIMES: [string, string][] = [['claude', 'Claude'], ['codex', 'Codex']];
export const RT_PICKS: Record<string, { models: [string, string][]; efforts: [string, string][] }> = {
  claude: { models: RT_MODELS, efforts: RT_EFFORTS },
  codex: { models: [['', 'Default (gpt-6-astra)'], ['gpt-6-astra', 'gpt-6-astra']], efforts: RT_EFFORTS.filter(([v]) => v !== 'max') },
};
export const rtPicks = (d: J) => RT_PICKS[d.runtime as string] ?? RT_PICKS.claude!;
// The runtime, model and effort of a routine, set only when picked.
const own = (d: J): J => ({ ...(d.runtime && d.runtime !== 'claude' ? { runtime: d.runtime } : {}), ...(d.model ? { model: d.model } : {}), ...(d.effort ? { effort: d.effort } : {}) });
export const RT_ZONES: [string, string][] = [
  ['America/New_York', 'Eastern'], ['America/Chicago', 'Central'], ['America/Denver', 'Mountain'], ['America/Los_Angeles', 'Pacific'],
  ['UTC', 'UTC'], ['Europe/London', 'UK'], ['Europe/Berlin', 'Central Europe'], ['Asia/Kolkata', 'India'], ['Asia/Tokyo', 'Japan'], ['Australia/Sydney', 'Sydney'],
];
export type Start = { template: string; name: string; about?: string; mode?: string; locked_mode?: string; skip_no_commits?: boolean; prompt?: string; on?: string };
export const RT_BLANK: Start = { template: 'blank', name: 'Write your own', about: 'Start with an empty prompt, for a task the other starts do not cover.', mode: 'report', skip_no_commits: true, prompt: '' };
// The dependency PR start (on='pr-label'): no schedule and no prompt; a red PR that asks for help starts each run.
export const RT_DEPFIX: Start = { template: 'depfix', on: 'pr-label', name: 'Fix dependency PRs', about: 'When a red Dependabot or BLEnder PR asks for help, pushes one fix commit to its branch and posts in Slack.', mode: 'pr' };
export const RT_VERB: Record<string, string> = {
  'code-review': 'Reviews new commits on', 'perf-review': 'Looks for slow paths in', 'security-review': 'Looks for security defects in', 'ux-review': 'Checks the changed screens in',
};
// The v1 dot of a run in the strip of last runs, as a tone with its word.
export const RT_DOT: Record<string, Tone> = { ok: 'merged', report: 'info', failed: 'bad', missed: 'bad', stopped: 'warn' };

export const rtStarts = (tpls: Start[] | null) => [...(tpls ?? []), RT_DEPFIX, RT_BLANK];

// A text's size against its limit, in bytes as the server counts.
export const textSize = (s: unknown, max: number) => {
  const n = new TextEncoder().encode(String(s ?? '')).length;
  return n >= 0.9 * max ? `${n} of ${max} bytes, ${max - n} left` : `${n} of ${max}`;
};

// A routine's config as form fields, and back.
export function rtDraft(data?: J): J {
  const d = data ?? { template: 'blank', name: '', prompt: '', schedule: 'weekdays 09:00', zone: 'America/New_York', repos: [], channel: '', mode: 'report', max_usd: 10, skip_no_commits: true };
  const [kind, a, b] = String(d.schedule || 'weekdays 09:00').split(' '), pr = d.pr ?? {};
  return {
    ...d, template: d.template || 'blank', kind, day: kind === 'weekly' ? a : 'mon', time: kind === 'weekly' ? b : a, repos: [...(d.repos ?? [])],
    branch: d.branch ?? '', watch: d.watch ?? '', channel: d.channel ?? '', draft: d.draft !== false,
    ...(d.on === 'pr-label' ? { pr_repo: pr.repo ?? '', pr_authors: (pr.authors ?? []).join(', '), pr_label: pr.label ?? 'agent-help', pr_mention: pr.blender_mention ?? '' } : {}),
  };
}
export function rtRoutine(d: J): J {
  if (d.on === 'pr-label') {
    // An edit keeps the pr fields the form does not show (blender_login, sweep_min).
    const pr: J = { ...(d.pr ?? {}), repo: d.pr_repo, authors: String(d.pr_authors).split(/[\s,]+/).filter(Boolean), label: String(d.pr_label).trim() || 'agent-help' };
    if (String(d.pr_mention ?? '').trim()) pr.blender_mention = String(d.pr_mention).trim(); else delete pr.blender_mention;
    return { on: 'pr-label', template: 'blank', name: d.name, repos: d.pr_repo ? [d.pr_repo] : [], channel: String(d.channel).trim(), mode: 'pr', max_usd: Number(d.max_usd), pr, ...own(d), ...(d.env ? { env: d.env } : {}) };
  }
  const r: J = {
    template: d.template, name: d.name, prompt: d.prompt, schedule: d.kind === 'weekly' ? `weekly ${d.day} ${d.time}` : `${d.kind} ${d.time}`,
    zone: d.zone, repos: d.repos, channel: String(d.channel).trim(), mode: d.mode, draft: d.draft !== false, max_usd: Number(d.max_usd), skip_no_commits: !!d.skip_no_commits, ...own(d),
  };
  if (String(d.branch).trim() && d.repos.length === 1) r.branch = String(d.branch).trim();
  if (d.watch && !d.repos.includes(d.watch)) r.watch = d.watch;
  if (d.env) r.env = d.env;
  return r;
}
// A new draft from a start: its prompt and result, and the team's repo when it has only one.
export function rtFromTpl(x: Start, repos: J[]): J {
  const d = rtDraft(), work = repos.filter((r) => r.role === 'work');
  if (x.on === 'pr-label') return { ...d, template: 'blank', on: 'pr-label', name: 'Dependency fixes', prompt: '', mode: 'pr', max_usd: 10,
    pr_repo: work.length === 1 ? work[0].slug : '', pr_authors: 'dependabot[bot]', pr_label: 'agent-help', pr_mention: '' };
  return { ...d, template: x.template, name: x.template === 'blank' ? '' : x.name, prompt: x.prompt ?? '', mode: x.locked_mode || x.mode || 'report',
    skip_no_commits: x.skip_no_commits !== false, repos: repos.length === 1 ? [repos[0].slug] : [], max_usd: 5 };
}
// The pr block's errors go to the field they name (v1 put them all on the fieldset).
const PR_SUB: Record<string, string> = { repo: 'pr_repo', authors: 'pr_authors', label: 'pr_label', blender_mention: 'pr_mention' };
// The validator answers one "field: reason" line for each bad field; the rest is the summary.
export function rtErrs(text: unknown): { errs: Record<string, string>; summary: string } {
  const errs: Record<string, string> = {}, other: string[] = [];
  for (const l of String(text || '').split('\n').map((s) => s.replace(/^ERROR: /, '').trim()).filter(Boolean)) {
    const m = l.match(/^([a-z_]+): (.*)$/);
    if (!m || !RT_FIELDS.includes(m[1]!)) { other.push(l); continue; }
    const sub = m[1] === 'pr' ? PR_SUB[m[2]!.match(/^(\w+)/)?.[1]?.toLowerCase() ?? ''] : undefined;
    errs[sub ?? m[1]!] ??= m[2]!;
  }
  const n = Object.keys(errs).length;
  return { errs, summary: [n ? `${n} field${n === 1 ? '' : 's'} need${n === 1 ? 's' : ''} a change: ${Object.values(errs).join('. ')}.` : '', ...other].filter(Boolean).join(' ') };
}
export const rtFirstErr = (errs: Record<string, string>) => RT_FIELDS.find((k) => errs[k]);

export const rtWhen = (iso: string, zone: string, short?: boolean) => {
  try {
    return new Date(iso).toLocaleString('en-GB', { weekday: 'short', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit', timeZone: zone }) + (short ? '' : ` ${zone}`);
  } catch {
    return iso;
  }
};
// "in 17h" from now to an ISO time; nothing when it cannot be read.
export const rtIn = (iso: string, now: number) => {
  const s = (Date.parse(iso) - now) / 1000;
  return !(s >= 0) ? '' : s < 3600 ? `in ${Math.max(1, Math.round(s / 60))}m` : s < 172800 ? `in ${Math.round(s / 3600)}h` : `in ${Math.round(s / 86400)}d`;
};
export const rtZoneName = (z: string) => RT_ZONES.find((x) => x[0] === z)?.[1] ?? z;
// "every day at 10:30", "weekdays at 10:30" or "every Friday at 17:30".
export const rtSched = (d: J) => {
  const [k, a, b] = String(d.schedule || '').split(' ');
  return k === 'weekly' ? `every ${RT_DAY_NAMES[RT_DAYS.indexOf(a ?? '')] ?? a} at ${b}` : `${k === 'daily' ? 'every day' : 'weekdays'} at ${a}`;
};
export type Chans = { channels: { id: string; name: string; why?: string; why_security?: string }[]; err?: string; runtimes?: string[] };
export const rtChName = (id: string, name: string | undefined, chans: Chans | null) => {
  const c = name ? null : chans?.channels.find((x) => x.id === id);
  return name ? `#${name}` : c ? `#${c.name}` : id;
};
// A pr-label routine's live runs in line order: the running one, then the queued ones, oldest first.
export const rtLine = (r: J): J[] => {
  const L: J[] = r.lives ?? [];
  return [...L.filter((x) => x.state !== 'queued'), ...L.filter((x) => x.state === 'queued').sort((a, b) => a.id - b.id)];
};
export const rtPrN = (f: J) => (/^\d{1,9}$/.test(String(f?.pr ?? '')) ? `#${f.pr}` : 'a PR');
// Only a GitHub PR link becomes a link; anything else shows as text.
export const rtPr = (u: unknown) => {
  const m = String(u || '').match(/^https:\/\/github\.com\/([^/]+\/[^/]+)\/pull\/\d+$/);
  return m && REPO_RE.test(m[1]!) ? String(u) : '';
};
export const sessHref = (k: unknown) => (/^agent-[a-z0-9]{4,12}$/.test(String(k || '')) ? `#sessions/stopped/${k}` : '');
export const rtSha7 = (s: unknown) => (/^[0-9a-f]{7,40}$/.test(String(s ?? '')) ? String(s).slice(0, 7) : '');

export type Result = [string, Tone, string, string?];
// A run's result: [tag, tone, one line]. A routine with no channel keeps its report in History.
export function rtResult(x: J, d: J): Result {
  if (d?.on === 'pr-label' || x.heads?.fix) return rtFixResult(x, d);
  const pr = rtPr(x.pr_url);
  const by: Record<string, Result> = {
    ok: ['Draft PR', 'merged', pr ? `Opened draft PR #${pr.split('/').pop()}` : x.pr_url ? `Finished: ${x.pr_url}` : 'Finished'],
    report: ['Report', 'info', !d?.channel ? 'Report in History' : x.reason ? `Report held: ${x.reason}. Read it in History` : 'Posted a report'],
    nochange: ['No change', 'dim', 'Nothing to change'],
    failed: ['Failed', 'bad', x.reason ? sentence(String(x.reason)) : 'Failed'],
    missed: ['Missed', 'bad', x.reason ? sentence(String(x.reason)) : 'The run did not start'],
    stopped: ['Stopped', 'warn', 'Stopped by an admin'],
  };
  return by[x.state] ?? [String(x.state ?? 'unknown'), 'dim', x.reason || String(x.state ?? '')];
}
const FIX_GUARD: Record<string, [string, string]> = {
  lock: ['yarn.lock', 'The fix changes yarn.lock entries, which I do not push. Fix it by hand.'],
  tooling: ['Yarn tooling', 'The fix changes Yarn tooling files, which I do not push. Fix it by hand.'],
  frozen: ['protected files', 'The fix changes protected files, which I do not push. Fix it by hand.'],
  pii: ['personal data', 'The fix may hold personal data or a secret, so it was not pushed. Read the report here.'],
};
// A dependency fix run's result from ctl's state and fix.why, never agent text: [tag, tone, one line, the next step].
export function rtFixResult(x: J, d: J): Result {
  const f = x.heads?.fix ?? {}, n = rtPrN(f), lb = d?.pr?.label || 'agent-help', why = String(f.why ?? ''), again = `Add ${lb} again to retry.`;
  const not: Record<string, [string, string]> = {
    'new-commit': ['the PR has a new commit', `Add ${lb} again to fix the new head.`], expired: ['it waited 24 h', again], 'not-red': ['CI passes on its head', `Add ${lb} again if CI fails.`],
    used: ['a run on its head already ended', 'A new commit allows a new run.'], 'no-write': ['the label needs a person with write access', `Ask a person with write access to add ${lb}.`],
    fork: ['the PR is from a fork', 'Fix it by hand.'], base: ['the PR branch is a base or release branch', 'Fix it by hand.'], closed: ['the PR is closed', `Reopen it and add ${lb} again.`],
    merged: ['the PR is merged', 'No step is needed.'], boot: ['the sandbox did not start', again], target: ['the PR no longer matches this routine', "Check the routine's repo and authors."],
  };
  if (x.state === 'ok') return ['Pushed', 'merged', `Pushed ${rtSha7(f.new_sha) || 'the fix'} to ${n}`, 'Next: review the fix commit, then approve the functional tests gate.'];
  if (x.state === 'report' && why === 'moved') return ['Branch moved', 'warn', `The branch of ${n} moved, so nothing was pushed`, again];
  if (x.state === 'report' && why.startsWith('guard:')) {
    const [c, t] = FIX_GUARD[why.slice(6)] ?? ['a guard', 'A guard refused the fix. Fix it by hand.'];
    return ['Not pushed', 'warn', `Not pushed (${c})`, t];
  }
  if (x.state === 'report' || x.state === 'nochange') return ['No fix found', 'dim', `No fix found for ${n}`, 'A new commit allows a new run.'];
  if (x.state === 'stopped') {
    const c = why === 'label' ? `the ${lb} label was removed` : ['closed', 'merged'].includes(why) ? `${n} was ${why}` : 'a team admin stopped it';
    return ['Stopped', 'warn', `Stopped (${c})`, `Nothing was pushed. ${why === 'merged' ? 'No step is needed.' : why === 'label' || why === 'closed' ? again : 'Use Run now to retry.'}`];
  }
  if (x.state === 'skipped') {
    const [c, nx] = not[why] ?? ['the run could not start', again];
    return ['Not started', 'dim', `Not started (${c})`, nx];
  }
  return ['Failed', 'bad', x.reason ? sentence(String(x.reason)) : `The fix for ${n} failed`, `Nothing was pushed. ${again}`];
}
// The next step for a failed run whose reason is known.
export function rtFix(why: unknown) {
  const w = String(why || '');
  if (/channel_not_found|not_in_channel/.test(w)) return 'Invite @fxa-agent to the channel, then use Run now.';
  if (/no session started/.test(w)) return 'No runner was free. The next run tries again.';
  return /spend/.test(w) ? "The team's spend stopped the run. See the team's Overview." : '';
}
export const rtFailed = (r: J, sum: J) => !!sum?.routines?.[r.id]?.failed || ['failed', 'missed'].includes(r.last?.state);

// The next run days of a draft, in its zone, from its kind, day and time (no DST math: a day and a wall time).
export function rtNextDays(d: J, n: number, now: number): string[] {
  try {
    const [hh, mm] = String(d.time || '').split(':').map(Number) as [number, number];
    if (!(hh >= 0 && hh < 24 && mm >= 0 && mm < 60)) return [];
    const p = Object.fromEntries(new Intl.DateTimeFormat('en-US', { timeZone: d.zone, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' })
      .formatToParts(now).map((x) => [x.type, x.value]));
    const out: string[] = [], late = +p.hour! * 60 + +p.minute! >= hh * 60 + mm;
    for (let i = 0, day = Date.UTC(+p.year!, +p.month! - 1, +p.day!); out.length < n && i < 22; i++, day += 86400000) {
      const wd = (new Date(day).getUTCDay() + 6) % 7;
      if ((i === 0 && late) || (d.kind === 'weekdays' && wd > 4) || (d.kind === 'weekly' && RT_DAYS[wd] !== d.day)) continue;
      out.push(new Date(day).toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short', timeZone: 'UTC' }));
    }
    return out;
  } catch {
    return [];
  }
}
export const rtNextText = (d: J, now: number) => {
  const x = rtNextDays(d, 3, now);
  return x.length ? `Next runs: ${x.length > 1 ? `${x.slice(0, -1).join(', ')} and ` : ''}${x.at(-1)}, at ${d.time}.` : 'Pick a time and a zone to see the next runs.';
};
// The cost hint: what runs of this start cost on this team in 30 days.
export function rtCostHint(sum: J, team: string, d: J, tpls: Start[] | null) {
  const xs = Object.values<J>(sum?.routines ?? {}).filter((x) => x.team === team && x.template === d.template && x.cost_min_30d != null);
  if (!xs.length) return '';
  const lo = Math.min(...xs.map((x) => x.cost_min_30d)), hi = Math.max(...xs.map((x) => x.cost_max_30d));
  const name = d.template === 'blank' ? 'Custom' : (tpls ?? []).find((x) => x.template === d.template)?.name ?? d.template;
  return `${name} runs on this team cost ${usd(lo)} to ${usd(hi)} a run in the last 30 days.`;
}
// The routine list from the server: an array today; a {routines, limits} answer gives its limit (Q11).
export const rtList = (raw: unknown): { list: J[] | null; limit: number } => {
  if (raw == null) return { list: null, limit: RT_LIMIT };
  if (Array.isArray(raw)) return { list: raw, limit: RT_LIMIT };
  const o = raw as J;
  return { list: Array.isArray(o.routines) ? o.routines : [], limit: Number(o.limits?.routines) || RT_LIMIT };
};
