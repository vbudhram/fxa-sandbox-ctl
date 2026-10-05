// Serves the fxa-settings prod build that <dir>/current points to on :3000, as the
// content server would, with the network throttled here: no proxy, so no proxy bugs.
//   node serve.js <dir> <profile: mobile|desktop|none> [port]
// Each chunk goes out only after the last one is written, so a body always arrives whole.
const http = require('http'), fs = require('fs'), path = require('path'), zlib = require('zlib');
const [dir, profile = 'mobile', port = 3000] = process.argv.slice(2);
// Lighthouse's slow 4G (150 ms, 1.6 Mbit/s) and a fast desktop line.
const PROFILES = { mobile: { rtt: 150, mbit: 1.6 }, desktop: { rtt: 40, mbit: 10 }, none: { rtt: 0, mbit: 0 } };
const { rtt, mbit } = PROFILES[profile] || PROFILES.mobile;
const perMs = (mbit * 1e6) / 8 / 1000; // bytes a millisecond; 0 is no limit
const TYPES = { '.js': 'application/javascript', '.css': 'text/css', '.html': 'text/html; charset=utf-8', '.json': 'application/json',
  '.svg': 'image/svg+xml', '.png': 'image/png', '.ftl': 'text/plain; charset=utf-8', '.ico': 'image/x-icon', '.woff2': 'font/woff2' };
// The content server's config, read once from the live page on :3030 (perf.sh saves it).
const live = fs.existsSync(path.join(dir, 'live.html')) ? fs.readFileSync(path.join(dir, 'live.html'), 'utf8') : '';
const cfg = (live.match(/name="fxa-config" content="([^"]*)"/) || [])[1] || '';
const fill = (h) => h.replace('__SERVER_CONFIG__', cfg).replace(/__(AUTH|OAUTH|SENTRY)_URL_PRECONNECT__/g, '')
  .replace('__FLOW_ID__', (live.match(/data-flow-id="([^"]*)"/) || [])[1] || '').replace('__FLOW_BEGIN_TIME__', String(Date.now()));
const gz = new Map();
let linkFree = 0; // when the shared link has sent all it was given

function send(res, body) {
  if (!perMs) return res.end(body);
  let off = 0;
  const next = () => {
    if (off >= body.length) return res.end();
    const chunk = body.subarray(off, (off += 16384)), now = Date.now();
    linkFree = Math.max(now, linkFree) + chunk.length / perMs;
    setTimeout(() => res.write(chunk, next), linkFree - now);
  };
  next();
}

http.createServer((req, res) => setTimeout(() => {
  const root = fs.realpathSync(path.join(dir, 'current'));
  const p = decodeURIComponent(req.url.split('?')[0]).replace(/^\/settings(?=\/)/, '');
  let file = path.join(root, p);
  if (!file.startsWith(root + path.sep) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) file = path.join(root, 'index.html');
  const ext = path.extname(file);
  let body = fs.readFileSync(file);
  if (ext === '.html') body = Buffer.from(fill(body.toString()));
  const headers = { 'content-type': TYPES[ext] || 'application/octet-stream', 'cache-control': ext === '.html' ? 'no-store' : 'public, max-age=31536000' };
  if (ext !== '.html' && ext !== '.png' && /gzip/.test(req.headers['accept-encoding'] || '')) {
    if (!gz.has(file)) gz.set(file, zlib.gzipSync(body, { level: 9 }));
    body = gz.get(file); headers['content-encoding'] = 'gzip';
  }
  headers['content-length'] = body.length;
  res.writeHead(200, headers);
  send(res, body);
}, rtt)).listen(+port, () => console.log(`serving ${dir}/current on ${port}, ${profile}`));
