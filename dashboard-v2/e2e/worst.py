"""Make the worst realistic case of a page fixture: long text, long keys, big counts and money, old times, many rows.
  python3 e2e/worst.py ../skills/fxa-ctl-dev/page-fixture-overview.json > /tmp/worst.json
Then serve it with e2e/serve.py --fixture and probe it at each width. Shapes and enums stay valid, so what breaks is the layout."""
import json, re, sys

LONG = {
    "summary": "Fix the Benachrichtigungseinstellungen page so that a person with a very long display name, such as Aleksandra Wiśniewska-Kowalczyk, can sign in on a second device",
    "title": "fix(settings): keep the recovery-key confirmation focused after an error on the Paramètres de confidentialité et de sécurité page (revised v12)",
    "request": "Look at https://example.com/workspaces/acme/projects/q3-launch/docs/9f8e7d6c5b4a?tab=comments&filter=unresolved and tell me why the build fails",
    "last_text": "Reading bartholomew.fitzgerald@northwind-industries-holdings.example.com/packages/fxa-settings/src/components/Settings/PageRecoveryKeyCreate/index.tsx",
    "last_tool": "Bash yarn workspace fxa-settings test --runTestsByPath src/components/Settings/PageRecoveryKeyCreate/index.test.tsx --coverage",
    "owner_name": "Christopher Alexander Montgomery III",
    "text": "The PR needs a decision from a person: the reviewer asked for a different approach and the agent stopped after two rounds",
    "name": "Konstantin Oberhauser-Wettstein nightly dependency and security report",
}
MANY = 40  # rows in each list of items with a key
OLD = "@epoch-34560000"  # 400 days ago


def key(k, i):
    m = re.fullmatch(r"([A-Z][A-Z0-9]*)-(\d+)", k)
    return f"VERYLONGPROJECT-{int(m.group(2)) * 1000 + i}" if m else k


def worst(v, field="", i=0):
    if isinstance(v, dict):
        return {k: worst(x, k, i) for k, x in v.items()}
    if isinstance(v, list):
        if v and isinstance(v[0], dict) and "key" in v[0] and field != "rows":
            v = [v[n % len(v)] for n in range(MANY)]
        return [worst(x, field, n) for n, x in enumerate(v)]
    if isinstance(v, bool) or v is None:
        return v
    if field == "key" and isinstance(v, str):
        return key(v, i)
    if field in LONG and isinstance(v, str):
        return LONG[field]
    if field in ("usd", "cost_so_far", "cost_30d", "month_usd") and isinstance(v, (int, float)):
        return 12345.67 if field != "month_usd" else 1234567.89
    if field in ("pr", "n", "pr_number") and isinstance(v, int):
        return 123456 + i
    if field in ("idle_seconds", "elapsed_seconds") and isinstance(v, int):
        return 4622400  # 1,284 hours
    if field in ("at", "created") and isinstance(v, str) and v.startswith("@epoch"):
        return OLD
    return v


json.dump(worst(json.load(open(sys.argv[1]))), sys.stdout, indent=1, ensure_ascii=False)
