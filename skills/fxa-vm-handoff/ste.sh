#!/usr/bin/env bash
# Check prose against the ASD-STE100 rules a script can check without guessing.
#   ste.sh [--skip-lines-of <file>] < text
# Unapproved words, em dashes, sentences over 25 words, paragraphs over 6
# sentences. Code blocks, inline code, URLs, headings and table rows are skipped,
# and so is any line that is in the --skip-lines-of file (a PR template's own text).
# Passive voice, -ing forms and noun clusters stay with the model: a script flags
# too many false cases. Prints one "ste: ..." line per problem; exits 1 when there is one.
skip=/dev/null
[ "${1:-}" = --skip-lines-of ] && [ -f "${2:-}" ] && skip="$2"
# Portable awk (mawk on Ubuntu, BSD awk on macOS): no \b, no IGNORECASE.
LC_ALL=C awk -v skipfile="$skip" '
BEGIN {
  while ((getline l < skipfile) > 0) { gsub(/^[ \t]+|[ \t]+$/, "", l); if (l != "") skipline[l] = 1 }
  n = split("utilize:use|utilise:use|utilizes:uses|utilized:used|utilizing:using|leverage:use|leverages:uses|" \
    "initiate:start|initiates:starts|commence:start|commences:starts|remediate:fix|remediates:fixes|" \
    "regarding:about|prior to:before|subsequent to:after|facilitate:help|facilitates:helps|" \
    "demonstrate:show|demonstrates:shows|sufficient:enough|ensure:make sure|ensures:makes sure|" \
    "approximately:about|in order to:to|replenish:fill|additionally:also|numerous:many|" \
    "endeavor:try|commencing:starting|terminate:stop", pairs, "|")
  for (i = 1; i <= n; i++) { split(pairs[i], kv, ":"); bad[kv[1]] = kv[2] }
  problems = 0
}
function say(m) { if (problems < 15) print "ste: " m; problems++ }
function first_words(s, k,   w, m, i, out) {
  m = split(s, w, /[ \t]+/); out = ""
  for (i = 1; i <= m && i <= k; i++) out = out (out == "" ? "" : " ") w[i]
  return out (m > k ? " ..." : "")
}
# One paragraph or list item: its sentences and their lengths.
function flush(   m, i, s, words, cnt, orig) {
  if (para == "") return
  orig = para
  gsub(/[.!?]+( |$)/, "&\n", para)
  m = split(para, s, "\n"); cnt = 0
  for (i = 1; i <= m; i++) {
    words = split(s[i], tmp, /[ \t]+/)
    for (j = 1; j <= words; j++) if (tmp[j] !~ /[A-Za-z0-9]/) words--
    if (words <= 0) continue
    cnt++
    if (words > 25) say(words " words, limit 25: \"" first_words(s[i], 8) "\"")
  }
  if (!item && cnt > 6) say("a paragraph of " cnt " sentences, limit 6: \"" first_words(orig, 8) "\"")
  para = ""; item = 0
}
{
  line = $0
  if (line ~ /^[ \t]*(```|~~~)/) { fence = !fence; flush(); next }
  if (fence) next
  t = line; gsub(/^[ \t]+|[ \t]+$/, "", t)
  if (t == "" || t ~ /^#/ || t ~ /^\|/ || t ~ /^<!--/ || (t in skipline)) { flush(); next }
  gsub(/`[^`]*`/, " ", line)
  gsub(/\]\([^)]*\)/, "]", line)
  gsub(/https?:\/\/[^ )>]+/, " ", line)
  if (index(line, "\342\200\224")) say("em dash: \"" first_words(t, 8) "\" (use a comma)")
  low = " " tolower(line) " "; gsub(/[^a-z0-9]+/, " ", low)
  for (w in bad) if (index(low, " " w " ") && !(w in seen)) { seen[w] = 1; say("\"" w "\": use \"" bad[w] "\"") }
  if (t ~ /^([-*+]|[0-9]+[.)])[ \t]/) { flush(); item = 1; sub(/^[ \t]*([-*+]|[0-9]+[.)])[ \t]+(\[[ xX]\][ \t]+)?/, "", line) }
  para = para (para == "" ? "" : " ") line
}
END { flush(); if (problems > 15) print "ste: ... and " problems - 15 " more"; exit problems > 0 }
'
