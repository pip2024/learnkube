# Pod Security Admission: cluster-level vs. namespace-level

**Windows users**: all three `.sh` scripts in this directory are POSIX shell scripts — heredocs, `head -c /dev/urandom`, `od`, the `bash -c`-or-`read` fallback for the pause prompt — none of which PowerShell or cmd.exe can run. Execute them from **Git Bash** or **WSL**, not PowerShell (e.g. `sh ./kind-with-cluster-level-baseline-pod-security.sh`, or `./script.sh` directly if it's marked executable).

This directory also has `kind-with-encryption-at-rest.sh`, which is a different topic (etcd storage protection, not pod admission) — see its own comments and [`../secrets/README.md`](../secrets/README.md) for that one.

One thing worth calling out about that script specifically: it generates its own AES key on the spot and owns that key's entire lifecycle itself — written to a plaintext file, read once, destroyed on cleanup. That's fine for a disposable demo, but it's *not* how you'd manage a real cluster's encryption key. With the `aescbc`/`aesgcm`/`secretbox` providers it uses, you (the cluster admin) are responsible for generating the key, copying the identical config to every API server replica, backing it up, and manually rotating it. For anything beyond a demo, the `kms` provider (stable since ~1.29) is the better answer — it delegates generation, rotation, and access policy to an external KMS (AWS KMS, GCP Cloud KMS, Vault Transit, etc.), and the API server never even sees the raw key.

The rest of this file covers the two scripts that both enforce the same [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/) policy — `enforce: baseline`, `audit`/`warn: restricted` — but configure it through two different mechanisms built into the [Pod Security Admission (PSA)](https://kubernetes.io/docs/concepts/security/pod-security-admission/) controller:

| | `kind-with-cluster-level-baseline-pod-security.sh` | `namespace-level-baseline-pod-security.sh` |
|---|---|---|
| Tutorial | [Apply Pod Security Standards at the Cluster Level](https://kubernetes.io/docs/tutorials/security/cluster-level-pss/) | [Apply Pod Security Standards at the Namespace Level](https://kubernetes.io/docs/tutorials/security/ns-level-pss/) |
| Configured via | `AdmissionConfiguration`/`PodSecurityConfiguration` YAML, passed to the API server via `--admission-control-config-file` | `pod-security.kubernetes.io/*` labels on a `Namespace` object |
| Scope | Cluster-wide default, applied to every namespace except those listed under `exemptions.namespaces` | Only the namespace(s) you label |
| When it takes effect | Only when the API server starts with that config — can't be hot-patched into a running control plane | Immediately, the moment `kubectl label` succeeds |
| Requires | Control-plane/node access (or a cluster provisioner like `kind` that lets you inject kubeadm patches) | Just RBAC permission to label namespaces (`patch`/`update` on `namespaces`) |
| Per-team self-service? | No — one policy for the whole cluster (short of the exemptions list) | Yes — any namespace owner with label permissions can opt their own namespace in or out |
| What this project's script does | Boots a throwaway `kind` cluster with the policy baked in from the first API server start, then applies a bare `nginx` pod to show it's admitted (baseline) but flagged (restricted audit/warn) | Labels an `example` namespace on an *already-running* cluster (e.g. this project's minikube), then applies the same pod to both `example` and the unlabeled `default` namespace to contrast the two |

## The shared policy model

Both scripts configure the same three independent modes, and both use them the same way:

- **`enforce`** — actually rejects a pod at admission time if it violates the given [Pod Security Standard](https://kubernetes.io/docs/concepts/security/pod-security-standards/) level. This is the only mode that blocks anything.
- **`audit`** — allows the pod through regardless, but adds a violation entry to the cluster's audit log.
- **`warn`** — allows the pod through regardless, but returns a warning message to the client (visible in `kubectl apply`/`kubectl create` output).

Each mode is set independently and can target a different Pod Security Standard level:

- `privileged` — no restrictions at all.
- `baseline` — blocks known privilege-escalation paths (e.g. `hostNetwork`, `hostPID`, `privileged: true`, dangerous `hostPath` mounts), but doesn't require hardening like running as non-root.
- `restricted` — baseline plus hardening: `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, all capabilities dropped, a `seccompProfile` set, etc.

Both scripts set `enforce: baseline` (so nothing gets rejected by their test pod, which is a plain `nginx` container with no `securityContext`) but `audit`/`warn: restricted` (so that same pod still gets flagged as *not* meeting the stricter standard, without being blocked). That combination is intentional: it's a common "detect drift toward `restricted` without breaking existing workloads yet" rollout pattern.

## Cluster-level: how it actually works

`kind-with-cluster-level-baseline-pod-security.sh` writes a `PodSecurityConfiguration` to `/tmp/pss/cluster-level-pss.yaml`, then a `kind` `Cluster` config that:

1. Bind-mounts that host directory into the `kind` node's filesystem at `/etc/config` (`extraMounts`).
2. Patches the node's `kubeadm` `ClusterConfiguration` so the API server is started with `--admission-control-config-file=/etc/config/cluster-level-pss.yaml` (`kubeadmConfigPatches`).

Because this flag only takes effect when the API server process starts, the whole cluster has to be created (or the control plane restarted) with this config already in place — there's no `kubectl` command that applies it to a running cluster. That's also why the script spins up a brand-new disposable `kind` cluster rather than reusing an existing one.

The `exemptions.namespaces: [kube-system]` entry in the config is what keeps this from also blocking the cluster's own system pods, many of which legitimately need `hostNetwork`/`hostPID` and would otherwise fail even `baseline`.

## Namespace-level: how it actually works

`namespace-level-baseline-pod-security.sh` does the equivalent configuration with six labels on a `Namespace` object:

```sh
kubectl label --overwrite ns example \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/enforce-version=latest \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/warn-version=latest \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/audit-version=latest
```

The PodSecurity admission plugin is already compiled into any modern (1.25+) API server and enabled by default — no `--admission-control-config-file` needed. It just checks for these labels on the target namespace of every pod-creating request, live, on every request. That's why this script can run against an already-running cluster (this project's minikube) instead of needing a special cluster-creation step: labeling a namespace takes effect the instant `kubectl label` returns, and un-labeling it (or deleting the namespace, as the script's cleanup does) removes the policy just as instantly.

## Which one wins if both are configured?

They compose, they don't conflict. The cluster-level `AdmissionConfiguration` sets the *default* policy for every namespace (short of its exemption list). Namespace labels **override** that default for whichever namespace they're set on. So a real cluster might reasonably run both at once: a cluster-level `baseline` default from the cluster-level script's approach, with individual teams layering stricter `pod-security.kubernetes.io/enforce=restricted` labels onto their own namespaces via the namespace-level approach, without needing cluster-admin access to do so.

## When to reach for which

- **Cluster-level** — you want one non-negotiable floor for the entire cluster (e.g. "nothing outside `kube-system` may ever run `hostNetwork`"), enforced in a way individual namespace owners can't opt out of by editing a label.
- **Namespace-level** — you want per-team/per-workload granularity, want changes to take effect without a control-plane change, or don't have (or want to require) node/control-plane access just to adjust a security policy.
