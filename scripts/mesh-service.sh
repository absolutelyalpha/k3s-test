#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Cross-cluster service access over an ssh L4 tunnel.
#
#   ./mesh-service.sh add <name> <namespace> <peerSSH> <targetHost> <targetPort> [localPort]
#   ./mesh-service.sh list
#   ./mesh-service.sh status <name>
#   ./mesh-service.sh test <name>
#   ./mesh-service.sh remove <name>
#
# Example - reach web.default.svc.cluster.local:30269 in the friend cluster from
# this cluster:
#
#   ./mesh-service.sh add friend-web default friend-vm 10.43.131.95 30269
#
# What it does:
#   1. keeps an ssh tunnel alive:  0.0.0.0:<localPort> -> <targetHost>:<targetPort>
#      the far side of the tunnel resolves <targetHost> INSIDE the peer cluster,
#      so a peer ClusterIP that is unreachable from here still works
#   2. publishes a HEADLESS Service + EndpointSlice in this cluster whose only
#      endpoint is <thisNodeIP>:<localPort>
#   3. pods here then use <name>.<namespace>.svc.cluster.local:<localPort>
#
# Headless on purpose: CoreDNS returns the endpoint address directly and nothing
# is programmed by kube-proxy, which matters because k3s with the nftables proxy
# mode ignores hand written EndpointSlices for ClusterIP services. The price is
# no port translation, so the name resolves with the tunnel's own port.
#
# When the peer node is reachable directly (same provider private network), skip
# the tunnel entirely and use charts/service-mirror with the peer's node IP and
# NodePort.
# ---------------------------------------------------------------------------
set -uo pipefail

KUBECTL=/usr/local/bin/kubectl
CONF_DIR=/etc/mesh-services
FACTS=/root/cluster-facts.env

usage() { sed -n '2,30p' "$0"; }

need_kubectl() { command -v "$KUBECTL" >/dev/null || { echo "kubectl not found at $KUBECTL"; exit 1; }; }
need_ssh() {
  command -v ssh >/dev/null && return 0
  echo "installing openssh-client"
  apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq openssh-client >/dev/null 2>&1
  command -v ssh >/dev/null
}

free_port() {
  local p
  for p in "$@"; do
    ss -ltn 2>/dev/null | grep -q ":${p} " || { echo "$p"; return 0; }
  done
  return 1
}

cmd_add() {
  local name="${1:-}" ns="${2:-}" peer="${3:-}" target="${4:-}" tport="${5:-}"
  local lport="${6:-}"
  [ -n "$name" ] && [ -n "$ns" ] && [ -n "$peer" ] && [ -n "$target" ] && [ -n "$tport" ] \
    || { usage; exit 1; }
  echo "$name" | grep -Eq '^[a-z0-9]([-a-z0-9]*[a-z0-9])?$' || { echo "invalid name: $name"; exit 1; }
  need_kubectl; need_ssh

  # shellcheck disable=SC1091
  [ -f "$FACTS" ] && . "$FACTS"
  local node_ip="${NODE_IP:-$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')}"

  if [ -z "$lport" ]; then
    lport=$(free_port 20080 20081 20082 20083 20084 20085) \
      || { echo "give me an explicit local port, 20080-20085 are taken"; exit 1; }
  fi
  ss -ltn 2>/dev/null | grep -q ":${lport} " && { echo "local port ${lport} already in use"; exit 1; }

  install -d "$CONF_DIR"
  cat > "$CONF_DIR/${name}.conf" <<EOF
NAME=${name}
NAMESPACE=${ns}
PEER_SSH=${peer}
TARGET_HOST=${target}
TARGET_PORT=${tport}
LOCAL_PORT=${lport}
SERVICE_PORT=${lport}
NODE_IP=${node_ip}
CREATED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

  cat > "/usr/local/bin/mesh-keeper-${name}.sh" <<'KEEPER'
#!/usr/bin/env bash
# Keeps one ssh forward alive. Stands in for a systemd unit on a host without one.
# shellcheck disable=SC1090
. "REPLACED_BY_SETUP"
while true; do
  ssh -N \
      -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
      -o ExitOnForwardFailure=yes -o StrictHostKeyChecking=accept-new \
      -L 0.0.0.0:"LOCAL_PORT_PLACEHOLDER":"TARGET_HOST_PLACEHOLDER":"TARGET_PORT_PLACEHOLDER" \
      "PEER_SSH_PLACEHOLDER"
  echo "[keeper] tunnel closed rc=$? - reconnecting in 5s"
  sleep 5
done
KEEPER
  sed -i \
    -e "s#REPLACED_BY_SETUP#$CONF_DIR/${name}.conf#" \
    -e "s#LOCAL_PORT_PLACEHOLDER#${lport}#" \
    -e "s#TARGET_HOST_PLACEHOLDER#${target}#" \
    -e "s#TARGET_PORT_PLACEHOLDER#${tport}#" \
    -e "s#PEER_SSH_PLACEHOLDER#${peer}#" \
    "/usr/local/bin/mesh-keeper-${name}.sh"
  chmod +x "/usr/local/bin/mesh-keeper-${name}.sh"

  pkill -f "mesh-keeper-${name}" 2>/dev/null; sleep 1
  setsid nohup "/usr/local/bin/mesh-keeper-${name}.sh" > "/var/log/mesh-${name}.log" 2>&1 < /dev/null &

  # wait for the listener, then publish it as a Service in this cluster
  local waited=0
  while [ $waited -lt 15 ]; do
    ss -ltn 2>/dev/null | grep -q ":${lport} " && break
    sleep 1; waited=$((waited + 1))
  done
  if ss -ltn 2>/dev/null | grep -q ":${lport} "; then
    echo "tunnel up: 0.0.0.0:${lport} -> ${peer}:${target}:${tport}"
  else
    echo "WARNING: tunnel did not come up, see /var/log/mesh-${name}.log"
  fi

  cat <<EOF | "$KUBECTL" apply -f - >/dev/null
apiVersion: v1
kind: Service
metadata:
  name: ${name}
  namespace: ${ns}
  labels:
    k8s-app: cross-cluster-mirror
    cluster.mesh/peer: "true"
spec:
  # headless: DNS returns the tunnel address directly, kube-proxy stays out of it
  clusterIP: None
  sessionAffinity: None
  ports:
    - name: http
      port: ${lport}
      targetPort: ${lport}
      protocol: TCP
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: ${name}-mirror
  namespace: ${ns}
  labels:
    kubernetes.io/service-name: ${name}
    k8s-app: cross-cluster-mirror
addressType: IPv4
ports:
  - name: http
    port: ${lport}
    protocol: TCP
endpoints:
  - addresses:
      - ${node_ip}
EOF
  echo "mirror published: http://${name}.${ns}.svc.cluster.local:${lport}"
  echo "verify:  ./mesh-service.sh test ${name}"
}

cmd_status() {
  local name="${1:-}"
  [ -f "$CONF_DIR/${name}.conf" ] || { echo "no such mesh service: $name"; exit 1; }
  # shellcheck disable=SC1090
  . "$CONF_DIR/${name}.conf"
  echo "name          ${NAME}"
  echo "namespace     ${NAMESPACE}"
  echo "peer (ssh)    ${PEER_SSH}"
  echo "tunnel        0.0.0.0:${LOCAL_PORT} -> ${PEER_SSH}:${TARGET_HOST}:${TARGET_PORT}"
  echo "keeper        $(pgrep -f "mesh-keeper-${name}" | tr '\n' ' ')"
  if ss -ltn 2>/dev/null | grep -q ":${LOCAL_PORT} "; then
    echo "listener      up"
  else
    echo "listener      DOWN - tail /var/log/mesh-${name}.log"
  fi
  "$KUBECTL" -n "$NAMESPACE" get svc "$NAME" -o wide 2>/dev/null | sed 's/^/service       /'
  "$KUBECTL" -n "$NAMESPACE" get endpointslice "$NAME-mirror" \
    -o jsonpath='{.endpoints[*].addresses[*]}:{.ports[*].port}' 2>/dev/null \
    | sed 's/^/endpoints     /'
  echo
  echo "host-side test:"
  curl -s -m 8 -o /dev/null -w "  http://127.0.0.1:${LOCAL_PORT} -> %{http_code}\n" \
    "http://127.0.0.1:${LOCAL_PORT}/" || true
}

cmd_test() {
  local name="${1:-}"
  [ -f "$CONF_DIR/${name}.conf" ] || { echo "no such mesh service: $name"; exit 1; }
  # shellcheck disable=SC1090
  . "$CONF_DIR/${name}.conf"
  echo "calling http://${NAME}.${NAMESPACE}.svc.cluster.local:${SERVICE_PORT} from a pod"
  "$KUBECTL" run "mesh-test-${NAME}-$(date +%s)" --rm -i --restart=Never \
    --image=busybox:1.36 --labels="k8s-app=mesh-test" -- \
    wget -qO- -T8 "http://${NAME}.${NAMESPACE}.svc.cluster.local:${SERVICE_PORT}/" 2>&1 | head -20
}

cmd_remove() {
  local name="${1:-}"
  [ -f "$CONF_DIR/${name}.conf" ] || { echo "no such mesh service: $name"; exit 1; }
  # shellcheck disable=SC1090
  . "$CONF_DIR/${name}.conf"
  pkill -f "mesh-keeper-${name}" 2>/dev/null
  rm -f "/usr/local/bin/mesh-keeper-${name}.sh" "$CONF_DIR/${name}.conf"
  "$KUBECTL" -n "$NAMESPACE" delete svc "$NAME" --ignore-not-found >/dev/null 2>&1
  "$KUBECTL" -n "$NAMESPACE" delete endpointslice "$NAME-mirror" --ignore-not-found >/dev/null 2>&1
  echo "removed ${name} (tunnel, config, service, endpointslice)"
}

cmd_list() {
  printf '%-20s %-12s %-18s %s\n' NAME NAMESPACE PEER TUNNEL
  shopt -s nullglob
  for c in "$CONF_DIR"/*.conf; do
    # shellcheck disable=SC1090
    . "$c"
    printf '%-20s %-12s %-18s %s\n' "$NAME" "$NAMESPACE" "$PEER_SSH" "0.0.0.0:${LOCAL_PORT} -> ${TARGET_HOST}:${TARGET_PORT}"
  done
}

case "${1:-}" in
  add)    shift; cmd_add "$@" ;;
  list)   cmd_list ;;
  status) shift; cmd_status "$@" ;;
  test)   shift; cmd_test "$@" ;;
  remove) shift; cmd_remove "$@" ;;
  *)      usage ;;
esac