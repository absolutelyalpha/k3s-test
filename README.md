# shared-k3s-cluster

One-shot Kubernetes cluster on the Railway VM `dev.new`, plus a Helm chart so anyone can
deploy into the same cluster from their own machine.

- `scripts/setup-k3s.sh` - provisions the entire cluster from nothing (~3 min, idempotent)
- `scripts/friend-connect.sh` - fetches a working kubeconfig and verifies it
- `scripts/kubectl-remote.sh` / `scripts/helm-remote.sh` - run kubectl/helm over ssh, no
  kubeconfig or open port needed
- `charts/demo-app` - small app chart (Deployment + Service + optional Ingress)

Only port 22 (ssh) is publicly reachable on the VM, so there are two ways in:
**over ssh** (always works) or **through an ssh tunnel** (gives you a normal kubeconfig).

## 1. Bootstrap the cluster (only needed after the VM was replaced)

```bash
scp scripts/setup-k3s.sh dev.new:/root/setup-k3s.sh
ssh dev.new 'bash /root/setup-k3s.sh'
```

What the script works around in this sandbox:

| Problem here | What the script does |
| --- | --- |
| no systemd / openrc | runs k3s under a supervisor loop that restarts it |
| kernel has no vxlan support | `--flannel-backend=none` + bridge CNI |
| no legacy iptables tables | kube-proxy in nftables mode, ServiceLB disabled |
| bridge CNI adds no gateway route | pre-creates `cni0` with `10.42.0.1/24`; a watchdog keeps it |
| no SNAT for pod traffic | own nftables table `ip pod-egress` |
| host resolver is IPv6-only | CoreDNS forwards to `1.1.1.1` / `8.8.8.8` |

## 2. Connect from your machine

### Option A - ssh wrappers (needs only ssh access)

```bash
./scripts/kubectl-remote.sh get nodes
./scripts/helm-remote.sh list -A
./scripts/helm-remote.sh install myapp ./charts/demo-app
```

### Option B - real kubeconfig through an ssh tunnel

```bash
./scripts/friend-connect.sh dev.new     # defaults to host dev.new
export KUBECONFIG=$PWD/kubeconfig.yaml
kubectl get nodes
```

It copies `/root/kubeconfig-share.yaml` off the VM, tries a direct connection first, and
otherwise opens `ssh -L 6443:127.0.0.1:6443 dev.new` and points the kubeconfig at
`127.0.0.1:6443`. If the tunnel cannot be established it tells you to use option A.

## 3. Deploy the chart

```bash
helm install myapp ./charts/demo-app
kubectl get pods -w
kubectl get svc myapp     # NodePort; reach it with: ssh -L 8080:127.0.0.1:<nodePort> dev.new
```

Common overrides:

```bash
helm install myapp ./charts/demo-app \
  --set replicaCount=3 \
  --set image.repository=nginx --set image.tag=1.29-alpine \
  --set service.type=ClusterIP \
  --set ingress.enabled=true --set ingress.host=demo.example.com
```

Uninstall with `helm uninstall myapp`.

## Notes

- Single node. The bridge CNI has no overlay network, so this is for one VM, not many.
- CoreDNS, Traefik, metrics-server and local-path storage all come up with the cluster.
- If k3s dies, the supervisor restarts it. If Railway replaces the VM, re-run
  `setup-k3s.sh` and everything is back in about three minutes.