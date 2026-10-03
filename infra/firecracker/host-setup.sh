#!/bin/bash
# host-setup.sh: prepare a GCE host with nested virtualization to run
# Firecracker slots. Run once as root; safe to run again.
#   Firecracker in /usr/local/bin, a Docker-capable guest kernel in /fc/vmlinux,
#   the data disk as XFS (reflink copies) on /fc, IP forwarding on.
set -euo pipefail
FC_VERSION="${FC_VERSION:-v1.17.0}"
KERNEL_VERSION="${KERNEL_VERSION:-6.18}"
[ -e /dev/kvm ] || { echo "ERROR: no /dev/kvm; create the host with --enable-nested-virtualization" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq xfsprogs qemu-utils e2fsprogs iptables iproute2 jq curl rsync \
  build-essential flex bison bc libelf-dev libssl-dev dwarves >/dev/null

# The data disk: XFS so `cp --reflink` gives each slot its own disk at once.
dev=/dev/disk/by-id/google-data
if ! mountpoint -q /fc; then
  blkid "$dev" >/dev/null 2>&1 || mkfs.xfs -q -m reflink=1 "$dev"
  mkdir -p /fc
  grep -q ' /fc ' /etc/fstab || echo "$dev /fc xfs defaults,nofail 0 2" >> /etc/fstab
  mount /fc
fi
mkdir -p /fc/build /fc/snap /fc/slots /fc/run

if ! [ -x /usr/local/bin/firecracker ] || ! firecracker --version | grep -q "${FC_VERSION#v}"; then
  curl -fsSL "https://github.com/firecracker-microvm/firecracker/releases/download/${FC_VERSION}/firecracker-${FC_VERSION}-x86_64.tgz" | tar -xz -C /tmp
  install -m 755 "/tmp/release-${FC_VERSION}-x86_64/firecracker-${FC_VERSION}-x86_64" /usr/local/bin/firecracker
  install -m 755 "/tmp/release-${FC_VERSION}-x86_64/jailer-${FC_VERSION}-x86_64" /usr/local/bin/jailer
fi
firecracker --version | head -1

# Guest kernel: Firecracker's CI config plus what Docker and the runner's
# egress firewall need. No modules, so every option is built in.
if [ ! -f /fc/vmlinux ]; then
  cd /fc/build
  [ -d "linux-${KERNEL_VERSION}" ] || curl -fsSL "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KERNEL_VERSION}.tar.xz" | tar -xJ
  cd "linux-${KERNEL_VERSION}"
  curl -fsSL "https://raw.githubusercontent.com/firecracker-microvm/firecracker/${FC_VERSION}/resources/guest_configs/microvm-kernel-ci-x86_64-${KERNEL_VERSION}.config" -o .config
  scripts/config --disable MODULES \
    --enable NAMESPACES --enable NET_NS --enable PID_NS --enable IPC_NS --enable UTS_NS --enable USER_NS \
    --enable CGROUPS --enable CGROUP_BPF --enable CGROUP_CPUACCT --enable CGROUP_DEVICE --enable CGROUP_FREEZER \
    --enable CGROUP_PIDS --enable CGROUP_SCHED --enable CPUSETS --enable MEMCG --enable BLK_CGROUP --enable CFS_BANDWIDTH \
    --enable OVERLAY_FS --enable BRIDGE --enable BRIDGE_NETFILTER --enable VETH --enable MACVLAN --enable VXLAN --enable DUMMY \
    --enable NETFILTER --enable NETFILTER_ADVANCED --enable NF_CONNTRACK --enable NF_NAT --enable NF_TABLES --enable NF_TABLES_INET \
    --enable NFT_COMPAT --enable NFT_NAT --enable NFT_MASQ --enable NFT_CT --enable NFT_REJECT --enable NFT_CHAIN_NAT \
    --enable IP_NF_IPTABLES --enable IP_NF_FILTER --enable IP_NF_NAT --enable IP_NF_TARGET_MASQUERADE --enable IP_NF_TARGET_REJECT \
    --enable IP_NF_MANGLE --enable IP_NF_RAW --enable IP6_NF_IPTABLES --enable IP6_NF_FILTER --enable IP6_NF_NAT --enable IP6_NF_TARGET_REJECT \
    --enable NETFILTER_XTABLES --enable NETFILTER_XT_MATCH_ADDRTYPE --enable NETFILTER_XT_MATCH_CONNTRACK --enable NETFILTER_XT_MATCH_OWNER \
    --enable NETFILTER_XT_MATCH_MULTIPORT --enable NETFILTER_XT_MATCH_STATE --enable NETFILTER_XT_MATCH_COMMENT --enable NETFILTER_XT_MATCH_MARK \
    --enable NETFILTER_XT_MATCH_IPVS --enable NETFILTER_XT_TARGET_MASQUERADE --enable NETFILTER_XT_TARGET_REDIRECT --enable NETFILTER_XT_NAT \
    --enable NETFILTER_XT_MARK --enable NETFILTER_XT_TARGET_LOG --enable IP_VS --enable IP_VS_NFCT --enable IP_VS_RR \
    --enable POSIX_MQUEUE --enable KEYS --enable SECCOMP --enable SECCOMP_FILTER --enable FUSE_FS --enable TUN \
    --enable MEMCG_SWAP --enable SWAP --enable EXT4_FS_POSIX_ACL --enable EXT4_FS_SECURITY --enable TMPFS_POSIX_ACL \
    --enable VIRTIO_VSOCKETS --enable VMGENID
  make olddefconfig >/dev/null
  make -j"$(nproc)" vmlinux >/fc/build/kernel.log 2>&1 || { tail -30 /fc/build/kernel.log; exit 1; }
  cp vmlinux /fc/vmlinux
fi
grep -q '=y' <(grep -E '^CONFIG_OVERLAY_FS=|^CONFIG_NETFILTER_XT_MATCH_OWNER=|^CONFIG_BRIDGE=' /fc/build/linux-${KERNEL_VERSION}/.config) && echo "kernel ok: $(ls -la /fc/vmlinux | awk '{print $5}') bytes"

# Slots route through the host: forward, loose reverse-path check.
cat > /etc/sysctl.d/90-fc.conf <<'SYSCTL'
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
SYSCTL
sysctl -q --system
# Guest traffic to the internet leaves as the host (Cloud NAT knows only the
# host); traffic to the VPC keeps the slot's own address, so replies route back.
iptables -t nat -C POSTROUTING -s 10.42.16.0/24 ! -d 10.42.0.0/16 -j MASQUERADE 2>/dev/null \
  || iptables -t nat -A POSTROUTING -s 10.42.16.0/24 ! -d 10.42.0.0/16 -j MASQUERADE
[ -f /fc/host_key ] || ssh-keygen -t ed25519 -N "" -q -f /fc/host_key -C fc-host
# Keep the snapshot near main: a session on an old one fetches, and after a
# yarn.lock change it installs for 40 s or more. fc-refresh does nothing when
# main has not moved. Installed by hand beside this script: fc, fc-make-snapshot, fc-refresh,
# and fc-idle-stop (idle-stop.sh).
cat > /etc/systemd/system/fc-refresh.service <<'UNIT'
[Unit]
Description=Refresh the Firecracker snapshot when main moved
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/fc-refresh
UNIT
cat > /etc/systemd/system/fc-refresh.timer <<'UNIT'
[Unit]
Description=Check main for a new snapshot every 30 minutes
[Timer]
OnBootSec=5min
OnUnitActiveSec=30min
[Install]
WantedBy=timers.target
UNIT
# On demand: a controller starts the host for a session; the host stops itself after
# 30 minutes with no slot in use (idle-stop.sh), so no controller decides for the others.
cat > /etc/systemd/system/fc-idle-stop.service <<'UNIT'
[Unit]
Description=Power off after 30 minutes with no Firecracker slot in use
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/fc-idle-stop
UNIT
cat > /etc/systemd/system/fc-idle-stop.timer <<'UNIT'
[Unit]
Description=Check for an idle host every minute
[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now fc-refresh.timer fc-idle-stop.timer
echo "host ready"
