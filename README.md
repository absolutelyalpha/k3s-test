# k3s-test

One reproducible single-node **k3s** cluster on a bare Linux VM (built and
verified on a Railway `fvm` sandbox), plus the tooling to let a **second person
run their own cluster and connect to this one**.

Everything in this repo was executed on the target machine. Where something is
not verified, the docs say so and give the exact command to verify it.

---

## What is running right now

| | |
| --- | --- |
| cluster | k3s `v1.37.1+k3s1`, single node, `Ready` |
| CNI | bridge (`cni0`), ipam host-local, pod CIDR `10.42.0.0/16` |
| services | `10.43.0.0/16` |
| addons | CoreDNS, metrics-server, local-path-provisioner, Traefik (+ gateway-api CRDs) |
| workloads | `myapp` (2 x nginx, NodePort `30443`), `web-mirror` (cross-cluster mirror) |
| kubeconfigs | `/root/.kube/config` (admin), `/root/kubeconfig-share.yaml`, `/root/users/<name>.kubeconfig` (scoped) |
| facts | `/root/cluster-facts.env` (sourceable, written by the installer) |

Verified behaviours on this host: cluster DNS, external DNS, external HTTPS
egress from pods, ClusterIP services, NodePort on the private node IP, the apiserver
answering `401` on the private IP (reachable, auth required), least-privilege
users, and a headless service mirror carrying traffic to an address outside the
cluster.

---

## Quick start

On a fresh VM:

```bash
git clone https://github.com/absolutelyalpha/k3s-test.git
cd k3s-test
bash scripts/setup-k3s.sh
kubectl get pods -A          # all addons should reach Running/Ready
```

For a second cluster with **disjoint CIDRs** (this is what makes two clusters
coexist):

```bash
NODE_IP=$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
POD_CIDR=10.44.0.0/16 POD_SUBNET=10.44.0.0/24 SERVICE_CIDR=10.45.0.0/16 \
APISERVER_ADVERTISE=$NODE_IP PEER_CIDRS="10.42.0.0/16 10.43.0.0/16" \
bash scripts/setup-k3s.sh
```

Preview the configuration without touching the machine:

```bash
RENDER_ONLY=1 RENDER_DIR=/tmp/render \
  POD_CIDR=10.44.0.0/16 POD_SUBNET=10.44.0.0/24 SERVICE_CIDR=10.45.0.0/16 \
  bash scripts/setup-k3s.sh
ls /tmp/render
```

Re-provision an existing machine (idempotent; keeps workloads and Helm releases):

```bash
bash /root/setup-k3s.sh
```

---

## Repository layout

```
charts/demo-app/          nginx Deployment + Service, values-driven, the smoke test
charts/service-mirror/    publish a service from ANOTHER cluster as a local Service
scripts/setup-k3s.sh      the installer: k3s + CNI + networking + addons + kubeconfigs
scripts/create-scoped-user.sh   least-privilege kubeconfigs, --list, --revoke
scripts/kubeconfig-merge.sh      merge many clusters into one kubeconfig, --verify
scripts/mesh-preflight.sh        what this host allows (vxlan, iptables, tun, UDP)
scripts/mesh-service.sh          optional SSH-tunnel mirrors for peers with an sshd
scripts/status.sh                one-shot health report
scripts/friend-connect.sh        fetch a kubeconfig, tunnel if needed, verify
scripts/kubectl-remote.sh        run kubectl against a VM over SSH
scripts/helm-remote.sh           same for helm
docs/MULTI-CLUSTER.md   *** the main document: what this platform allows, and how
                            two clusters talk to each other, with verified findings
docs/STATUS.md          what is verified, what is not, and what is left to do
```

---

## Cross-cluster calls in three commands

```bash
# peer publishes: kubectl -n demo expose deployment web --type=NodePort --port=80
helm install friend-web ./charts/service-mirror \
  --set name=web --set addresses=10.250.x.y:30443 --set port=30443

kubectl run netcheck --rm -it --restart=Never --image=busybox:1.36 -- \
  wget -qO- -T5 http://web.default.svc.cluster.local:30443/
```

The mirror is **headless** on purpose: on k3s with kube-proxy in nftables mode a
ClusterIP service backed by a hand-written EndpointSlice is silently never
programmed, while a headless one works. Details and the evidence are in
[docs/MULTI-CLUSTER.md](docs/MULTI-CLUSTER.md).

---

## Platform notes that will save you an hour

This VM has no init system, no sshd, no kernel WireGuard, no legacy iptables
tables, no vxlan, and no outbound UDP; only TCP 22 (Railway's SSH gateway) is
publicly reachable. `scripts/setup-k3s.sh` handles all of that:

* no systemd/openrc -> `k3s-supervise.sh` + `k3s-net-watchdog.sh` under `nohup`
* no vxlan -> `--flannel-backend=none` + a bridge CNI conflist rendered by the script
* no iptables -> `--kube-proxy-arg=proxy-mode=nftables`
* no netfilter policy support -> `--disable-network-policy` (documented as a gap)
* IPv6-only host resolver -> CoreDNS is patched to `forward . 1.1.1.1 8.8.8.8`
* pod egress needs a NAT rule the CNI does not write -> nftables table `ip pod-egress`

---

## Security

Do not share `/root/.kube/config`; it is cluster-admin. Use:

```bash
bash scripts/create-scoped-user.sh alice            # read-only in default
bash scripts/create-scoped-user.sh bob team-a edit  # deploy in team-a
bash scripts/create-scoped-user.sh --list
bash scripts/create-scoped-user.sh --revoke bob     # verified: requests become Forbidden
```

Two caveats stated plainly: network policy is **disabled** on this kernel, so
pod-to-pod isolation is not available here, and secrets live in etcd unencrypted
at rest.

---

## Status

See [docs/STATUS.md](docs/STATUS.md) for the verified/unverified split and the
remaining work. Short version: the single-cluster setup, the scoped users, the
kubeconfig merge and the service mirror are verified end to end on this VM; the
two-VM path needs the friend's VM to exist before it can be verified.