// The Stats main pane: the loading and error states, the heading with the range, the filter chips, and the tab.
import { useEffect, useMemo, useState } from 'react';
import { modelName, sentence } from '../../format';
import type { J } from '../../model/base';
import { statsBounds } from '../../model/stats';
import { teamLabel } from '../../model/teams';
import { format } from '../../router';
import { setRoute, store, useApp } from '../../store';
import { SF_DEFAULT } from '../../store/prefs';
import type { StatsFilter } from '../../store/types';
import { statsNote } from '../shared/stats';
import { filterRows } from './compute';
import { filterFromQuery, isOn, KIND, keepFilter, restoreFilter, setFilter, SF_SRC, STATS_USES, TAB_TITLE, tabOf, useFilter, useTmp } from './filter';
import { Prs } from './Prs';
import { Pipeline, Runners } from './Runners';
import { bucketLabel, Spend } from './Spend';
import './stats.css';

export function Main() {
  const route = useApp((s) => s.route);
  const f = useApp((s) => s.feeds.stats);
  // The parts that name a row: session titles and owners, team names, the admin flag, the repo and Jira site.
  useApp((s) => [s.sessions, s.feeds.teams, s.viewer, s.feeds.full]);
  const s = store.getState();
  const tab = tabOf(route.tab);
  const sf = useFilter();
  const tmp = useTmp((x) => x.tmp);

  // An Overview link: #stats/<tab>?range=<r>&src=<s> sets the filter for the visit. Restore and Keep these drop the query.
  const { range: qRange, src: qSrc } = route.query;
  useEffect(() => { filterFromQuery({ range: qRange, src: qSrc }); }, [qRange, qSrc]);
  const leave = (f: () => void) => {
    f();
    const r = { ...store.getState().route, query: {} };
    history.replaceState(null, '', format(r));
    setRoute(r);
  };

  // The clock moves each minute, so a range follows the day change and the ages stay current.
  const [now, setNow] = useState(Date.now);
  useEffect(() => { const t = setInterval(() => setNow(Date.now()), 60000); return () => clearInterval(t); }, []);
  const data = f?.data as J;
  const [lo, hi] = statsBounds(sf.range, now, sf);
  const rows = useMemo(() => (data?.rows ? filterRows(data.rows, sf, tab, lo, hi) : []), [data, sf, tab, lo, hi]);

  if (!data || data.error) {
    return (
      <section id="s-stats" className="st">
        <h2>Stats</h2>
        <div className="emptybox">{data?.error || (f?.error ? `${sentence(f.error)}. The next poll tries again.` : 'loading the run log…')}</div>
      </section>
    );
  }
  const on = isOn(tab, sf), unk = statsNote(f, now);
  const range = lo ? `${bucketLabel(lo)} to ${bucketLabel(Math.min(hi, now) - 1)}` : 'all time';
  const label = (k: keyof StatsFilter) => (k === 'src' ? SF_SRC[sf.src] ?? sf.src : k === 'kind' ? KIND[sf.kind] ?? sf.kind : k === 'team' ? teamLabel(s, sf.team) : k === 'model' ? modelName(sf.model) : `"${sf.q}"`);
  const chips = STATS_USES[tab].filter((k) => sf[k] !== SF_DEFAULT[k]);
  const props = { s, rows, lo, hi, now, unk, srcOn: on('src') };
  return (
    <section id="s-stats" className="st">
      {tmp && (
        <div className="st-ov" role="status">
          Filters set from Overview are not saved.{' '}
          <button type="button" className="linkbtn" data-sfrestore onClick={() => leave(restoreFilter)}>Restore my filters</button>{' · '}
          <button type="button" className="linkbtn" data-sfkeep onClick={() => leave(keepFilter)}>Keep these</button>
        </div>
      )}
      <div className="st-head">
        <h2>{TAB_TITLE[tab]}<span className="sub">{range}</span></h2>
        {chips.length > 0 && (
          <span className="fchips">
            {chips.map((k) => (
              <button key={k} type="button" className="chip" data-sfclear={k} title="Remove this filter" aria-label={`Remove the filter ${label(k)}`}
                onClick={() => setFilter({ [k]: SF_DEFAULT[k] })}>{label(k)} ×</button>
            ))}
          </span>
        )}
      </div>
      {sf.range === 'custom' && sf.from && sf.to && sf.from > sf.to && <p className="unknown" role="status">From is after To, so no day is in the range.</p>}
      {tab === 'spend' && <Spend {...props} />}
      {tab === 'prs' && <Prs {...props} all={data.prs ?? []} src={sf.src} q={on('q') ? sf.q.trim().toLowerCase() : ''} team={on('team') ? sf.team : 'all'} />}
      {tab === 'runners' && <Runners st={data} rows={rows} lo={lo} hi={hi} />}
      {tab === 'pipeline' && <Pipeline st={data} lo={lo} hi={hi} />}
    </section>
  );
}
