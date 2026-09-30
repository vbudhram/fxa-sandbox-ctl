#!/usr/bin/env bash
# Summarize Playwright traces: actions, the failure, console errors, failed requests. See SKILL.md.
#   trace.sh <trace.zip | dir>    trace.sh --selftest
exec python3 - "$@" <<'PY'
import io, json, os, re, sys, tempfile, zipfile
from contextlib import redirect_stdout

MAX_ACTIONS, MAX_CONSOLE, MAX_NET, W = 40, 10, 15, 160
ANSI = re.compile(r'\x1b\[[0-9;]*m')
RULE = re.compile(r'={5,}( logs =+)?')  # Playwright's "==== logs ====" banners
# Route handler steps: one per intercepted request, they bury the real actions.
NOISE = {'Continue request', 'Fulfill request', 'Abort request', 'Fallback request'}

def short(s, n=W):
    s = ' '.join(RULE.sub(' ', ANSI.sub('', str(s))).split())
    return s if len(s) <= n else s[:n - 3] + '...'

def lines(z, name):
    for raw in z.read(name).decode('utf-8', 'replace').splitlines():
        try:
            yield json.loads(raw)
        except ValueError:
            pass

def cut(items, cap, what, keep='tail'):
    if len(items) <= cap:
        return items, ''
    kept = items[-cap:] if keep == 'tail' else items[:cap]
    return kept, f'  ({len(items) - cap} {what} cut)'

def actions(z, names):
    # The runner's test.trace has the test's own steps with titles; browser traces are the fallback.
    runner = 'test.trace' in names
    files = ['test.trace'] if runner else [n for n in names if n.endswith('.trace')]
    before, after, errors = {}, {}, []
    for f in files:
        for e in lines(z, f):
            t = e.get('type')
            if t == 'before':
                before[e['callId']] = e
            elif t == 'after':
                after[e['callId']] = e
            elif t == 'error' and e.get('message'):
                errors.append(short(e['message'], 400))
    setup = {k for k, b in before.items() if b.get('method') in ('hook', 'fixture')}
    def in_setup(b):
        p = b.get('parentId')
        while p:
            if p in setup:
                return True
            p = before.get(p, {}).get('parentId')
        return False
    out, noise = [], 0
    for k, b in sorted(before.items(), key=lambda kv: kv[1].get('startTime', 0)):
        if k in setup or in_setup(b) or b.get('method') == 'test.attach':
            continue
        title = b.get('title') or f"{b.get('class', '')}.{b.get('method', '')}"
        if title in NOISE or b.get('class') == 'Route':
            noise += 1
            continue
        p = b.get('params') or {}
        target = '' if runner else (p.get('selector') or p.get('url') or '')
        a = after.get(k, {})
        dur = f"{a['endTime'] - b['startTime']:.0f}ms" if 'endTime' in a and 'startTime' in b else 'no end'
        err = (a.get('error') or {}).get('message') if isinstance(a.get('error'), dict) else a.get('error')
        out.append((title, target, dur, err))
    return out, noise, errors

def summarize(z, label):
    names = z.namelist()
    print(f'=== {label}')
    acts, noise, test_errors = actions(z, names)
    shown, note = cut(acts, MAX_ACTIONS, 'earlier actions')
    print(f'Actions ({len(acts)}, {noise} route handler steps hidden):')
    if note:
        print(note)
    for title, target, dur, err in shown:
        mark = '!!' if err else '  '
        print(f"{mark} {short(title, 110)}{'  ' + short(target, 80) if target else ''}  [{dur}]")
        if err:
            print(f'     ERROR: {short(err, 400)}')
    shown_errs = {short(a[3], 400) for a in acts if a[3]}
    for m in dict.fromkeys(test_errors):
        if m in shown_errs:
            continue
        print(f'!! TEST ERROR: {m}')

    console, pages = [], []
    ctx = [n for n in names if n.endswith('.trace') and n != 'test.trace']
    net = [n for n in names if n.endswith('.network')]
    for f in ctx:
        for e in lines(z, f):
            t = e.get('type')
            if t == 'console' and e.get('messageType') in ('error', 'warning'):
                console.append(f"{e['messageType']}: {short(e.get('text', ''))}")
            elif t == 'event' and e.get('method') == 'pageError':
                console.append(f"pageerror: {short(json.dumps(e.get('params', {}).get('error', e.get('params'))))}")
            elif t == 'frame-snapshot' and e.get('snapshot', {}).get('isMainFrame'):
                s = e['snapshot']
                pages.append((s.get('timestamp', 0), s.get('frameUrl')))
            elif t == 'before' and e.get('method') == 'goto':
                pages.append((e.get('startTime', 0), (e.get('params') or {}).get('url')))
    console = list(dict.fromkeys(console))
    shown, note = cut(console, MAX_CONSOLE, 'more', keep='head')
    print(f'Console errors and warnings ({len(console)}):')
    for c in shown:
        print(f'  {c}')
    if note:
        print(note)

    failed = []
    for f in net:
        for e in lines(z, f):
            s = e.get('snapshot') or {}
            req, res = s.get('request') or {}, s.get('response') or {}
            st = res.get('status', -1)
            fail = res.get('_failureText')
            if st >= 400 or st < 0 or fail:
                failed.append(f"{req.get('method', '?')} {st if st >= 0 else 'FAILED'} {short(req.get('url', ''), 140)}{'  (' + fail + ')' if fail else ''}")
    shown, note = cut(failed, MAX_NET, 'earlier requests')
    print(f'Failed requests ({len(failed)}):')
    if note:
        print(note)
    for r in shown:
        print(f'  {r}')
    last = max(pages, key=lambda p: p[0])[1] if pages else None
    print(f'Last page URL: {short(last, 300) if last else "unknown"}')

def run(path):
    zips = [path] if os.path.isfile(path) else sorted(
        os.path.join(d, f) for d, _, fs in os.walk(path) for f in fs if f == 'trace.zip')
    if not zips:
        sys.exit(f'no trace.zip at {path}')
    for i, p in enumerate(zips):
        if i:
            print()
        try:
            with zipfile.ZipFile(p) as z:
                summarize(z, p)
        except zipfile.BadZipFile:
            print(f'=== {p}\n  not a zip file')

def selftest():
    j = lambda rows: '\n'.join(json.dumps(r) for r in rows)
    test = j([
        {'type': 'before', 'callId': 'h1', 'method': 'hook', 'title': 'Before Hooks', 'startTime': 0},
        {'type': 'before', 'callId': 'c1', 'parentId': 'h1', 'method': 'pw:api', 'title': 'Create page', 'startTime': 1},
        {'type': 'before', 'callId': 'a1', 'method': 'pw:api', 'title': 'Navigate to "/"', 'startTime': 10},
        {'type': 'after', 'callId': 'a1', 'endTime': 35},
        {'type': 'before', 'callId': 'r1', 'method': 'pw:api', 'title': 'Continue request', 'startTime': 20},
        {'type': 'before', 'callId': 'a2', 'method': 'pw:api', 'title': 'Click Submit', 'startTime': 40},
        {'type': 'after', 'callId': 'a2', 'endTime': 100, 'error': {'message': 'Error: timeout'}},
        {'type': 'error', 'message': '\x1b[31mTest timeout of 60000ms exceeded.\x1b[39m'},
    ])
    ctx = j([
        {'type': 'console', 'messageType': 'error', 'text': 'boom'},
        {'type': 'console', 'messageType': 'info', 'text': 'quiet'},
        {'type': 'frame-snapshot', 'snapshot': {'isMainFrame': True, 'timestamp': 5, 'frameUrl': 'http://a/first'}},
        {'type': 'frame-snapshot', 'snapshot': {'isMainFrame': True, 'timestamp': 9, 'frameUrl': 'http://a/last'}},
    ])
    net = j([
        {'type': 'resource-snapshot', 'snapshot': {'request': {'method': 'GET', 'url': 'http://a/ok'}, 'response': {'status': 200}}},
        {'type': 'resource-snapshot', 'snapshot': {'request': {'method': 'POST', 'url': 'http://a/bad'}, 'response': {'status': 400}}},
        {'type': 'resource-snapshot', 'snapshot': {'request': {'method': 'GET', 'url': 'http://a/down'}, 'response': {'status': -1, '_failureText': 'NS_ERROR_CONNECTION_REFUSED'}}},
    ])
    with tempfile.TemporaryDirectory() as d:
        os.makedirs(os.path.join(d, 't1'))
        with zipfile.ZipFile(os.path.join(d, 't1', 'trace.zip'), 'w') as z:
            z.writestr('test.trace', test)
            z.writestr('0-trace.trace', ctx)
            z.writestr('0-trace.network', net)
        buf = io.StringIO()
        with redirect_stdout(buf):
            run(d)
    out = buf.getvalue()
    for want in ['Navigate to "/"  [25ms]', '!! Click Submit  [60ms]', 'ERROR: Error: timeout',
                 'TEST ERROR: Test timeout of 60000ms exceeded.', '1 route handler steps hidden',
                 'error: boom', 'POST 400 http://a/bad', 'GET FAILED http://a/down  (NS_ERROR_CONNECTION_REFUSED)',
                 'Last page URL: http://a/last']:
        assert want in out, f'missing {want!r} in:\n{out}'
    for unwanted in ['Create page', 'quiet', 'http://a/ok']:
        assert unwanted not in out, f'unexpected {unwanted!r} in:\n{out}'
    print('selftest ok')

if len(sys.argv) != 2:
    sys.exit('usage: trace.sh <trace.zip | dir> | --selftest')
selftest() if sys.argv[1] == '--selftest' else run(sys.argv[1])
PY
