// Errors: one row per signature that the host and the bot recorded, with its list and its details (design 6.9).
import { memo, useEffect, useState, type ReactNode } from 'react';
import { errOpen } from '../../app/derive';
import type { SideGroup } from '../../app/store';
import type { ViewChunk } from '../../app/views';
import { Heatmap } from '../../charts';
import { ago, sentence } from '../../format';
import type { ErrorRow } from '../../live/schema';
import { SESSION_RE, sessTabOf } from '../../router';
import { useApp } from '../../store';
import type { Store } from '../../store/types';
import { Kv, Meter, Tag, type Tone } from '../../ui';
import { Button } from '../../ui/button';
import './errors.css';

// A row from an older server can miss a field: each one is guarded.
type E = Partial<ErrorRow>;

const CHIP: Record<string, Tone> = { open: 'bad', reopened: 'bad', resolved: 'dim', quiet: 'dim' };
const CLI = (sig: string) => `fxa-sandbox-ctl errors resolve ${sig} "<commit or note>"`;

const list = (s: Store) => (Array.isArray(s.feeds.errors?.data) ? (s.feeds.errors.data as E[]) : null);
const ofTab = (l: E[], tab: string) => l.filter((e) => tab === 'all' || errOpen(e));
export const ageOf = (iso: string | undefined, now = Date.now()) => {
  const t = Date.parse(iso ?? '');
  return Number.isNaN(t) ? null : Math.max(0, Math.round((now - t) / 1000));
};
const lastAgo = (e: E) => {
  const a = ageOf(e.last);
  return a == null ? 'unknown' : ago(a);
};
const minute = (iso: string | undefined) => (iso ? iso.slice(0, 16).replace('T', ' ') : '');
const resolvedText = (e: E) => (e.resolved ? `${String(e.resolved.at ?? '').slice(0, 10)}${e.resolved.note ? `: ${e.resolved.note}` : ''}` : '');

// The Sessions tab of each session key in the list: a session delta that moves no key to another tab repaints nothing.
const sessTabs = (s: Store) => {
  const o: Record<string, string> = {};
  for (const e of list(s) ?? []) for (const k of e.keys ?? []) o[k] = sessTabOf(s.sessions.byKey[k]?.state);
  return o;
};

// A key opens the session on its own tab; a key the store does not know opens Stopped, as in v1.
function SessLinks({ keys, tabs }: { keys: string[]; tabs: Record<string, string> }) {
  return keys.map((k, i) => (
    <span key={k}>
      {i ? ' ' : ''}
      {SESSION_RE.test(k) ? <a className="font-mono" href={`#sessions/${tabs[k] ?? 'stopped'}/${k}`}>{k}</a> : <span className="font-mono">{k}</span>}
    </span>
  ));
}

function Copy({ text, label }: { text: string; label: string }) {
  const [said, setSaid] = useState('');
  const copy = () => (navigator.clipboard?.writeText(text) ?? Promise.reject(new Error('no clipboard'))).then(
    () => setSaid('Copied.'),
    () => setSaid('Copy did not work: select the line and copy it.'),
  );
  return (
    <span className="inline-flex items-center gap-s2">
      <Button aria-label={label} onClick={() => void copy()}>Copy</Button>
      <span role="status" className="text-label text-dim">{said}</span>
    </span>
  );
}

// Time since the last hit on a log axis from 1 minute (right) to 30 days (left).
const LO = Math.log(60), HI = Math.log(30 * 86400);
function Recency({ age, word }: { age: number | null; word: string }) {
  const p = age == null ? null : Math.min(1, Math.max(0, (Math.log(Math.max(age, 60)) - LO) / (HI - LO)));
  return (
    <span className="err-rec" role="img" aria-label={`Last seen ${word}, on a scale from 1 minute to 30 days`} title={`last ${word}`}>
      {p != null && <i style={{ left: `${Math.round((1 - p) * 100)}%` }} />}
    </span>
  );
}

// Open signatures by source and kind.
const OpenHeat = memo(function OpenHeat({ rows }: { rows: E[] }) {
  const open = rows.filter(errOpen);
  if (!open.length) return null;
  const by = new Map<string, number>();
  for (const e of open) by.set(`${e.source ?? '?'}\n${e.kind ?? '?'}`, (by.get(`${e.source ?? '?'}\n${e.kind ?? '?'}`) ?? 0) + 1);
  const pairs = [...by].map(([k, n]) => [...k.split('\n'), n] as [string, string, number]);
  const srcs = [...new Set(pairs.map((p) => p[0]))].sort(), kinds = [...new Set(pairs.map((p) => p[1]))].sort();
  const top = pairs.reduce((a, b) => (b[2] > a[2] ? b : a));
  return (
    <div className="err-heat">
      <Heatmap
        title="Open errors by source and kind"
        summary={`Open errors by source and kind. ${open.length} open in ${pairs.length} groups. Most: ${top[0]}/${top[1]}, ${top[2]}.`}
        table={{ head: ['Source', 'Kind', 'Open'], rows: pairs.map((p) => [p[0], p[1], p[2]]) }}
        rows={srcs}
        cols={kinds}
        cells={pairs.map(([s, k, n]) => ({ row: srcs.indexOf(s), col: kinds.indexOf(k), value: n, label: `${n} open` }))}
      />
    </div>
  );
});

const Head = ({ title, n }: { title: string; n?: number }) => (
  <h2>{sentence(title)}{n != null && <span className="n">{n}</span>}</h2>
);

// memo: a delta keeps the rows that it does not change, so only the changed row repaints.
const Row = memo(function Row({ e, max, tabs }: { e: E; max: number; tabs: Record<string, string> }) {
  const st = e.status ?? 'unknown', word = lastAgo(e);
  return (
    <div className="err" id={`err-${e.sig}`}>
      <Tag label={st} tone={CHIP[st] ?? 'dim'} />
      <div className="body">
        <div className="m">{e.message}</div>
        <div className="meta">
          <span className="font-mono">{e.sig}</span> · {e.source ?? '?'}/{e.kind ?? '?'} · {e.where ?? '?'} · ×{e.count ?? '?'} · last {word}
          {e.keys?.length ? <> · <SessLinks keys={e.keys} tabs={tabs} /></> : null}
          {e.log ? <> · <span className="font-mono">{e.log}</span></> : null}
          {e.resolved ? ` · ${e.status === 'reopened' ? 'last fix' : 'resolved'} ${resolvedText(e)}` : null}
        </div>
      </div>
      <div className="err-viz" aria-hidden="true">
        <Meter pct={e.count == null ? null : (100 * e.count) / max} tone={errOpen(e) ? 'bad' : 'dim'} label={`Seen ${e.count ?? '?'} times`} />
        <Recency age={ageOf(e.last)} word={word} />
      </div>
    </div>
  );
});

const reduced = () => matchMedia('(prefers-reduced-motion: reduce)').matches;

function Main() {
  const f = useApp((s) => s.feeds.errors);
  const tab = useApp((s) => s.route.tab);
  const sel = useApp((s) => s.route.sel);
  const tabs = useApp(sessTabs);
  useEffect(() => {
    if (sel) document.getElementById(`err-${sel}`)?.scrollIntoView({ block: 'center', behavior: reduced() ? 'auto' : 'smooth' });
  }, [sel]);
  const l = Array.isArray(f?.data) ? (f.data as E[]) : null;
  // A failed read keeps the last good list and never says "No open errors".
  const fail = f?.error ? (
    <div className="emptybox err-fail" role="alert">Could not read the errors: {f.error}. {l ? 'This is the last list that loaded. ' : ''}Retrying.</div>
  ) : null;
  let body: ReactNode;
  if (!l || (fail && !l.length)) body = <><Head title="errors" />{fail ?? <div className="emptybox">loading…</div>}</>;
  else {
    const rows = ofTab(l, tab), max = Math.max(1, ...rows.map((e) => e.count ?? 0));
    body = (
      <>
        <Head title={tab === 'all' ? 'all errors' : 'open errors'} n={rows.length} />
        {fail}
        {rows.length === 0 ? (
          <div className="emptybox">{tab === 'all' ? 'No errors recorded.' : 'No open errors.'}</div>
        ) : (
          <>
            <div className="errs">{rows.map((e) => <Row key={e.sig} e={e} max={max} tabs={tabs} />)}</div>
            <p className="empty err-hint">
              Mark one fixed: <span className="font-mono">{CLI('<sig>')}</span>. It reopens if it happens again. The log is also copied to the
              state bucket under <span className="font-mono">errors/</span>. <Copy text={CLI('<sig>')} label="Copy the resolve command" />
            </p>
          </>
        )}
      </>
    );
  }
  // The frame of the updated pages: the list card, and the chart in a side column that wraps under it when narrow.
  const heat = l && l.some(errOpen) ? <section className="err-card err-chart"><OpenHeat rows={l} /></section> : null;
  return (
    <div className="err-page">
      <section className="err-card" id="s-errors">{body}</section>
      {heat}
    </div>
  );
}

function side(s: Store): SideGroup[] | null {
  const l = list(s), all = s.route.tab === 'all';
  if (!l) return null;
  const items = ofTab(l, s.route.tab).map((e) => ({
    id: String(e.sig), d: errOpen(e) ? 'bad' : 'ok', t: String(e.message ?? ''),
    m: [all ? String(e.status ?? '') : '', `${e.count ?? '?'}×`, `${e.source ?? '?'}/${e.kind ?? '?'}`, lastAgo(e)],
    find: `${e.message ?? ''} ${e.sig}`,
  }));
  return items.length ? [{ items }] : [];
}

// The first row of the tab shows until a person picks one.
function right(s: Store): ReactNode | null {
  const l = list(s);
  if (!l) return null;
  const sig = s.route.sel || ofTab(l, s.route.tab)[0]?.sig;
  const e = l.find((x) => x.sig === sig);
  if (!e?.sig) return null;
  const v = (x: string | number | null | undefined) => (x == null || x === '' ? '—' : x);
  return (
    <div className="err-right">
      <h2 className="rh">Error<small>{e.sig}</small></h2>
      <div className="err-kv">
        <h3>Signature</h3>
        <Kv label="Status" value={v(e.status)} na={!e.status} />
        <Kv label="Source" value={`${e.source ?? '?'}/${e.kind ?? '?'}`} />
        <Kv label="Where" value={v(e.where)} na={!e.where} />
        <Kv label="Seen" value={e.count == null ? '—' : `${e.count} times`} na={e.count == null} />
        <Kv label="First" value={v(minute(e.first))} na={!e.first} />
        <Kv label="Last" value={v(minute(e.last))} na={!e.last} />
        {e.keys?.length ? <Kv label="Sessions" value={<SessLinks keys={e.keys} tabs={sessTabs(s)} />} /> : null}
        {e.log ? <Kv label="Log" value={<span className="font-mono">{e.log}</span>} /> : null}
        {e.resolved ? <Kv label="Resolved" value={resolvedText(e)} /> : null}
      </div>
      <div>
        <h3>Message</h3>
        <div className="err-mono">{e.message}</div>
      </div>
      <div>
        <h3>Mark it fixed</h3>
        <div className="err-mono">{CLI(e.sig)}</div>
        <Copy text={CLI(e.sig)} label={`Copy the resolve command for ${e.sig}`} />
      </div>
    </div>
  );
}

export default { Main, side, right } satisfies ViewChunk;
