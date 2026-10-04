#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# One-shot Kubernetes (k3s) bootstrap for container-style sandbox VMs.
#
# Written against a host that fights back. Every workaround below exists
# because the stock path failed on it:
#
#   1. no init system (no systemd/openrc)
#        -> k3s runs under a supervisor loop that restarts it forever
#   2. kernel has no vxlan
#        -> flannel disabled, plain bridge CNI instead
#   3. kernel has no legacy iptables tables (nat/filter)
#        -> kube-proxy in nftables mode, k3s ServiceLB disabled
#   4. bridge CNI never configures the L3 gateway, and pods that get created
#      before the bridge exists come up with a broken network
#        -> bridge + gateway IP are created before k3s starts, and a watchdog
#           re-applies them forever
#   5. no SNAT for pod traffic, host resolver is IPv6-only
#        -> own nftables masquerade table, CoreDNS forced to IPv4 upstreams
#
# MULTI-CLUSTER: every cluster must own disjoint CIDRs, so the pod/service
# ranges are parameters. For a second cluster use e.g.
#
#   POD_CIDR=10.44.0.0/16 POD_SUBNET=10.44.0.0/24 SERVICE_CIDR=10.45.0.0/16 \
#   APISERVER_ADVERTISE=<reachable-ip> TLS_SANS=<reachable-ip> \
#   PEER_CIDRS="10.42.0.0/16 10.43.0.0/16" \
#   bash setup-k3s.sh
#
# Usage:
#   bash setup-k3s.sh              # provision / re-provision (idempotent)
#   RENDER_ONLY=1 bash setup-k3s.sh # write configs to /tmp/k3s-render, start
#                                   # nothing (used to validate parameters)
# ---------------------------------------------------------------------------
set -uo pipefail

# ---- parameters (all overridable from the environment) ---------------------
POD_CIDR="${POD_CIDR:-10.42.0.0/16}"          # cluster-wide pod range
POD_SUBNET="${POD_SUBNET:-10.42.0.0/24}"      # this node's slice of it
SERVICE_CIDR="${SERVICE_CIDR:-10.43.0.0/16}"  # service ClusterIP range
BRIDGE="${BRIDGE:-cni0}"
MTU="${MTU:-1500}"                            # use 1380 when peering over a mesh
TLS_SANS="${TLS_SANS:-}"                      # extra cert SANs: mesh IPs, DNS names
APISERVER_ADVERTISE="${APISERVER_ADVERTISE:-}"  # IP the friend connects to (default: node IP)
PEER_CIDRS="${PEER_CIDRS:-}"                  # peer pod/service CIDRs, space separated
EXTRA_SERVER_FLAGS="${EXTRA_SERVER_FLAGS:-}"
RENDER_ONLY="${RENDER_ONLY:-0}"
RENDER_DIR="${RENDER_DIR:-/tmp/k3s-render}"
K3S_VERSION="${K3S_VERSION:-}"               # e.g. v1.37.1+k3s1 (default: latest)

K3S_LOG=/var/log/k3s.log
SUPERVISOR=/usr/local/bin/k3s-supervise.sh
WATCHDOG=/usr/local/bin/k3s-net-watchdog.sh
FACTS=/root/cluster-facts.env
SHARE_KUBECONFIG=/root/kubeconfig-share.yaml

# gateway = first usable address of POD_SUBNET (10.42.0.0/24 -> 10.42.0.1)
net="${POD_SUBNET%/*}"
IFS=. read -r o1 o2 o3 o4 <<<"$net"
POD_GW="${POD_GW:-${o1}.${o2}.${o3}.$((o4 + 1))}"
GW_PREFIX="${POD_SUBNET#*/}"

log()  { printf '[setup-k3s] %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# write a config file either for real, or into RENDER_DIR when validating
render() {
  local dest="$1"
  if [ "$RENDER_ONLY" = "1" ]; then
    install -d "$RENDER_DIR"
    cat > "$RENDER_DIR/$(printf '%s' "$dest" | tr '/' '_')"
  else
    cat > "$dest"
  fi
}

# --- 0. stop whatever the previous run left behind ---------------------------
if [ "$RENDER_ONLY" = "1" ]; then
  log "RENDER_ONLY=1 -> writing configs only, not touching the running cluster"
else
  log "stopping previous runs"
  pkill -f k3s-supervise 2>/dev/null
  pkill -f k3s-net-watchdog 2>/dev/null
  pkill -f mesh-service- 2>/dev/null
  pkill -x k3s 2>/dev/null
  sleep 2
  # k3s starts its own containerd - never touch the docker one
  for p in $(pgrep -x containerd 2>/dev/null); do
    tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q docker || kill "$p" 2>/dev/null
  done
fi

# --- 1. k3s ------------------------------------------------------------------
if ! have k3s; then
  log "installing k3s"
  if [ -n "$K3S_VERSION" ]; then
    curl -sfL -o /usr/local/bin/k3s \
      "https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION/+/%2B}/k3s"
  else
    curl -sfL -o /usr/local/bin/k3s \
      https://github.com/k3s-io/k3s/releases/latest/download/k3s
  fi
  chmod +x /usr/local/bin/k3s
fi
ln -sf /usr/local/bin/k3s /usr/local/bin/kubectl
ln -sf /usr/local/bin/k3s /usr/local/bin/crictl
log "k3s $(k3s --version 2>/dev/null | head -1)"

# --- 2. helm ----------------------------------------------------------------
if ! have helm; then
  log "installing helm"
  hv=$(curl -fsSL https://get.helm.sh/helm-latest-version | tr -d '\r\n' | sed 's/^v//')
  curl -sfL -o /tmp/helm.tgz "https://get.helm.sh/helm-v${hv}-linux-amd64.tar.gz"
  tar -xzf /tmp/helm.tgz -C /tmp && install -m 0755 /tmp/linux-amd64/helm /usr/local/bin/helm
  rm -rf /tmp/linux-amd64 /tmp/helm.tgz
fi
log "helm $(helm version --short 2>/dev/null)"

# --- 3. CNI plugins (bridge / host-local / loopback) ------------------------
if [ "$RENDER_ONLY" != "1" ]; then
  install -d /opt/cni/bin
  if [ ! -x /opt/cni/bin/bridge ]; then
    log "installing CNI plugins"
    url=$(curl -fsSL https://api.github.com/repos/containernetworking/plugins/releases/latest \
          | grep -m1 'cni-plugins-linux-amd64.*tgz"' | cut -d'"' -f4)
    [ -n "$url" ] || url=https://github.com/containernetworking/plugins/releases/download/v1.9.1/cni-plugins-linux-amd64-v1.9.1.tgz
    curl -sfL -o /tmp/cni.tgz "$url" && tar -xzf /tmp/cni.tgz -C /opt/cni/bin && rm -f /tmp/cni.tgz
  fi
fi

# --- 4. pick a network mode the kernel can actually do ----------------------
NODE_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
[ -n "$NODE_IP" ] || NODE_IP=$(hostname -i | awk '{print $1}')
[ -n "$APISERVER_ADVERTISE" ] || APISERVER_ADVERTISE="$NODE_IP"
log "node ip $NODE_IP, apiserver advertised as $APISERVER_ADVERTISE"

if ip link add k3sprobe type vxlan id 4242 dstport 4789 >/dev/null 2>&1; then
  ip link del k3sprobe 2>/dev/null
  log "vxlan available -> flannel vxlan"
  NET_ARGS="--flannel-backend=vxlan"
  if [ "$RENDER_ONLY" != "1" ]; then rm -f /etc/cni/net.d/10-bridge.conflist; fi
else
  log "no vxlan support -> flannel disabled, bridge CNI"
  NET_ARGS="--flannel-backend=none --disable-network-policy"
  [ "$RENDER_ONLY" = "1" ] || install -d /etc/cni/net.d

  # The generated conflist is the single most important file in this setup:
  #  - ipam range/gateway must match POD_SUBNET
  #  - routes MUST contain the default route, otherwise pods can only reach
  #    other pods and never leave the node (this is why a first attempt left
  #    CoreDNS and every addon CrashLooping)
  #  - mtu is lowered when a mesh tunnel is in the path
  render /etc/cni/net.d/10-bridge.conflist <<JSON
{
  "cniVersion": "0.4.0",
  "name": "k3s-bridge",
  "plugins": [
    {
      "type": "bridge",
      "bridge": "${BRIDGE}",
      "isLayer3": true,
      "mtu": ${MTU},
      "ipam": {
        "type": "host-local",
        "ranges": [[{ "subnet": "${POD_SUBNET}", "gateway": "${POD_GW}" }]],
        "routes": [{ "dst": "0.0.0.0/0", "gw": "${POD_GW}" }]
      }
    },
    { "type": "loopback" }
  ]
}
JSON
  log "wrote bridge CNI conflist: subnet ${POD_SUBNET} gw ${POD_GW} mtu ${MTU}"

  if [ "$RENDER_ONLY" != "1" ]; then
    rm -f /etc/cni/net.d/10-flannel.conflist
    # the bridge plugin does not configure the L3 gateway on this kernel, so the
    # bridge and its gateway IP have to exist before the first pod is created
    ip link show "$BRIDGE" >/dev/null 2>&1 || ip link add "$BRIDGE" type bridge
    ip link set "$BRIDGE" mtu "$MTU" 2>/dev/null
    ip addr replace "${POD_GW}/${GW_PREFIX}" dev "$BRIDGE"
    ip link set "$BRIDGE" up
    log "pre-created $BRIDGE with ${POD_GW}/${GW_PREFIX}"
  fi
fi

# --- 5. pod egress SNAT + forward rules -------------------------------------
# k3s' own nftables support is fine, but the legacy iptables tables this kernel
# lacks are what klipper-lb and iptables-mode kube-proxy need, hence both the
# nat table below and --disable=servicelb / proxy-mode=nftables.
PEER_RULES=""
for c in $PEER_CIDRS; do
  PEER_RULES="${PEER_RULES}    ip saddr ${c} accept comment \"peer ${c}\"
"
done
render /usr/local/bin/k3s-nft-rules.nft <<NFT
table ip pod-egress {
  chain forward {
    type filter hook forward priority filter; policy accept;
    ct state established,related accept
    ip saddr ${POD_CIDR} oifname "${BRIDGE}" accept
${PEER_RULES}  }
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr ${POD_CIDR} oifname != "${BRIDGE}" masquerade
  }
}
NFT
if [ "$RENDER_ONLY" != "1" ]; then
  nft delete table ip pod-egress 2>/dev/null
  nft -f /usr/local/bin/k3s-nft-rules.nft 2>/dev/null \
    || nft list table ip pod-egress >/dev/null 2>&1 \
    || log "WARNING: could not install nft table pod-egress"
  log "nft table pod-egress installed (masquerade ${POD_CIDR}, peer accepts: ${PEER_CIDRS:-none})"
fi

# --- 6. watchdog: re-apply the things the CNI/kernel will not keep ---------
render "$WATCHDOG" <<WD
#!/usr/bin/env bash
# Re-applies host networking the bridge CNI does not maintain on this kernel.
# Needed because a pod that starts before ${BRIDGE}/${POD_GW} exists keeps a
# half-configured network, and because a fresh VM can lose the nft table.
while sleep 10; do
  if ip link show ${BRIDGE} >/dev/null 2>&1; then
    ip addr replace ${POD_GW}/${GW_PREFIX} dev ${BRIDGE} 2>/dev/null
    ip link set ${BRIDGE} mtu ${MTU} 2>/dev/null
  fi
  if ! nft list table ip pod-egress >/dev/null 2>&1; then
    nft -f /usr/local/bin/k3s-nft-rules.nft 2>/dev/null
  fi
done
WD
chmod +x "$WATCHDOG"
if [ "$RENDER_ONLY" != "1" ]; then
  setsid nohup "$WATCHDOG" >/var/log/k3s-watchdog.log 2>&1 < /dev/null &
  log "watchdog started: $WATCHDOG"
fi

# --- 7. server flags --------------------------------------------------------
# servicelb (klipper) needs the legacy iptables tables -> cannot run here.
# --tls-san must include every address the friend will use, including a mesh
# address, otherwise their kubectl fails certificate verification.
SAN_ARGS="--tls-san=${NODE_IP} --tls-san=${APISERVER_ADVERTISE} --tls-san=localhost --tls-san=127.0.0.1"
for s in $TLS_SANS; do SAN_ARGS="${SAN_ARGS} --tls-san=${s}"; done

SERVER_FLAGS="server \
--cluster-cidr=${POD_CIDR} \
--service-cidr=${SERVICE_CIDR} \
${NET_ARGS} \
--disable=servicelb \
--kube-proxy-arg=proxy-mode=nftables \
--node-ip=${NODE_IP} \
${SAN_ARGS} \
${EXTRA_SERVER_FLAGS}"

# --- 8. start k3s (systemd when present, otherwise a supervisor loop) ------
if [ "$RENDER_ONLY" = "1" ]; then
  render "$SUPERVISOR" <<SUP
#!/usr/bin/env bash
# RENDER_ONLY preview of the supervisor that would run:
while true; do
  /usr/local/bin/k3s ${SERVER_FLAGS} >> ${K3S_LOG} 2>&1
  echo "[supervisor] k3s exited - restarting in 5s" >> ${K3S_LOG}
  sleep 5
done
SUP
  log "rendered supervisor with flags:"
  log "  k3s ${SERVER_FLAGS}"
  log "--- cluster facts preview ---"
  log "POD_CIDR=${POD_CIDR} POD_SUBNET=${POD_SUBNET} SERVICE_CIDR=${SERVICE_CIDR}"
  log "configs in ${RENDER_DIR}"
  exit 0
fi

if have systemctl && [ -d /run/systemd/system ]; then
  log "systemd detected -> unit file"
  cat > /etc/systemd/system/k3s.service <<UNIT
[Unit]
Description=Lightweight Kubernetes (k3s)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/k3s ${SERVER_FLAGS}
Restart=always
RestartSec=5
KillMode=process
Delegate=yes

[Install]
WantedBy=multi-user.target
UNIT
  systemctl enable --now k3s
else
  log "no init system -> supervisor loop (${SUPERVISOR})"
  cat > "$SUPERVISOR" <<SUP
#!/usr/bin/env bash
# Stands in for the service manager on a host without systemd/openrc.
while true; do
  /usr/local/bin/k3s ${SERVER_FLAGS} >> ${K3S_LOG} 2>&1
  echo "[supervisor] k3s exited rc=\$? - restarting in 5s" >> ${K3S_LOG}
  sleep 5
done
SUP
  chmod +x "$SUPERVISOR"
  setsid nohup "$SUPERVISOR" >/var/log/k3s-supervisor.log 2>&1 < /dev/null &
fi

# --- 9. wait for the cluster ----------------------------------------------
log "waiting for apiserver"
for _ in $(seq 1 90); do
  k3s kubectl get --raw /readyz >/dev/null 2>&1 && break
  sleep 4
done
log "waiting for node Ready"
for _ in $(seq 1 60); do
  k3s kubectl get node -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True && break
  sleep 5
done

# --- 10. coredns upstream: the host resolver here is IPv6-only -------------
CM=/var/lib/rancher/k3s/server/manifests/coredns.yaml
# k3s rewrites this manifest on every start, so patch it only once we are up
if [ -f "$CM" ]; then
  sed -i 's#forward \. /etc/resolv\.conf#forward . 1.1.1.1 8.8.8.8#' "$CM"
  k3s kubectl apply -f "$CM" >/dev/null 2>&1
  k3s kubectl -n kube-system rollout restart deploy/coredns >/dev/null 2>&1
  log "coredns upstream -> 1.1.1.1 8.8.8.8"
fi
log "waiting for coredns"
for _ in $(seq 1 30); do
  k3s kubectl -n kube-system get pod -l k8s-app=kube-dns -o jsonpath='{.items[*].status.containerStatuses[*].ready}' 2>/dev/null | grep -q true && break
  sleep 5
done

# --- 11. kubeconfigs -------------------------------------------------------
install -d -m 700 /root/.kube
k3s kubectl config view --raw > /root/.kube/config 2>/dev/null \
  || install -m 600 /etc/rancher/k3s/k3s.yaml /root/.kube/config
sed "s#https://127.0.0.1:6443#https://${APISERVER_ADVERTISE}:6443#g" \
  /etc/rancher/k3s/k3s.yaml > "$SHARE_KUBECONFIG"
chmod 600 "$SHARE_KUBECONFIG" /root/.kube/config

# facts file: the multi-cluster tooling and the docs read this.
# every value is quoted so this file is safe to `source` (the bare k3s version
# string contains spaces and parentheses, which broke sourcing).
FACTS_K3S_VERSION=$(k3s --version 2>/dev/null | head -1)
cat > "$FACTS" <<EOF
NODE_IP="${NODE_IP}"
APISERVER_ADVERTISE="${APISERVER_ADVERTISE}"
POD_CIDR="${POD_CIDR}"
POD_SUBNET="${POD_SUBNET}"
POD_GW="${POD_GW}"
SERVICE_CIDR="${SERVICE_CIDR}"
BRIDGE="${BRIDGE}"
MTU="${MTU}"
PEER_CIDRS="${PEER_CIDRS}"
K3S_VERSION="${FACTS_K3S_VERSION}"
CLUSTER_FACTS_UPDATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EOF
chmod 600 "$FACTS"
# prove it: the whole point of the file is that other scripts can source it
# shellcheck disable=SC1090
. "$FACTS" || { log "FATAL: $FACTS is not sourceable"; exit 1; }
log "facts file written and verified: $FACTS"

# --- 12. report ------------------------------------------------------------
log "cluster status"
k3s kubectl get nodes
k3s kubectl get pods -A
cat <<EOF

  ready. how to use it
  ------------------------------------------------------------------
  on this host:      kubectl / helm  (kubeconfig at /root/.kube/config)
  peer/friend:       scp root@${APISERVER_ADVERTISE}:${SHARE_KUBECONFIG} ./kubeconfig.yaml
                     (or: scp dev.new:${SHARE_KUBECONFIG} ./kubeconfig.yaml)
                     kubectl --kubeconfig ./kubeconfig.yaml get nodes
  if 6443 is not reachable from outside:
                     ssh -L 6443:127.0.0.1:6443 <this-vm>
                     # then set server: https://127.0.0.1:6443 in kubeconfig.yaml
  least-privilege access for a friend:
                     bash /root/shared-k3s-cluster/scripts/create-scoped-user.sh <name> [namespace]
  multi-cluster notes and the peer setup:
                     /root/shared-k3s-cluster/docs/MULTI-CLUSTER.md
  re-provision after Railway replaced the VM:
                     bash /root/setup-k3s.sh
EOF