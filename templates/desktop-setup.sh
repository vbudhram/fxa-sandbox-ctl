#!/bin/bash
# Runs as root on a session runner: a Linux desktop a person can open through
# noVNC. Safe to run again; the last line is the VNC password.
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
if ! iptables -C OUTPUT -m owner --uid-owner "$v" -o lo -j ACCEPT 2>/dev/null; then
  iptables -A OUTPUT -m owner --uid-owner "$v" -o lo -j ACCEPT
  # The content server links to the VM's own address, not localhost.
  for ip in $(hostname -I); do iptables -A OUTPUT -m owner --uid-owner "$v" -d "$ip" -j ACCEPT; done
  iptables -A OUTPUT -m owner --uid-owner "$v" -j REJECT
fi
iptables -C OUTPUT -m owner --uid-owner "$a" -o lo -p tcp -m multiport --dports 5901,6080 -j REJECT 2>/dev/null \
  || iptables -I OUTPUT 1 -m owner --uid-owner "$a" -o lo -p tcp -m multiport --dports 5901,6080 -j REJECT

# websockify accepts any origin, so a page in the person's browser could reach
# the tunnel; a password per runner stops it.
if [ ! -s /root/.desktop-password ]; then
  (umask 077; openssl rand -base64 12 | tr -dc 'A-Za-z0-9' | cut -c1-8 > /root/.desktop-password)
fi
pw="$(cat /root/.desktop-password)"

sudo -u viewer -H bash -s "$pw" <<'VIEWER'
set -euo pipefail
cd ~
mkdir -p ~/.vnc ~/Desktop
ln -sfn /srv/workspace ~/Desktop/fxa
(umask 077; printf '%s\n' "$1" | tigervncpasswd -f > ~/.vnc/passwd)
printf '#!/bin/sh\nunset SESSION_MANAGER DBUS_SESSION_BUS_ADDRESS\nexec dbus-launch --exit-with-session startxfce4\n' > ~/.vnc/xstartup
chmod +x ~/.vnc/xstartup
if ! pgrep -u viewer -x Xtigervnc >/dev/null; then
  tigervncserver :1 -localhost yes -SecurityTypes VncAuth -PasswordFile ~/.vnc/passwd \
    -geometry 1440x900 -xstartup ~/.vnc/xstartup >/tmp/viewer-vnc.log 2>&1
fi
if ! pgrep -u viewer -f 'websockify .*127.0.0.1:6080' >/dev/null; then
  nohup setsid websockify --web /usr/share/novnc 127.0.0.1:6080 127.0.0.1:5901 >/tmp/viewer-websockify.log 2>&1 </dev/null &
fi
if ! pgrep -u viewer -x firefox >/dev/null; then
  DISPLAY=:1 nohup setsid firefox http://localhost:3030/ >/tmp/viewer-firefox.log 2>&1 </dev/null &
fi
VIEWER

printf 'password=%s\n' "$pw"
