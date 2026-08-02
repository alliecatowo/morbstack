# Kubernetes (`morb k8s`)

A local single-node cluster wired to the same `dockerd` everything else in
Morbstack already uses. Off by default and costs nothing until you ask for
it.

Status: **working**, verified live end to end (cold enable to a Ready
node, `docker build` running with no registry push, a Service reachable
from the Mac, clean disable). See "What was actually measured" below for
the numbers this status rests on, and "Known gap" for the one thing this
pass found and fixed.

## Why this shape

The obvious way to add Kubernetes to a VM is to let k3s run its own
embedded containerd. Morbstack deliberately does not do that. `k3s` is
started with `--container-runtime-endpoint` pointed at `cri-dockerd`,
which translates kubelet's CRI calls into Docker Engine API calls against
the very same `/var/run/docker.sock` every `docker build` already writes
to. That is the entire ergonomic point of this feature:

```sh
docker build -t local-only:v1 .
kubectl apply -f deploy.yaml   # imagePullPolicy: IfNotPresent
```

runs the image you just built, in the cluster, with **no registry push
and no `kind load`** — verified directly: `kubectl describe pod` on the
running pod reports

```
Normal  Pulled  3s  kubelet  Container image "local-only:v1" already present on machine and can be accessed by the pod
```

not a pull event, because there is nothing to pull.

## Turning it on

```sh
morb k8s enable      # installs the payload if needed, then starts the cluster
morb k8s status      # installed / enabled / phase / node & pod readiness
morb k8s kubeconfig  # writes ~/.morbstack/kubeconfig
morb k8s disable      # stops the cluster; the payload and its data are kept
```

`morb k8s enable` is one command on purpose. "Enable Kubernetes" is a
single intention; a two-step flow whose first step is "upload 122 MB" is
an implementation detail escaping into the interface. The payload (`k3s`
+ `cri-dockerd`, streamed over vsock port 2377 — see
[`protocol.md`](protocol.md) §3.3) is sha256-verified on both ends and
skipped if the guest already has a byte-identical copy, so the second and
later `enable` calls do no transfer at all.

### The kubeconfig rule

`morb k8s kubeconfig` writes `~/.morbstack/kubeconfig` — **never**
`~/.kube/config`. That file routinely holds production clusters, and a
tool that rewrites it because you flipped a local toggle is a tool that
will eventually point `kubectl delete` at the wrong cluster. Merging
Morbstack's context into `~/.kube/config` is a separate, explicit
`morb k8s kubeconfig --merge`, which takes a timestamped backup first and
never switches `current-context` unless asked. Verified directly in this
pass: after a plain `morb k8s kubeconfig`, `~/.kube/config` did not
exist — nothing touched it.

### Reaching a Service from the Mac

k3s's `servicelb` (klipper-lb) is deliberately kept on (`traefik` and
`metrics-server` are the ones turned off, to cut boot time). It schedules
a small proxy pod with a host port for every `LoadBalancer` Service;
`cri-dockerd` creates that pod's sandbox as an ordinary Docker container
with a published port, and the same `PortForwarder` that already mirrors
every other published container port onto `127.0.0.1` picks it up — no
Kubernetes-aware code in that path at all. A `NodePort` Service works the
same way via kube-proxy's own port. Ports below 1024 need root to bind on
the Mac side, same as any other published port in Morbstack; pick a
Service port above 1024 (or run the daemon with elevated privileges) if
you need one of those.

## What was actually measured

Everything below was run live, one guest boot, in the priority order this
milestone specified — not simulated and not carried over from a previous
write-up.

**Cold `morb k8s enable` to a Ready node: 8.3 seconds**, measured against
a guest with no k3s payload and no prior cluster state at all (both wiped
before the run). That number includes the payload transfer — locally over
vsock, `k3s` (70 MB) and `cri-dockerd` (46 MB) landed in 0.6s and 0.3s
respectively, well over 100 MB/s — so the remaining ~7.4s is genuinely
`k3s` + `cri-dockerd` starting and the node registering Ready. A later
`enable` against a guest that already has the payload and prior cluster
state (the common case — most users install once) reaches Ready in about
4 seconds.

**Idle cost, Kubernetes on vs off**, sampled after the cluster settled
with nothing deployed against it beyond the smoke-test workload above:

| | k8s off | k8s on, idle |
| --- | --- | --- |
| Guest memory used (`free -m` in the guest) | ~137 MB | ~617 MB |
| Host-side VM process CPU (`top`, sampled over ~20s) | ~0.7% | ~20-23% |

The guest-memory delta (~480 MB) is `k3s` + `kubelet` + `cri-dockerd` +
`coredns` + `local-path-provisioner` sitting resident. The CPU delta is
almost entirely kubelet/k3s's own reconcile-and-watch loops running with
nothing to do — there is no workload in this measurement, so this is the
cost of the toggle being on, not of anything it is running.

**`morb k8s disable` stops the cluster cleanly and the engine keeps
working.** Verified: `docker ps` and a fresh `docker run --rm hello-world`
both succeed immediately after `disable`, and the Kubernetes-created
containers (`coredns`, the app pod, etc.) are simply ordinary stopped
Docker containers afterward — disable stops `k3s`/`cri-dockerd`, it does
not touch dockerd or anything dockerd already has.

**Node runtime, confirmed via `kubectl get nodes -o wide`:**
`CONTAINER-RUNTIME docker://29.7.1` — the cluster is provably running on
the same engine version as everything else, not a separate embedded one.

## Known gap this pass found (and fixed)

Kubernetes Service routing (`ClusterIP`, `NodePort`, `LoadBalancer`) did
not work at all before this pass, for every Service including the
cluster's own `kube-dns` — kube-proxy's `iptables-restore` failed
permanently with `unknown option "--xor-mark"` on every 30-second retry.
Nothing about the node or the API server showed this: nodes went Ready,
pods went Running, `docker build` + `IfNotPresent` worked, and the only
symptom was that a curl to a Service's ClusterIP or published port hung
forever.

Root cause: `scripts/mkinitramfs.sh` builds the initramfs on the Mac's
boot volume, which is APFS in its default case-**in**sensitive mode.
Alpine's `iptables` package ships both `usr/lib/xtables/libxt_MARK.so`
(the `MARK` jump target kube-proxy's rules use) and
`usr/lib/xtables/libxt_mark.so` (the unrelated `-m mark` *match* module)
in the same directory. Extracted onto a case-insensitive filesystem, the
second file silently overwrote the first — `tar` reported no error, the
initramfs built and booted fine, and the failure only surfaced minutes
later and two layers away. Fixed by staging the initramfs on a
just-in-time, case-sensitive APFS scratch volume (`hdiutil create -fs
"Case-sensitive APFS"`) instead of a plain `mktemp -d`. Verified after the
fix: both files are present in the built initramfs, kube-proxy's
`KUBE-SERVICES` chain populates real per-Service rules, and the curl in
"Why this shape" above actually returns the response over the
`LoadBalancer` Service it claims to.

This is a general fix, not a special case for these two filenames — it is
the same class of bug for any future package that ships two files whose
names differ only by case, and a plain `mktemp -d` staging directory on a
Mac cannot represent that regardless of which package hits it next.

## What is not covered

- **`kubectl exec` / `kubectl port-forward` / `kubectl logs -f`** were not
  exercised by this pass. `kubectl logs` (non-follow) and `kubectl
  describe` both work; the streaming/exec paths were not verified either
  way and no claim is made about them here.
- **Multi-node.** The node is fixed as `morbstack`; there is no join flow
  and none is planned — this is a local single-node cluster, not a
  cluster simulator.
- **`traefik` and `metrics-server`** are disabled by default (see "Why
  this shape") — `kubectl top` and ingress need an explicit
  `kubectl apply` for anyone who wants them.

## See also

- [`protocol.md`](protocol.md) §3.3 — the vsock 2377 payload install wire
  protocol, including the `HAVE`/`PUT` handshake and why it is
  sha256-verified on both ends.
- [`roadmap.md`](roadmap.md) — milestone sequencing.
