(() => {
  // The layout faults a person sees: clipped text, overlapping text, sideways scroll, the first card's position.
  const main = document.getElementById('main') ?? document.body;
  const leaves = [...main.querySelectorAll('*')].filter((e) => e.children.length === 0 && e.textContent.trim() && e.getClientRects().length);
  // Also a visually hidden caption (1px, clipped) and a chart tooltip that waits off screen.
  const hidden = (e) => e.closest('.vh, .sr-only, [hidden], details:not([open]), [role=tooltip], .recharts-tooltip-wrapper')
    || (getComputedStyle(e).position === 'absolute' && e.clientWidth <= 1);
  const style = (e) => getComputedStyle(e);
  // Clipped: text wider than its box, in a box that hides or cuts the overflow.
  const clipped = leaves.filter((e) => !hidden(e) && e.scrollWidth > e.clientWidth + 1 && style(e).overflow !== 'visible')
    .map((e) => `${style(e).textOverflow === 'ellipsis' ? 'ellipsis' : 'CUT'} ${e.className}: ${e.textContent.trim().slice(0, 40)} (${e.scrollWidth} in ${e.clientWidth})`);
  // Overlap: two visible text boxes on the same line that cross.
  const boxes = leaves.filter((e) => !hidden(e)).map((e) => [e, e.getBoundingClientRect()]);
  const overlap = [];
  for (let i = 0; i < boxes.length && overlap.length < 10; i++) for (let j = i + 1; j < boxes.length; j++) {
    const [a, ra] = boxes[i], [b, rb] = boxes[j];
    if (a.contains(b) || b.contains(a)) continue;
    const x = Math.min(ra.right, rb.right) - Math.max(ra.left, rb.left), y = Math.min(ra.bottom, rb.bottom) - Math.max(ra.top, rb.top);
    if (x > 2 && y > 2) overlap.push(`${a.textContent.trim().slice(0, 20)} x ${b.textContent.trim().slice(0, 20)}`);
  }
  // Headings in reading order with their top in px: what needs the person must come first and sit above the fold.
  return { width: innerWidth, fold: innerHeight, sideways: document.documentElement.scrollWidth > innerWidth,
    headings: [...main.querySelectorAll('h1, h2, h3')].map((h) => `${Math.round(h.getBoundingClientRect().top + scrollY)} ${h.textContent.trim()}`),
    clipped: clipped.slice(0, 10), overlap };
})();
