// Text formatters, ported from the retired v1 dashboard. Pure: no store, no DOM.

const ESC: Record<string, string> = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };
export const esc = (s: unknown): string => String(s ?? '').replace(/[&<>"']/g, (c) => ESC[c] ?? c);

export const sentence = (t: string): string => t.charAt(0).toUpperCase() + t.slice(1);

// s is an age in seconds.
export const ago = (s: number | null | undefined): string =>
  s == null ? 'never' : s < 60 ? `${s}s ago` : s < 3600 ? `${Math.round(s / 60)}m ago` : s < 172800 ? `${Math.round(s / 3600)}h ago` : `${Math.round(s / 86400)}d ago`;

export const short = (s: number | null | undefined): string =>
  s == null ? '' : s < 60 ? `${s}s` : s < 3600 ? `${Math.round(s / 60)}m` : `${(s / 3600).toFixed(1)}h`;

// e is an epoch in seconds. One formatter for all calls: toLocaleString builds a new one each time, about 10 times slower.
const STAMP = new Intl.DateTimeFormat(undefined, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
export const stamp = (e: number | null | undefined): string => {
  if (e == null) return '';
  const d = new Date(e * 1000);
  return Number.isNaN(d.getTime()) ? 'Invalid Date' : STAMP.format(d);
};

// Days since an ISO time, or null.
export const days = (iso: string | null | undefined): number | null => (iso == null ? null : (Date.now() - Date.parse(iso)) / 86400000);

export const usd = (n: number | null | undefined): string => (n == null ? '—' : '$' + Number(n).toFixed(2));

export const tokn = (n: number | null | undefined): string =>
  n != null && n >= 1e6 ? `${(n / 1e6).toFixed(1)}M` : n != null && n >= 1e3 ? `${Math.round(n / 1e3)}K` : String(n || 0);

// "claude-opus-4-5-20251101[1m]" reads as "Opus 4.5 (1M)".
export const modelName = (m: string | null | undefined): string => {
  const l = /\[1m\]$/.test(m || '');
  return (m || 'unknown').replace(/\[1m\]$/, '').replace(/^claude-/, '').replace(/-\d{8}$/, '').replace(/-(\d+)-(\d+)$/, ' $1.$2')
    .replace(/-(\d+)$/, ' $1').replace(/^./, (c) => c.toUpperCase()) + (l ? ' (1M)' : '');
};

// Links fail closed: a bad site, repo, key or number gives "".
export const REPO_RE = /^(?!.*\.\.)[\w-][\w.-]*\/[\w-][\w.-]*$/;
export const jiraHref = (key: string | null | undefined, site: unknown): string => {
  const s = String(site ?? '').replace(/\/+$/, '');
  return /^https:\/\/[\w-]+(\.[\w-]+)+(:\d+)?$/.test(s) && /^[A-Z][A-Z0-9]+-\d+$/.test(key ?? '') ? `${s}/browse/${encodeURIComponent(key ?? '')}` : '';
};
export const prUrl = (n: unknown, repo: unknown): string => {
  const r = String(repo ?? '');
  return REPO_RE.test(r) && /^\d+$/.test(String(n ?? '')) ? `https://github.com/${r}/pull/${n}` : '';
};
// A PR link from the data, or '' when it is not a PR of a valid repo.
export const prHref = (u: unknown): string => {
  const m = String(u || '').match(/^https:\/\/github\.com\/([^/]+\/[^/]+)\/pull\/\d+$/);
  return m && REPO_RE.test(m[1] ?? '') ? String(u) : '';
};

// "[README.md](/workspace/README.md:15)" reads as "README.md".
export const plainMd = (t: unknown): string => String(t ?? '').replace(/\[([^\]]+)\]\([^)]*\)/g, '$1').replace(/[*`]/g, '');

// Agent replies are Markdown: escape first, then allow code, bold, italics, headings, lists and http(s) links.
export function mdHtml(src: unknown): string {
  const blocks: string[] = [];
  const t = String(src ?? '').replace(/```[^\n]*\n([\s\S]*?)```/g, (_, c: string) => {
    blocks.push(`<pre><code>${esc(c.replace(/\n$/, ''))}</code></pre>`);
    return `\uE000${blocks.length - 1}\uE000`;
  });
  const inline = (x: string) => esc(x)
    .replace(/`([^`\n]+)`/g, '<code>$1</code>')
    .replace(/\*\*([^*\n]+)\*\*/g, '<b>$1</b>')
    .replace(/(^|[\s(])\*([^*\n]+)\*(?=[\s).,;:!?]|$)/g, '$1<b>$2</b>')
    .replace(/(^|[\s(])_([^_\n]+)_(?=[\s).,;:!?]|$)/g, '$1<i>$2</i>')
    // Both link forms in one pass: a second pass could match inside the first one's href.
    .replace(/\[([^\]\n]+)\]\((https?:\/\/[^\s)<>"]+)\)|&lt;(https?:\/\/[^|\s<>"&]+)\|([^&]+?)&gt;/g,
      (all: string, t1?: string, u1?: string, u2?: string, t2?: string) => {
        const u = u1 ?? u2 ?? '';
        return u.includes('&lt;') ? all : `<a href="${u}" target="_blank" rel="noopener">${t1 ?? t2}</a>`;
      });
  const out: string[] = [];
  let list: { tag: string; items: string[] } | null = null, para: string[] = [], table: string[] = [];
  const flush = () => {
    if (para.length) { out.push(`<p>${para.join('<br>')}</p>`); para = []; }
    if (list) { out.push(`<${list.tag}>${list.items.join('')}</${list.tag}>`); list = null; }
    if (table.length) { out.push(`<pre>${esc(table.join('\n'))}</pre>`); table = []; }
  };
  for (const line of t.split('\n')) {
    const blk = line.match(/^\uE000(\d+)\uE000$/), ul = line.match(/^(\s*)[-*•] (.*)$/), ol = line.match(/^(\s*)\d+[.)] (.*)$/), h = line.match(/^#{1,6} (.*)$/);
    if (blk) { flush(); out.push(blocks[+(blk[1] ?? 0)] ?? ''); }
    else if (/^\s*\|.*\|\s*$/.test(line)) { if (!table.length) flush(); table.push(line); }
    else if (ul || ol) {
      const tag = ul ? 'ul' : 'ol', m = (ul || ol)!;
      if (para.length || table.length || (list && list.tag !== tag)) flush();
      list ??= { tag, items: [] };
      list.items.push(`<li${(m[1] ?? '').length >= 2 ? ' class="sub"' : ''}>${inline(m[2] ?? '')}</li>`);
    }
    else if (h) { flush(); out.push(`<span class="h">${inline(h[1] ?? '')}</span>`); }
    else if (!line.trim()) flush();
    else { if (list || table.length) flush(); para.push(inline(line)); }
  }
  flush();
  return out.join('');
}

// One terminal line: a command gets a prompt (p) or a tool name (t); only real results get a colour.
export type TtyLine = { kind: '' | 'p' | 't' | 'bad' | 'ok' | 'opt' | 'dim'; head: string; text: string };
export function ttyLine(l: string): TtyLine {
  const m = l.match(/^\[tool\] (\S+)\s*(.*)$/);
  if (m) return m[1] === 'Bash' || m[1] === 'shell' ? { kind: 'p', head: '$', text: m[2] ?? '' } : { kind: 't', head: m[1] ?? '', text: m[2] ?? '' };
  if (/^\s*(FAIL\b|ERROR\b|Error:|✗|✕|Tests:.*\bfailed\b)/.test(l)) return { kind: 'bad', head: '', text: l };
  if (/^\s*(PASS\b|✓|Tests:.*\bpassed\b)/.test(l)) return { kind: 'ok', head: '', text: l };
  if (/^OPTION:/.test(l)) return { kind: 'opt', head: '', text: l };
  if (/^status:/.test(l)) return { kind: 'dim', head: '', text: l };
  return { kind: '', head: '', text: l };
}
