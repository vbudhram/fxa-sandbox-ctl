#!/usr/bin/env bash
# writer-results.check.sh: test results outside the verify verdict (coverage, repeat runs) reach the PR body.
# The fxa-writer subagent deleted them as claims with no verdict line. Checks agents/fxa-writer.md and lib/session.sh.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
fail=0; check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2] got [$3]"; fail=1; fi; }
check "the writer keeps a test result the caller gives it" "1" "$(grep -c 'A test result the caller gives you' "$root/agents/fxa-writer.md")"
check "the session wrap-up gives the writer the results outside /fxa-verify" "1" "$(grep -c 'each test result you ran outside /fxa-verify' "$root/lib/session.sh")"
exit "$fail"
