# STATUS: what is verified, what is not, what is left

Written so this repo can be picked up by anyone (including future me) without
re-deriving what was actually tested.

---

## Verified on this VM (executed, output seen)

| Area | Evidence |
| --- | --- |
| clean provisioning from zero | `/root/reinstall.log`: wipe + `setup-k3s.sh`, node `Ready`, addons running |
| idempotent re-run | second `setup-k3s.sh` run kept Helm releases (`myapp`, `web-mirror`, traefik) |
| cluster DNS | `nslookup kubernetes.default.svc.cluster.local` from a pod resolves |
| external DNS from pods | `nslookup github.com` from a pod resolves |
| external HTTPS egress from pods | `wget https://ifconfig.me` from a pod returns the egress page |
| apiserver on private IP | `https://10.250.12.112:6443/healthz` -> `401` |
| NodePort on private IP | `http://10.250.12.112:30443/` -> `200` |
| demo chart | `helm install myapp ./charts/demo-app`, 2/2 Running |
| **cross-cluster service mirror** | pod calls `web.default.svc.cluster.local:30443`, headless EndpointSlice -> `10.250.12.112:30443`, nginx page returned |
| multi-address mirror values | rendered and installed from a values file (Helm `--set` cannot parse `IP:port,IP:port`) |
| facts file | `/root/cluster-facts.env` is sourceable (fixed: values are quoted now) |
| least privilege, view | `alice`: list pods `yes`, list secrets `no`, create pods `no`, get nodes `yes` |
| least privilege, namespaced edit | `bob`: create deployments in `team-a` `yes`, in `default` `no` |
| **revocation** | after `--revoke bob`, a *kept copy* of his kubeconfig gets `Forbidden: User "bob" cannot list resource "pods"`; `alice` unaffected |
| kubeconfig merge | two clusters -> one file, contexts named after the files, certs embedded, `--verify` contacts both |
| `--list` | shows every scoped user and its binding |
| installer parameterization | `RENDER_ONLY=1` renders `10.44.0.0/16` / `10.45.0.0/16` with gateway `10.44.0.1` and peer nft rules |
| platform probing | no vxlan, no `nat` table, no kernel WireGuard, `/dev/net/tun` present, outbound UDP blocked |

## Known platform behaviours (measured, documented, worked around)

* **kube-proxy in nftables mode ignores hand-written EndpointSlices for ClusterIP
  services.** `nft list table ip kube-proxy` never contains such a service, and
  the ClusterIP times out. Selector-based services are fine. Mitigation:
  `charts/service-mirror` is headless by default.
* No init system: k3s is supervised by `/usr/local/bin/k3s-supervise.sh`, network
  state by `/usr/local/bin/k3s-net-watchdog.sh`.
* Host resolver is IPv6-only (`fd12::10`), so CoreDNS must be patched after k3s
  writes its manifest.
* Pod default route is **not** created by the bridge CNI's ipam config on this
  kernel; the installer writes it, plus the gateway and MTU.
* Pod egress needs an explicit masquerade rule; the installer creates nftables
  table `ip pod-egress`.
* Public ingress is limited to Railway's SSH gateway (TCP 22). No sshd inside the
  VM, so a tunnel to this VM is only possible for accounts Railway authorizes.

## Not verified (needs the friend's VM, or a normal cloud VM)

* `https://<friend node ip>:6443` answering `401` from my VM (private routing
  between two Railway VMs in one project).
* `http://<friend node ip>:<nodePort>` reachable from my VM.
* Cross-cluster calls in both directions with two real clusters (the mechanism
  is verified against an external address; the second cluster is the missing part).
* `scripts/mesh-service.sh` end to end: this VM has no sshd, so the tunnel cannot
  be established here. The script is written for peers that do have one.
* Tailscale/DERP as an alternative transport: `/dev/net/tun` exists but outbound
  UDP is blocked, so only a relay would work. Untested.
* IPv6 ingress from a network that actually has IPv6 (my test host had none).

## Left to do

1. Provision the friend's VM with the disjoint CIDRs from `docs/MULTI-CLUSTER.md`
   §2, then run the reachability pair in §13 of that document.
2. Merge the two real clusters' kubeconfigs and keep the merged file out of git.
3. Decide whether the static mirrors get a refresh CronJob (see
   `docs/MULTI-CLUSTER.md` §5.4) or a real endpoint controller.
4. Optional, on a VM that allows UDP: Tailscale, then `service-mirror` over
   tailnet addresses instead of the provider private network.
5. Cleanup on the VM: throw away the test scratch files (`/root/t*.sh`,
   `/root/dbg.sh`, `/root/verify.sh`, `/root/reinstall.sh`, `/root/k3s-test.tgz`)
   and the self-test SSH key if it is still in `~/.ssh/authorized_keys`.
6. Longer term: single node means no HA. Consider a second node on a different
   host (needs a real CNI/etcd story) or accept the single point of failure.