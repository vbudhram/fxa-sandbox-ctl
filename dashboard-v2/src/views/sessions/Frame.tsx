// The session frame: the bar, the outcome card, and the thread (v1 renderSess); the terminal opens in its own window.
import { memo, useEffect, useMemo, useState } from 'react';
import { mdHtml, short, stamp } from '../../format';
import type { State } from '../../live/reducers';
import { SS } from '../../model/base';
import { chainOf, convTitle, fixGated, sessStatus } from '../../model/sessions';
import { readHistory } from '../../store';
import type { Session } from '../../store/types';
import { Dot, EmptyBox, Tag } from '../../ui';
import { cx } from '../../ui/tone';
import { barLink, type HistMsg, TONE_OF, isLive, isVideo, mediaUrl, outcome, pauseIn, pick, sharedWhat, threadItems, type ThreadItem } from './data';
import { useNow } from './hooks';

export function SessFrame({ s }: { s: State }) {
  const x = pick(s), tab = s.route.tab;
  const gated = !!x && fixGated(s, x);
  return (
    <div className="sx" id="s-sess">
      <div className="sxbar" id="sx-bar">{x && <Bar s={s} x={x} gated={gated} />}</div>
      <div className="sxbody">
        <div className="convo">
          {gated ? <EmptyBox>Dependency fix. Only a team admin can see its PR, trigger, cost and conversation.</EmptyBox>
            : x ? <><Outcome s={s} x={x} /><Thread s={s} x={x} /></>
            : <EmptyBox>No {tab} session.{tab !== 'stopped' && <> <a className="text-link" href="#sessions/stopped">See stopped sessions</a></>}</EmptyBox>}
        </div>

      </div>
    </div>
  );
}

function Bar({ s, x, gated }: { s: State; x: Session; gated: boolean }) {
  const now = useNow();
  const [st, tone] = sessStatus(x);
  if (gated) return <><Dot tone={TONE_OF[tone]} label={st} /><h2 className="sxt">Dependency fix</h2><span className="sxm">{st}</span></>;
  const title = convTitle(s, x), p = pauseIn(s, x, now), link = barLink(s, x);
  return (
    <>
      <Dot tone={TONE_OF[tone]} label={st} live={tone === 'info' && isLive(x)} />
      <span className="key">{x.key}</span>
      <h2 className="sxt" title={title}>{title}</h2>
      <span className="sxm">{st}{p != null && p < 600 ? ` · pauses in ${short(p)}` : ''}</span>
      <span className="sp" />
      {!!x.slack_url && <a className="lnk" href={String(x.slack_url)} target="_blank" rel="noopener noreferrer">Slack ↗</a>}
      {link && <span className="lnk">{link.href ? <a href={link.href} target="_blank" rel="noopener noreferrer">{link.text}</a> : link.text}</span>}
      {isLive(x) && <a className="tgl" href={`#term/${x.key}`} target={`term-${x.key}`} rel="noopener" onClick={(e) => { e.preventDefault(); window.open(`#term/${x.key}`, `term-${x.key}`, 'popup,width=820,height=520'); }}>Terminal ↗<span className="sr-only"> (opens a new window)</span></a>}
    </>
  );
}

function Outcome({ s, x }: { s: State; x: Session }) {
  const o = outcome(s, x);
  const [all, setAll] = useState(false);
  if (!o) return null;
  const r = o.result, long = o.notes.length > 600;
  return (
    <div className="sxout rounded-lg border border-line bg-panel px-s4 py-s3" id="sx-outcome">
      <div className="kvs">
        {r && <span><b>Result</b>{'pr' in r ? <><a href={r.pr.url} target="_blank" rel="noopener noreferrer">{r.pr.text} ↗</a>{r.pr.state && <> <Tag label={r.pr.state.toLowerCase()} tone={r.pr.state === 'MERGED' ? 'ok' : r.pr.state === 'OPEN' ? 'info' : 'dim'} /></>}</>
          : 'branch' in r ? <>branch {r.href ? <a href={r.href} target="_blank" rel="noopener noreferrer">{r.branch} ↗</a> : r.branch}</> : r.text}</span>}
        {o.diff && <span><b>Change</b>{o.diff}</span>}
        {o.media > 0 && <span><b>Media</b>{o.media} file{o.media === 1 ? '' : 's'} in the thread</span>}
        {o.sessions > 1 && <span><b>Conversation</b>{o.sessions} sessions</span>}
      </div>
      {o.notes && (
        <div className="notes">
          {all || !long ? o.notes : `${o.notes.slice(0, 600)}…`}
          {long && <> <button type="button" className="linkbtn" aria-expanded={all} onClick={() => setAll(!all)}>{all ? 'Show less' : 'Show all'}</button></>}
        </div>
      )}
    </div>
  );
}

// Thread headings are real headings, one level below the bar's h2.
const md = (t: string) => mdHtml(t).replace(/<span class="h">(.*?)<\/span>/g, '<h3 class="h">$1</h3>');
const PERSON = (
  <span className="av" aria-hidden="true">
    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><circle cx="12" cy="8" r="4" /><path d="M4 21c0-4 4-6 8-6s8 2 8 6" /></svg>
  </span>
);

function Thread({ s, x }: { s: State; x: Session }) {
  const h = s.history[x.key], sessions = SS(s);
  // Read on select, and again when a session of the chain changes: a delta, not a timer.
  const sig = chainOf(x, sessions).map((y) => `${y.key}:${y.last_activity ?? ''}:${y.turns ?? ''}:${y.state}:${s.live?.changed[`history:${y.key}`] ?? 0}`).join(',');
  useEffect(() => { void readHistory(x.key); }, [x.key, sig]);
  const rows = h?.rows as HistMsg[] | undefined;
  // The thread reads only the media of the chain from the sessions, so a delta of another session keeps the items.
  const media = JSON.stringify(chainOf(x, sessions).map((y) => [y.key, y.media]));
  // eslint-disable-next-line react-hooks/exhaustive-deps -- media stands for the sessions that threadItems reads
  const items = useMemo(() => (rows ? threadItems(rows, sessions) : []), [rows, media]);
  const rt = x.runtime === 'codex' ? 'Codex' : 'Claude';
  return (
    <div className="thread" id="sx-thread" data-thread={x.key}>
      {!h ? <div className="empty">loading…</div> : h.error && !items.length ? <div className="empty">{h.error}</div>
        : !items.length ? <div className="empty">nothing recorded</div> : items.map((it) => <Item key={it.id} it={it} rt={rt} />)}
    </div>
  );
}

// memo: a history read gives new rows, and only the items whose fields changed repaint.
type ItemProps = { it: ThreadItem; rt: string };
const same = (a: ItemProps, b: ItemProps) => a.rt === b.rt && Object.keys(a.it).length === Object.keys(b.it).length
  && Object.entries(a.it).every(([k, v]) => { const w = (b.it as Record<string, unknown>)[k]; return Array.isArray(v) ? Array.isArray(w) && v.join('\n') === w.join('\n') : v === w; });
const Item = memo(function Item({ it, rt }: ItemProps) {
  return (
    <>
      {it.sep && <div className="tsep">{it.sep}</div>}
      {it.role === 'media' ? (
        <div className="tmsg agent">
          <img className="av" src="/icon.png" alt="" />
          <div className="media-box">
            <div className="who"><b>FxA Agent</b><Tag sq label="APP" />shared {sharedWhat(it.files)} · {stamp(it.at)}</div>
            <div className="media">
              {it.files.map((n, i) => {
                const u = mediaUrl(it.key, n);
                return (
                  <figure key={`${n}${i}`}>
                    {isVideo(n) ? <video src={u} controls preload="metadata" aria-label={n} /> : <a href={u} target="_blank" rel="noopener noreferrer"><img src={u} alt={n} loading="lazy" /></a>}
                    <figcaption>{n}</figcaption>
                  </figure>
                );
              })}
            </div>
          </div>
        </div>
      ) : it.role === 'action' ? <div className="tact">{it.text.slice(0, 8000)}</div> : <Msg it={it} rt={rt} />}
    </>
  );
}, same);

const CUT = 8000;
function Msg({ it, rt }: { it: Extract<ThreadItem, { text: string }>; rt: string }) {
  // Both stay open across updates: the item keeps its id, so React keeps this state.
  const [open, setOpen] = useState(false);
  const [whole, setWhole] = useState(false);
  const cut = it.text.length > CUT && !whole, body = cut ? `${it.text.slice(0, CUT)}…` : it.text;
  const long = body.length > 700 || body.split('\n').length > 12;
  const html = useMemo(() => md(body), [body]);
  const agent = it.role === 'agent';
  return (
    <div className={cx('tmsg', agent && 'agent')}>
      {agent ? <img className="av" src="/icon.png" alt="" /> : it.image ? <img className="av" src={it.image} alt="" referrerPolicy="no-referrer" /> : PERSON}
      <div>
        <div className="who">{agent ? <><b>FxA Agent</b><Tag sq label="APP" />{rt} · {stamp(it.at)}</> : <><b>{it.name || 'Message'}</b>{stamp(it.at)}</>}</div>
        <div className={cx('txt md', long && !open && 'clip')} dangerouslySetInnerHTML={{ __html: html }} />
        {long && <button type="button" className="linkbtn more" aria-expanded={open} onClick={() => setOpen(!open)}>{open ? 'Show less' : 'Show more'}</button>}
        {cut && <button type="button" className="linkbtn more" onClick={() => { setWhole(true); setOpen(true); }}>Show the whole message</button>}
      </div>
    </div>
  );
}
