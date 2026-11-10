// The shell: rail, header and tabs, side list, main, details panel, status bar, and the keys.
import { memo, useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, type ComponentType, type CSSProperties, type KeyboardEvent as RKey, type ReactNode } from 'react';
import { firstSessTab, format, parse, TEAM_RE, TEAM_TABS, viewHash } from '../router';
import type { Route, ViewId } from '../router/types';
import type { Prefs, Store, Theme } from '../store/types';
import { agentsOf, docTitle, pipeTeams, railBadges, sessionList, tabCount } from './derive';
import { Help, Palette, wrapTab } from './Dialogs';
import { Boundary, ICON, VIEW_ICON } from './parts';
import { Alerts, StatusBar, useTabTitle } from './Status';
import { safe, savePref, SIDE, useParts, useSel, useStore, type SideGroup } from './store';
import { VIEWS, viewOf } from './views';
import './shell.css';

const useMedia = (q: string) => {
  const [m, setM] = useState(() => matchMedia(q).matches);
  useEffect(() => {
    const l = matchMedia(q), on = () => setM(l.matches);
    l.addEventListener('change', on);
    return () => l.removeEventListener('change', on);
  }, [q]);
  return m;
};

const THEMES: Theme[] = ['system', 'light', 'dark'];
export function applyTheme(t: Theme) {
  savePref('theme', t);
  document.documentElement.dataset.theme = t === 'system' ? (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light') : t;
}

// The details panel body per view; the views add theirs in wave 2. null shows the empty text.
export const RIGHT: Partial<Record<ViewId, (s: Store) => ReactNode | null>> = {};
// The main content per view; the views add theirs in wave 2.
export const MAIN: Partial<Record<ViewId, () => ReactNode>> = {};
const TOOLS: Partial<Record<ViewId, ComponentType>> = {};
// The whole side panel, for a view whose chunk gives a Side in place of a list.
export const SIDEPANE: Partial<Record<ViewId, () => ReactNode>> = {};

// The store parts the shell reads: not the terminal lines, the flow or the event clock, which change many times a second.
const SHELL = (x: Store): unknown[] => [...Object.entries(x).filter(([k]) => k !== 'tails' && k !== 'flow' && k !== 'conn').map(([, v]) => v), x.conn.mode, x.conn.error, !x.conn.lastEventAt];

const PANES = { side: { v: '--side', min: 220, max: 640, def: 300, dir: 1 }, right: { v: '--right', min: 260, max: 720, def: 340, dir: -1 } } as const;

export function Shell({ poll }: { poll?: () => Promise<void> }) {
  const st = useStore();
  const s = useParts(SHELL);
  const sel = useSel();
  const { route, prefs } = s;
  const def = viewOf(route.view);
  const narrowSide = useMedia('(max-width:900px)');
  const narrowRight = useMedia('(max-width:1280px)');
  const [q, setQ] = useState('');
  const [showside, setShowside] = useState(false);
  const [showright, setShowright] = useState(false);
  const [tlistClosed, setTlistClosed] = useState(false);
  const [help, setHelp] = useState(false);
  const [palette, setPalette] = useState(false);
  const cur = useRef(-1);
  const mainRef = useRef<HTMLElement>(null);
  const autoSess = useRef(false);
  // A hashchange, not the first read of the hash: only a navigation moves the focus.
  const navd = useRef(false);
  // When "/" last put the focus in the search: a "/" that comes just after a tab key wins over the heading focus.
  const slashAt = useRef(-Infinity);

  const setPrefs = useCallback((p: Partial<Prefs>) => st.setState((x) => ({ prefs: { ...x.prefs, ...p } })), [st]);

  // A view's chunk loads on its first visit and fills MAIN, RIGHT and SIDE.
  const [, setLoaded] = useState(0);
  useEffect(() => {
    const id = def.id;
    if (!def.load || MAIN[id]) return;
    def.load().then(({ default: c }) => {
      // memo: a view repaints only on the store parts that it reads, not on each repaint of the shell.
      const Main = memo(c.Main);
      MAIN[id] = () => <Main />;
      if (c.right) RIGHT[id] = c.right;
      if (c.side) SIDE[id] = c.side;
      if (c.sideTools) TOOLS[id] = memo(c.sideTools);
      const Side = c.Side && memo(c.Side);
      if (Side) SIDEPANE[id] = () => <Side />;
    }, () => {
      MAIN[id] = () => <p className="empty">This view did not load. Reload the page.</p>;
    }).finally(() => setLoaded((n) => n + 1));
  }, [def]);

  // The router: the hash writes the route; a rewrite or a chosen tab goes back with replace.
  useEffect(() => {
    const go = (r: Route) => {
      const prev = st.getState().route;
      if (r.view !== prev.view) {
        setQ('');
        cur.current = -1;
      }
      st.setState({ route: r });
      // Opening or closing a belt inside one tab keeps the place; a new view or tab starts at the top.
      if (!(r.view === 'pipeline' && prev.view === r.view && prev.tab === r.tab) && mainRef.current) mainRef.current.scrollTop = 0;
    };
    const on = (e?: Event) => {
      if (e) navd.current = true;
      const hash = location.hash, prev = st.getState().route;
      const r = parse(hash, prev);
      autoSess.current = r.view === 'sessions' && !hash.replace(/^#/, '').split(/[/?]/)[1] && prev.view !== 'sessions';
      if (autoSess.current && agentsOf(st.getState())) {
        r.tab = firstSessTab(sessionList(st.getState()).map((x) => x.state));
        autoSess.current = false;
      }
      const h = format(r);
      if (h !== hash) history.replaceState(null, '', h);
      go(r);
    };
    on();
    addEventListener('hashchange', on);
    // #sessions with no tab picks its tab after the first agents feed, not in a render.
    const unsub = st.subscribe(() => {
      const x = st.getState();
      if (!autoSess.current || x.route.view !== 'sessions' || !agentsOf(x)) return;
      autoSess.current = false;
      const r = { ...x.route, tab: firstSessTab(sessionList(x).map((y) => y.state)) };
      history.replaceState(null, '', format(r));
      go(r);
    });
    return () => {
      removeEventListener('hashchange', on);
      unsub();
    };
  }, [st]);

  const alerts = useMemo(() => safe(() => sel.alerts(s)) ?? [], [s, sel]);
  const needs = useMemo(() => safe(() => sel.ovNeeds(s)), [s, sel]);
  const health = useMemo(() => safe(() => sel.health(s)), [s, sel]);
  const badges = useMemo(() => railBadges(s, sel, alerts), [s, sel, alerts]);
  useTabTitle(docTitle(needs, alerts), s.conn.mode === 'offline' ? '' : (health?.level ?? ''));

  const bare = def.bareTabs.includes(route.tab);
  const rightBody = RIGHT[route.view]?.(s) ?? null;
  const noitem = !rightBody && (route.view === 'sessions' || route.view === 'runners');
  const sideOn = def.side && !bare, rightOn = def.right && !bare && !noitem;
  const sideShown = sideOn && (route.view === 'teams' && narrowSide ? !tlistClosed : narrowSide ? showside : !prefs.noside);
  const rightShown = rightOn && (narrowRight ? showright : !prefs.noright);

  const toggle = useCallback((which: 'side' | 'right') => {
    const narrow = which === 'side' ? narrowSide : narrowRight;
    if (narrow) {
      if (which === 'side') setShowside((o) => !o);
      else setShowright((o) => !o);
    } else {
      const k = which === 'side' ? 'noside' : 'noright';
      const v = !st.getState().prefs[k];
      savePref(k, v);
      setPrefs({ [k]: v });
    }
  }, [narrowSide, narrowRight, setPrefs, st, setShowside, setShowright]);

  // A drawer that opens takes the focus: the list on its search box, the details on their close button.
  useEffect(() => {
    if (showside && narrowSide) document.getElementById('q')?.focus();
  }, [showside, narrowSide]);
  useEffect(() => {
    if (showright && narrowRight) document.getElementById('rclose')?.focus();
  }, [showright, narrowRight]);
  // An open drawer makes the page behind it inert, so browse mode stays in it; the header keeps its List and Details buttons.
  const drawer = narrowSide && showside && route.view !== 'teams' ? 'side' : narrowRight && showright ? 'right' : '';
  useEffect(() => {
    if (!drawer) return;
    const els = [...document.querySelectorAll<HTMLElement>(`.rail, #main > .mc, footer.status, #${drawer === 'side' ? 'right' : 'side'}`)];
    for (const el of els) el.inert = true;
    return () => { for (const el of els) el.inert = false; };
  }, [drawer]);

  // A new view or tab puts the focus on its heading, unless the view put the focus in its content or a fast "/" put it in the search.
  const at = useRef('');
  useEffect(() => {
    const k = `${route.view}/${route.tab}`;
    if (at.current === k) return;
    at.current = k;
    const nav = navd.current;
    navd.current = false;
    if (!nav || mainRef.current?.querySelector('.mc')?.contains(document.activeElement)) return;
    if (document.activeElement?.id === 'q' && performance.now() - slashAt.current < 1000) return;
    document.getElementById('vtitle')?.focus({ preventScroll: !narrowSide });
  }, [route.view, route.tab, narrowSide]);

  // An update that removes the focused node: the focus goes to its panel, and a polite message says so.
  const last = useRef<{ el: Element; k: string; box: string } | null>(null);
  const gone = useRef<HTMLParagraphElement>(null);
  useLayoutEffect(() => {
    const f = last.current, k = `${route.view}/${route.tab}`;
    if (!f || f.el.isConnected || document.activeElement !== document.body || f.k !== k) return;
    last.current = null;
    const to = f.box === 'side' ? document.querySelector<HTMLElement>('#side .slist2') : f.box === 'right' ? document.getElementById('right') : document.getElementById('vtitle');
    to?.focus({ preventScroll: true });
    if (gone.current) gone.current.textContent = 'The item you were on is gone.';
  });

  const cycleTheme = useCallback(() => {
    const t = THEMES[(THEMES.indexOf(st.getState().prefs.theme) + 1) % THEMES.length]!;
    applyTheme(t);
    setPrefs({ theme: t });
  }, [setPrefs, st]);

  const setKeys = useCallback((on: boolean) => {
    savePref('keys', on);
    setPrefs({ keys: on });
  }, [setPrefs]);

  const refresh = useCallback(async () => {
    try {
      await fetch('/api/refresh', { method: 'POST' });
    } catch {
      // The next feed read shows the failure.
    }
    // Live mode waits for the feed frames; the fallback polls while the feeds rebuild.
    if (!poll || st.getState().conn.mode === 'live') return;
    for (let i = 0; i < 15; i++) {
      await new Promise((r) => setTimeout(r, i ? 2000 : 1500));
      await poll();
      if (!st.getState().feeds.full?.refreshing) break;
    }
  }, [poll, st]);

  // Stable, so the memo side rows skip a repaint: it reads the route at the click.
  const select = useCallback((id: string) => {
    const route = st.getState().route;
    if (route.view === 'teams') {
      location.hash = id === '__all' ? '#teams' : `#teams/${id}`;
      if (narrowSide) setTlistClosed(true);
      return;
    }
    location.hash = format({ ...route, sel: id, rid: '' });
    if (narrowSide) setShowside(false);
    if (narrowRight) setShowright(true);
  }, [st, narrowSide, narrowRight]);

  // The keys: Ctrl or Cmd+K and Esc always; the single keys only when turned on.
  useEffect(() => {
    const on = (e: KeyboardEvent) => {
      // The hash, not the store: a key pressed before the last hashchange event still steps from the new place.
      const x = st.getState(), r = parse(location.hash, x.route);
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'k') {
        e.preventDefault();
        setPalette(true);
        return;
      }
      if (document.querySelector('dialog[open]')) return;
      const t = e.target as HTMLElement;
      if (e.key === 'Escape') {
        if (r.view === 'pipeline' && r.tab === 'belts' && r.sel) {
          location.replace('#pipeline/belts');
          return;
        }
        // A drawer that closes gives the focus back to the button that opens it.
        const b = showside ? 'tside' : showright ? 'tright' : '';
        setShowside(false);
        setShowright(false);
        if (t.id === 'q') t.blur();
        if (b) document.getElementById(b)?.focus();
        return;
      }
      if (!x.prefs.keys || e.metaKey || e.ctrlKey || e.altKey || t.closest?.('input, select, textarea, [contenteditable]')) return;
      const d = viewOf(r.view);
      if (/^[1-9]$/.test(e.key) && VIEWS[+e.key - 1]) location.hash = '#' + VIEWS[+e.key - 1]!.id;
      else if (e.key === '/') {
        e.preventDefault();
        if (narrowSide) setShowside(true);
        else {
          document.getElementById('q')?.focus();
          slashAt.current = performance.now();
        }
      } else if (e.key === 'j' || e.key === 'k') {
        const items = [...document.querySelectorAll<HTMLElement>('.si')];
        if (!items.length) return;
        cur.current = Math.max(0, Math.min(items.length - 1, cur.current + (e.key === 'j' ? 1 : -1)));
        items.forEach((it, i) => it.classList.toggle('cur', i === cur.current));
        items[cur.current]!.focus();
      } else if (e.key === 'h' || e.key === 'l') {
        const step = (n: number, i: number) => (i + (e.key === 'l' ? 1 : n - 1)) % n;
        if (r.view === 'teams' && TEAM_RE.test(r.sel)) {
          // A draft shows only Settings and Routines, and Settings in place of the others.
          const tm = (Array.isArray(x.feeds.teams?.data) ? (x.feeds.teams.data as { profile?: string; access?: { record?: boolean; status?: string } }[]) : []).find((y) => y.profile === r.sel);
          const tabs: readonly string[] = tm?.access?.record && tm.access.status !== 'active' ? ['settings', 'routines'] : TEAM_TABS;
          const nt = tabs[step(tabs.length, Math.max(0, tabs.indexOf(r.tab)))]!;
          location.hash = `#teams/${r.sel}${nt === 'overview' ? '' : '/' + nt}`;
        } else if (d.tabs.length) location.hash = viewHash(r.view, d.tabs[step(d.tabs.length, d.tabs.findIndex((x2) => x2.id === r.tab))]!.id);
      } else if (e.key === '[') toggle('side');
      else if (e.key === ']') toggle('right');
      else if (e.key === 'r') void refresh();
      else if (e.key === '?') setHelp(true);
    };
    document.addEventListener('keydown', on);
    return () => document.removeEventListener('keydown', on);
  }, [st, showside, showright, narrowSide, toggle, refresh]);

  const paneStyle = {} as Record<string, string>;
  for (const p of Object.values(PANES)) {
    const w = prefs.panelW[p.v];
    if (w != null) paneStyle[p.v] = `${w}px`;
  }
  const shellCls = [
    'shell', `v-${route.view}`,
    !sideOn && 'hideside', !rightOn && 'hideright',
    !narrowSide && prefs.noside && 'noside', !narrowRight && prefs.noright && 'noright',
    showside && 'showside', showright && 'showright', tlistClosed && 'tlist-closed',
  ].filter(Boolean).join(' ');

  return (
    <div className={shellCls} style={paneStyle as CSSProperties} onFocus={(e) => { last.current = { el: e.target, k: `${route.view}/${route.tab}`, box: e.target.closest('#side') ? 'side' : e.target.closest('#right') ? 'right' : '' }; }}>
      <p className="vh" aria-live="polite" id="focus-say" ref={gone} />
      <Boundary>
        <Rail route={route} badges={badges} theme={prefs.theme} onTheme={cycleTheme} onHelp={() => setHelp(true)} onPalette={() => setPalette(true)} />
      </Boundary>
      <aside className="side" id="side" aria-label="List" onKeyDown={narrowSide && showside && route.view !== 'teams' ? (e) => wrapTab(e, e.currentTarget) : undefined}>
        <Boundary key={route.view}>
          {sideOn && SIDEPANE[route.view] ? SIDEPANE[route.view]!() : route.view === 'stats' ? (
            <><div className="sh"><h2>Filters</h2></div><p className="empty sgroup">loading…</p></>
          ) : sideOn ? (
            <SideList title={def.title} groups={safe(() => sel.side(s))} q={q} setQ={setQ} keys={prefs.keys} route={route} onSelect={select} Tools={TOOLS[route.view]} />
          ) : null}
        </Boundary>
      </aside>
      <main className="main" id="main" ref={mainRef}>
        <Boundary>
          <Header route={route} s={s} sideShown={sideShown} rightShown={rightShown} tlistClosed={tlistClosed}
            onToggle={toggle} onTlist={() => setTlistClosed((o) => !o)}
            team={route.view === 'pipeline' ? <PipeTeam s={s} onPick={(t) => { savePref('pipeTeam', t); setPrefs({ pipeTeam: t }); }} /> : null} />
        </Boundary>
        <div className="mc">
          {route.view === 'overview' && <Boundary><Alerts alerts={alerts} ready={!!(s.feeds.full || s.feeds.agents)} /></Boundary>}

          <Boundary key={`${route.view}/${route.tab}`}>
            {MAIN[route.view]?.() ?? <p className="empty">{def.load ? 'loading…' : 'This view is not built yet.'}</p>}
          </Boundary>
        </div>
      </main>
      <aside className="right" id="right" aria-label="Details" tabIndex={-1} onKeyDown={narrowRight && showright ? (e) => wrapTab(e, e.currentTarget) : undefined}>
        <Boundary key={route.view}>
          <button type="button" className="drawer-close" id="rclose" onClick={() => { setShowright(false); document.getElementById('tright')?.focus(); }}>Close</button>
          {rightBody ?? <div className="emptybox">Select an item in the list to see its details.</div>}
        </Boundary>
      </aside>
      {(['side', 'right'] as const).map((k) => (
        <Resize key={k} which={k} width={prefs.panelW[PANES[k].v]} onWidth={(w) => {
          const panelW = { ...st.getState().prefs.panelW, [PANES[k].v]: w };
          if (w == null) delete panelW[PANES[k].v];
          savePref('panelW', panelW);
          setPrefs({ panelW });
        }} />
      ))}
      <Boundary>
        <StatusBar s={s} sel={sel} health={health} onRefresh={refresh} />
      </Boundary>
      <Help open={help} onClose={() => setHelp(false)} keys={prefs.keys} onKeys={setKeys} />
      <Palette open={palette} onClose={() => setPalette(false)} s={s}
        actions={{ refresh, theme: cycleTheme, side: () => toggle('side'), right: () => toggle('right'), keys: () => setKeys(!prefs.keys), help: () => setHelp(true) }} />
    </div>
  );
}

function Rail(p: { route: Route; badges: ReturnType<typeof railBadges>; theme: Theme; onTheme: () => void; onHelp: () => void; onPalette: () => void }) {
  const m = p.theme[0]!.toUpperCase() + p.theme.slice(1);
  return (
    <nav className="rail" aria-label="Views">
      <img className="logo" src="/icon.png" alt="FxA Agent" />
      {VIEWS.map((v) => {
        const b = p.badges[v.id];
        return (
          <a key={v.id} href={`#${v.id}`} data-nav={v.id} aria-current={p.route.view === v.id ? 'page' : undefined}>
            {VIEW_ICON[v.id]}{v.title}
            <span className={`n ${b.tone}`.trim()} id={`n-${v.id}`} aria-label={b.n && b.label ? b.label : undefined} title={b.n ? b.label : undefined}>{b.n}</span>
          </a>
        );
      })}
      <span className="grow" />
      <button className="rb" id="find" type="button" title="Go to a view, a ticket or a session (Ctrl K)" onClick={p.onPalette}>{ICON.find}Go to</button>
      <button className="rb" id="theme" type="button" aria-label={`Theme: ${m}`} title={`Theme: ${m}. Click for the next one.`} onClick={p.onTheme}>{ICON.theme}<span id="themelbl">Theme</span></button>
      <button className="rb" id="helpbtn" type="button" title="Keyboard shortcuts" onClick={p.onHelp}>{ICON.keys}Shortcuts</button>
    </nav>
  );
}

function Header(p: { route: Route; s: Store; sideShown: boolean; rightShown: boolean; tlistClosed: boolean; onToggle: (w: 'side' | 'right') => void; onTlist: () => void; team: ReactNode }) {
  const sel = useSel();
  const { view, tab } = p.route;
  const def = viewOf(view), bare = def.bareTabs.includes(tab);
  const sideLbl = view === 'stats' ? 'Filters' : 'List';
  const showSideBtn = def.side && !bare && view !== 'teams';
  const showRightBtn = def.right && !bare;
  return (
    <div className="mh">
      <div className="row">
        <h1 id="vtitle" tabIndex={-1}>{def.title}</h1>
        <span className="vsub" id="vsub">{def.sub}</span>
        <span className="acts" id="vacts">
          {p.team}
          {view === 'teams' && (
            <button type="button" className="iconbtn lbl tlist-btn" id="tlist" aria-expanded={!p.tlistClosed} aria-controls="side" onClick={p.onTlist}>{ICON.side}List</button>
          )}
          {showSideBtn && (
            <button type="button" className={`iconbtn${view === 'stats' ? ' lbl' : ''}`} id="tside" aria-label={sideLbl} title={sideLbl} aria-pressed={p.sideShown} onClick={() => p.onToggle('side')}>
              {ICON.side}{view === 'stats' ? 'Filters' : ''}
            </button>
          )}
          {showRightBtn && (
            <button type="button" className="iconbtn" id="tright" aria-label="Details" title="Details" aria-pressed={p.rightShown} onClick={() => p.onToggle('right')}>{ICON.right}</button>
          )}
        </span>
      </div>
      <nav className="tabs" id="vtabs" aria-label={`${def.title} tabs`} hidden={!def.tabs.length}>
        {def.tabs.map((t) => {
          const n = tabCount(p.s, sel, t.id);
          return (
            <a key={t.id} href={`#${view}/${t.id}`} aria-current={tab === t.id ? 'page' : undefined}>
              {t.label}
              {n !== '' && <span className="n">{n}{n === '?' && <span className="vh">, unknown: a feed failed</span>}</span>}
            </a>
          );
        })}
      </nav>
    </div>
  );
}

function SideList(p: { title: string; groups: SideGroup[] | null; q: string; setQ: (q: string) => void; keys: boolean; route: Route; onSelect: (id: string) => void; Tools?: ComponentType }) {
  const ql = p.q.trim().toLowerCase();
  const hit = (it: SideGroup['items'][number]) =>
    ql ? !it.id.startsWith('__') && (it.find ?? `${it.t} ${it.m.join(' ')}`).toLowerCase().includes(ql) : true;
  const groups = (p.groups ?? []).map((g) => ({ ...g, items: g.items.filter(hit) })).filter((g) => g.items.length);
  const total = groups.reduce((n, g) => n + g.items.filter((i) => !i.id.startsWith('__')).length, 0);
  const first = groups[0]?.items[0]?.id ?? '';
  const sel = p.route.view === 'teams' ? p.route.sel || '__all' : p.route.sel || (p.route.view === 'sessions' || p.route.view === 'errors' ? first : '');
  return (
    <>
      <div className="sh">
        <h2>{p.title} <span className="n">{total}</span></h2>
        <div className="search">
          {ICON.search}
          <input id="q" type="search" placeholder="Search" value={p.q} aria-label="Search the list" onChange={(e) => p.setQ(e.target.value)} />
          {p.keys && <kbd>/</kbd>}
        </div>
        {p.Tools && <p.Tools />}
      </div>
      <div className="slist2" tabIndex={-1}>
        {groups.length ? groups.map((g, gi) => (
          <div key={g.group ?? gi}>
            {g.group && <h3 className="sgroup">{g.group}</h3>}
            <ul>
              {g.items.map((it) => (
                <SideRow key={it.id} id={it.id} d={it.d} t={it.t} m={it.m.filter(Boolean).join(' · ')} tip={it.tip} cur={it.id === sel} onSelect={p.onSelect} />
              ))}
            </ul>
          </div>
        )) : <p className="empty">{p.q ? 'Nothing matches.' : p.groups ? 'Nothing here.' : 'loading…'}</p>}
      </div>
    </>
  );
}

// memo on plain props: a side function gives new items on each event, and most of them show the same text.
const SideRow = memo(function SideRow(p: { id: string; d: string; t: string; m: string; tip?: string; cur: boolean; onSelect: (id: string) => void }) {
  return (
    <li>
      <button type="button" className="si" data-id={p.id} aria-current={p.cur ? 'true' : undefined} title={p.tip} onClick={() => p.onSelect(p.id)}>
        <span className={`dot ${p.d === 'live' ? 'info live' : p.d === 'fix' ? 'bad' : p.d}`} aria-hidden="true" />
        <span className="t" title={p.t}>{p.t}</span>
        <span className="m">{p.m}</span>
      </button>
    </li>
  );
});

function Resize({ which, width, onWidth }: { which: 'side' | 'right'; width?: number; onWidth: (w?: number) => void }) {
  const p = PANES[which];
  const now = width ?? p.def;
  const clamp = (w: number) => Math.round(Math.min(p.max, Math.max(p.min, w)));
  const label = which === 'side' ? 'Resize the list' : 'Resize the details';
  const key = (e: RKey) => {
    const d = e.key === 'ArrowRight' ? 16 : e.key === 'ArrowLeft' ? -16 : 0;
    if (!d) return;
    e.preventDefault();
    onWidth(clamp(now + p.dir * d));
  };
  return (
    <div className={`rsz rsz-${which}`} role="separator" tabIndex={0} aria-orientation="vertical" aria-label={label}
      aria-valuenow={now} aria-valuemin={p.min} aria-valuemax={p.max} title="Drag to resize; double-click to reset"
      onKeyDown={key} onDoubleClick={() => onWidth(undefined)}
      onPointerDown={(e) => {
        e.preventDefault();
        const h = e.currentTarget, x0 = e.clientX;
        h.setPointerCapture(e.pointerId);
        h.classList.add('on');
        const move = (m: PointerEvent) => onWidth(clamp(now + p.dir * (m.clientX - x0)));
        const up = () => {
          h.classList.remove('on');
          h.removeEventListener('pointermove', move);
        };
        h.addEventListener('pointermove', move);
        h.addEventListener('pointerup', up, { once: true });
        h.addEventListener('pointercancel', up, { once: true });
      }} />
  );
}

function PipeTeam({ s, onPick }: { s: Store; onPick: (t: string) => void }) {
  const ts = pipeTeams(s);
  if (ts.length < 2) return null;
  const pick = s.prefs.pipeTeam, cur = ts.find((t) => t.key === pick);
  const name = (t: (typeof ts)[number]) => String((t.snap?.team as Record<string, unknown> | undefined)?.name || t.key);
  const red = (t: (typeof ts)[number]) => !!t.snap?.redacted;
  const counts = (cur?.snap?.counts ?? {}) as Record<string, number>;
  const why = !pick || !cur
    ? `${ts.filter((t) => t.snap && !red(t)).length} teams joined`
    : red(cur) ? `A private team: details for team admins. ${counts.review} in review, ${counts.inflight} in flight, ${counts.ready} ready.`
      : !cur.snap ? `Unknown: ${cur.error || "the team's snapshot has not loaded"}` : '';
  return (
    <div className="pteam" title={why}>
      <label className="hint">Team{' '}
        <select data-pteam aria-label="Pipeline team" value={cur ? pick : ''} onChange={(e) => onPick(e.target.value)}>
          <option value="">All teams</option>
          {ts.map((t) => <option key={t.key} value={t.key}>{name(t)}{red(t) ? ' (private)' : ''}</option>)}
        </select>
      </label>
      {cur && why && <span className="hint">{why}</span>}
    </div>
  );
}
