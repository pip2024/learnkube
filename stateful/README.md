# StatefulSet example

Based on the [StatefulSet Basics](https://kubernetes.io/docs/tutorials/stateful-application/basic-stateful-set/) tutorial. Reuses the same `learnkube:v1` image built and loaded into minikube in the main [README](../README.md) (steps 1-2) — no rebuild needed — but runs it as a `StatefulSet` instead of a `Deployment`, to contrast with the Deployment + single shared PVC example in the main README's step 11.

```
stateful/
  service.yaml       headless Service (clusterIP: None) — gives each pod a stable DNS name
  statefulset.yaml    StatefulSet with a volumeClaimTemplate — gives each pod its own PVC
```

## Deployment vs. StatefulSet

| | Deployment (main README) | StatefulSet (this example) |
|---|---|---|
| Pod names | Random suffix (`learnkube-7d8f9c9b7-x2kqp`) | Stable, ordered (`learnkube-0`, `learnkube-1`, `learnkube-2`) |
| Storage | One `PersistentVolumeClaim`, defined once — if scaled beyond 1 replica, every pod mounts the *same* PVC | `volumeClaimTemplates` — Kubernetes creates a **separate** PVC per pod ordinal (`data-learnkube-0`, `data-learnkube-1`, ...), which follows that ordinal across restarts/rescheduling |
| Scaling order | Unordered — all replicas created/terminated roughly in parallel | Ordered — pods created and made `Ready` sequentially (0, then 1, then 2...); on scale-down, terminated in reverse order (2, then 1, then 0) |
| Network identity | None — pods are interchangeable, reached only via the Service | Each pod gets a stable DNS name via a required **headless Service**: `<pod-name>.<service-name>.<namespace>.svc.cluster.local` |
| Typical use case | Stateless web servers/APIs, where any replica can serve any request | Databases, queues, or coordination services where each member has distinct identity/data (e.g. a primary vs. replicas, or a quorum where member identity matters) |
| PVC lifecycle | Deleted along with the Deployment (Helm/Terraform/`kubectl delete`) | **Retained by default** even after the StatefulSet or its pods are deleted — must be cleaned up separately |

## Why the pod name matters (it's not cosmetic)

The stable pod name isn't just a nicer label — it's the actual mechanism that makes per-replica storage possible at all.

`volumeClaimTemplates` names each generated PVC as `<template-name>-<pod-name>`, which is why you end up with `data-learnkube-0`, `data-learnkube-1`, `data-learnkube-2`. The pod's name is the **key** Kubernetes uses to know which PVC belongs to which replica. So when `learnkube-1` is deleted, the StatefulSet controller doesn't just create "a" replacement pod — it specifically recreates one named `learnkube-1` again, precisely *because* that's the only way it can deterministically reattach `data-learnkube-1` to the right pod. If pod naming weren't stable (as with a Deployment, where every replacement pod gets a brand-new random name), there'd be no way to answer "which PVC does this new pod get?" without some other bookkeeping layer.

Compare that to the main README's Deployment + single-PVC example (step 11): there, every pod — whatever its random name — mounts the *same one* PVC. There's no per-replica identity-to-storage binding at all; it's one shared volume that happens to be attached to however many pods currently exist. Scaling that Deployment past 1 replica doesn't give each replica its own data — a StatefulSet's per-ordinal PVC is a fundamentally different storage model, not just "the Deployment example but with more pods."

The same stable name is also what a headless Service turns into a fixed DNS entry (`learnkube-1.learnkube-headless.default.svc.cluster.local`), which is the other reason StatefulSets exist independent of storage — distributed systems (see the Cassandra/ZooKeeper tutorials in this same "Stateful Applications" category) often need peers to address a *specific* member by a name that never changes across restarts, e.g. for leader election or replica-set configuration keyed by ordinal.

### Each pod's PVC is bound to its own PV

Everything above talks about each pod getting its own **PVC** — worth being precise about whether that also means its own **PV**, since the two terms get used almost interchangeably but aren't the same object. Strictly, `volumeClaimTemplates` creates one **PVC** per pod ordinal — the "own PV per pod" result follows from the ordinary rule that a PVC always binds to exactly one PV (that's true with or without a StatefulSet). What's specific to a StatefulSet is generating a *separate PVC per pod* in the first place, instead of one shared PVC every replica references. Each of those per-pod PVCs then gets bound to its own distinct PV by the cluster's dynamic provisioner (minikube's `hostPath`-backed `standard` StorageClass, same as the main README's step 11) — so yes, each pod does end up with its own dedicated PV, but that's a consequence of each pod having its own PVC, not a separate mechanism.

Confirm the distinct PVC-to-PV bindings directly:

```sh
kubectl get pvc -l app=learnkube-stateful -o custom-columns=PVC:.metadata.name,PV:.spec.volumeName
```

Each row shows a different PVC bound to a different PV name.

## Try it

Deploy:

```sh
kubectl apply -f stateful/service.yaml -f stateful/statefulset.yaml
```

Watch the ordered rollout — `learnkube-0` reaches `Running`/`Ready` before `learnkube-1` is even created, and so on:

```sh
kubectl get pods -l app=learnkube-stateful -w
```

Notice each pod got its own PVC, not a shared one:

```sh
kubectl get pvc -l app=learnkube-stateful
```

You should see `data-learnkube-0`, `data-learnkube-1`, `data-learnkube-2` — three separate claims, one per pod.

### Each pod has independent state

Port-forward to each pod individually (not the Deployment/Service — we want to hit one specific ordinal) and curl it a few times:

```sh
kubectl port-forward pod/learnkube-0 8080:8080   # in one terminal
curl http://localhost:8080                        # in another; repeat a few times
```

Repeat for `learnkube-1` and `learnkube-2` (stop the previous port-forward first, or use different local ports). Each pod's request counter starts from 1 and increments independently — unlike the Deployment example in the main README, where every replica would read/write the *same* `/data/counter.txt` on the one shared PVC.

### Identity and storage survive pod deletion

Delete one pod directly:

```sh
kubectl delete pod learnkube-1
kubectl get pods -l app=learnkube-stateful -w
```

The replacement pod comes back as `learnkube-1` again — not a new randomly-named pod, and its PVC (`data-learnkube-1`) is reattached automatically. Port-forward to it and curl: the counter continues from where it left off, because the StatefulSet guarantees ordinal *N* always gets the same PVC, no matter how many times that pod is recreated.

### Scaling preserves per-replica storage

Scale down, then back up:

```sh
kubectl scale statefulset/learnkube --replicas=1
kubectl get pods -l app=learnkube-stateful -w    # learnkube-2 terminates first, then learnkube-1
kubectl get pvc -l app=learnkube-stateful         # data-learnkube-1 and data-learnkube-2 are still there

kubectl scale statefulset/learnkube --replicas=3
```

`learnkube-1` and `learnkube-2` come back bound to their original PVCs, so their counters resume from their previous values instead of starting over at 1 — the PVCs were never deleted by scaling down, only the pods were.

## Clean up

```sh
kubectl delete -f stateful/service.yaml -f stateful/statefulset.yaml
```

This does **not** delete the PVCs — that's intentional StatefulSet behavior (protects against accidentally losing data from a scale-down or an accidental StatefulSet deletion). Remove them explicitly once you're actually done:

```sh
kubectl delete pvc -l app=learnkube-stateful
```
