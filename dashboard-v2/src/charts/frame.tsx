// The shared chart frame and hooks: one look, one keyboard model and one table for every chart (section 7.3).
import { useCallback, useEffect, useId, useRef, useState, type KeyboardEvent, type ReactNode } from 'react';
import type { ChartFrameProps, ChartTable } from './index';

/** The keyboard model of section 7.1: one tab stop, arrows move, Home and End go to the ends, Enter picks. */
export function useChartKeys(count: number, onPick?: (i: number) => void, rowStep = 1) {
  const [active, setActive] = useState<number | null>(null);
  const at = active == null || count === 0 ? null : Math.min(active, count - 1);
  const onKeyDown = (e: KeyboardEvent) => {
    if (count === 0) return;
    const cur = at ?? -1;
    const moves: Record<string, number> = {
      ArrowRight: cur + 1,
      ArrowLeft: cur - 1,
      ArrowDown: cur + rowStep,
      ArrowUp: cur - rowStep,
      Home: 0,
      End: count - 1,
    };
    const next = moves[e.key];
    if (next != null) {
      e.preventDefault();
      setActive(Math.max(0, Math.min(count - 1, next)));
    } else if ((e.key === 'Enter' || e.key === ' ') && at != null && onPick) {
      e.preventDefault();
      onPick(at);
    }
  };
  return { active: at, setActive, keys: { tabIndex: 0, onKeyDown, onBlur: () => setActive(null) } };
}

/** The width of an element, for an SVG chart that fills its column. */
export function useWidth(fallback = 640) {
  const [width, setWidth] = useState(fallback);
  const ref = useCallback(
    (el: Element | null) => {
      if (!el || typeof ResizeObserver === 'undefined') return;
      const ro = new ResizeObserver(([e]) => setWidth(Math.round(e?.contentRect.width ?? 0) || fallback));
      ro.observe(el);
      return () => ro.disconnect();
    },
    [fallback],
  );
  return [ref, width] as const;
}

const reduced = () => typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches;

/** Rule 8: a number counts to its new value once, in 300 ms; the first paint and reduced motion do not count. */
export function useTween(target: number | null, ms = 300) {
  const [shown, setShown] = useState(target);
  const on = useRef(target);
  useEffect(() => {
    const from = on.current;
    let raf = 0;
    if (target == null || from == null || from === target || reduced()) {
      on.current = target;
      raf = requestAnimationFrame(() => setShown(target));
      return () => cancelAnimationFrame(raf);
    }
    const t0 = performance.now();
    // performance.now(), not the frame time: the two can have other origins.
    const step = () => {
      const k = Math.min(1, (performance.now() - t0) / ms);
      const v = k < 1 ? from + (target - from) * k : target;
      on.current = Number.isInteger(target) ? Math.round(v) : v;
      setShown(on.current);
      if (k < 1) raf = requestAnimationFrame(step);
    };
    raf = requestAnimationFrame(step);
    return () => cancelAnimationFrame(raf);
  }, [target, ms]);
  return shown;
}

export function DataTable({ title, table }: { title: string; table: ChartTable }) {
  return (
    // A table wider than a phone card scrolls in its own region, not the page.
    <div className="mt-s2 overflow-x-auto" role="region" aria-label={`${title} as a table`} tabIndex={0}>
      <table className="w-full border-collapse text-sub">
        <caption className="sr-only">{title}</caption>
        <thead>
          <tr>
            {table.head.map((h, j) => (
              <th key={h} scope="col" className={`whitespace-nowrap border-b border-line px-s2 py-s1 font-semibold text-dim ${j ? 'text-right' : 'text-left'}`}>
                {h}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {table.rows.map((r, i) => (
            <tr key={i}>
              {r.map((c, j) => (
                // The first column names the row; the rest are figures, so they align right.
                <td key={j} className={`whitespace-nowrap border-b border-line px-s2 py-s1 ${j ? 'text-right tabular-nums' : ''}`}>
                  {c}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

/** The text of the focused or hovered point: shown on the chart and read once by a screen reader. */
export function Tip({ text }: { text: string | null }) {
  return (
    <>
      {text && (
        <span aria-hidden className="pointer-events-none absolute right-0 bottom-full z-10 mb-s1 rounded-sm bg-ink px-s2 py-s1 text-label text-panel">
          {text}
        </span>
      )}
      <span className="sr-only" aria-live="polite">
        {text ?? ''}
      </span>
    </>
  );
}

type Keys = ReturnType<typeof useChartKeys>['keys'];

/** ChartFrame with the keyboard model: keys go on the role=img element, so no focusable element sits inside it. */
export function Frame({ title, summary, table, children, note, keys, tip = null }: ChartFrameProps & { keys?: Keys; tip?: string | null }) {
  const id = useId();
  return (
    <figure aria-labelledby={id} className="m-0 min-w-0">
      <figcaption id={id} className="mb-s2 font-head text-sub font-semibold text-ink">{title}</figcaption>
      <div className="relative">
        <div role="img" aria-label={summary} {...keys}>
          {children}
        </div>
        <Tip text={tip} />
      </div>
      {note != null && <div className="mt-s1 text-tiny text-faint">{note}</div>}
      <details className="mt-s2 text-sub">
        <summary className="cursor-pointer py-s1 text-link">Show as table</summary>
        <DataTable title={title} table={table} />
      </details>
    </figure>
  );
}

/** A chart with no point model of its own: the keys step through the rows of its table. */
export function ChartFrame(props: ChartFrameProps) {
  const { head, rows } = props.table;
  const k = useChartKeys(rows.length);
  const r = k.active == null ? null : rows[k.active];
  const tip = r ? (r.length > 1 ? `${r[0]}: ${r.slice(1).map((c, i) => `${head[i + 1]} ${c}`).join(', ')}` : String(r[0])) : null;
  return <Frame {...props} keys={k.keys} tip={tip} />;
}

/** An empty chart says so in words. */
export function NoData({ children = 'No data yet.' }: { children?: ReactNode }) {
  return <p className="m-0 py-s4 text-center text-sub text-dim">{children}</p>;
}

/** A time label for an axis or a tip: the time of day, or the day when the span is longer than two days. */
export function timeLabel(epoch: number, span: number) {
  const d = new Date(epoch * 1000);
  return span > 172800
    ? d.toLocaleDateString(undefined, { month: 'short', day: 'numeric' })
    : d.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' });
}
