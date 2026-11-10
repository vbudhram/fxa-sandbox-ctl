// The team page: the heading with its state tag, the sub line, the team tabs, and the tab's body.
import { lazy, Suspense } from 'react';
import { type J, TEAMS } from '../../model/base';
import { rtAdmin, rtSum, teamAccess, teamLevel, teamName } from '../../model/teams';
import { useApp } from '../../store';
import { Card, Tag } from '../../ui';
import { teamDraftOf, teamWho } from './lib';
import { Overview } from './Overview';
import { Settings } from './Settings';
import { useTs } from './state';

// Routines and Memory are admin tabs: they load in their own chunks when opened.
const RoutinesTab = lazy(() => import('./routines')), MemoryTab = lazy(() => import('./memory'));
const TABS = [['overview', 'Overview'], ['routines', 'Routines'], ['memory', 'Memory'], ['settings', 'Settings']] as const;

export function TeamPage({ p, tab: want }: { p: string; tab: string }) {
  const ts = useApp((s) => TEAMS(s)?.teams), admin = useApp((s) => s.viewer.admin), rt = useApp((s) => rtAdmin(s, p)), r = useApp((s) => rtSum(s, p));
  const R = useTs((s) => (s.rec?.name === p ? s.rec : null)), running = useTs((s) => s.test?.team === p && s.test.data?.result === 'running');
  const feedRun = useApp((s) => (s.feeds[`team-test:${p}`]?.data as { result?: string } | null)?.result === 'running');
  let t = (ts ?? []).find((x: J) => x.profile === p), note = '';
  // Just after a create the feed can lag: the loaded record stands in until it has the team.
  if (!t && R?.rec) {
    const a = R.rec.access ?? {};
    t = { profile: p, label: R.rec.label, repos: [], issues: [], test: null,
      access: { record: true, status: R.rec.status, open: !!a.open, listed: (a.users ?? []).length, channels: (a.channels ?? []).length } };
    note = 'The team list updates in a minute.';
  }
  if (!t) return <div className="tpage"><h2 className="th" id="team-h" tabIndex={-1}>No team {p}</h2><p className="tsub">It may have been deleted. <a className="lnk" href="#teams">All teams</a></p></div>;
  const draft = teamDraftOf(t), rec = R?.rec ?? null, base = `#teams/${t.profile}`;
  // A draft has no Overview and no Memory: nothing runs for it yet.
  const tab = draft && (want === 'overview' || want === 'memory') ? 'settings' : want;
  const tabs = draft ? [TABS[3], TABS[1]] : TABS;
  const st = rec?.status ?? t.access?.status;
  const stateTag = (running || feedRun) && admin ? <Tag label="testing" tone="info" run live />
    : !t.access?.record ? <Tag label={teamAccess(t)[0]} tone={teamLevel(t) || 'ok'} />
    : st === 'active' ? <Tag label="active" tone="ok" /> : st === 'disabled' ? <Tag label="disabled" tone="warn" /> : <Tag label="draft" />;
  const who = teamWho(t, rec);
  const say = !t.access?.record ? <span className="tkey">{t.profile} · {t.access?.open === 'built-in' ? 'built into the bot' : `profiles/${t.profile}/profile.conf`}</span>
    : draft ? <p className="readback">Nobody can start <b>{teamName(t)}</b> yet. {t.access.status === 'disabled' ? 'It is off. Test it, and it turns on again when the test passes.' : 'Test it, and it turns on when the test passes.'}</p>
    : <p className="readback"><b>{who}</b> can start <b>{teamName(t)}</b>.</p>;
  const gate = (text: string) => <Card><p>{text}</p></Card>;
  const body = t.load_error ? <Card><p>profile.conf did not load. Check it with <span className="mono">fxa-sandbox-ctl --pipeline {t.profile} profile show</span></p></Card>
    : tab === 'routines' ? (rt ? <>{draft && <Card flat><p className="hint">Routines run only when the team is active.</p></Card>}<RoutinesTab team={t} /></> : gate('Only a team admin can see and change routines.'))
    : tab === 'memory' ? (admin ? <MemoryTab team={t} /> : gate('Only a team admin can see and change team memory.'))
    : tab === 'settings' ? <Settings t={t} />
    : <Overview t={t} />;
  return (
    <div className="tpage">
      <div className="thead stack sm">
        <h2 className="th" id="team-h" tabIndex={-1}>{teamName(t)} {stateTag}</h2>
        {say}
        {note && <p className="hint">{note}</p>}
      </div>
      <nav className="ttabs" id="team-tabs" aria-label="Team">
        {tabs.map(([k, l]) => (
          <a key={k} href={`${base}${k === 'overview' ? '' : `/${k}`}`} aria-current={tab === k ? 'page' : undefined}>
            {l}
            {k === 'settings' && draft && <span className="n">1 step left</span>}
            {k === 'routines' && r && <><span className="n">{r.routines}</span>{!!r.failed && <span className="n bad">{r.failed} failed</span>}</>}
          </a>
        ))}
      </nav>
      <Suspense fallback={<p className="hint">loading…</p>}>{body}</Suspense>
    </div>
  );
}
