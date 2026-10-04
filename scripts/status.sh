#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# One-screen health report for this cluster. Read-only, safe to run any time.
#
#   ./status.sh          # overview
#   ./status.sh --full   # adds pod-to-pod DNS and egress tests
# ---------------------------------------------------------------------------
set -uo pipefail

KUBECTL=/usr/local/bin/kubectl
export KUBECONFIG=/root/.kube/config
FULL=0
[ "${1:-}" = "--full" ] && FULL=1

hr() { printf '%s\n' "-------------------------------------------------------------"; }

echo "=== node ==="
"$KUBECTL" get nodes -o wide 2>/dev/null
hr

echo "=== versions ==="
printf '  k3s     %s\n' "$(k3s --version 2>/dev/null | head -1)"
printf '  helm    %s\n' "$(helm version --short 2>/dev/null)"
printf '  kernel  %s\n' "$(uname -r)"
hr

echo "=== cluster facts ==="
if [ -f /root/cluster-facts.env ]; then
  while IFS='=' read -r k v; do printf '  %-20s %s\n' "$k" "$v"; done < /root/cluster-facts.env
else
  echo "  (run setup-k3s.sh to create /root/cluster-facts.env)"
fi
hr

echo "=== pods ==="
"$KUBECTL" get pods -A 2>/dev/null
hr

echo "=== helm releases ==="
helm list -A 2>/dev/null || echo "  (none)"
hr

echo "=== network plumbing ==="
printf '  %s\n' "$(ip -br addr show cni0 2>/dev/null)"
printf '  default route: %s\n' "$(ip route show default | head -1)"
if nft list table ip pod-egress >/dev/null 2>&1; then
  echo "  nft table pod-egress:"
  nft list table ip pod-egress | sed 's/^/    /'
else
  echo "  WARNING: nft table pod-egress is missing (watchdog should recreate it)"
fi
printf '  k3s supervisor: %s\n' "$(pgrep -f 'k3s-super[v]ise' | tr '\n' ' ')"
printf '  net watchdog  : %s\n' "$(pgrep -f 'k3s-net-watchdo[g]' | tr '\n' ' ')"
mesh=$(ss -ltn 2>/dev/null | grep -c ':2008')
printf '  mesh tunnels  : %s listener(s) on 2008x ports\n' "$mesh"
hr

if [ "$FULL" = "1" ]; then
  echo "=== live network tests (pod side) ==="
  ts=$(date +%s)
  "$KUBECTL" run "t-dns-$ts" --rm -i --restart=Never --image=busybox:1.36 -- \
    nslookup kubernetes.default.svc.cluster.local >/dev/null 2>&1 \
    && echo "  cluster DNS           ok" || echo "  cluster DNS           FAILED"
  "$KUBECTL" run "t-ext-$ts" --rm -i --restart=Never --image=busybox:1.36 -- \
    nslookup github.com >/dev/null 2>&1 \
    && echo "  external DNS          ok" || echo "  external DNS          FAILED"
  ext=$("$KUBECTL" run "t-https-$ts" --rm -i --restart=Never --image=busybox:1.36 -- \
    wget -qO- -T8 https://ifconfig.me 2>/dev/null)
  [ -n "$ext" ] && echo "  external HTTPS egress ${ext}" || echo "  external HTTPS egress FAILED"
  hr
fi

echo "=== mesh services ==="
if [ -d /etc/mesh-services ]; then
  /usr/local/bin/mesh-service.sh list 2>/dev/null || echo "  (none)"
else
  echo "  (none)"
fi