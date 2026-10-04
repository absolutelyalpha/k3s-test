#!/usr/bin/env bash
# Run helm against the shared cluster over ssh (needs nothing but port 22).
#
#   ./scripts/helm-remote.sh list -A
#   ./scripts/helm-remote.sh install myapp ./charts/demo-app   # run from a clone
#
# env overrides: VM=dev.new
set -euo pipefail

VM="${VM:-dev.new}"

if [ -t 0 ]; then
  exec ssh -t "$VM" helm "$@"
else
  exec ssh "$VM" helm "$@"
fi