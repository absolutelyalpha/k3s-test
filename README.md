# shared-k3s-cluster

One-shot Kubernetes cluster on the Railway VM `dev.new`, plus a Helm chart so you can
deploy into the same cluster from your own machine.

- `scripts/setup-k3s.sh` - provisions the whole cluster from nothing (~3 min, idempotent)
- `scripts/friend-connect.sh` - fetches a working kubeconfig and verifies it
- `charts/demo-app` - small app chart (Deployment + Service + optional Ingress)

## 1. Bootstrap the cluster (only if the VM was replaced)

```bash
scp scripts/setup-k3s.sh dev.new:/root/setup-k3s.sh
ssh dev.new 'bash /root/setup-k3s.sh'
```

The script handles what this sandbox does not support out of the box:

| Problem | What the script does |
| --- | --- |
| no systemd/openrc | runs k3s under a supervisor loop that restarts it |
| kernel has no vxlan | `--flannel-backend=none` + bridge CNI |
| no legacy iptables tables | kube-proxy in nftables mode, ServiceLB disabled |
| bridge CNI sets no gateway | pre-creates `cni0` with `10.42.0.1/24`, watchdog keeps it |
| no SNAT for pods | own nftables table `ip pod-egress` |
| host DNS is IPv6-only | CoreDNS forwards to `1.1.1.1` / `8.8.8.8` |

## 2. Connect from your machine

```bash
git clone <this repo>
cd shared-k3s-cluster
./scripts/friend-connect.sh dev.new
export KUBECONFIG=$PWD/kubeconfig.yaml
kubectl get nodes
```

`friend-connect.sh` copies `/root/kubeconfig-share.yaml` off the VM, tries a direct
connection, and falls back to `ssh -L 6443:127.0.0.1:6443 dev.new` when the API server
port is not reachable from outside.

## 3. Deploy the chart

```bash
helm install myapp ./charts/demo-app
kubectl get pods -w
kubectl get svc myapp          # NodePort -> tunnel it: ssh -L 8080:127.0.0.1:<nodePort> dev.new
```

Configurable via `--set`: `replicaCount`, `image.repository`, `image.tag`,
`service.type=ClusterIP`, `ingress.enabled=true`, `ingress.host=...`.

## Notes

- Single node, so the chart is for sharing this one cluster; the bridge CNI has no
  overlay network for multi-node.
- Everything else (CoreDNS, Traefik, metrics-server, local-path storage) comes up with
  the cluster.
- If k3s ever dies, the supervisor restarts it; if the whole VM is replaced, re-run
  `setup-k3s.sh`.