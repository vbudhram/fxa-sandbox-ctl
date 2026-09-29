#!/bin/bash
# Runs as root on a session runner: a Linux desktop a person can open through
# noVNC. Safe to run again; it ends with the private IP and the VNC password.
#
# The desktop user `viewer` cannot read /home/agent (the agent's login lives
# there), sees the repo read-only at /srv/workspace, and reaches only this VM.
# The agent cannot reach the VNC ports, so it cannot watch or drive the desktop.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

if ! command -v Xtigervnc >/dev/null || ! command -v firefox >/dev/null; then
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg -o /etc/apt/keyrings/packages.mozilla.org.asc
  echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" > /etc/apt/sources.list.d/mozilla.list
  # Ubuntu's firefox is a snap wrapper; Mozilla's own build wins.
  printf 'Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n' > /etc/apt/preferences.d/mozilla
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends xfce4 xfce4-terminal thunar dbus-x11 \
    tigervnc-standalone-server tigervnc-tools novnc websockify firefox xfonts-base fonts-dejavu >/tmp/desktop-apt.log 2>&1
fi

id viewer >/dev/null 2>&1 || useradd -m -s /bin/bash viewer
mkdir -p /srv/workspace
if ! mountpoint -q /srv/workspace; then
  mount --bind /home/agent/fxa /srv/workspace
  mount -o remount,bind,ro /srv/workspace
fi

v="$(id -u viewer)"; a="$(id -u agent)"
# At the top of the chain: the agent's egress rules end with an ACCEPT for
# everyone else, so rules appended after it never match. Drop any older viewer
# rules first, so a rerun also fixes a runner set up in the wrong order.
# No older rules on a fresh runner: grep finds nothing, which is not a failure.
iptables -S OUTPUT | { grep -- "--uid-owner $v " || true; } | sed 's/^-A /-D /' | while read -r r; do eval "iptables $r"; done
iptables -I OUTPUT 1 -m owner --uid-owner "$v" -j REJECT
# The content server links to the VM's own address, not localhost.
for ip in $(hostname -I); do iptables -I OUTPUT 1 -m owner --uid-owner "$v" -d "$ip" -j ACCEPT; done
iptables -I OUTPUT 1 -m owner --uid-owner "$v" -o lo -j ACCEPT
# websockify runs as the viewer: let it answer the gateway's connections.
iptables -I OUTPUT 1 -m owner --uid-owner "$v" -m conntrack --ctstate ESTABLISHED -j ACCEPT
iptables -C OUTPUT -m owner --uid-owner "$a" -o lo -p tcp -m multiport --dports 5901,6080 -j REJECT 2>/dev/null \
  || iptables -I OUTPUT 1 -m owner --uid-owner "$a" -o lo -p tcp -m multiport --dports 5901,6080 -j REJECT

# The desktop is for looking at the FxA stack: start it when it is not running
# (the agent starts it only when a request needs it). It runs as the agent,
# as when the agent starts it, and takes about two minutes.
if ! ss -ltn | grep -q ':3030 ' && ! pgrep -u agent -f fxa-start >/dev/null; then
  sudo -u agent bash -c 'cd /workspace && nohup setsid bash -c "source /etc/agent-env.sh && fxa-start" > /workspace/.fxa-auto-stack-start.log 2>&1 < /dev/null & disown'
  echo "stack=starting"
fi

# websockify accepts any origin, so a page in the person's browser could reach
# the tunnel; a password per runner stops it.
if [ ! -s /root/.desktop-password ]; then
  (umask 077; openssl rand -base64 12 | tr -dc 'A-Za-z0-9' | cut -c1-8 > /root/.desktop-password)
fi
pw="$(cat /root/.desktop-password)"

# The full-screen page (templates/novnc-fxa.html), passed in base64 as $1.
[ -n "${1:-}" ] && printf '%s' "$1" | base64 -d > /usr/share/novnc/fxa.html
# The mail viewer the proxy serves at /__inbox (templates/inbox-viewer.html), as $2.
[ -n "${2:-}" ] && printf '%s' "$2" | base64 -d | install -m 644 -o agent -g agent /dev/stdin /tmp/inbox-viewer.html

# Firefox for the desktop: no first-run terms or welcome, the local stack as
# the home page (the Home button), and its other pages on the bookmarks toolbar,
# each opening in a new tab so the page under test stays open.
mkdir -p /usr/lib/firefox/distribution
cat > /usr/lib/firefox/distribution/policies.json <<'POLICIES'
{"policies": {
  "SkipTermsOfUse": true,
  "OverrideFirstRunPage": "",
  "OverridePostUpdatePage": "",
  "DontCheckDefaultBrowser": true,
  "DisableAppUpdate": true,
  "Homepage": {"URL": "http://localhost:3030/", "StartPage": "homepage"},
  "DisplayBookmarksToolbar": "always",
  "Preferences": {"browser.tabs.loadBookmarksInTabs": {"Value": true, "Status": "default"}},
  "Bookmarks": [
    {"Title": "Settings", "URL": "http://localhost:3030/settings", "Placement": "toolbar"},
    {"Title": "Inbox", "URL": "http://localhost:3030/__inbox", "Placement": "toolbar"},
    {"Title": "123done", "URL": "http://localhost:8080/", "Placement": "toolbar"}
  ]
}}
POLICIES

sudo -u viewer -H bash -s "$pw" <<'VIEWER'
set -euo pipefail
cd ~
mkdir -p ~/.vnc ~/Desktop
ln -sfn /srv/workspace ~/Desktop/fxa
# Firefox with the repo's FxA dev profile, so FxA, Sync and OAuth use the local
# stack. Not the repo's bin script: with no debugger it passes Firefox an empty
# argument, which opens file:/// in place of the stack.
cat > ~/fxa-firefox.mjs <<'MJS'
const { default: foxfire } = await import('/srv/workspace/node_modules/foxfire/index.js');
const { default: profile } = await import('/srv/workspace/packages/fxa-dev-launcher/profile.mjs');
foxfire({ args: ['http://localhost:3030/'], profileOptions: profile });
MJS
# foxfire also adds an empty argument, which Firefox opens as file:///; drop it.
printf '#!/bin/bash\na=(); for x in "$@"; do [ -n "$x" ] && a+=("$x"); done\nexec /usr/bin/firefox "${a[@]}"\n' > ~/firefox-bin
# Wait for the stack (up to 3 min), so Firefox opens on the accounts page, not an error.
printf '#!/bin/bash\nfor i in $(seq 1 90); do (exec 3<>/dev/tcp/127.0.0.1/3030) 2>/dev/null && break; sleep 2; done\nFIREFOX_BIN=%s/firefox-bin exec node %s/fxa-firefox.mjs\n' "$HOME" "$HOME" > ~/fxa-firefox
chmod +x ~/firefox-bin ~/fxa-firefox
mkdir -p ~/.local/share/applications
printf '[Desktop Entry]\nType=Application\nName=Firefox (FxA dev)\nComment=Firefox with the FxA dev profile for the local stack\nExec=%s/fxa-firefox\nIcon=firefox\nTerminal=false\n' "$HOME" \
  | tee ~/.local/share/applications/fxa-firefox.desktop > ~/Desktop/fxa-firefox.desktop
chmod +x ~/Desktop/fxa-firefox.desktop
# A plain background the color of the page around it.
x=~/.config/xfce4/xfconf/xfce-perchannel-xml; mkdir -p "$x"
[ -f "$x/xfce4-desktop.xml" ] || cat > "$x/xfce4-desktop.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-desktop" version="1.0">
  <property name="backdrop" type="empty"><property name="screen0" type="empty">
    <property name="monitorVNC-0" type="empty"><property name="workspace0" type="empty">
      <property name="color-style" type="int" value="0"/>
      <property name="image-style" type="int" value="0"/>
      <property name="rgba1" type="array">
        <value type="double" value="0.11"/><value type="double" value="0.106"/><value type="double" value="0.133"/><value type="double" value="1"/>
      </property>
    </property></property>
  </property></property>
</channel>
XML
(umask 077; printf '%s\n' "$1" | tigervncpasswd -f > ~/.vnc/passwd)
printf '#!/bin/sh\nunset SESSION_MANAGER DBUS_SESSION_BUS_ADDRESS\nexec dbus-launch --exit-with-session startxfce4\n' > ~/.vnc/xstartup
chmod +x ~/.vnc/xstartup
if ! pgrep -u viewer -x Xtigervnc >/dev/null; then
  tigervncserver :1 -localhost yes -SecurityTypes VncAuth -PasswordFile ~/.vnc/passwd \
    -geometry 1440x900 -xstartup ~/.vnc/xstartup >/tmp/viewer-vnc.log 2>&1
  DISPLAY=:1 xset s off -dpms 2>/dev/null || true  # no screen blanking
fi
# All addresses: the gateway reaches it on the private IP. The GCP firewall
# admits only the gateway's subnet, and the agent is blocked above.
if ! pgrep -u viewer -f 'websockify .*:6080 127.0.0.1:5901' >/dev/null; then
  nohup setsid websockify --web /usr/share/novnc 0.0.0.0:6080 127.0.0.1:5901 >/tmp/viewer-websockify.log 2>&1 </dev/null &
fi
if ! pgrep -u viewer -x firefox >/dev/null; then
  DISPLAY=:1 nohup setsid ~/fxa-firefox >/tmp/viewer-firefox.log 2>&1 </dev/null &
fi
VIEWER

# Fail closed: a desktop whose user reaches the internet is not served.
if sudo -u viewer timeout 5 bash -c 'exec 3<>/dev/tcp/1.1.1.1/443' 2>/dev/null \
   || sudo -u viewer timeout 5 bash -c 'exec 3<>/dev/tcp/169.254.169.254/80' 2>/dev/null; then
  pkill -u viewer || true
  echo "ERROR: the desktop user reached the internet or the metadata server; desktop stopped" >&2
  exit 1
fi

printf 'ip=%s\n' "$(hostname -I | awk '{print $1}')"
printf 'password=%s\n' "$pw"
