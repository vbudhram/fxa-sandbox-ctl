#!/usr/bin/env bash
# Offline check that ground reads every frozen entry of check-frozen.ts, multi-line ones too.
#   bash lib/frozen-patterns.check.sh
set -u
fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}

eval "$(sed -n '/^_frozen_patterns() {/,/^}/p' "$(dirname "$0")/../fxa-sandbox-ctl")"
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
cat >"$tmp" <<'TS'
const FROZEN: Array<{ pattern: string; reason: string; exclude?: string }> = [
  {
    pattern: 'packages/a/email.js',
    reason: 'Files moved',
  },
  {
    pattern: 'packages/a/(emails|renderer)/.*',
    // a tool that hasn't moved
    exclude: 'storybook-email\\.ts$',
  },
  {
    pattern:
      'packages/b/v1-envelope-fixture\\.json$',
    reason:
      'Golden vectors',
  },
];
TS
out="$(_frozen_patterns <"$tmp")"
check "three entries" "3" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
check "multi-line entry, unescaped" "packages/b/v1-envelope-fixture\.json$" "$(sed -n 3p <<<"$out" | cut -f1)"
check "exclude read" "storybook-email\.ts$" "$(sed -n 2p <<<"$out" | cut -f2)"
check "unescaped pattern matches the file" "yes" \
  "$(printf 'packages/b/v1-envelope-fixture.json' | grep -qE "^$(sed -n 3p <<<"$out" | cut -f1)" && echo yes)"

exit "$fail"
