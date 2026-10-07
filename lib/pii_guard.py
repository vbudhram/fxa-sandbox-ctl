#!/usr/bin/env python3
"""Find personal or internal data in what a PR sends to GitHub, which is public.

  python3 lib/pii_guard.py <prose.json> <diff>

prose.json maps a name (pr_title, pr_body, ...) to its text; diff is `git diff -U0`.
Prints one finding per line, the place and the kind, never the value; exits 1 on any.
Links are fine (internal ones are SSO-protected); the data itself is not.
The diff gets only the checks that test code does not trip: a fixture may hold a fake
uid or token, but not a real email, an IP, a secret or an internal host.
"""
import json
import re
import sys

EVERYWHERE = [
    ("secret", re.compile(r"\b(?:ghp_|gho_|ghs_|github_pat_|sk-ant-|xox[abpr]-|xapp-|sntry[su]_)[A-Za-z0-9_-]{8,}"
                          r"|\bAKIA[0-9A-Z]{16}\b|\bAIza[0-9A-Za-z_-]{35}\b|-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("internal host", re.compile(r"(?i)\b(?![\w.-]*docker\.internal\b)[\w-]+(?:\.[\w-]+)*\.(?:internal|svc\.cluster\.local)\b|\bmoz-fx-[a-z0-9-]+")),
]
PROSE_ONLY = [
    ("FxA uid", re.compile(r"(?i)\b(?:uid|user_?id|user)\W{1,4}(?:id:)?[0-9a-f]{32}\b")),
    ("token", re.compile(r"(?i)(?<![0-9a-f])[0-9a-f]{64}(?![0-9a-f])|\beyJ[\w-]+\.[\w-]+\.[\w-]+|\b(?:Bearer|Hawk)\s+[A-Za-z0-9._~+/=-]{20,}")),
    ("Sentry user data", re.compile(r"(?i)\*\*user(?:\.\w+)?\*\*:|\buser\.geo\b|x-sigsci-|client-ja[34]|fastly-client-ip"
                                    r"|x-forwarded-for\"?\s*[:=]")),
]
EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,})\b")
# Fake test domains, and Mozilla's own: a staff or role address is already public in git.
EMAIL_OK = re.compile(r"(?i)(?:^|\.)(?:example(?:\.com|\.org|\.net)?|test|invalid|localhost|restmail\.net"
                      r"|mozilla\.(?:com|org)|firefox\.com|github\.com|users\.noreply\.github\.com|anthropic\.com)$"
                      r"|\.(?:png|jpe?g|gif|svg|webp|js|ts|css|json|map|txt)$")  # icon@2x.png
# Test code makes up domains (u@e.com), so the diff flags only the mail providers users have.
# ponytail: a fixed list; a user at a small provider pasted into a test is missed.
EMAIL_REAL = re.compile(r"(?i)(?:^|\.)(?:gmail|googlemail|outlook|hotmail|live|msn|yahoo|ymail|icloud|me|mac|aol|proton|protonmail"
                        r"|pm|gmx|web|mail|yandex|qq|163|126|naver|orange|free|comcast|t-online)\.[a-z.]{2,6}$")
FAKE_LOCAL = re.compile(r"(?i)(?:test|user|foo|bar|fake|dummy|example|noreply|no-reply)[\w.+-]*@")
# Asset data (SVG paths, lockfile hashes, minified code) is not text a person wrote.
SKIP_FILE = re.compile(r"\.(?:svg|lock|map|snap)$|\.min\.\w+$|(?:^|/)package-lock\.json$")
IPV4 = re.compile(r"(?<![\d.])(?<![A-Za-z]/)((?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d))(?![\d.])")
IPV4_OK = re.compile(r"^(?:127\.|0\.0\.0\.0$|255\.|192\.0\.2\.|198\.51\.100\.|203\.0\.113\.)"
                     r"|^(?:1\.2\.3\.4|4\.3\.2\.1|5\.6\.7\.8|8\.8\.8\.8|8\.8\.4\.4|1\.1\.1\.1)$")  # placeholders
IPV4_PRIVATE = re.compile(r"^(?:10\.|192\.168\.|172\.(?:1[6-9]|2\d|3[01])\.|169\.254\.)")  # internal in prose, fixtures in tests
IPV6 = re.compile(r"(?i)(?<![\w:])(?:(?:[0-9a-f]{1,4}:){7}[0-9a-f]{1,4}"
                  r"|(?:[0-9a-f]{1,4}:){1,6}:(?:[0-9a-f]{1,4}(?::[0-9a-f]{1,4}){0,5})?)(?![\w:])")
PHONE = re.compile(r"(?<![\w+])\+(\d{10,15})\b")
PHONE_OK = re.compile(r"^1\d{3}555\d{4}$|^(\d)\1+$|^1?234567890")  # 555 numbers, Twilio test numbers, 1111..., 1234...


def findings(text, prose):
    for kind, pat in EVERYWHERE + (PROSE_ONLY if prose else []):
        if pat.search(text):
            yield kind
    if any(not EMAIL_OK.search(m.group(1)) if prose else EMAIL_REAL.search(m.group(1)) and not FAKE_LOCAL.match(m.group(0))
           for m in EMAIL.finditer(text)):
        yield "email"
    if any(not (IPV4_OK.match(ip) or (not prose and IPV4_PRIVATE.match(ip))) for ip in (m.group(1) for m in IPV4.finditer(text))) or \
            any(not m.group(0).lower().startswith("2001:db8") for m in IPV6.finditer(text)):
        yield "IP address"
    if any(not PHONE_OK.match(m.group(1)) for m in PHONE.finditer(text)):
        yield "phone number"


def scan(prose, diff):
    out = []
    for name, text in prose.items():
        for i, line in enumerate((text or "").splitlines(), 1):
            out += ["%s line %d: %s" % (name, i, k) for k in findings(line, True)]
    path, n = "?", 0
    for line in diff.splitlines():
        if line.startswith("+++ "):
            path = line[6:] if line.startswith("+++ b/") else line[4:]
        elif line.startswith("@@"):
            m = re.match(r"@@ -\S+ \+(\d+)", line)
            n = int(m.group(1)) if m else 0
        elif line.startswith("+") and not SKIP_FILE.search(path):
            out += ["%s:%d: %s" % (path, n, k) for k in findings(line[1:], False)]
            n += 1
    return out


if __name__ == "__main__":
    with open(sys.argv[1]) as f:
        prose = json.load(f)
    with open(sys.argv[2], errors="replace") as f:
        diff = f.read()
    hits = scan(prose, diff)
    print("\n".join(hits))
    sys.exit(1 if hits else 0)
