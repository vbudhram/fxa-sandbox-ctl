// Small parts of the Routines and Memory tabs: the start glyph, the routine sentence, and the form field.
import type { ReactNode } from 'react';
import { sentence } from '../../../format';
import type { J } from '../../../model/base';
import type { Tone } from '../../../ui';
import { cx, TONE } from '../../../ui/tone';
import { type Chans, RT_VERB, rtChName, rtSched, rtZoneName } from './rt';

// Each start's glyph: a tone and a 24px stroke icon.
const GLYPH: Record<string, [Tone | '', ReactNode]> = {
  'code-review': ['info', <path d="M16 18l6-6-6-6M8 6l-6 6 6 6" />],
  'perf-review': ['warn', <><path d="M12 13l4-4" /><path d="M3.3 17a9 9 0 1 1 17.4 0" /></>],
  'security-review': ['ok', <path d="M12 3l8 3v6c0 4.5-3.4 8.2-8 9-4.6-.8-8-4.5-8-9V6z" />],
  'ux-review': ['merged', <><rect x="3" y="4" width="18" height="14" rx="2" /><path d="M8 21h8" /></>],
  blank: ['', <><path d="M12 20h9" /><path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z" /></>],
  depfix: ['', <path d="M14 7l3-3 3 3-3 3M17 4v6M4 20l9-9" />],
};
export function Glyph({ tpl }: { tpl: string }) {
  const [tone, d] = GLYPH[tpl] ?? GLYPH.blank!;
  return (
    <span className={cx('inline-grid size-s6 shrink-0 place-items-center rounded-md', tone ? TONE[tone] : TONE.dim)}>
      <svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
        {d}
      </svg>
    </span>
  );
}

const Mono = ({ children }: { children: ReactNode }) => <span className="font-mono">{children}</span>;

// One sentence that says what a routine does: when, what, where it looks, what it makes, where it posts.
export function Says({ d, chName, chans }: { d: J; chName?: string; chans: Chans | null }) {
  if (d.on === 'pr-label')
    return <>When a dependency PR in <Mono>{d.pr?.repo ?? (d.repos ?? [])[0] ?? 'its repo'}</Mono> asks for help, pushes one fix commit, and posts in {rtChName(d.channel, chName, chans)}.</>;
  const mode = ({ report: 'reports', tickets: 'files Jira tickets', pr: 'opens a draft PR', 'pr+notes': 'opens a draft PR with notes' } as Record<string, string>)[d.mode] ?? d.mode;
  const ch = d.channel ? rtChName(d.channel, chName, chans) : '';
  return (
    <>
      {sentence(rtSched(d))} {rtZoneName(d.zone)}. {RT_VERB[d.template] ?? 'Runs its prompt on'}{' '}
      {(d.repos ?? []).map((s: string, i: number) => <span key={s}>{i ? ', ' : ''}<Mono>{s}</Mono></span>)}, {mode}
      {d.channel ? <>, and posts in {ch.startsWith('#') ? ch : <Mono>{d.channel}</Mono>}</> : ''}.{d.channel ? '' : ' Nothing posts in Slack.'}
    </>
  );
}

export const INPUT = 'w-full rounded-md border border-line2 bg-panel px-s3 py-s1 text-body text-ink aria-invalid:border-bad';

// A labelled field: the error is tied to the input with aria-describedby (the input sets it from err).
export function Field({ id, label, children, hint, err }: { id: string; label: ReactNode; children: ReactNode; hint?: ReactNode; err?: string }) {
  return (
    <div className="flex min-w-0 flex-col gap-s1">
      <label htmlFor={id} className="text-sub font-semibold">{label}</label>
      {children}
      {hint && <p className="hint m-0">{hint}</p>}
      {err && <p className="m-0 text-sub font-semibold text-warn" id={`${id}-err`}>{err}</p>}
    </div>
  );
}
// The aria props of an input with a field error.
export const bad = (id: string, err?: string) => (err ? { 'aria-invalid': true, 'aria-describedby': `${id}-err` } : {});
export const Opt = () => <span className="font-normal text-faint">· optional</span>;

// Focus an element after React paints; with lost, only when the focused control is gone or turned off.
export const focusLater = (id: string, lost = false) => setTimeout(() => {
  const a = document.activeElement as HTMLButtonElement | null;
  if (lost && a && a !== document.body && a.isConnected && !a.disabled) return;
  document.getElementById(id)?.focus();
});
