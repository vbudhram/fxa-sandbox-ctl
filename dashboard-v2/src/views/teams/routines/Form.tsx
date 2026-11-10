// The routine form: step 1 picks a start, step 2 sets it up; Edit opens step 2 with the routine's setup.
import type { ReactNode } from 'react';
import { usd } from '../../../format';
import type { J } from '../../../model/base';
import { Card, Tag } from '../../../ui';
import type { Ctl } from './index';
import { Choices } from './List';
import { Field, INPUT, Opt, bad } from './parts';
import {
  RT_DAY_NAMES, RT_DAYS, RT_LIMIT, RT_MODES, RT_PROMPT_MAX, RT_RUNTIMES, RT_ZONES, rtChName, rtCostHint, rtNextText, rtPicks, rtRoutine, rtSched, rtZoneName, textSize,
} from './rt';

const H2 = ({ children }: { children: ReactNode }) => <h2 className="m-0 mb-s3 text-heading">{children}</h2>;
const Steps = ({ n }: { n: number }) => (
  <ol className="m-0 flex list-none gap-s3 p-0 text-sub">
    {['Pick a start', 'Set it up'].map((l, i) => (
      <li key={l} aria-current={i + 1 === n ? 'step' : undefined} className={i + 1 === n ? 'font-bold text-ink' : 'text-dim'}>
        <b className="mr-s1">{i + 1 < n ? '✓' : i + 1}</b>{l}
      </li>
    ))}
  </ol>
);

// The draft read back in one sentence, before it is saved.
function Readback({ d, c }: { d: J; c: Ctl }) {
  const ch = String(d.channel).trim(), chn = ch ? rtChName(ch, undefined, c.chans) : '';
  if (d.on === 'pr-label') {
    const au = String(d.pr_authors).split(/[\s,]+/).filter(Boolean);
    return <><b>{d.name || 'This routine'}</b> runs when a dependency PR in <b>{d.pr_repo || 'no repo yet'}</b> by <b>{au.length ? au.join(' or ') : 'no author yet'}</b> asks for help with the <b>{String(d.pr_label).trim() || 'agent-help'}</b> label. It pushes one fix commit to the PR branch, {ch ? <>posts in <b>{chn}</b></> : 'needs a channel for its results'}, and stops at <b>{usd(Number(d.max_usd))}</b> a run.</>;
  }
  const pr = d.draft === false ? 'a regular PR' : 'a draft PR';
  const mode = ({ report: 'reports', tickets: 'files Jira tickets', pr: `opens ${pr}`, 'pr+notes': `opens ${pr} with notes` } as Record<string, string>)[d.mode] ?? d.mode;
  return <><b>{d.name || 'This routine'}</b> runs <b>{rtSched(rtRoutine(d))} {rtZoneName(d.zone)}</b> on <b>{d.repos.join(', ') || 'no repo yet'}</b>{d.watch ? <>, for the new commits of <b>{d.watch}</b></> : ''}{d.skip_no_commits ? ', when there are new commits' : ''}. It {mode}{ch ? <>, posts in <b>{chn}</b>,</> : ', posts nothing in Slack (the results are in History),'} and stops at <b>{usd(Number(d.max_usd))}</b> a run.</>;
}

export function Form({ c }: { c: Ctl }) {
  const f = c.form!, t = c.team;
  if (f.step === 1)
    return (
      <div data-routine-form className="flex flex-col gap-s4">
        <div className="flex flex-wrap items-start justify-between gap-s3">
          <div><h3 id="rt-form-h" tabIndex={-1} className="m-0 text-heading">New routine</h3>
            <p className="hint m-0">Pick what the routine does. Each start fills in a tested prompt and a result type. You can change all of it in the next step.</p></div>
          <Steps n={1} />
        </div>
        <Choices c={c} />
        <div className="flex flex-wrap items-center gap-s3">
          <span className="hint flex-1">Every run is a normal session with the team's repos, access and budget. A team can have {c.limit || RT_LIMIT} routines.</span>
          <button type="button" data-rt-cancel onClick={() => c.act('cancel')}>Cancel</button>
        </div>
      </div>
    );
  const d = f.d, e = f.errs, repos: string[] = (t.repos ?? []).map((r: J) => r.slug), tpl = (c.tpls ?? []).find((x) => x.template === d.template);
  const set = (patch: J) => c.setForm((x) => (x?.step === 2 ? { ...x, d: { ...x.d, ...patch } } : x));
  const setF = (patch: J) => c.setForm((x) => (x?.step === 2 ? { ...x, ...patch } : x));
  const inp = (k: string) => ({ id: `rt-${k}`, 'data-rt': k, value: d[k] ?? '', onChange: (ev: { target: { value: string } }) => set({ [k]: ev.target.value }), ...bad(`rt-${k}`, e[k]) });
  const locked = tpl?.locked_mode, onpr = d.on === 'pr-label';
  const modeOff = (m: string) => (m === 'report' || m === 'tickets' ? '' : locked ? 'a security review never opens a PR' : t.read_only ? 'this team gets diffs only' : '');
  const openPrompt = f.promptOpen || d.template === 'blank' || !String(d.prompt).trim() || e.prompt;
  const zones = RT_ZONES.some((z) => z[0] === d.zone) ? RT_ZONES : [[d.zone, d.zone] as [string, string], ...RT_ZONES];
  const work: string[] = (t.repos ?? []).filter((r: J) => r.role === 'work').map((r: J) => r.slug), prRepos = work.includes(d.pr_repo) || !d.pr_repo ? work : [d.pr_repo, ...work];
  const hint = rtCostHint(c.sum, t.profile, d, c.tpls);
  const usdField = (
    <Field id="rt-max_usd" label="Cost limit for each run, USD" err={e.max_usd} hint={!onpr && hint ? hint : undefined}>
      <input {...inp('max_usd')} className={INPUT} type="number" min={1} step={1} />
    </Field>
  );
  return (
    <div data-routine-form className="flex flex-col gap-s4">
      <div className="flex flex-wrap items-start justify-between gap-s3">
        <div>
          <h3 id="rt-form-h" tabIndex={-1} className="m-0 flex flex-wrap items-center gap-s2 text-heading">{f.id ? `Edit ${d.name}` : 'New routine'} <Tag label={onpr ? 'Dependency fix' : tpl?.name ?? 'Custom prompt'} sq /></h3>
          <p className="hint m-0">{f.id ? 'Change what you need, then save. The next run uses the new setup.' : onpr ? 'Check the repo, the authors and the channel, then create it.' : 'The start filled in each field. Check the schedule and the channel, then create it.'}</p>
        </div>
        {!f.id && <Steps n={2} />}
      </div>
      <div className="grid gap-s4" style={{ gridTemplateColumns: 'repeat(auto-fit, minmax(300px, 1fr))' }}>
        <div className="flex flex-col gap-s4">
          <Card><H2>What it does</H2><div className="flex flex-col gap-s3">
            <Field id="rt-name" label="Name" err={e.name}><input {...inp('name')} className={INPUT} maxLength={40} /></Field>
            {onpr ? <p className="hint m-0">Each run reads the PR, its failing checks and the BLEnder comment, and fixes the dependency update. The host writes the prompt, so this routine has none.</p>
              : openPrompt ? (
                <Field id="rt-prompt" label={<>Prompt <span className="font-normal text-faint" data-rt-count>{textSize(d.prompt, RT_PROMPT_MAX)}</span></>} err={e.prompt}>
                  <textarea {...inp('prompt')} className={INPUT} rows={10} />
                </Field>
              ) : (
                <div className="flex flex-col gap-s1">
                  <span className="text-sub font-semibold">Prompt <span className="font-normal text-faint">· {textSize(d.prompt, RT_PROMPT_MAX)}</span></span>
                  <p className="m-0 whitespace-pre-wrap rounded-md bg-sunk p-s2 text-sub">{String(d.prompt).slice(0, 260)}{String(d.prompt).length > 260 ? '…' : ''}</p>
                  <div className="flex flex-wrap items-center gap-s2">
                    <button type="button" data-rt-prompt onClick={() => { setF({ promptOpen: true }); setTimeout(() => document.getElementById('rt-prompt')?.focus()); }}>Edit the prompt</button>
                    <span className="hint">The start's prompt is tested. Change it only when you need to.</span>
                  </div>
                </div>
              )}
          </div></Card>
          {onpr ? (
            <Card><H2>When it runs</H2><div className="flex flex-col gap-s3">
              <p className="m-0"><b>When:</b> a dependency PR asks for help</p>
              <p className="hint m-0">A run starts for a red PR by one of the authors, when a person with write access adds the label or BLEnder tags the agent in a comment. It does not run on a schedule.</p>
              <fieldset id="rt-pr" tabIndex={-1} className="m-0 flex flex-col gap-s3 border-0 p-0" {...bad('rt-pr', e.pr)}>
                <legend className="mb-s2 text-sub font-semibold">The dependency PRs</legend>
                <Field id="rt-pr_repo" label="Repo" err={e.pr_repo} hint={work.length ? undefined : 'This team has no work repo, so it cannot push a fix.'}>
                  <select {...inp('pr_repo')} className={INPUT}>
                    <option value="">Pick a work repo</option>
                    {prRepos.map((s) => <option key={s} value={s}>{s}</option>)}
                  </select>
                </Field>
                <Field id="rt-pr_authors" label="Authors" err={e.pr_authors} hint={<span id="rt-pr_authors-hint">GitHub logins, with commas. Only PRs by these authors get a fix.</span>}>
                  <input {...inp('pr_authors')} className={INPUT} {...(e.pr_authors ? {} : { 'aria-describedby': 'rt-pr_authors-hint' })} />
                </Field>
                <div className="grid gap-s3" style={{ gridTemplateColumns: 'repeat(auto-fit, minmax(180px, 1fr))' }}>
                  <Field id="rt-pr_label" label="Label" err={e.pr_label}><input {...inp('pr_label')} className={INPUT} maxLength={50} /></Field>
                  <Field id="rt-pr_mention" label={<>BLEnder mention <Opt /></>} err={e.pr_mention}><input {...inp('pr_mention')} className={INPUT} placeholder="@login or @org/team" /></Field>
                </div>
                {e.pr && <p className="m-0 text-sub font-semibold text-warn" id="rt-pr-err">{e.pr}</p>}
              </fieldset>
            </div></Card>
          ) : <>
            <Card><H2>When it runs</H2><div className="flex flex-col gap-s3">
              <fieldset id="rt-schedule" tabIndex={-1} className="m-0 flex flex-col gap-s2 border-0 p-0" {...bad('rt-schedule', e.schedule)}>
                <legend className="mb-s2 text-sub font-semibold">How often</legend>
                <span className="flex flex-wrap gap-s1">
                  {[['daily', 'Every day'], ['weekdays', 'Weekdays'], ['weekly', 'Once a week']].map(([v, l]) => (
                    <button key={v} type="button" data-rt-kind={v} aria-pressed={d.kind === v} className={d.kind === v ? 'bg-sunk' : undefined} onClick={() => set({ kind: v })}>{l}</button>
                  ))}
                </span>
                {d.kind === 'weekly' && (
                  <span className="flex flex-wrap gap-s1" role="group" aria-label="Day">
                    {RT_DAYS.map((x, i) => (
                      <button key={x} type="button" data-rt-day={x} aria-pressed={d.day === x} aria-label={RT_DAY_NAMES[i]} className={d.day === x ? 'bg-sunk' : undefined} onClick={() => set({ day: x })}>{RT_DAY_NAMES[i]!.slice(0, 3)}</button>
                    ))}
                  </span>
                )}
                {e.schedule && <p className="m-0 text-sub font-semibold text-warn" id="rt-schedule-err">{e.schedule}</p>}
              </fieldset>
              <div className="grid gap-s3" style={{ gridTemplateColumns: 'repeat(auto-fit, minmax(180px, 1fr))' }}>
                <Field id="rt-time" label="Time"><input {...inp('time')} className={INPUT} type="time" /></Field>
                <Field id="rt-zone" label="Time zone" err={e.zone}>
                  <select {...inp('zone')} className={INPUT}>{zones.map(([z, l]) => <option key={z} value={z}>{l === z ? z : `${l}, ${z}`}</option>)}</select>
                </Field>
              </div>
              <p className="hint m-0" data-rt-next>{rtNextText(d, c.now)}</p>
              <label className="flex items-center gap-s2">
                <input type="checkbox" id="rt-skip_no_commits" data-rt="skip_no_commits" checked={!!d.skip_no_commits} onChange={(ev) => set({ skip_no_commits: ev.target.checked })} {...bad('rt-skip_no_commits', e.skip_no_commits)} />
                Skip the run when the repo has no new commits
              </label>
              {e.skip_no_commits && <p className="m-0 text-sub font-semibold text-warn" id="rt-skip_no_commits-err">{e.skip_no_commits}</p>}
            </div></Card>
            <Card><H2>Where it looks</H2><div className="flex flex-col gap-s3">
              <fieldset id="rt-repos" tabIndex={-1} className="m-0 flex flex-col gap-s1 border-0 p-0" {...bad('rt-repos', e.repos)}>
                <legend className="mb-s2 text-sub font-semibold">Repos</legend>
                {repos.length ? repos.map((s) => (
                  <label key={s} className="flex items-center gap-s2">
                    <input type="checkbox" data-rt-repo={s} checked={d.repos.includes(s)} onChange={(ev) => set({ repos: ev.target.checked ? [...new Set([...d.repos, s])] : d.repos.filter((x: string) => x !== s) })} />
                    <span className="font-mono">{s}</span>
                  </label>
                )) : <span className="hint">This team has no repos.</span>}
                {e.repos && <p className="m-0 text-sub font-semibold text-warn" id="rt-repos-err">{e.repos}</p>}
              </fieldset>
              {d.repos.length === 1 && <Field id="rt-branch" label={<>Branch <Opt /></>} err={e.branch}><input {...inp('branch')} className={INPUT} placeholder="the repo's default branch" /></Field>}
              {repos.length > 1 && <Field id="rt-watch" label={<>Watch repo <Opt /></>} err={e.watch}
                hint="The run reads this repo's new commits and changes nothing in it. Its new commits start the run.">
                <select {...inp('watch')} className={INPUT}>
                  <option value="">None</option>
                  {repos.filter((s) => !d.repos.includes(s) || s === d.watch).map((s) => <option key={s} value={s}>{s}</option>)}
                </select>
              </Field>}
            </div></Card>
          </>}
          <Card><H2>What you get</H2><div className="flex flex-col gap-s3">
            {onpr ? <p className="m-0">One fix commit on the PR branch. Nothing merges by itself.</p> : <>
              <fieldset id="rt-mode" tabIndex={-1} className="m-0 flex flex-col gap-s2 border-0 p-0" {...bad('rt-mode', e.mode)}>
                <legend className="mb-s2 text-sub font-semibold">Result</legend>
                {RT_MODES.map(([v, l, about]) => {
                  const off = modeOff(v);
                  return (
                    <label key={v} className="flex items-start gap-s2">
                      <input type="radio" name="rt-mode" data-rt="mode" value={v} checked={d.mode === v} disabled={!!off} onChange={() => set({ mode: v })} />
                      <span className="flex flex-col"><b>{l}</b><span className="hint">{off ? `Off: ${off}.` : about}</span></span>
                    </label>
                  );
                })}
                {e.mode && <p className="m-0 text-sub font-semibold text-warn" id="rt-mode-err">{e.mode}</p>}
              </fieldset>
              {(d.mode === 'pr' || d.mode === 'pr+notes') && (
                <div className="flex flex-col gap-s1">
                  <label className="flex items-center gap-s2">
                    <input type="checkbox" id="rt-draft" data-rt="draft" checked={d.draft !== false} onChange={(ev) => set({ draft: ev.target.checked })} {...bad('rt-draft', e.draft)} /> Open the PR as a draft
                  </label>
                  <p className="hint m-0">Clear it to open a regular PR. A regular PR asks the code owners for a review at once.</p>
                  {e.draft && <p className="m-0 text-sub font-semibold text-warn" id="rt-draft-err">{e.draft}</p>}
                </div>
              )}
            </>}
            <Channel c={c} d={d} e={e} set={set} setF={setF} paste={!!f.chPaste} />
            {usdField}
            <div className="grid gap-s3" style={{ gridTemplateColumns: 'repeat(auto-fit, minmax(180px, 1fr))' }}>
              {(c.chans?.runtimes?.includes('codex') || (d.runtime && d.runtime !== 'claude')) && (
                <Field id="rt-runtime" label="Runtime" err={e.runtime}>
                  {/* Another runtime has other models and efforts, so the picks go back to the default. */}
                  <select {...inp('runtime')} value={d.runtime || 'claude'} onChange={(ev) => set({ runtime: ev.target.value, model: '', effort: '' })} className={INPUT}>
                    {RT_RUNTIMES.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
                  </select>
                </Field>
              )}
              <Field id="rt-model" label={<>Model <Opt /></>} err={e.model}>
                <select {...inp('model')} className={INPUT}>{rtPicks(d).models.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select>
              </Field>
              <Field id="rt-effort" label={<>Effort <Opt /></>} err={e.effort}>
                <select {...inp('effort')} className={INPUT}>{rtPicks(d).efforts.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select>
              </Field>
            </div>
          </div></Card>
        </div>
        <aside className="flex flex-col gap-s4">
          <Card><H2>{f.id ? 'Before you save' : 'Before you create it'}</H2><div className="flex flex-col gap-s3">
            <p className="readback m-0" data-rt-readback><Readback d={d} c={c} /></p>
            <p className="hint m-0">{onpr ? 'Each run posts its start and its result in the channel, and keeps one comment on the PR up to date.' : String(d.channel).trim() ? 'Each run is one thread in the channel, with the result and the next run time.' : "Each run's result is in the routine's Runs, here."}</p>
            <div className="flex flex-wrap gap-s2">
              <button type="button" data-rt-save disabled={!!f.saving} onClick={() => c.act('save')}>{f.saving ? 'Saving…' : f.id ? 'Save' : 'Create'}</button>
              {!f.id && !onpr && <button type="button" data-rt-save data-rt-then="run" disabled={!!f.saving} onClick={() => c.act('save', undefined, 'run')}>Create and run now</button>}
            </div>
            <div className="flex flex-wrap gap-s2">
              {!f.id && <button type="button" data-rt-back onClick={() => c.act('back')}>Back</button>}
              <button type="button" data-rt-cancel onClick={() => c.act('cancel')}>Cancel</button>
            </div>
          </div></Card>
        </aside>
      </div>
    </div>
  );
}

function Channel({ c, d, e, set, setF, paste }: { c: Ctl; d: J; e: Record<string, string>; set: (p: J) => void; setF: (p: J) => void; paste: boolean }) {
  const C = c.chans?.channels ?? [], why = (x: (typeof C)[number]) => (d.template === 'security-review' ? x.why_security : x.why), cur = C.find((x) => x.id === d.channel), onpr = d.on === 'pr-label';
  const none = onpr ? 'A dependency fix routine needs a channel: each run posts its start and its result there.' : 'With no channel, nothing posts in Slack and the results show only in History.';
  const label = <>Slack channel{onpr ? '' : <> <Opt /></>}</>;
  if (C.length && !paste && (!d.channel || cur))
    return (
      <Field id="rt-channel" label={label} err={e.channel}
        hint={cur ? (why(cur) ? <span className="font-semibold text-warn">{why(cur)}</span> : <span className="text-ok">✓ @fxa-agent is in this channel</span>) : none}>
        <select id="rt-channel" data-rt="channel" className={INPUT} value={d.channel} {...bad('rt-channel', e.channel)}
          onChange={(ev) => (ev.target.value === '__paste' ? (setF({ chPaste: true }), set({ channel: '' })) : set({ channel: ev.target.value }))}>
          <option value="">{onpr ? 'Pick a channel' : 'None: results show only in History'}</option>
          {C.map((x) => <option key={x.id} value={x.id} disabled={!!why(x) && x.id !== d.channel}>#{x.name}{why(x) ? ' (not allowed)' : ''}</option>)}
          <option value="__paste">Another channel: paste its ID or link</option>
        </select>
      </Field>
    );
  return (
    <Field id="rt-channel" label={label} err={e.channel}
      hint={<>{onpr ? 'A dependency fix routine needs a channel.' : 'Leave it empty and the results show only in History.'} Invite @fxa-agent to the channel first. A team with a private repo posts only to a channel of this team; a security review can post to any channel.
        {C.length > 0 && <> <button type="button" data-rt-chlist onClick={() => { setF({ chPaste: false }); set({ channel: '' }); }}>Pick from the list</button></>}</>}>
      <input id="rt-channel" data-rt="channel" className={INPUT} placeholder="C0123ABCD or a link to the channel" value={d.channel} onChange={(ev) => set({ channel: ev.target.value })} {...bad('rt-channel', e.channel)} />
    </Field>
  );
}
