// The design system example page at #__ds. main.tsx loads it only in the dev build. The data is fake.
import { useEffect, useState, type ReactNode } from 'react';
import { BarList, Belt, ChartFrame, Gantt, Heatmap, KpiCard, Sankey, Spark, StripPlot, Terminal, Tracker } from '../charts';
import { Card, CheckBars, Dot, EmptyBox, Kv, Meter, StatTile, Tag, Unknown, type Tone } from './index';
import { Button } from './button';
import { Checkbox } from './checkbox';
import { Command, CommandEmpty, CommandGroup, CommandInput, CommandItem, CommandList } from './command';
import { Dialog, DialogContent, DialogDescription, DialogTitle, DialogTrigger } from './dialog';
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuLabel, DropdownMenuSeparator, DropdownMenuTrigger } from './dropdown-menu';
import { Popover, PopoverContent, PopoverTrigger } from './popover';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from './select';
import { Sheet, SheetContent, SheetDescription, SheetTitle, SheetTrigger } from './sheet';
import { Toaster, toast } from './sonner';
import { Switch } from './switch';
import { Tabs, TabsContent, TabsList, TabsTrigger } from './tabs';
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from './tooltip';
import { plural } from '../format';

const TONES: Tone[] = ['ok', 'warn', 'bad', 'info', 'merged', 'dim'];
const WORD: Record<Tone, string> = { ok: 'green', warn: 'held', bad: 'failing', info: 'live', merged: 'merged', dim: 'idle' };
const STOPS = ['Ready', 'Claimed', 'Boot', 'Agent', 'Verify', 'PR', 'CI', 'Review', 'Merged'] as const;
const T0 = 1_790_000_000;

function Section({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section className="flex flex-col gap-s3">
      <h2 className="m-0 font-head text-heading font-bold">{title}</h2>
      {children}
    </section>
  );
}

const Row = ({ children }: { children: ReactNode }) => <div className="flex flex-wrap items-center gap-s3">{children}</div>;

export default function DsPage() {
  const [theme, setTheme] = useState(document.documentElement.dataset.theme ?? 'light');
  const [kpi, setKpi] = useState(1240);
  const [at, setAt] = useState(3);
  const [lines, setLines] = useState([
    '[tool] Bash npm test',
    'PASS src/model/belts.test.ts',
    'FAIL src/model/needs.test.ts',
    'OPTION: retry the failing test',
    'status: waiting on you',
    'A plain line of agent prose that says the test failed.',
  ]);
  const [on, setOn] = useState(true);
  useEffect(() => {
    document.documentElement.dataset.theme = theme;
  }, [theme]);
  const days = Array.from({ length: 14 }, (_, i) => (i === 5 ? null : 20 + ((i * 7) % 11)));
  const heatCells = Array.from({ length: 7 * 24 }, (_, n) => {
    const v = (n * 13) % 9;
    return { row: Math.floor(n / 24), col: n % 24, value: v, label: plural(v, 'run') };
  });
  return (
    <TooltipProvider>
      <main className="mx-auto flex max-w-5xl flex-col gap-s6 p-s6">
        <header className="flex flex-wrap items-center gap-s3">
          <h1 className="m-0 font-head text-page font-bold">Design system</h1>
          <span className="text-sub text-dim">Every C3 part with fake data. The dev build only.</span>
          <span className="ml-auto flex gap-s2">
            <Button aria-pressed={theme === 'light'} onClick={() => setTheme('light')}>
              Light
            </Button>
            <Button aria-pressed={theme === 'dark'} onClick={() => setTheme('dark')}>
              Dark
            </Button>
          </span>
        </header>

        <Section title="Tags and dots">
          <Row>
            {TONES.map((t) => (
              <Tag key={t} tone={t} label={WORD[t]} />
            ))}
            <Tag tone="info" label="2 running" run live />
            <Tag tone="dim" label="sq" sq />
            <Tag label="no tone" />
          </Row>
          <Row>
            {TONES.map((t) => (
              <span key={t} className="inline-flex items-center gap-s1 text-sub">
                <Dot tone={t} label={WORD[t]} live={t === 'info'} /> {WORD[t]}
              </span>
            ))}
          </Row>
        </Section>

        <Section title="Meters, tiles and facts">
          <div className="grid grid-cols-3 gap-s3">
            <Meter pct={72} tone="warn" label="72% of budget" />
            <Meter pct={30} label="30% of slots" />
            <Meter pct={null} label="Budget" />
          </div>
          <div className="grid grid-cols-4 gap-s3">
            <StatTile label="Needs you" value={3} sub="2 reviews, 1 answer" tone="bad" />
            <StatTile label="In flight" value={7} sub="of 8 slots" />
            <StatTile label="Spend today" value={null} sub={<Unknown reason="The stats feed failed" />} tone="warn" />
            <KpiCard label="Merged, 30 days" value={kpi} delta={{ tone: 'ok', label: 'up 12%' }} spark={days} />
          </div>
          <Row>
            <Button onClick={() => setKpi(kpi + 37)}>Add 37 to the KPI</Button>
          </Row>
          <Card>
            <h3 className="m-0 mb-s2 text-body font-bold">A card</h3>
            <Kv label="Team" value="example" />
            <Kv label="Cost" value="none" na />
            <Kv label="CI" value={<CheckBars ok={12} fail={2} running={1} />} />
            <Kv label="CI, no data" value={<CheckBars ok={null} fail={null} running={null} />} />
          </Card>
          <div className="grid grid-cols-2 gap-s3">
            <Card sm flat>
              A flat small card.
            </Card>
            <Card sm tone="warn" label="held">
              A held card.
            </Card>
          </div>
          <EmptyBox>No merged ticket yet.</EmptyBox>
        </Section>

        <Section title="Copy-ins">
          <Row>
            <Dialog>
              <DialogTrigger asChild>
                <Button>Open a dialog</Button>
              </DialogTrigger>
              <DialogContent>
                <DialogTitle>Stop the session</DialogTitle>
                <DialogDescription>The runner stops, and the branch stays.</DialogDescription>
              </DialogContent>
            </Dialog>
            <Sheet>
              <SheetTrigger asChild>
                <Button>Open a drawer</Button>
              </SheetTrigger>
              <SheetContent>
                <SheetTitle className="m-0 text-heading font-bold">Details</SheetTitle>
                <SheetDescription className="m-0 text-sub text-dim">The side panel below 1280 px.</SheetDescription>
              </SheetContent>
            </Sheet>
            <Popover>
              <PopoverTrigger asChild>
                <Button>Open a popover</Button>
              </PopoverTrigger>
              <PopoverContent>A popover with text.</PopoverContent>
            </Popover>
            <Tooltip>
              <TooltipTrigger asChild>
                <Button>Hover for a tooltip</Button>
              </TooltipTrigger>
              <TooltipContent>The full text of an alert.</TooltipContent>
            </Tooltip>
            <DropdownMenu>
              <DropdownMenuTrigger asChild>
                <Button>Open a menu</Button>
              </DropdownMenuTrigger>
              <DropdownMenuContent>
                <DropdownMenuLabel>Session</DropdownMenuLabel>
                <DropdownMenuItem>Open the thread</DropdownMenuItem>
                <DropdownMenuSeparator />
                <DropdownMenuItem disabled>Stop</DropdownMenuItem>
              </DropdownMenuContent>
            </DropdownMenu>
            <Button kind="strong" onClick={() => toast.success('Saved the routine.')}>
              Show a toast
            </Button>
          </Row>
          <Row>
            <Select defaultValue="7d">
              <SelectTrigger aria-label="Range">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="7d">7 days</SelectItem>
                <SelectItem value="30d">30 days</SelectItem>
              </SelectContent>
            </Select>
            <label className="inline-flex items-center gap-s2 text-sub">
              <Checkbox defaultChecked /> Only mine
            </label>
            <label className="inline-flex items-center gap-s2 text-sub">
              <Switch checked={on} onCheckedChange={setOn} /> Routine {on ? 'on' : 'off'}
            </label>
          </Row>
          <Tabs defaultValue="a">
            <TabsList aria-label="Example tabs">
              <TabsTrigger value="a">Spend</TabsTrigger>
              <TabsTrigger value="b">Runs</TabsTrigger>
            </TabsList>
            <TabsContent value="a">The spend tab.</TabsContent>
            <TabsContent value="b">The runs tab.</TabsContent>
          </Tabs>
          <Card flat>
            <Command label="Example commands">
              <CommandInput placeholder="Type a command" aria-label="Command" />
              <CommandList>
                <CommandEmpty>No command found.</CommandEmpty>
                <CommandGroup heading="Go to">
                  <CommandItem>Overview</CommandItem>
                  <CommandItem>Pipeline</CommandItem>
                </CommandGroup>
              </CommandList>
            </Command>
          </Card>
        </Section>

        <Section title="Charts">
          <div className="grid grid-cols-2 gap-s6">
            <BarList
              label="Spend by team"
              items={[
                { name: 'example', value: 42.5 },
                { name: 'example-two', value: 18 },
                { name: 'example-three', value: 3.25 },
              ]}
              format={(n) => `$${n.toFixed(2)}`}
            />
            <div className="flex flex-col gap-s2">
              <Spark label="Runs per day, last 14 days, one day unknown" values={days} color="chart-2" />
              <Tracker
                label="Last runs"
                items={TONES.slice(0, 3).flatMap((t) => [{ tone: t, label: WORD[t] }, { tone: 'ok' as const, label: 'green' }])}
              />
            </div>
          </div>
          <ChartFrame
            title="A frame around any chart"
            summary="Spend per day, last 3 days. Total $12. Peak Monday, $6."
            table={{ head: ['Day', 'Spend'], rows: [['Saturday', 2], ['Sunday', 4], ['Monday', 6]] }}
          >
            <BarList label="Spend per day" items={[{ name: 'Saturday', value: 2 }, { name: 'Sunday', value: 4 }, { name: 'Monday', value: 6 }]} />
          </ChartFrame>
          <Gantt
            title="Session timeline"
            summary="Two sessions. The second ran past its cap."
            table={{ head: ['Session', 'Start', 'End'], rows: [['EX-1', 'boot', 'idle'], ['EX-2', 'boot', 'over cap']] }}
            start={T0}
            end={T0 + 3600}
            now={T0 + 3000}
            lines={[{ at: T0 + 2400, label: 'idle pause' }]}
            selected="b"
            rows={[
              { id: 'a', label: 'EX-1', bars: [{ start: T0, end: T0 + 300, tone: 'dim', label: 'boot' }, { start: T0 + 300, end: T0 + 1800, tone: 'info', label: 'busy' }], marks: [{ at: T0 + 1200, label: 'verify run' }] },
              { id: 'b', label: 'EX-2', tone: 'bad', cap: T0 + 2700, bars: [{ start: T0 + 600, end: T0 + 3000, tone: 'info', label: 'busy' }] },
            ]}
          />
          <Sankey
            title="Pipeline flow"
            summary="10 tickets: 8 to an agent run, 6 to a PR, 4 merged, 1 closed."
            table={{ head: ['From', 'To', 'Tickets'], rows: [['Queue', 'Agent run', 8], ['Agent run', 'PR', 6], ['PR', 'Merged', 4], ['PR', 'Closed', 1]] }}
            nodes={[{ id: 'q', label: 'Queue' }, { id: 'a', label: 'Agent run' }, { id: 'p', label: 'PR' }, { id: 'm', label: 'Merged' }, { id: 'c', label: 'Closed' }]}
            links={[{ source: 'q', target: 'a', value: 8 }, { source: 'a', target: 'p', value: 6 }, { source: 'p', target: 'm', value: 4 }, { source: 'p', target: 'c', value: 1 }]}
          />
          <Heatmap
            title="Runs by hour"
            summary="Runs by weekday and hour, last 7 days. Peak 8 runs."
            table={{ head: ['Day', 'Hour', 'Runs'], rows: heatCells.slice(0, 5).map((c) => [c.row, c.col, c.value]) }}
            rows={['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']}
            cols={Array.from({ length: 24 }, (_, h) => String(h))}
            cells={heatCells}
          />
          <StripPlot
            title="Days to merge"
            summary="Days to merge per week. Median 2 days."
            unit="d"
            table={{ head: ['Week', 'Ticket', 'Days'], rows: [['W1', 'EX-1', 1], ['W1', 'EX-2', 3], ['W2', 'EX-3', 2]] }}
            groups={[
              { label: 'Week 1', median: 2, points: [{ value: 1, label: 'EX-1' }, { value: 3, label: 'EX-2' }] },
              { label: 'Week 2', median: 2, points: [{ value: 2, label: 'EX-3' }] },
            ]}
          />
          <div className="flex flex-col gap-s2">
            <Belt stops={STOPS} at={at} tone="info" label="running" live />
            <Belt stops={STOPS} at={6} tone="bad" label="CI failing" />
            <Belt stops={STOPS} at={8} tone="merged" label="merged" />
            <Row>
              <Button onClick={() => setAt((at + 1) % STOPS.length)}>Move the belt one stop</Button>
              <Button onClick={() => setLines([...lines, `[tool] Read file ${lines.length}.ts`])}>Add a terminal line</Button>
            </Row>
          </div>
          <Terminal title="agent@sandbox: EX-1" lines={lines} state="running" />
        </Section>
      </main>
      <Toaster />
    </TooltipProvider>
  );
}
