#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# One-shot Kubernetes (k3s) bootstrap for Railway-style sandboxes.
#
# This host is a container-style VM, so the normal installer fails. Handled:
#   1. no init system (no systemd/openrc)  -> k3s under a supervisor loop
#   2. kernel has no vxlan                 -> flannel off, bridge CNI instead
#   3. kernel has no legacy iptables tables-> kube-proxy in nftables mode,
#                                           k3s ServiceLB disabled
#   4. bridge CNI leaves the gateway unset -> re-applied by a watchdog
#   5. no SNAT for pods / v6-only DNS      -> own nat table + coredns v4 upstream
#
# Idempotent: wipes nothing, stops old runs, then provisions everything.
# Usage:  bash setup-k3s.sh
# ---------------------------------------------------------------------------
set -uo pipefail

POD_SUBNET="${POD_SUBNET:-10.42.0.0/24}"     # node PodCIDR (single node)
POD_GW="${POD_GW:-10.42.0.1}"
BRIDGE=cni0
POD_CIDR=10.42.0.0/16
K3S_LOG=/var/log/k3s.log
SUPERVISOR=/usr/local/bin/k3s-supervise.sh
WATCHDOG=/usr/local/bin/k3s-net-watchdog.sh
SHARE_KUBECONFIG=/root/kubeconfig-share.yaml

log()  { printf '[setup-k3s] %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# --- 0. stop previous run (idempotency) ------------------------------------
log "stopping previous runs"
pkill -f k3s-supervise 2>/dev/null
pkill -f k3s-net-watchdog 2>/dev/null
pkill -x k3s 2>/dev/null
sleep 2
# k3s spawns its own containerd - never touch docker's
for p in $(pgrep -x containerd 2>/dev/null); do
  tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q docker || kill "$p" 2>/dev/null
done

# --- 1. k3s binary --------------------------------------------------------
if ! have k3s; then
  log "installing k3s"
  curl -sfL -o /usr/local/bin/k3s https://github.com/k3s-io/k3s/releases/latest/download/k3s
  chmod +x /usr/local/bin/k3s
fi
ln -sf /usr/local/bin/k3s /usr/local/bin/kubectl
ln -sf /usr/local/bin/k3s /usr/local/bin/crictl
log "k3s $(k3s --version | head -1)"

# --- 2. helm --------------------------------------------------------------
if ! have helm; then
  log "installing helm"
  hv=$(curl -fsSL https://get.helm.sh/helm-latest-version | tr -d '\r\n' | sed 's/^v//')
  curl -sfL -o /tmp/helm.tgz "https://get.helm.sh/helm-v${hv}-linux-amd64.tar.gz"
  tar -xzf /tmp/helm.tgz -C /tmp && install -m 0755 /tmp/linux-amd64/helm /usr/local/bin/helm
  rm -rf /tmp/linux-amd64 /tmp/helm.tgz
fi
log "helm $(helm version --short 2>/dev/null)"

# --- 3. CNI plugins -------------------------------------------------------
install -d /opt/cni/bin
if [ ! -x /opt/cni/bin/bridge ]; then
  log "installing CNI plugins"
  url=$(curl -fsSL https://api.github.com/repos/containernetworking/plugins/releases/latest \
        | grep -m1 'cni-plugins-linux-amd64.*tgz"' | cut -d'"' -f4)
  [ -n "$url" ] || url=https://github.com/containernetworking/plugins/releases/download/v1.9.1/cni-plugins-linux-amd64-v1.9.1.tgz
  curl -sfL -o /tmp/cni.tgz "$url" && tar -xzf /tmp/cni.tgz -C /opt/cni/bin && rm -f /tmp/cni.tgz
fi

# --- 4. network mode the kernel can actually do ---------------------------
NODE_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
[ -n "$NODE_IP" ] || NODE_IP=$(hostname -i | awk '{print $1}')
log "node ip $NODE_IP"

if ip link add k3sprobe type vxlan id 4242 dstport 4789 >/dev/null 2>&1; then
  ip link del k3sprobe 2>/dev/null
  log "vxlan available -> flannel vxlan"
  NET_ARGS="--flannel-backend=vxlan"
  rm -f /etc/cni/net.d/10-bridge.conflist
else
  log "no vxlan -> flannel disabled, bridge CNI"
  NET_ARGS="--flannel-backend=none --disable-network-policy"
  install -d /etc/cni/net.d
  rm -f /etc/cni/net.d/10-flannel.conflist
  cat > /etc/cni/net.d/10-bridge.conflist <<JSON
{
  "cniVersion": "0.4.0",
  "name": "k3s-bridge",
  "plugins": [
    {
      "type": "bridge",
      "bridge": "${BRIDGE}",
      "isLayer3": true,
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
  log "wrote /etc/cni/net.d/10-bridge.conflist (${POD_SUBNET})"
  # The bridge plugin does not configure the L3 gateway on this kernel, and pods
  # created before it exists get a broken network. Build the bridge up front.
  ip link show "$BRIDGE" >/dev/null 2>&1 || ip link add "$BRIDGE" type bridge
  ip addr replace "${POD_GW}/24" dev "$BRIDGE"
  ip link set "$BRIDGE" up
  log "pre-created $BRIDGE with ${POD_GW}/24"
fi

# servicelb (klipper) needs legacy iptables tables -> it cannot run here
SERVER_FLAGS="server $NET_ARGS --disable=servicelb \
--kube-proxy-arg=proxy-mode=nftables \
--node-ip=$NODE_IP --tls-san=$NODE_IP --tls-san=localhost --tls-san=127.0.0.1"

# --- 5. watchdog: gateway IP + pod egress SNAT ----------------------------
cat > "$WATCHDOG" <<WD
#!/usr/bin/env bash
# Re-applies host networking bits the bridge CNI does not do on this kernel.
while sleep 10; do
  if ip link show ${BRIDGE} >/dev/null 2>&1; then
    ip addr replace ${POD_GW}/24 dev ${BRIDGE} 2>/dev/null
  fi
  if ! nft list table ip pod-egress >/dev/null 2>&1; then
    nft add table ip pod-egress 2>/dev/null
    nft add chain ip pod-egress postrouting '{ type nat hook postrouting priority 100; policy accept; }' 2>/dev/null
    nft add rule ip pod-egress postrouting ip saddr ${POD_CIDR} oifname != ${BRIDGE} masquerade 2>/dev/null
  fi
done
WD
chmod +x "$WATCHDOG"
setsid nohup "$WATCHDOG" >/var/log/k3s-watchdog.log 2>&1 < /dev/null &
log "watchdog started (gateway on ${BRIDGE} + nft masquerade)"

# --- 6. start k3s (systemd if present, else supervisor loop) --------------
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
  log "no init system -> supervisor loop"
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
  log "supervisor started ($SUPERVISOR)"
fi

# --- 7. coredns upstream: host resolver is IPv6-only on Railway ----------
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
CM=/var/lib/rancher/k3s/server/manifests/coredns.yaml
log "coredns upstream patch prepared"

# --- 8. wait for cluster ---------------------------------------------------
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
# k3s rewrites this manifest on every start, so patch it only once we are up
if [ -f "$CM" ]; then
  sed -i 's#forward \. /etc/resolv\.conf#forward . 1.1.1.1 8.8.8.8#' "$CM"
  k3s kubectl apply -f "$CM" >/dev/null 2>&1
  k3s kubectl -n kube-system rollout restart deploy/coredns >/dev/null 2>&1
  log "coredns upstream -> 1.1.1.1 8.8.8.8 (pod egress DNS works)"
fi
log "waiting for coredns"
for _ in $(seq 1 30); do
  k3s kubectl -n kube-system get pod -l k8s-app=kube-dns -o jsonpath='{.items[*].status.containerStatuses[*].ready}' 2>/dev/null | grep -q true && break
  sleep 5
done

# --- 9. kubeconfigs -------------------------------------------------------
install -d -m 700 /root/.kube
k3s kubectl config view --raw > /root/.kube/config 2>/dev/null \
  || install -m 600 /etc/rancher/k3s/k3s.yaml /root/.kube/config
sed "s#https://127.0.0.1:6443#https://${NODE_IP}:6443#g" /etc/rancher/k3s/k3s.yaml > "$SHARE_KUBECONFIG"
chmod 600 "$SHARE_KUBECONFIG" /root/.kube/config

# --- 10. report -----------------------------------------------------------
log "cluster status"
k3s kubectl get nodes
k3s kubectl get pods -A
cat <<EOF

  ready. how to use it
  ------------------------------------------------------------------
  on this host:      kubectl / helm  (kubeconfig at /root/.kube/config)
  your friend:       scp root@${NODE_IP}:${SHARE_KUBECONFIG} ./kubeconfig.yaml
                     kubectl --kubeconfig ./kubeconfig.yaml get nodes
  if port 6443 is firewalled:
                     ssh -L 6443:127.0.0.1:6443 <this-vm>
                     # then set server: https://127.0.0.1:6443 in kubeconfig.yaml
  re-provision (e.g. Railway replaced the VM):
                     bash /root/setup-k3s.sh
EOF