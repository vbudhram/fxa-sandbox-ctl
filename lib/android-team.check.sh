#!/usr/bin/env bash
# Offline check for the FxA Android team: its profile picks the Android runner, another team's
# does not, and an Android run gets the android-verify skill and the Android goal step.
#   bash lib/android-team.check.sh
set -u
fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: want [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi; }
here="$(cd "$(dirname "$0")" && pwd)"
# Each load in its own shell, as the controller runs one profile per process.
load() { bash -c 'cd "$1/.." && source lib/config.sh >/dev/null 2>&1; source lib/pipeline.sh; pipeline_load "$2" >/dev/null 2>&1 || exit 1
  printf "%s|%s|%s|%s|%s" "${FXA_ANDROID:-}" "${FXA_GCE_NESTED:-}" "${FXA_GCE_MACHINE_TYPE:-}" "${FXA_GCE_IMAGE:-}" "${FXA_GCE_MACHINE_FALLBACK-}"' _ "$here" "$1"; }
check "the FxA Android team runs on the Android runner" "1|1|n2-standard-8|fxa-dev-android|c3-standard-8" "$(load fxa-android)"
check "the FxA team keeps its runner" "||c4a-standard-4|fxa-dev-base|" "$(load fxa | cut -d'|' -f1-4)|"

# The pattern goes through a variable: bash 3.2 brace-expands it inside "$(...)".
pat='/^_vm_skill_allowlist() {/,/^}/p'; eval "$(sed -n "$pat" "$here/agent.sh")"
_vm_repo_dirs() { :; }
check "an Android run gets android-verify" 1 "$(FXA_ANDROID=1 _vm_skill_allowlist | grep -cx android-verify)"
check "another run does not" 0 "$(_vm_skill_allowlist | grep -cx android-verify)"

pat='/^_jira_render_prompt() {/,/^}/p'; eval "$(sed -n "$pat" "$here/../fxa-sandbox-ctl")"
runtime_skill_ref() { printf '/%s' "$1"; }; runtime_prompt_header() { :; }; runtime_prompt_handoff_step() { :; }
SANDBOX_ROOT="$here/.."
check "an Android run's step 4 is /android-verify" 1 "$(FXA_ANDROID=1 PIPE_PROFILE=fxa-android _jira_render_prompt FXA-1 b s c true 2>/dev/null | grep -c '^4\. Android verification is REQUIRED: /android-verify')"
check "a functional run's step 4 stays the functional spec" 1 "$(PIPE_PROFILE=fxa _jira_render_prompt FXA-1 b s c true 2>/dev/null | grep -c '^4\. Functional tests are REQUIRED')"

# An Android run on the FxA team (the FXA pass) gets the Android team's rules, guide and boot.
for f in android_overlay vm_guide_build _vm_team_rules _gce_profile_boot; do
  pat="/^${f}() {/,/^}/p"; eval "$(sed -n "$pat" "$here/config.sh" "$here/agent.sh")"; done
FXA_ANDROID_TEAM=fxa-android; _profile_guide_trees() { :; }
rules() { _vm_team_rules | grep -c '^# Team rules: FxA Android'; }
guide() { vm_guide_build pipeline 2>/dev/null | grep -c '^# FxA Android$'; }
vm_exec() { printf '%s' "$*" > "$tmp/boot"; }; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
boot() { : > "$tmp/boot"; _gce_profile_boot r >/dev/null; grep -c "$(base64 < "$SANDBOX_ROOT/profiles/fxa-android/boot.sh" | tr -d '\n' | cut -c1-40)" "$tmp/boot"; }
check "the FXA pass's Android run: Android rules, guide and boot" "1|1|1" "$(export FXA_ANDROID=1 PIPE_PROFILE=fxa; echo "$(rules)|$(guide)|$(boot)")"
check "a plain FxA run gets none of them" "0|0|0" "$(export PIPE_PROFILE=fxa; unset FXA_ANDROID; echo "$(rules)|$(guide)|$(boot)")"
check "the Android team itself: its guide once, its rules once" "1|1" "$(export FXA_ANDROID=1 PIPE_PROFILE=fxa-android PIPE_LABEL='FxA Android Team'; echo "$(_vm_team_rules | grep -c '^# Team rules:')|$(guide)")"

[ "$fail" = 0 ] && echo "all checks pass"; exit "$fail"
