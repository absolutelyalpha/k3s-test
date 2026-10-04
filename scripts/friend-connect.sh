#!/usr/bin/env bash
# Grab a working kubeconfig for the shared cluster and verify it.
#
#   usage: ./scripts/friend-connect.sh [ssh-host]
#   default ssh-host: dev.new
#
# Produces ./kubeconfig.yaml and prints the export line to use.
set -euo pipefail

VM="${1:-dev.new}"
KCFG="$PWD/kubeconfig.yaml"

echo "==> fetching kubeconfig from $VM"
scp -q "$VM:/root/kubeconfig-share.yaml" "$KCFG"
chmod 600 "$KCFG"

if kubectl --kubeconfig "$KCFG" get nodes >/dev/null 2>&1; then
  echo "==> direct connection works"
else
  echo "==> port 6443 is not reachable from here, using an SSH tunnel instead"
  ssh -fN -L 6443:127.0.0.1:6443 "$VM"
  sed -i.bak 's#server: https://.*:6443#server: https://127.0.0.1:6443#' "$KCFG"
  rm -f "$KCFG.bak"
fi

kubectl --kubeconfig "$KCFG" get nodes

cat <<EOF

ready. use it like this:

  export KUBECONFIG=$KCFG
  kubectl get nodes
  helm list -A

  helm install myapp ./charts/demo-app
  kubectl get pods -w
EOF