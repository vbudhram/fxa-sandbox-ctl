// The small Stats parts: a card with its heading, a share row, a KPI tile and a day table.
import type { CSSProperties, ReactNode } from 'react';
import { jiraHref, prUrl } from '../../format';
import { KEY_RE } from '../../model/base';
import { jiraSite, teamRepo } from '../../model/pipeline';
import { Card, StatTile } from '../../ui';
import type { Store } from '../../store/types';

export function Box({ title, note, children }: { title: string; note?: string; children: ReactNode }) {
  return (
    <Card flat className="st-card">
      <h3>{title}{note && <span className="note">{note}</span>}</h3>
      {children}
    </Card>
  );
}
export const Sub = ({ title, note }: { title: string; note?: string }) => <h3>{title}{note && <span className="note">{note}</span>}</h3>;

// A label and value row; p draws the share bar behind it.
export function Row({ k, v, p, na }: { k: ReactNode; v: ReactNode; p?: number; na?: boolean }) {
  return (
    <div className={`st-kv${p != null ? ' st-share' : ''}${na ? ' na' : ''}`} style={p != null ? ({ '--p': `${p}%` } as CSSProperties) : undefined}>
      <span className="k">{k}</span><span className="v">{v}</span>
    </div>
  );
}

// The tile keeps its label and value in data attributes, so the parity probe reads the same pair as in v1.
export function Kpi({ label, value, sub }: { label: string; value: string | number; sub: ReactNode }) {
  return (
    <div data-lbl={label} data-big={String(value)}>
      <StatTile label={label} value={value} sub={sub === '' ? ' ' : sub} />
    </div>
  );
}

export const shortDay = (day: string) => new Date(`${day}T00:00`).toLocaleDateString(undefined, { month: 'short', day: 'numeric' });

// One row a day, newest first: the first cell is the YYYY-MM-DD day, the rest are figures.
export function DayTable({ label, head, rows }: { label: string; head: string[]; rows: [string, ...ReactNode[]][] }) {
  return (
    <div className="tscroll" role="region" aria-label={label} tabIndex={0}>
      <table className="st-table">
        <thead><tr><th scope="col">Day</th>{head.map((h) => <th key={h} scope="col">{h}</th>)}</tr></thead>
        <tbody>
          {rows.map(([d, ...c]) => <tr key={d}><td className="nowrap">{shortDay(d)}</td>{c.map((v, i) => <td key={i}>{v}</td>)}</tr>)}
        </tbody>
      </table>
    </div>
  );
}

export const Empty = ({ children }: { children: ReactNode }) => <div className="empty">{children}</div>;

// A Jira key or a PR number: a link when the team's site or repo is known, else the plain key.
export function JiraKey({ s, k }: { s: Store; k: string }) {
  const h = jiraHref(k, jiraSite(s, k));
  return h ? <a className="key" href={h} target="_blank" rel="noreferrer">{k}</a> : <span className="key">{k}</span>;
}
export function PrLink({ s, k, n, repo }: { s: Store; k: string; n: unknown; repo?: string }) {
  const h = prUrl(n, repo || teamRepo(s, k));
  return h ? <a className="key" href={h} target="_blank" rel="noreferrer">#{String(n)}</a> : <span className="key">#{String(n ?? '')}</span>;
}
export const isKey = (k: unknown) => KEY_RE.test(String(k ?? ''));
