"""A real Firefox syncs with the local server: headless Firefox with FxA's local dev prefs signs
in to a new FxA account through its own FxA code, adds a bookmark, and syncs. The server's
database must then hold that bookmark. Run with the venv from boot.sh:
  ~/.syncstorage-venv/bin/python firefox.py [path to firefox]"""
import json, os, shutil, subprocess, sys, tempfile, time
from fxa import core, crypto
from marionette_driver.marionette import Marionette
from e2e import AUTH, confirm

# Every runner image and the snapshot set FIREFOX_BINARY (06-agent-init.sh, refresh.sh): no path of one backend here.
FIREFOX = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("FIREFOX_BINARY", "/opt/firefox-nightly/firefox")
PREFS = {  # the "local" set of fxa-dev-launcher/profile.mjs, which the desktop Firefox uses too
    "identity.fxaccounts.auth.uri": AUTH, "identity.fxaccounts.allowHttp": True,
    "identity.fxaccounts.remote.root": "http://localhost:3030/",
    "identity.fxaccounts.remote.oauth.uri": AUTH, "identity.fxaccounts.remote.profile.uri": "http://localhost:1111/v1",
    "identity.fxaccounts.autoconfig.uri": "http://localhost:3030/",
    "identity.sync.tokenserver.uri": "http://localhost:8000/1.0/sync/1.5",
    "services.sync.tokenServerURI": "http://localhost:8000/1.0/sync/1.5",
    "marionette.port": 2828, "app.update.auto": False, "browser.shell.checkDefaultBrowser": False,
}
JS = """
const [creds, resolve] = arguments;
(async () => {
  try {
    const { getFxAccountsSingleton } = ChromeUtils.importESModule("resource://gre/modules/FxAccounts.sys.mjs");
    const fxa = getFxAccountsSingleton();
    await fxa._internal.setSignedInUser(creds);
    await fxa.keys.getKeyForScope("https://identity.mozilla.com/apps/oldsync");
    const { PlacesUtils } = ChromeUtils.importESModule("resource://gre/modules/PlacesUtils.sys.mjs");
    await PlacesUtils.bookmarks.insert({ parentGuid: PlacesUtils.bookmarks.toolbarGuid,
      url: "https://example.com/sync-e2e", title: "sync e2e from Firefox" });
    const { Weave } = ChromeUtils.importESModule("resource://services-sync/main.sys.mjs");
    // A web sign-in turns Sync on the same way (FxAccountsWebChannel).
    await Weave.Service.configure();
    await Weave.Service.sync({ why: "sync-e2e" });
    resolve({ sync: Weave.Status.sync, service: Weave.Status.service, cluster: Weave.Service.clusterURL });
  } catch (e) { resolve({ error: String(e), stack: e.stack }); }
})();
"""


def mysql(q):
    return subprocess.run(["mysql", "-usync", "-ptest", "-h127.0.0.1", "-Nse", q], capture_output=True, text=True).stdout.strip()


def runs(path):
    """Why this runner's Firefox cannot start, or None."""
    try:
        r = subprocess.run([path, "--headless", "--version"], capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError) as e:
        return str(e)
    out = (r.stderr or r.stdout).strip()
    return None if r.returncode == 0 else out.splitlines()[-1] if out else f"exit {r.returncode}"


def main():
    # Exit 4: the runner, not the change, lacks a Firefox. verify.sh skips the row and tells the operator.
    why = runs(FIREFOX)
    if why:
        print(f"this runner's Firefox ({FIREFOX}) does not start: {why}")
        sys.exit(4)
    email = f"sync-ff-{os.urandom(4).hex()}@restmail.net"
    session = core.Client(server_url=AUTH).create_account(email, "sync-e2e-password-1", keys=True)
    confirm(session, email)
    creds = {"email": email, "uid": session.uid, "sessionToken": session.token, "verified": True,
             "keyFetchToken": session._key_fetch_token,
             "unwrapBKey": crypto.derive_key(session.stretchpwd, "unwrapBkey").hex()}
    print(f"1. FxA: account {email}, confirmed")
    prof = tempfile.mkdtemp(prefix="sync-ff-")
    with open(os.path.join(prof, "user.js"), "w") as f:
        f.writelines(f'user_pref("{k}", {json.dumps(v)});\n' for k, v in PREFS.items())
    # Marionette's chrome context (Firefox's own FxA and Sync code) needs system access.
    env = dict(os.environ, MOZ_REMOTE_ALLOW_SYSTEM_ACCESS="1")
    ff = subprocess.Popen([FIREFOX, "-headless", "-marionette", "-no-remote", "-profile", prof],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env)
    try:
        m = Marionette(host="127.0.0.1", port=2828, startup_timeout=60)
        m.start_session()
        m.set_context(m.CONTEXT_CHROME)
        m.timeout.script = 180
        res = m.execute_async_script(JS, script_args=[creds])
        print(f"2. Firefox: {json.dumps(res)[:400]}")
        if res.get("error") or res.get("sync") != "success.sync":
            sys.exit("Firefox did not sync")
        n = mysql(f"select count(*) from syncstorage.bso b join tokenserver.users u on b.userid = u.uid "
                  f"where u.email like '{session.uid}@%' and b.collection = (select collection from syncstorage.collections where name = 'bookmarks')")
        print(f"3. server: {n} bookmark records for this account in syncstorage")
        if not n or int(n) == 0:
            sys.exit("the server holds no bookmarks for this account")
        print("firefox sync: ok")
    finally:
        ff.terminate(); ff.wait(timeout=30); shutil.rmtree(prof, ignore_errors=True)


if __name__ == "__main__":
    main()
