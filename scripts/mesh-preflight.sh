#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# What can this VM actually use to reach another cluster?
#
#   ./mesh-preflight.sh [peer-private-ip]
#
# Sandbox VMs differ from normal cloud VMs: this probes the kernel, the network
# path and the firewall, then prints which multi-cluster transports are usable.
# Run it on BOTH VMs and compare before designing the mesh.
# ---------------------------------------------------------------------------
set -uo pipefail

PEER_IP="${1:-}"
ok()   { printf '  %-38s %s\n' "$1" "$2"; }
bad()  { printf '  %-38s %s\n' "$1" "$2"; }

echo "=== host ==="
ok "hostname"            "$(hostname)"
ok "kernel"              "$(uname -r)"
ok "init system"         "$([ -d /run/systemd/system ] && echo systemd || echo 'none (no systemd/openrc)')"
ok "cpu / memory"        "$(nproc) cores / $(awk '/MemTotal/{printf "%.1f GiB", $2/1048576}' /proc/meminfo)"
ok "disk free"           "$(df -h / | awk 'NR==2{print $4}')"
ok "private ip"          "$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
ok "public ipv4 (egress)" "$(curl -s -m 6 https://api.ipify.org || echo 'unknown')"
ok "public ipv6 (egress)" "$(curl -s -m 6 -6 https://api64.ipify.org || echo 'none')"

echo
echo "=== kernel network features ==="
if ip link add preflightvx type vxlan id 4299 dstport 4789 >/dev/null 2>&1; then
  ip link del preflightvx 2>/dev/null; ok "vxlan" "available (flannel default works)"
else
  bad "vxlan" "NOT available -> flannel must be disabled"
fi
if ip link add preflightwg type wireguard >/dev/null 2>&1; then
  ip link del preflightwg 2>/dev/null; ok "wireguard (kernel)" "available"
else
  bad "wireguard (kernel)" "NOT available -> kernel WireGuard impossible here"
fi
if [ -c /dev/net/tun ]; then
  ok "/dev/net/tun" "present (userspace wireguard/tailscale possible)"
else
  bad "/dev/net/tun" "missing -> userspace VPN impossible"
fi
ok "ip_forward"          "$(cat /proc/sys/net/ipv4/ip_forward)"
if iptables -t nat -L >/dev/null 2>&1; then
  ok "legacy iptables" "usable"
else
  bad "legacy iptables" "no nat/filter tables -> kube-proxy needs nftables mode"
fi
ok "nftables"            "$(nft --version 2>/dev/null | head -1 || echo missing)"

echo
echo "=== egress paths ==="
if curl -s -m 6 -o /dev/null https://get.helm.sh/; then
  ok "TCP 443 out" "yes (https works)"
else
  bad "TCP 443 out" "NO"
fi
udp="unknown"
if command -v python3 >/dev/null 2>&1; then
  udp=$(python3 - <<'PY'
import socket
q = (bytes.fromhex('abcd01000001000000000000')
     + b'\x03www\x07github\x03com\x00' + bytes.fromhex('00010001'))
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(4)
s.sendto(q, ('1.1.1.1', 53))
try:
    s.recvfrom(512); print('yes')
except Exception:
    print('no')
PY
)
fi
ok "UDP 53 out (dns)"   "$udp"
if [ "$udp" = "no" ]; then
  bad "UDP in general" "blocked -> any UDP VPN (wireguard, tailscale direct) will not connect; relays over TCP/443 are the only option"
else
  ok "UDP in general" "reachable"
fi

echo
echo "=== transport verdict ==="
printf '  %-38s %s\n' "ssh L4 mesh (scripts/mesh-service.sh)" "USE THIS - needs only TCP 22, already proven on this host"
printf '  %-38s %s\n' "provider private network (10.x peers)" "test it: ping -c2 $PEER_IP  (fill in the peer ip, run on both VMs)"
if [ -c /dev/net/tun ] && [ "$udp" = "yes" ]; then
  printf '  %-38s %s\n' "wireguard / tailscale L3 mesh" "possible (userspace), needs the peer tunnel subnets to differ"
elif [ -c /dev/net/tun ]; then
  printf '  %-38s %s\n' "wireguard / tailscale L3 mesh" "needs a relay: Tailscale DERP over TCP 443 can work, plain WireGuard cannot"
else
  printf '  %-38s %s\n' "wireguard / tailscale L3 mesh" "not possible on this host"
fi
printf '  %-38s %s\n' "submariner / karmada federation" "needs kernel wireguard or a routable L3 -> treat as a phase-2 project"
if [ -n "$PEER_IP" ]; then
  echo
  echo "=== peer ${PEER_IP} ==="
  ping -c 3 -W 2 "$PEER_IP" >/dev/null 2>&1 \
    && echo "  ICMP to the peer works -> provider network may be routable (try pod CIDR ranges too)" \
    || echo "  no ICMP to the peer -> use the ssh L4 mesh"
fi
cat <<'EOF'

=== what to build, in order ===
  1. control plane : one kubeconfig, one context per cluster (scripts/kubeconfig-merge.sh)
  2. service access: ssh L4 mesh + service-mirror chart (scripts/mesh-service.sh)
  3. observability : per-cluster metrics, remote_write to one Prometheus/Grafana
  4. optional L3   : tailscale/wireguard when both hosts allow it, then the
                     service-mirror endpoints become plain routable pod IPs
EOF