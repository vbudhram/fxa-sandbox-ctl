#!/usr/bin/env bash
# verify.sh [test file...]   flake8 and the PyFxA unit tests, in a venv. See SKILL.md.
#   verify.sh --setup          only make the venv (pyfxa-live uses it)
set -uo pipefail
cd "${PYFXA_DIR:-/home/agent/pyfxa}" || { echo "pyfxa-verify: no PyFxA checkout" >&2; exit 2; }
v="${PYFXA_VENV:-/home/agent/.pyfxa-venv}"
# The test and lint packages from pyproject.toml's hatch envs. Installed again when it changes.
mark="$v/.pyproject.sha"; want="$(sha256sum pyproject.toml | cut -d' ' -f1)"
if [ ! -x "$v/bin/python" ] || [ "$(cat "$mark" 2>/dev/null)" != "$want" ]; then
  echo "pyfxa-verify: setting up the venv..."
  python3 -m venv "$v" && "$v/bin/pip" install -q --upgrade pip \
    && "$v/bin/pip" install -q -e . pytest responses parameterized pyotp grequests flake8 flake8-pyproject \
    && echo "$want" > "$mark" || { echo "pyfxa-verify: the venv setup failed" >&2; exit 2; }
fi
[ "${1:-}" = --setup ] && exit 0
rc=0
echo "== flake8"
"$v/bin/flake8" fxa || rc=1
echo "== pytest"
"$v/bin/python" -m pytest -q "${@:-fxa/tests}" 2>&1 | tail -25; [ "${PIPESTATUS[0]}" = 0 ] || rc=1
exit "$rc"
