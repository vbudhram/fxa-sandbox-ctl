// The health word and the alerts, ported from renderStatus and renderAlerts in the retired v1 dashboard.
import { ago, short } from '../format';
import { AGENTS, type J, STATE, memo } from './base';
import { SNAP, merged, pipe, queueWaits, stopName, strayRun, strays } from './pipeline';

export const health = memo((s) => [pipe(s), AGENTS(s), STATE(s), s.conn.mode], (s): { level: '' | 'dead' | 'warn' | 'paused'; word: string; title: string } => {
  const snap = SNAP(s), g = AGENTS(s), st = STATE(s), h = snap?.health ?? {};
  // The server cannot be reached: the health is unknown, not the last state.
  if (s.conn.mode === 'offline') return { level: 'dead', word: 'unknown', title: 'Server unreachable' };
  // A pause is on purpose: the pass age then says nothing about health.
  const paused = h.paused != null;
  const sp = h.seconds_since_pass, dead = !paused && (sp == null || sp > 7200), quiet = !paused && sp != null && sp > 1500;
  const lowDisk = h.free_gb != null && h.min_free_gb != null && h.free_gb < h.min_free_gb;
  const stale = st.age_seconds == null || st.age_seconds > 300;
  // Nothing launchable while tickets wait on a person: the pipeline is idle for a reason a person can fix.
  const q = snap?.queue, ready = q?.ready?.length ?? 0, waits = queueWaits(s).length, starved = !q?.fetch_failed && ready === 0 && waits > 0;
  const level = dead || lowDisk ? 'dead' : stale || st.error || st.agents_error || quiet || starved ? 'warn' : '';
  const word = level === 'dead' ? (lowDisk ? 'disk low' : 'no passes') : level === 'warn' ? (stale || st.error || st.agents_error || quiet ? 'degraded' : 'tickets wait') : paused ? 'paused' : 'healthy';
  const title = [`${g?.backend ?? snap?.backend ?? '?'}${g?.zone ? ` ${g.zone}` : ''}`, h.lock_held ? 'lock held' : 'lock free', g ? `launchcap ${g.launchcap ?? 'unknown'}` : '',
    `${h.free_gb ?? '?'}GB free`, snap ? `tickets snapshot took ${snap.took_seconds}s` : '', g ? `agents feed took ${g.took_seconds}s` : ''].filter(Boolean).join(' · ');
  return { level: level || (paused ? 'paused' : ''), word, title };
});

export type AlertRow = { tone: 'bad' | 'warn'; subject: string; what: string; fix?: string };
// passQuiet: the timer is on and its next run is over 25 min away, so an old last pass is the schedule
// (the night, a weekend hour), not a stall. A timer that fires and fails keeps its next run near.
export const passQuiet = (h: J, now = Date.now() / 1000): boolean =>
  h?.pass_timer === 'on' && typeof h.next_pass_epoch === 'number' && h.next_pass_epoch - now > 1500;

// The faults a person fixes. subject is a feed or a key; fix, when given, is the command that fixes it.
export const alerts = memo((s) => [pipe(s), AGENTS(s), STATE(s), merged(s), strays(s)], (s): AlertRow[] => {
  const snap = SNAP(s), g = AGENTS(s), st = STATE(s), out: AlertRow[] = [], h = snap?.health ?? {};
  const add = (tone: 'bad' | 'warn', subject: string, what: string, fix?: string) => out.push(fix ? { tone, subject, what, fix } : { tone, subject, what });
  // The stale feeds share one alert, so the page says the age once.
  const old: [string, number][] = [];
  const staleFeed = (name: string, age: J, every: J) => { if (age != null && every && age > 3 * every) old.push([name, age]); };
  staleFeed('agents', st.agents_age_seconds, st.agents_interval);
  staleFeed('tickets', st.age_seconds, st.interval);
  if (!st.stats_error) staleFeed('stats', st.stats_age_seconds, st.stats_interval);
  if (old.length) add('warn', old.map(([n]) => n).join(', '), `Data is up to ${ago(Math.max(...old.map(([, a]) => a))).replace(' ago', '')} old.`);
  if (st.error) add('bad', 'tickets', st.error);
  if (st.agents_error) add('bad', 'agents', st.agents_error);
  if (st.stats_error) add('warn', 'stats', st.stats_error);
  // Outside pass hours an old last pass is no fault: the status bar says when passes resume.
  const sp = h.seconds_since_pass, offHours = sp != null && passQuiet(h);
  if (!offHours && snap && (sp == null || sp > 7200)) add('warn', 'pass', sp == null ? 'no pass recorded yet' : `no pipeline pass in ${ago(sp).replace(' ago', '')}, so open PRs get no reconcile, feedback or rebase rounds. To start the passes, the operator runs /fxa-automation in Claude Code.`);
  else if (!offHours && sp > 1500) add('warn', 'pass', `last pass ${ago(sp)}; the cron fires every 20 minutes`);
  if (h.free_gb != null && h.min_free_gb != null && h.free_gb < h.min_free_gb) add('bad', 'disk', `${h.free_gb}GB free, launches refuse below ${h.min_free_gb}GB`);
  if (snap?.inflight_fetch_failed) add('warn', 'jira', 'could not read in-flight tickets; nothing running is unverified');
  merged(s).cards.forEach((t) => {
    const a = t.agent || {}, title = t.summary || t.key, stop = stopName(t.name);
    if (t.base_ok === false) add('bad', t.key, `${title} · the sandbox is not on the slot's commit`, stop ? `fxa-sandbox-ctl stop ${stop}` : '');
    if (a.num_turns === 0) add('bad', t.key, `${title} · the goal was rejected: the rendered prompt is over 4000 chars`, 'Stop the run, then shorten the ticket and requeue it');
    else if (t.agent_alive && (a.idle_seconds ?? 0) >= 600) add('warn', t.key, `idle ${short(a.idle_seconds)}: ${a.last_tool || a.last_text || 'no output'}`);
  });
  const stray = new Set(strays(s));
  (g?.instances ?? []).forEach((v: J) => {
    const run = strayRun(v.name);
    if (stray.has(v)) add('warn', v.name, `${v.state} with no run behind it (${short(v.age_seconds)} old); it bills until deleted`, stopName(run) ? `fxa-sandbox-ctl stop ${run}` : '');
    else if (v.max_seconds && v.age_seconds >= v.max_seconds) add('warn', v.name, `over the ${short(v.max_seconds)} lifetime cap; GCE deletes it any moment`);
  });
  return out;
});

