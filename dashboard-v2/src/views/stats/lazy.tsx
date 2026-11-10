// Recharts loads in its own chunk on the first Stats chart, so the KPI tiles and cards show without it.
import { type ComponentProps, lazy, Suspense } from 'react';

const charts = () => import('./charts');
const LazyBars = lazy(() => charts().then((m) => ({ default: m.Bars })));
const LazyScatter = lazy(() => charts().then((m) => ({ default: m.Scatter })));

// No chart role in the fallback: a key press on it would go nowhere.
const Wait = ({ h }: { h: number }) => <p className="empty" data-lazy="" style={{ minHeight: h }}>loading…</p>;

export const Bars = (p: ComponentProps<typeof LazyBars>) => <Suspense fallback={<Wait h={p.height ?? 230} />}><LazyBars {...p} /></Suspense>;
export const Scatter = (p: ComponentProps<typeof LazyScatter>) => <Suspense fallback={<Wait h={200} />}><LazyScatter {...p} /></Suspense>;
