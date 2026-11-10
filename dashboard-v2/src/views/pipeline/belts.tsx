// The Belts tab (v1 beltsHtml, beltRow, beltDetails): tiles, the 9-stop belts by phase, the outside list, and the flow.
import { m, useReducedMotion } from 'motion/react';
import { memo, useEffect, useLayoutEffect, useMemo, useRef, useState, type FocusEvent, type MouseEvent, type ReactNode } from 'react';
import { Belt, Spark } from '../../charts';
import { ago, days, jiraHref, plainMd, prUrl, usd } from '../../format';
import { beltCount, boardItems, beltGroups } from '../../model';
import { LANE_ST, type J } from '../../model/base';
import { SNAP, hasChecks, jiraSite, laneTitle, openPrCounts, pipe, teamRepo } from '../../model/pipeline';
import { rtAdmin } from '../../model/teams';
import { postJson } from '../../live/api';
import { badPipeLink, sessTabOf } from '../../router';
import { MODEL, useParts } from '../../app/store';
import type { State } from '../../live/reducers';

import type { Store } from '../../store/types';
import { Card, CheckBars, EmptyBox, Tag } from '../../ui';
import { cx } from '../../ui/tone';
import { BELT_HINT, BELT_SUBS, GROUP_NAME, GROUPS, ageSecs, ageWords, beltTone, doneRows, mergesPerDay, reviewHold } from './data';
import { Flow } from './flow';
import { WaitStrip } from './queue';
import { Ext, SrcBadge, Tile, useOpen } from './parts';

const plural = (n: number, w: string) => `${n} ${w}${n === 1 ? '' : 's'}`;
// The stops named under the live belts: Queue, Agent, PR, CI and Merged.
const LEGEND = [0, 2, 5, 6, 8];
const q = (x: number | null) => (x == null ? null : x);

// A link that names no ticket: the shell drops the key before this chunk loads, so the first one comes from the page load.
let navBad = (() => {
  try {
    const n = (performance.getEntriesByType('navigation')[0] as PerformanceNavigationTiming | undefined)?.name;
    return n ? badPipeLink(new URL(n).hash) : false;
  } catch {
    return false;
  }
})();
function useBadLink() {
  const [bad, setBad] = useState(navBad);
  useEffect(() => {
    const on = (e: HashChangeEvent) => {
      navBad = false;
      setBad(badPipeLink(new URL(e.newURL).hash));
    };
    addEventListener('hashchange', on);
    return () => removeEventListener('hashchange', on);
  }, []);
  return bad;
}

// cost_so_far of each live belt, one value per agents feed frame that changed it.
const COST: Record<string, number[]> = {};
function trackCost(agents: J) {
  for (const r of agents?.runners ?? []) {
    const c = r.agent?.cost_so_far, xs = (COST[r.key] ??= []);
    if (typeof c === 'number' && xs[xs.length - 1] !== c) {
      xs.push(c);
      xs.splice(0, xs.length - 60);
    }
  }
}



export function Belts() {
  const s = useParts<State>(MODEL);
  const g: J = beltGroups(s), snap = SNAP(s), sel = s.route.sel, bad = useBadLink();
  const box = useRef<HTMLDivElement>(null);
  const focus = useRef<{ el: HTMLElement; key: string; f: string } | null>(null);
  const said = useRef<HTMLParagraphElement>(null);
  const outside = useOpen('outside', false);
  useMemo(() => trackCost(s.feeds.agents?.data), [s.feeds.agents?.data]);


  // An update that replaces the focused row puts the focus back on the same row and control.
  useLayoutEffect(() => {
    const f = focus.current;
    if (!f || f.el.isConnected || document.activeElement !== document.body || !box.current) return;
    const li = box.current.querySelector(`[data-belt="${CSS.escape(f.key)}"]`);
    const to = li?.querySelector<HTMLElement>(`[data-focus="${f.f}"]`) ?? li?.querySelector<HTMLElement>('[data-focus="row"]');
    if (to) to.focus({ preventScroll: true });
    else {
      box.current.focus({ preventScroll: true });
      if (said.current) said.current.textContent = `${f.key} left the belts.`;
      focus.current = null;
    }
  });
  const onFocus = (e: FocusEvent) => {
    const el = e.target as HTMLElement, li = el.closest<HTMLElement>('[data-belt]');
    focus.current = li ? { el, key: li.dataset.belt!, f: el.dataset.focus ?? 'row' } : null;
  };
  useEffect(() => {
    if (sel) box.current?.querySelector(`[data-belt="${CSS.escape(sel)}"]`)?.scrollIntoView({ block: 'nearest' });
  }, [sel]);

  if (!snap) return <EmptyBox>Loading the pipeline…</EmptyBox>;
  const n = beltCount(g), anyLive = !!snap && g.working.some((r: J) => r.t.agent_alive);
  const old = g.outside.filter((r: J) => r.age >= 3).length;
  const repo = teamRepo(s, ''), lbl = snap.team?.pr_label;
  const prHref = repo && lbl ? `https://github.com/${repo}/pulls?q=is%3Apr+state%3Aopen+label%3A${encodeURIComponent(lbl)}` : '';
  // Needs you is the Overview's number: the belts only a person can move. Review waits on a reviewer, so it is named apart.
  const you = g.unknown.needs ? null : g.needs.length, pc = openPrCounts(s);
  const done = doneRows(snap), merged = snap.merged_prs == null ? null : snap.merged_prs.filter((p: J) => p.key && (days(p.merged) ?? 99) <= 7).length;
  // Blocked tickets that wait on a reporter or another ticket have no belt: the header still counts them.
  const offBelts = g.unknown.needs ? 0 : boardItems(s).filter((i: J) => i.column === 'blocked' && i.group === 'wait').length;
  const all = [...GROUPS.flatMap((k) => g[k]), ...g.outside] as J[];
  const ageMax = Math.max(1, ...all.map((r) => ageSecs(r) ?? 0));
  // A change to what sits above a row moves it, so the row repaints and motion moves it; else a row with the same data skips its repaint.
  const at = JSON.stringify([sel, bad, g.unknown, all.map((r) => `${r.group}:${r.tone}:${r.t.key}`)]);
  const row = (r: J) => (
    <BeltRow key={r.t.key} r={r} open={r.t.key === sel} ageMax={ageMax} at={at}
      jh={jiraHref(r.t.key, jiraSite(s, r.t.key))} ph={prUrl(r.t.pr, teamRepo(s, r.t.key))} />
  );

  // Working now always shows, so an empty belt says no agent runs; the other groups show only with rows.
  const sub = ([k, who, name, pick]: (typeof BELT_SUBS)[number]) => {
    if (g.unknown[k]) return null;
    const rs = g[k].filter(pick);
    return rs.length || k === 'working' ? (
      <div key={name} role="group" aria-label={name}>
        <h2 className="bsub"><span className="who">{who}</span>{name} <span className="cnt">{rs.length}</span><span className="hint">{BELT_HINT[name]}</span></h2>
        {rs.length ? <ul className="belts">{rs.map(row)}</ul> : <p className="bnone">No agent runs now.</p>}
        {k === 'working' && rs.length > 0 && (
          <div className="bgrid blegend" aria-hidden="true">
            <span />
            <span className="stops">{LEGEND.map((i) => <span key={i} style={{ left: `${(i / (LANE_ST.length - 1)) * 100}%` }}>{LANE_ST[i]}</span>)}</span>
            <span />
          </div>
        )}
      </div>
    ) : null;
  };
  const groups = BELT_SUBS.map(sub).filter(Boolean);
  const unknown = GROUPS.filter((k) => g.unknown[k]).map((k) => <EmptyBox key={k}>{GROUP_NAME[k]}: {g.unknown[k]}</EmptyBox>);

  return (
    <div id="s-lanes">
      <div className="ptiles">
        <Tile label="Needs you" value={q(you)} tone={you ? 'warn' : undefined}
          sub={you == null ? 'a feed failed' : `to decide or fix${g.unknown.review ? '' : ` · ${g.review.length} more wait on a review`}${offBelts ? ` · ${offBelts} wait off the belts` : ''}`} />
        <Tile label="Agents working" value={q(g.unknown.working ? null : g.working.length)}
          sub={<>{anyLive && <><span aria-hidden="true" className="ds-live ds-run inline-flex text-info" /> live · </>}{n == null ? '?' : n} belt{n === 1 ? '' : 's'} in all</>} />
        <Tile label="Open PRs" value={pc ? pc.total : '—'} sub={pc ? pc.parts : 'GitHub did not answer'} href={pc ? prHref || undefined : undefined} />
        <Tile label="Merged, 7 days" value={merged ?? '—'}
          sub={merged == null ? 'GitHub did not answer' : <>pipeline tickets<Spark label="Merges per day, last 14 days" values={mergesPerDay(done)} color="chart-3" /></>} />
      </div>
      <Where g={g} s={s} sel={sel} bad={bad} done={done} />
      <div className="pcols">
        <div className="bwrap" ref={box} tabIndex={-1} onFocus={onFocus} aria-label="Belts">
          {unknown}
          {groups}
          {g.outside.length > 0 && (
            <details className="bout" open={outside.open || g.outside.some((r: J) => r.t.key === sel)} onToggle={outside.onToggle}>
              <summary>Outside the pipeline ({g.outside.length}){old ? ` · ${old} wait 3+ days` : ''}</summary>
              <ul className="belts">{g.outside.map(row)}</ul>
            </details>
          )}
        </div>
        <aside className="paside" aria-label="Pipeline details">
          <Flow g={g} snap={snap} done={done} />
          {snap.review?.length > 0 && <WaitStrip review={snap.review} />}
        </aside>
      </div>
      <p className="sr-only" id="belts-said" aria-live="polite" ref={said} />
    </div>
  );
}

// Where a key from a link is when it has no belt: a hold, the queue, Done, or nowhere.
function Where({ g, s, sel, bad, done }: { g: J; s: Store; sel: string; bad: boolean; done: J[] }) {
  const qv = <>(<a href="#pipeline/queue">Queue</a>)</>;
  let text: ReactNode = null;
  if (bad) text = 'That link names no ticket.';
  else if (sel && !['working', 'needs', 'fixes', 'review', 'outside'].some((x) => g[x].some((r: J) => r.t.key === sel))) {
    const i = boardItems(s).find((x: J) => x.key === sel), d = done.find((x) => x.t.key === sel);
    text = i?.waitsOn ? <>{sel} waits on {i.waitsOn} {qv}</> : i?.column === 'next' ? <>{sel} is ready in the queue {qv}</> : i ? <>{sel} is in the queue {qv}</>
      : d ? <>{sel} {d.l1.replace(/^Merged/, 'merged')} (<a href="#pipeline/done">Done</a>)</>
        : <>{sel} is not on a belt now. Look in <a href="#pipeline/queue">Queue</a> or <a href="#pipeline/done">Done</a>.</>;
  }
  return text ? <p className="bwhere" id="bwhere">{text}</p> : null;
}

// A plain click opens or closes the row in place with replace, so Back leaves the page; a modified click keeps the browser default.
const onRow = (e: MouseEvent<HTMLAnchorElement>) => {
  if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey || e.button) return;
  e.preventDefault();
  location.replace(e.currentTarget.getAttribute('href')!);
};

type RowProps = { r: J; open: boolean; ageMax: number; at: string; jh: string; ph: string };
// The model builds new row objects on each feed frame, so the row data is compared by value.
const sameRow = (a: RowProps, b: RowProps) =>
  a.open === b.open && a.ageMax === b.ageMax && a.at === b.at && a.jh === b.jh && a.ph === b.ph && (a.r === b.r || JSON.stringify(a.r) === JSON.stringify(b.r));

const BeltRow = memo(function BeltRow({ r, open, ageMax, jh, ph }: RowProps) {
  const t = r.t, title = laneTitle(t.summary || t.branch), live = r.group === 'working' && !!t.agent_alive;
  const tone = beltTone(r);
  const age = ageWords(r), secs = ageSecs(r), cost = live ? COST[t.key] ?? [] : [];
  const href = open ? '#pipeline/belts' : `#pipeline/belts/${encodeURIComponent(t.key)}`;
  // Under MotionConfig "user" a moved row still got a layout transform, so reduced motion turns layout off.
  const still = useReducedMotion();
  return (
    <m.li layout={still ? false : 'position'} layoutId={still ? undefined : `belt-${t.key}`} transition={{ duration: 0.3 }} className={cx('belt', open && 'sel')} data-belt={t.key}>
      <div className="bgrid brow">
        <span className="tk">
          <SrcBadge kind={t.slack ? 'slack' : t.pr ? 'github' : 'jira'} />
          <span className="m">
            <Ext className="key mono" href={jh} focus="jira">{t.key}</Ext>
            {t.pr != null && <Ext className="mono" href={ph} focus="pr">#{t.pr}</Ext>}
            {title.tag && <Tag sq label={title.tag} />}
          </span>
          <a className="t blink" href={href} onClick={onRow} data-focus="row" aria-expanded={open} aria-controls={open ? `bd-${t.key}` : undefined} title={t.summary || undefined}>
            {title.text || t.key}
          </a>
        </span>
        {/* Only a run moves on the belt; a row that waits on a person shows why it stopped. */}
        <span className="trk">
          {r.group === 'working' ? (
            <>
              <Belt stops={LANE_ST} at={r.st} tone={tone ?? 'dim'} label={live ? `${r.l1}, agent working` : r.l1} live={live} />
            </>
          ) : (
            <span className="why" title={r.l2 || undefined}>
              {t.pr != null && hasChecks(t) && <CheckBars ok={t.ok ?? 0} fail={t.fail ?? 0} running={t.running ?? 0} />} {r.l2}
            </span>
          )}
        </span>
        <span className="st">
          {/* A run's stop is on its belt, so its status is what the agent does now. */}
          {r.group === 'working' ? <span className="stage" title={r.l2 || r.l1}>{r.l2 || r.l1}</span> : <Tag label={r.l1} tone={tone} title={r.l1} />}
          <span className="stn">at {LANE_ST[r.st]}</span>
          {!/\d+ days?/.test(r.l1) && age && (
            <span className={cx('age', r.age >= 7 && 'old')} title={`${r.group === 'working' ? 'running' : 'waiting'} ${age}`}>
              {age}
              {secs != null && <i className="agebar" aria-hidden="true" style={{ width: `${(Math.log1p(secs) / Math.log1p(ageMax)) * 100}%` }} />}
            </span>
          )}
          {cost.length > 1 && <span className="bcost"><Spark label={`Cost so far: ${usd(cost[cost.length - 1])}`} values={cost} format={usd} /></span>}
        </span>
      </div>
      {open && <BeltDetails r={r} jh={jh} ph={ph} />}
    </m.li>
  );
}, sameRow);


// The open row's details: four blocks, one main action and the links, each link checked or plain text.
function BeltDetails({ r, jh, ph }: { r: J; jh: string; ph: string }) {
  const s = useParts<State>(MODEL), t = r.t, i = r.item ?? {}, k = (s.feeds.stats?.data as J)?.tickets?.[t.key], a = t.agent || {}, lim = SNAP(s)?.limits?.attempts ?? 2;
  const stats = !!s.feeds.stats?.data;
  const team = pipe(s).keyTeam[t.key] || s.prefs.pipeTeam || 'fxa', cap = SNAP(s)?.limits?.feedback_rounds ?? 2;
  const give = i.column === 'blocked' && i.kind === 'rounds' && rtAdmin(s, team);
  // Every Working now row, not only a live agent: a run that still boots or stalled is the one to stop.
  const stop = r.group === 'working' && rtAdmin(s, team);
  const [busy, setBusy] = useState(false), [said, setSaid] = useState<[string, boolean] | null>(null);
  const [arm, setArm] = useState(false), [stopping, setStopping] = useState(false);
  const halt = async () => {
    if (!arm) { setArm(true); setSaid([`Stop ${t.key}? Click again to stop it. The ticket is then labelled blocked.`, true]); return; }
    setArm(false); setStopping(true);
    const g = await postJson(`/api/teams/${encodeURIComponent(team)}/pipeline/${encodeURIComponent(t.key)}/stop`, {});
    if (!('data' in g)) setStopping(false);
    setSaid('data' in g ? [`Stopping ${t.key}. Its row leaves Working now in a minute or two.`, true] : [g.error.replace(/^ERROR: /, ''), false]);
  };
  const more = async () => {
    setBusy(true);
    const g = await postJson(`/api/teams/${encodeURIComponent(team)}/pipeline/${encodeURIComponent(t.key)}/rounds`, {});
    setBusy(false);
    setSaid('data' in g ? [`${t.key} has one more review round. The agent uses it on the next trusted comment.`, true] : [g.error.replace(/^ERROR: /, ''), false]);
  };
  const blk = (h: string, body: ReactNode, bad?: boolean) =>
    bad ? <Card flat sm tone="bad" label="failed" className="blk"><h3>{h}</h3>{body}</Card> : <Card flat sm className="blk"><h3>{h}</h3>{body}</Card>;
  const total = (t.ok ?? 0) + (t.fail ?? 0) + (t.running ?? 0);
  const ci = !t.pr ? blk('CI: no PR yet', <p>Checks start after the agent opens the PR.</p>)
    : t.fail > 0 ? blk(`CI: ${t.fail} of ${total} checks failed`, <p>{t.infra ? `Known infra failure: ${t.infra}` : `${t.ok ?? 0} passed.`}</p>, true)
      : t.running > 0 ? blk(`CI: ${t.running} of ${total} running`, <p>{t.ok ?? 0} passed so far.</p>)
        : blk(`CI: ${t.ok ?? 0} checks passed`, <p>{t.mergeable === 'CONFLICTING' ? 'The branch has merge conflicts.' : 'Nothing failed.'}</p>);
  const facts = [a.model && <span key="m" className="mono">{a.model}</span>, a.cost_so_far && `${usd(a.cost_so_far)} so far`, a.turns && `${a.turns} turns`].filter(Boolean);
  const agent = t.agent_alive
    ? blk(`Agent: ${LANE_ST[r.st]} · ${Math.round((t.elapsed_seconds ?? 0) / 60)} min`, (
      <p>{facts.length ? facts.map((x, n) => <span key={n}>{n ? ' · ' : ''}{x}</span>) : 'working'}</p>
    ))
    : blk(`Agent: ${i.next || r.l1 || ''}`, <p>{i.kind === 'rounds' ? `Review rounds ${cap} of ${cap}. The agent stops here. Fix the PR by hand, or give the agent one more round.`
      : t.attempts != null || r.group === 'fixes' ? `Fix attempts ${t.attempts ?? 0} of ${lim}. Then it moves to Needs you.` : plainMd(r.l2)}</p>);
  const rv = ({ APPROVED: 'approved', CHANGES_REQUESTED: 'changes requested', REVIEW_REQUIRED: 'review required' } as Record<string, string>)[t.review] ?? t.review;
  const reqd = (t.reviewers ?? []).map((x: string) => x.replace(/^mozilla\//, '')).join(', ');
  const hold = reviewHold(t, SNAP(s)?.limits);
  const review = !t.pr ? blk('Review: none yet', <p>A reviewer gets it after CI passes.</p>)
    : blk(`Review: ${rv || 'none yet'}`, <><p>{t.last_human_review ? `${t.last_human_review.login} reviewed ${ago(Math.round((days(t.last_human_review.at) ?? 0) * 86400))}` : `no human review${reqd ? ` · requested ${reqd}` : ''}`}</p>{hold.map((h) => <p key={h} data-hold>{h}</p>)}</>);
  const runs = blk(`Agent runs: ${k ? k.runs : stats ? 'none' : '…'}`, (
    <p>{k ? [plural(k.turns, 'turn'), `${k.median_min} min`, usd(k.cost), plural(k.files, 'file')].join(' · ') : stats ? 'not in the run log: a run records only when it reaches handoff' : 'loading…'}</p>
  ));
  // The session's own tab: the Sessions view shows a key only on the tab of its state.
  const sess = t.sess && /^agent-[a-z0-9]{4,12}$/.test(t.sess.key) ? `#sessions/${sessTabOf(t.sess.state)}/${t.sess.key}` : '';
  const [label, href] = t.slack ? ['Open the session', sess] : t.agent_alive ? ['Watch the agent', ''] : t.fail > 0 && ph ? ['Open the failing check', `${ph}/checks`]
    : r.group === 'needs' && i.column === 'blocked' && jh ? ['Answer in Jira', jh] : ph ? ['Open the PR', ph] : jh ? ['Answer in Jira', jh] : ['', ''];
  const lane = `#lane/${t.key}`;
  const main = t.agent_alive
    ? <a className="main" data-focus="main" href={lane} target={`lane-${t.key}`} rel="noopener"
      onClick={(e) => { e.preventDefault(); window.open(lane, `lane-${t.key}`, 'popup,width=820,height=520'); }}>Watch the agent ↗<span className="sr-only"> (opens a new window)</span></a>
    : href ? <a className="main" data-focus="main" href={href} {...(href.startsWith('#') ? {} : { target: '_blank', rel: 'noopener' })}>{label}</a> : null;
  return (
    <div className="bdet" id={`bd-${t.key}`} role="region" aria-label={`Details of ${t.key}`}>
      <div className="blks">{ci}{agent}{review}{runs}</div>
      <div className="acts">
        {main}
        {stop && <button type="button" className="give" data-focus="d-stop" disabled={stopping} aria-busy={stopping} onClick={() => void halt()}>{stopping ? 'Stopping…' : arm ? 'Click again to stop' : 'Stop the agent'}</button>}
        {give && <button type="button" className="give" data-focus="d-rounds" disabled={busy} aria-busy={busy} onClick={() => void more()}>{busy ? 'Giving a round…' : 'Give one more round'}</button>}
        {jh && <a data-focus="d-jira" href={jh} target="_blank" rel="noopener">Jira ↗</a>}
        {ph && <a data-focus="d-pr" href={ph} target="_blank" rel="noopener">PR ↗</a>}
        {ph && <a data-focus="d-checks" href={`${ph}/checks`} target="_blank" rel="noopener">Checks ↗</a>}
        {sess && <a data-focus="sess" href={sess}>Session</a>}
      </div>
      {(give || stop) && <p role="status" className={cx('rsaid', said && !said[1] && 'bad')}>{said?.[0]}</p>}
    </div>
  );
}
