// The Sessions view's chunk: the frame or Answers, the side list with its Person and Team filters, and the details.
import { memo } from 'react';
import type { ViewChunk } from '../../app/views';
import { teamLabel } from '../../model/teams';
import { format } from '../../router';
import { setPref } from '../../store';
import { Answers } from './Answers';
import { owners, pick, sideGroups, teamOf } from './data';
import { Details } from './Details';
import { SessFrame } from './Frame';
import { useAll, useDetail } from './hooks';
import './sessions.css';

function Main() {
  const s = useAll();
  return s.route.tab === 'answers' ? <Answers s={s} /> : <SessFrame s={s} />;
}

function SideTools() {
  const s = useAll(), o = s.prefs.sowner, team = teamOf(s), people = owners(s);
  const clear = () => { location.hash = format({ ...s.route, sel: '', query: { ...s.route.query, team: undefined } }); };
  return (
    <>
      {(people.length > 0 || o) && (
        <label className="sowner">Person
          <select id="sowner" value={o} onChange={(e) => setPref('sowner', e.target.value)}>
            <option value="">Everyone</option>
            {people.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
            {o && !people.some((p) => p.id === o) && <option value={o}>{o}</option>}
          </select>
        </label>
      )}
      {team && <button type="button" className="tgl sm" aria-label={`Team: ${teamLabel(s, team)}. Clear the team filter.`} onClick={clear}>Team: {teamLabel(s, team)} ×</button>}
    </>
  );
}

// memo with no props: the details read the store on their own, so a shell repaint does not repaint them.
const Right = memo(function Right() {
  return <Details s={useDetail()} />;
});

const chunk: ViewChunk = {
  Main,
  side: sideGroups,
  right: (s) => (s.route.tab !== 'answers' && pick(s) ? <Right /> : null),
  sideTools: SideTools,
};
export default chunk;
