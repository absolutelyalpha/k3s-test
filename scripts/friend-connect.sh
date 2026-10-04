#!/usr/bin/env bash
# Get a working kubeconfig for the shared cluster on the VM.
#
#   usage: ./scripts/friend-connect.sh [ssh-host]     (default: dev.new)
#
# Writes ./kubeconfig.yaml and prints how to use it. Port 6443 is not publicly
# exposed on the VM, so this normally ends up using an SSH tunnel. If the tunnel
# cannot be established, ./scripts/kubectl-remote.sh works over ssh alone.
set -euo pipefail

VM="${1:-dev.new}"
KCFG="$PWD/kubeconfig.yaml"

echo "==> fetching kubeconfig from $VM"
scp -q "$VM:/root/kubeconfig-share.yaml" "$KCFG"
chmod 600 "$KCFG"

port_open() {
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && exec 3<&- && return 0
  return 1
}

MODE=""
if kubectl --kubeconfig "$KCFG" get nodes >/dev/null 2>&1; then
  MODE="direct"
  echo "==> api server is directly reachable"
else
  echo "==> port 6443 is not reachable from here, opening an SSH tunnel"
  ssh -fN -L 6443:127.0.0.1:6443 "$VM" 2>/dev/null || ssh -N -L 6443:127.0.0.1:6443 "$VM" &
  for _ in $(seq 1 10); do
    port_open 6443 && break
    sleep 1
  done
  if port_open 6443; then
    sed -i.bak 's#server: https://.*:6443#server: https://127.0.0.1:6443#' "$KCFG"
    rm -f "$KCFG.bak"
    if kubectl --kubeconfig "$KCFG" get nodes >/dev/null 2>&1; then
      MODE="tunnel"
    fi
  fi
fi

if [ "$MODE" = "tunnel" ]; then
  echo "==> connected through the tunnel"
  kubectl --kubeconfig "$KCFG" get nodes
  cat <<EOF

ready:

  export KUBECONFIG=$KCFG
  kubectl get nodes
  helm list -A

  helm install myapp ./charts/demo-app
  kubectl get pods -w
EOF
elif [ "$MODE" = "direct" ]; then
  echo "==> connected directly"
  kubectl --kubeconfig "$KCFG" get nodes
  echo
  echo "export KUBECONFIG=$KCFG"
else
  echo "==> the tunnel did not come up; use the ssh wrappers instead:"
  cat <<EOF

  ./scripts/kubectl-remote.sh get nodes
  ./scripts/helm-remote.sh list -A
  ./scripts/helm-remote.sh install myapp ./charts/demo-app

(kubeconfig was still saved to $KCFG in case it works for you)
EOF
fi