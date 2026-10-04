# Multi-cluster: connecting this cluster to your friend's

Goal: two independent single-node clusters, one per VM, that a single person can
drive from one `kubectl` and that can call each other's services over the network.

Nothing here is theory pulled from a blog: every "verified" line was executed on
this VM, and every "unverified" line says what exactly has to be tested and what
the expected result looks like.

---

## 1. What this sandbox actually allows (measured, not assumed)

| Capability | Result on this VM | How it was measured |
| --- | --- | --- |
| systemd / openrc | **absent** | `ls /run/systemd/system`, `command -v systemctl openrc` |
| sshd inside the VM | **absent** | `ss -ltnp`, `ps aux \| grep sshd` - shell access comes from Railway's agent, not from an sshd on the VM |
| public SSH | works, through Railway's edge | `ssh dev.new`, host `66.33.22.2` |
| apiserver on public IP | **not reachable** | `curl -k https://208.77.246.95:6443/healthz` and `[ipv6]:6443` both fail from a second machine |
| NodePort on public IP | **not reachable** | `curl http://208.77.246.95:30269` fails |
| private IP (same project) | works from inside the VM | `curl http://10.250.12.112:30269` → `200` |
| outbound TCP 443 | works | `curl https://get.helm.sh` |
| outbound UDP | **blocked** | python DNS query to `1.1.1.1:53` times out, so WireGuard/Tailscale direct paths are dead ends |
| kernel WireGuard | **absent** | `ip link add wgtest type wireguard` → `Error: Unknown device type.` |
| `/dev/net/tun` | present | `ls -l /dev/net/tun` - userspace VPNs are theoretically possible |
| legacy iptables tables | **absent** | `iptables -t nat -L` → `can't initialize iptables table 'nat'` |
| kube-proxy programming hand-written EndpointSlices | **broken for ClusterIP, fine for headless** | see [5.3](#53-the-one-kube-proxy-bug-that-shapes-the-design) |

Consequences, in plain English:

* **The only reliable network path between two VMs is the provider's private
  network**, which means both VMs have to live in the same Railway project (or
  otherwise share a private network).
* **There is no VPN option.** No kernel WireGuard, no UDP, so no tunnel that
  needs either.
* **You cannot share the apiserver over the internet.** The friend must reach
  the cluster from inside the project network (their own VM, a client container
  in the project) or through an SSH tunnel from a machine that can already reach
  the SSH gateway.

---

## 2. The model

```
        your laptop                    Railway project (private network 10.250.0.0/16)
   +------------------------+      +------------------------------------------------+
   | kubectl                |      |                                                |
   |  context: mine   -----+------->| apiserver  https://10.250.12.112:6443            |
   |  context: friend -----+------->|   pod net 10.42.0.0/16   svc net 10.43.0.0/16    |
   +------------------------+      |                                                |
                                   |   friend's VM (same project)                     |
                                   |   apiserver  https://10.250.x.y:6443             |
                                   |   pod net 10.44.0.0/16   svc net 10.45.0.0/16    |
                                   +------------------------------------------------+
```

Two clusters, no shared etcd, no federation controller, disjoint CIDRs. That is
enough for real cross-cluster service calls and is what the tooling here does.

### CIDR plan

| Cluster | POD_CIDR | POD_SUBNET | SERVICE_CIDR | node IP |
| --- | --- | --- | --- | --- |
| this one (`mine`) | `10.42.0.0/16` | `10.42.0.0/24` | `10.43.0.0/16` | `10.250.12.112` |
| your friend (`friend`) | `10.44.0.0/16` | `10.44.0.0/24` | `10.45.0.0/16` | `10.250.x.y` (from `ip -4 route get 1.1.1.1`) |

Overlapping ranges are the classic way to make two clusters unable to talk: every
packet becomes ambiguous, so pick disjoint ranges once and never reuse them.
`scripts/setup-k3s.sh` takes all of them as parameters, so this is enforced by
the installer rather than by remembering.

---

## 3. Provision your friend's VM

On the friend's VM, from a clone of this repo:

```bash
git clone https://github.com/absolutelyalpha/k3s-test.git
cd k3s-test

# pick CIDRs that do NOT collide with mine, and tell the installer the address the
# friend will use to reach the apiserver
NODE_IP=$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')

POD_CIDR=10.44.0.0/16 \
POD_SUBNET=10.44.0.0/24 \
SERVICE_CIDR=10.45.0.0/16 \
APISERVER_ADVERTISE=$NODE_IP \
PEER_CIDRS="10.42.0.0/16 10.43.0.0/16" \
bash scripts/setup-k3s.sh
```

Validate the parameters before committing to them - this writes the configs to
`/tmp/k3s-render` and starts nothing:

```bash
RENDER_ONLY=1 RENDER_DIR=/tmp/render-friend \
  POD_CIDR=10.44.0.0/16 POD_SUBNET=10.44.0.0/24 SERVICE_CIDR=10.45.0.0/16 \
  PEER_CIDRS="10.42.0.0/16 10.43.0.0/16" \
  bash scripts/setup-k3s.sh
cat /tmp/render-friend/_etc_cni_net.d_10-bridge.conflist
cat /tmp/render-friend/_usr_local_bin_k3s-nft-rules.nft
```

What to check in that output: the ipam gateway is `10.44.0.1` (first address of
the node's pod subnet), the masquerade rule matches the new pod CIDR, the peer
accept rules mention `10.42.0.0/16 10.43.0.0/16`, and the default route in the
ipam `routes` block is present.

`/root/cluster-facts.env` is written on every run and is the single source of
truth for the values below; the other scripts read it.

---

## 4. Control plane: one kubeconfig, two contexts

### 4.1 Mine: hand out least privilege, not the admin file

```bash
# on my VM
bash scripts/create-scoped-user.sh alice default view   # read-only in default
bash scripts/create-scoped-user.sh bob team-a edit      # can deploy in team-a
```

Verified result for `alice` (view in `default`):

```
can-i list secrets in default: no
can-i create pods in default:   no
```

The script mints an ed25519 key, submits a `CertificateSigningRequest` with
signer `kubernetes.io/kube-apiserver-client`, approves it, binds the identity to
a `RoleBinding` (built-in `view`/`edit` ClusterRole) plus a small
`k3s-infra-view` ClusterRole for `nodes`/`namespaces`, and writes a kubeconfig
containing **only that identity**. Never share `/root/.kube/config`: it is
cluster-admin and can read every ServiceAccount token and TLS key in the cluster.

Hand it over:

```bash
scp root@dev.new:/root/users/alice.kubeconfig ~/kubeconfig-mine.yaml
# point the server at whatever the friend can reach
sed -i 's#server: https://.*:6443#server: https://10.250.12.112:6443#' ~/kubeconfig-mine.yaml
```

### 4.2 Merge both clusters into one file

```bash
git clone https://github.com/absolutelyalpha/k3s-test.git
cd k3s-test
./scripts/kubeconfig-merge.sh -o clusters.yaml --verify \
    ~/kubeconfig-mine.yaml ~/kubeconfig-friend.yaml

export KUBECONFIG=$PWD/clusters.yaml
kubectl config get-contexts
kubectl --context mine   get nodes
kubectl --context friend get nodes
```

Contexts are renamed to the kubeconfig's basename (`mine`, `friend`), so the
default `default` context collision disappears. `--verify` contacts each context
and prints OK/FAIL per cluster, which is the fastest way to see that a
certificate or a `--tls-san` is wrong.

### 4.3 If the friend cannot reach port 6443

Only TCP 22 is publicly reachable here, so a tunnel is the fallback - but note it
requires shell access to the VM, and this VM has **no sshd**: shell access comes
from Railway's SSH gateway, which authorizes the account that owns the project.
In practice that means: add your friend to the Railway project (then the private
network path in section 5 works and no tunnel is needed), or have the friend run
their own client VM in the project.

If you do have SSH access to the VM, `scripts/friend-connect.sh` does the whole
sequence (fetch kubeconfig, try direct, open a tunnel, rewrite the server URL,
verify) and falls back to the `kubectl-remote.sh` / `helm-remote.sh` wrappers,
which run the command over SSH and need nothing else.

---

## 5. Data plane: calling services across the clusters

### 5.1 The mechanism

Each cluster only resolves its own `cluster.local` zone, so a peer service is
published **locally** as a Service whose EndpointSlice holds the peer's
addresses. Callers use an ordinary in-cluster DNS name; the packet leaves through
the normal service path and arrives in the other cluster.

```
pod in mine ──DNS──> web.default.svc.cluster.local
                 └─(headless A record)─> 10.250.12.112:30269  (friend's NodePort)
                                          └─> nginx pod in friend's cluster
```

### 5.2 Consuming a peer service (the verified path)

Publish the peer's service as a NodePort on the peer's node, then mirror it:

```bash
# on the friend's VM, so the service is reachable at 10.250.x.y:<nodePort>
kubectl -n demo get svc web                     # find or create a NodePort service

# on my VM: mirror it (headless, so kube-proxy is not involved)
helm install friend-web ./charts/service-mirror \
  --set name=web \
  --set addresses=10.250.x.y:30269 \
  --set port=30269
```

Verify from a pod:

```bash
kubectl run netcheck --rm -it --restart=Never --image=busybox:1.36 -- \
  wget -qO- -T5 http://web.default.svc.cluster.local:30269/
kubectl get endpointslice -l kubernetes.io/service-name=web -o yaml
```

This exact pattern is what the live `web` mirror in this cluster demonstrates: a
pod calling `web.default.svc.cluster.local:30269` gets the nginx page that is
served through the "peer" address.

Many endpoints (peer replicas), all on the same port - use a values file,
because Helm's `--set` cannot parse a comma separated list that contains colons:

```yaml
# values-peer.yaml
name: web
port: 8080
addresses:
  - 10.250.x.y:8080
  - 10.250.x.y:8080
```

```bash
helm install friend-web ./charts/service-mirror -f values-peer.yaml
```

Second port on the same peer service? Install a second mirror under another
name: one EndpointSlice carries exactly one port, and the chart fails with an
explicit message if you mix ports.

### 5.3 The one kube-proxy bug that shapes the design

On this build (k3s 1.37.1, kube-proxy in nftables mode) a **ClusterIP** service
backed by a hand-written EndpointSlice is silently not programmed:

```
nft list table ip kube-proxy | grep default/web     # -> nothing, ever
curl http://<clusterIP>/                            # -> connection refused / timeout
```

It does not matter whether the endpoint is a pod IP or a node IP, and adding
`conditions.ready: true` does not help. Slices written by the EndpointSlice
controller (selector-based services) are programmed normally. **Headless**
services (`clusterIP: None`) work perfectly, because there DNS hands the peer
addresses to the client and kube-proxy is not in the path at all.

That is why `charts/service-mirror` defaults to `headless: true`. Set
`--set headless=false` only on a cluster whose kube-proxy accepts hand-written
slices (most non-k3s clusters, e.g. kubeadm on a normal cloud VM), where you also
get port translation (`port` → `targetPort`) and kube-proxy load balancing.

### 5.4 Keeping endpoints fresh

Peer pod IPs and NodePorts change. The mirror is static, so re-apply it:

```bash
helm upgrade friend-web ./charts/service-mirror -f values-peer.yaml
```

or from a CronJob in this cluster:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: refresh-friend-web
spec:
  schedule: "*/10 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          containers:
            - name: refresh
              image: alpine/helm:3.16
              command: ["sh", "-c", "helm upgrade friend-web /chart -f /values.yaml"]
              volumeMounts:
                - {name: chart, mountPath: /chart}
                - {name: values, mountPath: /values.yaml, subPath: values.yaml}
          volumes:
            - name: chart
              configMap: {name: friend-web-chart}
            - name: values
              configMap: {name: friend-web-values}
```

### 5.5 Peers that are not in the same private network

| Option | Needs | Works here? |
| --- | --- | --- |
| `scripts/mesh-service.sh` (SSH forward per service) | sshd on both VMs | no - this VM has no sshd; works for a normal VPS peer |
| Tailscale, DERP relay | `/dev/net/tun`, outbound TCP 443 | possibly - UDP is blocked so it must relay; latency is worse than a tunnel |
| WireGuard | kernel module **or** userspace WG + UDP | no - no kernel module, no UDP |
| Submariner / Karmada | routable L3 + kernel WireGuard | no - treat as a phase-2 project on normal VMs |

`mesh-service.sh` for a peer that does have sshd:

```bash
./scripts/mesh-service.sh add friend-web default friend-vm 10.43.131.95 30269
./scripts/mesh-service.sh status friend-web
./scripts/mesh-service.sh test friend-web      # calls it from a pod
./scripts/mesh-service.sh remove friend-web
```

It keeps `ssh -L 0.0.0.0:<local>:<peerClusterIP>:<port>` alive in a keeper loop
(the far side resolves the ClusterIP *inside* the peer cluster, so it works even
though that ClusterIP is unroutable from here) and publishes the headless mirror
pointing at this node's tunnel port.

---

## 6. Cross-cluster DNS, if you really want it

The mirror approach means you never need cross-cluster DNS. If you want a peer's
*real* service name to resolve inside this cluster, forward it from CoreDNS:

```
# Corefile in this cluster
peer.svc.cluster.local {
    errors
    cache 30
    forward . 10.250.x.y:53      # friend's CoreDNS, reachable over private L3
}
```

That works for UDP DNS over the private network, but the answer is the peer's
ClusterIP, which is only routable inside the peer cluster - so it only helps
together with a routed mesh (Tailscale/WireGuard). In this sandbox the mirror is
the correct answer, and DNS stays boring.

---

## 7. Identity between the clusters

Each cluster has its own CA, and that is the right default: compromise of one
cluster does not hand over the other.

Cross-cluster *API* calls with a ServiceAccount token need the apiserver of the
receiving cluster to trust the issuer of the other one. If you ever need that,
share only the public CA bundle:

```bash
# on the friend's VM: export the client CA bundle
cat /var/lib/rancher/k3s/server/tls/client-ca.crt > /root/client-ca-bundle.crt
scp /root/client-ca-bundle.crt <my-vm>:/root/peer-client-ca.crt
```

```bash
# on my VM: append it to the bundle the apiserver trusts and restart
cat /var/lib/rancher/k3s/server/tls/client-ca.crt /root/peer-client-ca.crt \
  > /var/lib/rancher/k3s/server/tls/client-ca-bundle.crt
EXTRA_SERVER_FLAGS="--client-ca-file=/var/lib/rancher/k3s/server/tls/client-ca-bundle.crt" \
  bash scripts/setup-k3s.sh
```

Certificates: every address a client uses must be in the apiserver certificate.
`setup-k3s.sh` puts the node IP, `APISERVER_ADVERTISE`, `localhost`, `127.0.0.1`
and everything in `TLS_SANS` into `--tls-san`. A mismatch shows up as
`x509: certificate is valid for X, not Y` - add the address and re-run.

---

## 8. Storage: do not expect it to travel

Both clusters use k3s `local-path`, which is node-bound and ephemeral. A PVC in
your cluster is meaningless in your friend's cluster. For anything that must
survive a VM replacement or be visible from both clusters:

* S3-compatible object storage (Cloudflare R2, MinIO, Backblaze B2) with an
  `S3` CSI driver, or
* a shared NFS/EFS mount, or
* keep state in a database you run yourself and let both clusters talk to it.

`local-path` is fine for demos and for the chart in this repo.

---

## 9. GitOps for both clusters

Both clusters can be driven from this one GitHub repo:

```bash
# per cluster, once
kubectl create namespace flux-system
helm repo add flux https://fluxcd.io/flux --namespace flux-system
helm install flux fluxcd/flux -n flux-system
kubectl -n flux-system get pods
```

Then point a `GitRepository` at `https://github.com/absolutelyalpha/k3s-test`
with `path: ./deploy/mine` and `./deploy/friend`, one per cluster. Each cluster
then converges on its own subtree, and a pull request is how you ship to both.

---

## 10. Observability across both clusters

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install monitoring prometheus-community/kube-prometheus-stack -n monitoring --create-namespace
```

To see both clusters in one place without a federation controller, run one
Prometheus/Grafana (a third VM, or your laptop with a tunnel) and let each
cluster's Prometheus `remote_write` to it:

```yaml
# values for the central prometheus
prometheus-pushgateway:
  enabled: false
server:
  persistentVolume: {enabled: true, size: 20Gi}
```

```yaml
# extraScrapeConfigs / remote_write in each cluster
remoteWrite:
  - url: http://<central-prometheus>:9090/api/v1/write
```

Logs: `promtail` + Loki, or just accept per-cluster `kubectl logs` and ship log
files off the VMs.

---

## 11. Security posture, honestly

| Control | State here | Why |
| --- | --- | --- |
| least-privilege identities | **in place** | `create-scoped-user.sh`, no admin kubeconfig sharing |
| TLS everywhere | in place | apiserver, kubelet, CoreDNS upstream via HTTPS-capable resolvers |
| NetworkPolicy | **not available** | `--disable-network-policy`: this kernel has no netfilter policy support, so any pod can talk to any pod. Do not treat this as a segmented environment. |
| ResourceQuota / PSA | add per namespace | cheap and worth it on shared clusters |
| secrets at rest | plaintext etcd | single node, file-permission based; use an external secret manager if that matters |
| public exposure | none | nothing but the SSH gateway is reachable from the internet |

---

## 12. Failure modes and what to do

| Symptom | Likely cause | Check |
| --- | --- | --- |
| `x509: certificate is valid for A, not B` | address missing from `--tls-san` | add it to `TLS_SANS`, re-run `setup-k3s.sh` |
| kubeconfig works, pods cannot reach peer | no L3 route between the VMs | `ping -c2 <peer private ip>` from a pod and from the node |
| mirror Service exists, calls time out | peer NodePort not exposed or wrong port | `kubectl get svc -A`, `curl` the peer's `nodeIP:nodePort` from the VM |
| ClusterIP mirror never answers | known kube-proxy behaviour, section 5.3 | use `headless: true` |
| DNS resolves the mirror but the connection hangs | endpoint address not routable | `wget` the endpoint address directly from a pod |
| pods fine, external DNS fails | CoreDNS upstream still `/etc/resolv.conf` | `kubectl -n kube-system get cm coredns -o yaml \| grep forward` |
| everything died after a VM replacement | new VM, no cluster | `bash /root/setup-k3s.sh`, see `docs/VM-SETUP.md` |

---

## 13. Order of operations

1. Friend gets access to the Railway project, creates a VM.
2. Both run `./scripts/mesh-preflight.sh` and paste the output to each other.
3. Friend provisions with the disjoint CIDRs from section 2.
4. Prove the private path: on my VM `curl -sk https://<friend node ip>:6443/healthz`
   must answer `401` (that is "reachable, needs auth" = success).
5. Exchange scoped kubeconfigs, merge them, run `kubeconfig-merge.sh --verify`.
6. Friend publishes a service as NodePort; I mirror it with `service-mirror` and
   call it from a pod; then swap the roles.
7. Optional: GitOps, central metrics, Tailscale if you ever move to VMs that
   allow UDP.