// The view's store reads and its clock.
import { useEffect, useState } from 'react';
import { MODEL, useParts } from '../../app/store';
import type { State } from '../../live/reducers';
import { chainOf } from '../../model';
import { SS } from '../../model/base';
import { pick } from './data';

// The state: a history read or delta repaints the view only when it is the shown session's; the frame shows no terminal.
// Answers shows the usage of any row that it opens, the frame none.
const parts = (s: State) => {
  const x = s.route.tab === 'answers' ? null : pick(s);
  return [...MODEL(s), ...(x ? [s.history[x.key], ...chainOf(x, SS(s)).map((y) => s.live.changed[`history:${y.key}`])] : [s.usage])];
};
export const useAll = () => useParts(parts);
// The details panel: the model and the usage of the shown session, not the shell's every repaint.
const detail = (s: State) => [...MODEL(s), s.usage[pick(s)?.key ?? '']];
export const useDetail = () => useParts(detail);

// Epoch seconds, again every step ms, so a live countdown and the timeline grow on the client.
export function useNow(step = 1000) {
  const [now, setNow] = useState(() => Date.now() / 1000);
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now() / 1000), step);
    return () => clearInterval(t);
  }, [step]);
  return now;
}
