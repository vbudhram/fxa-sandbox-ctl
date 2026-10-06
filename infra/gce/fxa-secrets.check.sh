#!/usr/bin/env bash
# Offline check that manager.sh's splice puts infra/gce/fxa-secrets.sh into the setup
# script intact, and that both parse.
#   bash infra/gce/fxa-secrets.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
here="$(cd "$(dirname "$0")" && pwd)"
check "fxa-secrets.sh parses and is not empty" "yes" "$(bash -n "$here/fxa-secrets.sh" && [ -s "$here/fxa-secrets.sh" ] && echo yes)"
# The same sed line manager.sh runs.
splice="$(grep -o 'sed -e "/^__FXA_SECRETS__.*manager-setup.sh"' "$here/manager.sh")"
check "manager.sh still splices at the marker" "1" "$(grep -c '^__FXA_SECRETS__$' "$here/manager-setup.sh")"
out="$(ROOT="$here/../.." eval "$splice")"
check "the spliced setup parses" "yes" "$(bash -n <(printf '%s\n' "$out") && echo yes)"
check "it holds fxa-secrets.sh unchanged, and no marker" "same|0" \
  "$(awk '/^cat > \/usr\/local\/sbin\/fxa-secrets <<.SEC.$/{f=1;next} /^SEC$/{f=0} f' <<< "$out" | cmp -s - "$here/fxa-secrets.sh" && echo same)|$(grep -c '^__FXA_SECRETS__$' <<< "$out")"
exit "$fail"
