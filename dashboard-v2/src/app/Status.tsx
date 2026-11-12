// The status bar, the alerts strip, and the tab title and favicon.
import { useEffect, useRef, useState, type ReactNode } from 'react';
import type { Alert, Health } from '../model';
import type { FeedName, Store } from '../store/types';
import { agentsOf, connWord, snapOf } from './derive';
import { ago, usd } from '../format';
import { safe, type Sel } from './store';
import { passQuiet } from '../model/status';

type Row = Record<string, unknown>;

export function useTabTitle(title: string, level: string) {
  useEffect(() => {
    document.title = title;
  }, [title]);
  useEffect(() => {
    let link = document.getElementById('favicon') as HTMLLinkElement | null;
    if (!link) {
      link = Object.assign(document.createElement('link'), { id: 'favicon', rel: 'icon', href: '/icon.png' });
      document.head.append(link);
    }
    const img = new Image();
    img.onload = () => {
      const c = document.createElement('canvas');
      c.width = c.height = 64;
      const g = c.getContext('2d');
      if (!g) return;
      g.drawImage(img, 0, 0, 64, 64);
      const tone = level === 'dead' ? '--bad' : level === 'warn' ? '--warn' : '';
      if (tone) {
        g.beginPath();
        g.arc(50, 50, 13, 0, 2 * Math.PI);
        g.fillStyle = getComputedStyle(document.documentElement).getPropertyValue(tone).trim();
        g.fill();
        g.lineWidth = 4;
        g.strokeStyle = 'white';
        g.stroke();
      }
      link.href = c.toDataURL('image/png');
      link.dataset.level = level;
    };
    img.src = '/icon.png';
  }, [level]);
}

const FEEDS: [FeedName, string][] = [['full', 'Tickets'], ['agents', 'Agents'], ['stats', 'Stats'], ['teams', 'Teams']];

export function StatusBar({ s, sel, health, onRefresh }: { s: Store; sel: Sel; health: Health | null; onRefresh: () => void }) {
  const snap = snapOf(s), g = agentsOf(s), h = (snap?.health ?? {}) as Row;
  const paused = h.paused != null;
  const sp = h.seconds_since_pass as number | null | undefined;
  const offHrs = !paused && sp != null && passQuiet(h), np = h.next_pass_epoch as number | undefined;
  const dead = !paused && !offHrs && (sp == null || sp > 7200), quiet = !paused && !offHrs && sp != null && sp > 1500;
  const lowDisk = h.free_gb != null && h.min_free_gb != null && (h.free_gb as number) < (h.min_free_gb as number);
  const q = snap?.queue as Row | undefined, ready = (q?.ready as unknown[] | undefined)?.length ?? 0;
  const waits = safe(() => sel.queueWaits(s))?.length ?? 0, starved = !q?.fetch_failed && ready === 0 && waits > 0;
  const m = (snap?.mode ?? {}) as Row;
  const off = s.conn.mode === 'offline';
  const level = off ? '' : (health?.level ?? '');
  const word = off ? 'unknown' : (health?.word ?? 'unknown');
  const cells: ReactNode[] = [];
  const cell = (k: string, tone: string, body: ReactNode, title?: string) =>
    cells.push(<span key={k} className={`cell ${tone}`.trim()} title={title}>{body}</span>);
  if (snap) {
    cell('pass', dead ? 'bad' : quiet ? 'warn' : paused || offHrs ? '' : 'ok', <>last pass <b>{sp == null ? 'never' : ago(sp)}</b>{offHrs && np ? <> · passes resume at <b>{new Date(np * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}</b></> : null}</>);
    if (paused) cell('paused', '', <><b>passes paused</b> · {String(h.paused).slice(0, 60)}</>, String(h.paused));
    if (h.lock_held) cell('lock', 'warn', <b>lock held</b>);
    if (m.newtickets === 'off') cell('intake', 'warn', <><b>intake off</b> · PR rounds only</>, String(m.newtickets_note ?? ''));
    if (q) cells.push(
      <a key="queue" className={`cell ${starved ? 'warn' : ''}`.trim()} href="#pipeline/queue" title="queue: launchable, and skipped tickets that wait on a person">
        queue <b>{q.fetch_failed ? '?' : ready} ready</b>{waits ? <> · <b>{waits}</b> skipped</> : null}
      </a>,
    );
    if (m.focus) cell('focus', '', <>focus <span className="key">{String(m.focus)}</span></>);
    if (lowDisk) cell('disk', 'bad', <><b>{String(h.free_gb)}GB</b> free</>);
  }
  if (g) cell('burn', '', <>burn <b>{usd(((g.runner_hourly_usd as number) ?? 0) + ((g.infra_hourly_usd as number) ?? 0))}/h</b></>, 'sandboxes now plus always-on hosts, at list prices');
  const conn = connWord(s);
  const full = s.feeds.full, ag = s.feeds.agents;
  const age = !full && !ag ? 'connecting…' : `${full?.refreshing ? 'refreshing… ' : ''}agents ${ago(ag?.ageSeconds)}, tickets ${ago(full?.ageSeconds)}`;
  return (
    <footer className="status" aria-label="Status">
      <span className={`dot ${level}`.trim()} id="dot" aria-hidden="true" />
      <span className={`health ${level}`.trim()} id="health" title={health?.title}>{word}</span>
      <span id="cells">{cells.flatMap((c, i) => (i ? [<span key={`s${i}`} className="sep" />, c] : [c]))}</span>
      <span className="sp" />
      <span className="fresh">
        {FEEDS.map(([k, name]) => {
          const f = s.feeds[k];
          const lbl = f?.ageSeconds == null ? `${name} feed age unknown` : `${name} feed ${f.ageSeconds} s old, refreshes every ${f.interval} s`;
          const pct = f?.ageSeconds == null || !f.interval ? 0 : Math.min(100, (100 * f.ageSeconds) / (3 * f.interval));
          return (
            <span key={k} className={`fbar ${pct >= 100 ? 'bad' : pct > 33 ? 'warn' : ''}`.trim()} role="img" aria-label={lbl} title={lbl}>
              <i style={{ width: `${pct}%` }} />
            </span>
          );
        })}
      </span>
      <span id="conn" className="conn" data-mode={s.conn.mode}>
        <span className={`dot ${conn.tone}${conn.live ? ' live' : ''}`} aria-hidden="true" />{conn.word}
      </span>
      {s.conn.mode === 'signin' && (
        <span className="cell bad">Your sign-in ended. Reload the page. <button type="button" onClick={() => location.reload()}>Reload</button></span>
      )}
      {off && <span className="cell bad">Server unreachable</span>}
      <span id="repo">{String(snap?.repo ?? '')}</span>
      <span id="age">{age}</span>
      <button id="refresh" type="button" onClick={onRefresh}>Refresh</button>
    </footer>
  );
}

const alertKey = (a: Alert) => `${a.tone}|${a.subject}|${a.what}`;

// ready: the first feed read came; the alerts it brings are the start, not news.
export function Alerts({ alerts, ready }: { alerts: Alert[]; ready: boolean }) {
  const [open, setOpen] = useState<Set<string>>(() => new Set());
  const seen = useRef<Set<string> | null>(null);
  const [say, setSay] = useState('');
  // The live region says only the alerts that are new, not the whole strip again.
  useEffect(() => {
    if (!ready) return;
    const keys = new Set(alerts.map(alertKey));
    const fresh = seen.current ? alerts.filter((a) => !seen.current!.has(alertKey(a))) : [];
    seen.current = keys;
    if (fresh.length) setSay(fresh.map((a) => `New alert: ${a.subject}, ${a.what}`).join('. '));
  }, [alerts, ready]);
  return (
    <>
      <div className="vh" role="status" aria-live="polite" id="attn-say">{say}</div>
      <section id="attn" aria-label="Alerts" tabIndex={-1} hidden={!alerts.length}>
        {alerts.map((a) => {
          const k = alertKey(a), on = open.has(k);
          return (
            <div key={k} className={`alert ${a.tone}${on ? ' open' : ''}`}>
              <b className="key">{a.subject}</b>
              <span className="what" title={a.what}>{a.what}</span>
              {a.fix && <span className="fix">{a.fix}</span>}
              <button type="button" className="more" aria-expanded={on} onClick={() => setOpen((o) => {
                const n = new Set(o);
                if (on) n.delete(k);
                else n.add(k);
                return n;
              })}>{on ? 'Less' : 'More'}<span className="vh"> about {a.subject}</span></button>
            </div>
          );
        })}
      </section>
    </>
  );
}
