#!/usr/bin/env bash
# lib/finish.sh _finish_risk_section: an FxA PR gets a ## Risk section after "This pull request": merge risk from the
# paths and size, rollback from what a revert cannot undo, verification from the runner's records, and the agent's notes.
#   bash lib/finish-risk.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
eval "$(sed -n '/^_finish_risk_section() {/,/^}/p' "$(dirname "$0")/finish.sh")"
g() { git -c user.email=t@example.com -c user.name=t "$@"; }
body='## Because

- why

## This pull request

- what

## Issue that this pull request solves

Closes: FXA-1'
# repo <files...>: an FxA-shaped repo whose index holds a change to each file, as finish.sh has it after its soft reset.
repo() { rm -rf "$tmp/wt"; mkdir -p "$tmp/wt/packages/fxa-settings" && cd "$tmp/wt" && g init -q && touch packages/fxa-settings/.keep && g add . && g commit -qm base
  local f; for f in "$@"; do mkdir -p "$(dirname "$f")"; printf 'line\n%.0s' $(seq 1 "${N:-3}") > "$f"; done; g add -A; }
sec() { _finish_risk_section "$tmp/wt" "$body" "${1:-}"; }

repo packages/fxa-settings/src/Page.tsx packages/fxa-settings/src/Page.test.tsx
printf 'fxa-verify 2026-10-26T00:00:00Z\nPASS unit 3s /tmp/a\nPASS lint 2s /tmp/b\nCI functional 0s -\n' > .fxa-verify-verdict.txt
printf 'fxa-verify-revert 2026-10-26T00:00:00Z proof=yes\nFAIL PASS Page.test.tsx\n' > .fxa-verify-revert.txt
mkdir -p .fxa-auto-media && touch .fxa-auto-media/page.png
out="$(sec 'Would not catch: other locales'\'' text length.')"
check "the section sits after This pull request and before the issue" "1" "$(printf '%s\n' "$out" | awk '/^## This pull request/{a=NR} /^## Risk$/{b=NR} /^## Issue/{c=NR} END{print (a<b && b<c)}')"
check "a UI change with a revert proof and media: Medium overall, from the UI path" "**Risk: Medium** (the worst of the three below)" "$(printf '%s\n' "$out" | grep -m1 '^\*\*Risk')"
check "merge risk names the size and the area" "- Merge risk: Medium. 2 files, +6 -0: settings and React UI." "$(printf '%s\n' "$out" | grep '^- Merge risk')"
check "rollback is a plain revert" "- Rollback: Easy. A plain revert; it ships on the next train." "$(printf '%s\n' "$out" | grep '^- Rollback')"
check "verification names the proof, the counts and the media" "- Verification: Strong. A test fails without the fix (verify --revert). 2 checks pass, 1 left to CI. A screenshot or video is attached." "$(printf '%s\n' "$out" | grep '^- Verification')"
check "the agent's note is a line of its own" "- Would not catch: other locales' text length." "$(printf '%s\n' "$out" | grep '^- Would not catch')"

repo packages/fxa-auth-server/lib/routes/session.js packages/db-migrations/databases/fxa/patches/patch-186-187.sql
out="$(sec)"
check "auth and a migration with no verify run: High, each named" "**Risk: High** (the worst of the three below)|- Merge risk: High. 2 files, +6 -0: the database schema, auth (sessions, tokens, 2FA, OAuth).|- Rollback: Hard. A DB migration: production runs it by hand, and its reverse patch is commented out.|- Verification: Weak. No verify run is on record." \
  "$(printf '%s\n' "$out" | grep -E '^(\*\*Risk|- (Merge|Rollback|Verification))' | paste -sd'|' -)"

repo packages/fxa-auth-server/lib/senders/emails/templates/x.mjml packages/fxa-auth-server/config/index.ts
printf 'fxa-verify 2026-10-26T00:00:00Z\nPASS unit 3s /tmp/a\nFAIL lint 2s /tmp/b\n' > .fxa-verify-verdict.txt
check "email and config: Moderate rollback with both reasons; a failed check is Weak" "- Rollback: Moderate. A config change needs a restart; a sent email cannot be recalled.|- Verification: Weak. 1 check failed." \
  "$(sec | grep -E '^- (Rollback|Verification)' | paste -sd'|' -)"

repo packages/fxa-settings/src/a.test.tsx docs/x.md
check "tests and docs only: Low, nothing to prove" "**Risk: Low** (the worst of the three below)|- Verification: Strong. Only tests and docs change." "$(sec | grep -E '^(\*\*Risk|- Verification)' | paste -sd'|' -)"

N=300 repo packages/fxa-settings/src/A.tsx packages/fxa-settings/src/B.tsx
printf 'fxa-verify 2026-10-26T00:00:00Z\nPASS unit 3s /tmp/a\n' > .fxa-verify-verdict.txt
check "over 500 lines is High merge risk; passes with no proof are Partial" "- Merge risk: High. 2 files, +600 -0: settings and React UI.|- Verification: Partial. 1 check passes; no test is shown to fail without the fix." \
  "$(sec | grep -E '^- (Merge|Verification)' | paste -sd'|' -)"

# Kinds of change: copy, email copy, styles, dependencies, snapshots.
media() { mkdir -p .fxa-auto-media && touch .fxa-auto-media/shot.png; }
pass1() { printf 'fxa-verify 2026-10-26T00:00:00Z\nPASS l10n 3s /tmp/a\n' > .fxa-verify-verdict.txt; }
rows() { sec "$@" | grep -E '^(\*\*Risk|- (Merge|Rollback|Verification))' | paste -sd'|' -; }
repo packages/fxa-settings/public/locales/en/settings.ftl; pass1; media
check "copy only, a pass and a screenshot: Low, and no revert test is asked for" \
  "**Risk: Low** (the worst of the three below)|- Merge risk: Low. 1 file, +3 -0: copy.|- Rollback: Easy. A plain revert; it ships on the next train.|- Verification: Strong. A copy or style change: 1 check passes, and a screenshot or video shows it." "$(rows)"
repo packages/fxa-settings/public/locales/en/settings.ftl; pass1
check "copy only with no screenshot is Partial" "- Verification: Partial. A copy or style change: 1 check passes; no screenshot shows the change." "$(rows | tr '|' '\n' | grep '^- Verification')"
repo packages/fxa-auth-server/lib/senders/emails/templates/x/en.ftl; pass1; media
check "email copy: Low merge, Moderate rollback, as a sent email stays" "- Merge risk: Low. 1 file, +3 -0: email copy.|- Rollback: Moderate. A sent email cannot be recalled." "$(rows | tr '|' '\n' | grep -E '^- (Merge|Rollback)' | paste -sd'|' -)"
repo packages/fxa-settings/src/styles/a.css; pass1; media
check "styles only: Medium as UI, and a screenshot is the proof" "- Merge risk: Medium. 1 file, +3 -0: settings and React UI.|- Verification: Strong. A copy or style change: 1 check passes, and a screenshot or video shows it." "$(rows | tr '|' '\n' | grep -E '^- (Merge|Verification)' | paste -sd'|' -)"
N=300 repo packages/fxa-settings/package.json yarn.lock packages/fxa-settings/src/__snapshots__/A.snap; pass1
check "dependencies are named and Medium; the lock file and snapshots do not count toward the size" "- Merge risk: Medium. 3 files, +300 -0: dependencies." "$(rows | tr '|' '\n' | grep '^- Merge')"

# Code outside the listed areas is Low when small; a long test does not size the change.
proof() { printf 'fxa-verify 2026-10-26T00:00:00Z\nPASS unit 3s /tmp/a\n' > .fxa-verify-verdict.txt; printf 'fxa-verify-revert 2026-10-26T00:00:00Z proof=yes\n' > .fxa-verify-revert.txt; }
repo libs/shared/sentry/browser-id.ts; seq 1 120 > libs/shared/sentry/browser-id.test.ts; g add -A; proof
check "small other code with 120 test lines and a revert proof: Low overall" "**Risk: Low** (the worst of the three below)|- Merge risk: Low. 2 files, +123 -0: other code." "$(rows | tr '|' '\n' | grep -E '^(\*\*Risk|- Merge)' | paste -sd'|' -)"
N=150 repo libs/shared/sentry/browser-id.ts; proof
check "other code over 100 code lines is Medium" "- Merge risk: Medium. 1 file, +150 -0: other code." "$(rows | tr '|' '\n' | grep '^- Merge')"
repo packages/fxa-auth-server/lib/routes/session.js; proof
check "a small auth change stays High" "- Merge risk: High. 1 file, +3 -0: auth (sessions, tokens, 2FA, OAuth)." "$(rows | tr '|' '\n' | grep '^- Merge')"

rm -rf packages/fxa-settings; check "a repo that is not FxA gets no section" "$body" "$(sec)"
check "a body with no This pull request heading gets the section at the end" "## Risk" "$(mkdir -p packages/fxa-settings; _finish_risk_section "$tmp/wt" 'plain body' '' | sed -n 3p)"
exit "$fail"
