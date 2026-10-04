#!/usr/bin/env bash
# Run kubectl against the shared cluster over ssh (needs nothing but port 22).
#
#   ./scripts/kubectl-remote.sh get pods -A
#   ./scripts/kubectl-remote.sh -n kube-system logs deploy/coredns
#
# env overrides: VM=dev.new
set -euo pipefail

VM="${VM:-dev.new}"

if [ -t 0 ]; then
  exec ssh -t "$VM" kubectl "$@"
else
  exec ssh "$VM" kubectl "$@"
fi