# Operator pattern example

`argocd/` already has a running example of this pattern, without calling it out at the time: ArgoCD's `Application`/`ApplicationSet` objects are [CustomResourceDefinitions](https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/), and `argocd-application-controller` is an [Operator](https://kubernetes.io/docs/concepts/extend-kubernetes/operator/) — a controller that watches those CRs and continuously reconciles the live cluster to match what they declare. This example builds a minimal version of that exact same mechanism from scratch, for a toy resource of our own.

```
operator/
  crd.yaml               the LearnKubeApp CustomResourceDefinition
  example-resource.yaml   a sample LearnKubeApp object to create
  rbac.yaml               ServiceAccount + ClusterRole(Binding) for the operator
  deployment.yaml         runs the operator's own controller pod
  controller/
    handlers.py            the reconcile logic (Python, using kopf)
    requirements.txt
    Dockerfile
```

## Terminology: the CRD, the Kind, and a custom resource are three different things

Three names get used throughout this file, and they refer to three distinct layers, not synonyms for "our custom thing":

1. `learnkubeapps.learnkube.dev` — the actual **CRD** (`kind: CustomResourceDefinition`, in `crd.yaml`). Applying this object is what teaches the API server about a new type.
2. `LearnKubeApp` — the **Kind** that CRD registers. Once `crd.yaml` is applied, `LearnKubeApp` becomes usable as a `kind:` value, the same way `Deployment` or `Pod` already are (those just happen to be compiled in rather than registered dynamically — there's no `CustomResourceDefinition` object for `Deployment` at all).
3. `demo` (`example-resource.yaml`) — a **custom resource**: one specific *instance* of the `LearnKubeApp` Kind. Same relationship as a specific Deployment object being an instance of the `Deployment` Kind.

`reconcile()` in `handlers.py` watches for objects at layer 3, using the `(group, version, plural)` that layer 1 registered.

## A CRD alone does nothing

Applying `crd.yaml` (layer 1) only teaches the API server about the new `LearnKubeApp` shape (layer 2) — it lets you `kubectl apply` a `LearnKubeApp` object and have it validated and stored, same as any built-in Kind. But unlike a `Deployment` (which `kube-controller-manager`'s built-in Deployment controller is always watching) or ArgoCD's `Application` (which `argocd-application-controller` watches), nothing is watching a plain custom CRD by default. Apply `example-resource.yaml` right after just the CRD, with no operator running yet, and it will just sit there inertly — `kubectl get learnkubeapp demo` succeeds, but nothing else happens in the cluster. **The operator is what makes the CRD do anything at all** — that pairing (CRD + controller watching it) is the entire Operator pattern.

## What the operator actually does

`controller/handlers.py` uses [kopf](https://kopf.readthedocs.io/) (Kubernetes Operator Pythonic Framework), which handles the watch/informer machinery, retries, and event loop for you — comparable to what `controller-runtime` provides for Go operators built with Kubebuilder/Operator SDK, just in Python.

One function, `reconcile()`, is registered for both `@kopf.on.create` and `@kopf.on.update` on `learnkube.dev/v1 LearnKubeApp` objects. On either event, it builds three plain manifests — a `ConfigMap` (for `spec.greeting`, mounted the same way the main app already expects at `/etc/config/greeting` — no app code changes needed), a `Deployment` (`spec.replicas`, `spec.image`), and a `Service` — and upserts each one (create, or patch if it already exists — a 409 Conflict on create means "already there, patch it instead").

**Notice there's no `@kopf.on.delete` handler anywhere.** `kopf.adopt()` sets an `ownerReference` on all three generated objects, pointing back at the `LearnKubeApp`. That's enough for Kubernetes' own garbage collector to cascade-delete the ConfigMap/Deployment/Service automatically the moment the `LearnKubeApp` is deleted — the exact same mechanism that deletes a Deployment's ReplicaSet (and that ReplicaSet's Pods) when you delete the Deployment. The operator only had to declare the relationship once, at creation time; it didn't have to write any cleanup code.

## So what's actually running when a create/update fires?

Stack up what the last two sections established: one function, `reconcile()`, is registered for *both* `create` and `update` events, and there's no `delete` handler at all — Kubernetes' garbage collector handles that half on its own. That raises the obvious next question: when an event does fire and `reconcile()` runs, what is actually executing it? A dedicated worker spun up for that one event? A fresh pod, the way a Deployment creates a fresh pod per replica?

No — it's simpler than that, and worth being precise about since it's an easy thing to conflate: `@kopf.on.create` and `@kopf.on.update` are **two registrations on one already-running process**, not two separate pods, and not one pod per event either. `operator/deployment.yaml` defines exactly one Deployment, running one container (`kopf run --all-namespaces handlers.py`) — that single Python process opens the watch connection described above once, and keeps running indefinitely. When a `LearnKubeApp` is created or updated, kopf doesn't spin up anything new to handle it; it just calls `reconcile()` as a coroutine inside that same already-running pod. Add five more handler functions to `handlers.py` tomorrow, for five different CRDs, and all of them would still run inside that one pod.

Where "separate pod" genuinely applies is at the level of separate **operators** — separate controller programs entirely. This project's `operator/` (watching `LearnKubeApp`) and ArgoCD's own `argocd-application-controller` (watching `Application`/`ApplicationSet`, from `argocd/`) are two independent operators with two independent Deployments, so they really do run in two different pods (`kubectl get pods -l app=learnkube-operator` vs. `kubectl -n argocd get pods`) — but that's because they're two different codebases, not because each handler function gets its own pod.

One consequence of this worth knowing: `operator/deployment.yaml` deliberately runs `replicas: 1`. Scale it up and you'd get multiple pods all running the identical `handlers.py`, all watching the same objects, with nothing stopping them from racing each other to reconcile the same `LearnKubeApp` concurrently — real operators solve this with leader election (kopf calls its version of this "peering"), which this example doesn't set up at all.

## A loose end: where does `reconcile()`'s return value actually go?

Look again at the end of `reconcile()` in `handlers.py`:

```python
return {"configmap": config_name, "deployment": app_name, "service": app_name}
```

kopf's convention is that whatever a handler returns gets written onto the custom resource's `.status` field — so after reconciling, `kubectl get learnkubeapp demo -o yaml` will show that dict under `status.reconcile`. Fair enough — but that raises a question worth pausing on, since it touches something you'll run into in the next two files: **what request does that write actually turn into, and against which endpoint?**

`rbac.yaml` (used in the next section) already hints at the answer without explaining it — it grants the operator's ServiceAccount `patch` on two different things:

```yaml
- apiGroups: ["learnkube.dev"]
  resources: ["learnkubeapps"]
  verbs: ["get", "list", "watch", "patch"]
- apiGroups: ["learnkube.dev"]
  resources: ["learnkubeapps/status"]
  verbs: ["get", "patch"]
```

`learnkubeapps/status` there isn't a typo or a nested field reference — it's a **subresource**: an additional REST endpoint nested under a resource's main URL (`/apis/<group>/<version>/namespaces/<ns>/<plural>/<name>/<subresource>`), a general Kubernetes mechanism, not something specific to `status`. A few built-in examples: `pods/log` (streams log text, not a stored field at all), `pods/exec`/`pods/portforward` (upgrade to a streaming protocol — what `kubectl exec`/`kubectl port-forward` actually call), and `deployments/scale` (a small generic `Scale` object with just `replicas`, used by `kubectl scale` and the HPA so neither has to understand a full Deployment).

By convention, an object's `spec` (desired state, written by users/clients) and `status` (observed state, written by a controller) are logically separate concerns — but whether `.status` is backed by an *actual* separate subresource endpoint, as opposed to just being a field on the one main endpoint, depends entirely on one line in the CRD: `subresources: { status: {} }` under `spec.versions[]`. Go check `crd.yaml` — that line isn't there. Which means, in this project as it stands right now:

- There's only **one** endpoint for the whole `LearnKubeApp` object: `PATCH .../learnkubeapps/demo`. A single write there can touch `spec` and `status` together — which is exactly how `reconcile()`'s return value reaches `.status` today: kopf PATCHes it onto the main object, no separate endpoint involved.
- The plain `patch` verb on `learnkubeapps` is therefore all the operator actually needs. The second rule in `rbac.yaml`, for `learnkubeapps/status`, was written defensively, anticipating this subresource — but since `crd.yaml` never declares it, there's no `/status` endpoint for that RBAC rule to apply to. Right now, it's dead permission.

Here's why you'd normally want it anyway: **if** `subresources: { status: {} }` were added to `crd.yaml`, the API server would split this into two independently addressable endpoints — `PATCH .../learnkubeapps/demo` only ever touching `spec`/`metadata`, and `PATCH .../learnkubeapps/demo/status` only ever touching `status`, each silently ignoring the other half of whatever payload it's sent. That split buys you two things:

1. **RBAC that's actually enforced, not just conventional** — grant regular users `patch` on `learnkubeapps` (so they can edit `spec.replicas`) while granting only the operator's ServiceAccount `patch` on `learnkubeapps/status` — "users declare intent, only the controller reports what happened" becomes a real access-control boundary instead of a gentleman's agreement.
2. **No accidental clobbering** — a user's `kubectl edit` on `spec` can't wipe out a field the operator just wrote to `status`, or vice versa, regardless of what either payload contains.

This project's CRD skips it for simplicity — a toy operator with no other writer touching these objects has nothing to protect against yet — but it's the pattern real operators reach for as soon as more than one actor (users, and a controller) is writing to the same object.

## Try it

Build and load the operator's own image (same pattern as the main app):

```sh
docker build -t learnkube-operator:v1 operator/controller/
minikube image load learnkube-operator:v1
```

Install the CRD, then the operator's RBAC and Deployment:

```sh
kubectl apply -f operator/crd.yaml
kubectl apply -f operator/rbac.yaml -f operator/deployment.yaml
```

Watch it start up:

```sh
kubectl logs -l app=learnkube-operator -f
```

What you're watching boot up here is worth understanding, since it's the step that actually loads `reconcile()`. `controller/Dockerfile`'s `CMD` is `kopf run --all-namespaces handlers.py` — `kopf` is a CLI executable (`pip install kopf` registers it as a console-script entry point, so it's directly runnable, not `python -m kopf`). On startup, `kopf run` imports/executes `handlers.py` exactly the way `python handlers.py` would: every top-level statement runs in order, including the `def reconcile(...):` line with its two decorators on top. Decorators fire at *definition* time, not call time — ordinary Python semantics, nothing kopf-specific — so the instant that line executes during this import, `@kopf.on.create(...)` and `@kopf.on.update(...)` both run immediately. What they do isn't wrap or replace `reconcile`; they just add an entry to kopf's own internal registry (a table mapping `(cause, group, version, plural)` → the function object) pointing at it. `reconcile` itself comes out unchanged as a plain function. Only *after* that import finishes — so the registry is fully populated — does `kopf run` start the actual LIST-then-WATCH event loop from earlier in this file. From then on, whenever an event's classified cause matches something in the registry, kopf looks up and calls the corresponding function. There's no re-importing or reloading per event; the process just stays resident, dispatching to whatever got registered once at startup.

Create the example resource:

```sh
kubectl apply -f operator/example-resource.yaml
```

Watch the operator's log pick up the create event and reconcile — then look at what it created:

```sh
kubectl get learnkubeapps            # custom columns: NAME, REPLICAS, GREETING, AGE
kubectl get configmap,deployment,service -l app=demo-learnkube
```

Port-forward and curl to see `spec.greeting` reflected in the running app, same as the ConfigMap example in the root README's step 9:

```sh
kubectl port-forward deployment/demo-learnkube 8080:8080
curl http://localhost:8080   # "Howdy Kubernetes v1 from pod ... (request #1)"
```

### Change the spec, watch it reconcile

```sh
kubectl patch learnkubeapp demo --type merge -p '{"spec":{"replicas":3}}'
kubectl get pods -l app=demo-learnkube -w
```

No new command was needed beyond editing the custom resource itself — same idea as `kubectl scale`, except this one's implemented by *our* controller instead of the built-in Deployment controller.

### Delete it, watch the cascade

```sh
kubectl delete learnkubeapp demo
kubectl get configmap,deployment,service -l app=demo-learnkube   # all gone
```

## Clean up

```sh
kubectl delete -f operator/example-resource.yaml --ignore-not-found
kubectl delete -f operator/deployment.yaml -f operator/rbac.yaml
kubectl delete -f operator/crd.yaml
```

Deleting the CRD last also removes any remaining `LearnKubeApp` custom resources of that kind, cluster-wide.

## How this compares to ArgoCD

Same fundamental mechanism (CRD + a controller reconciling it), much smaller in scope. What ArgoCD's real operator adds on top of what's here: leader election across multiple controller replicas (this one only ever runs 1), rich `.status` conditions and a proper health-assessment model (ours just dumps a small dict), sync waves/hooks for ordering multi-resource rollouts, and a UI/CLI/API layer. The core loop — watch a custom resource, diff it against live cluster state, reconcile the difference — is identical.

## The takeaway: a CRD is a contract, not a behavior

Worth restating plainly, now that all the pieces are in view: `crd.yaml`'s `openAPIV3Schema` only specifies that `spec.replicas`/`spec.greeting`/`spec.image` are valid, typed fields a `LearnKubeApp` is allowed to have — plus, more broadly, it registers the whole `LearnKubeApp` Kind itself (its group/version, its REST path, namespaced scope, the printer columns). None of that says what those fields *mean*. `crd.yaml` has no idea `spec.greeting` is supposed to end up in a ConfigMap, or that `spec.replicas` is supposed to control a Deployment's pod count.

That meaning is supplied entirely by `reconcile()` in `handlers.py` — a completely separate piece of code that just happens to read `spec.get("greeting")` and decide to do something about it. Change the CRD's schema without touching the operator, and you get a new field that's valid but inert. Change the operator without touching the schema, and it'd be reading a field the API server never validated as intentional. **The CRD is the contract (what shape is allowed); the operator is the behavior (what actually happens because of it).** Neither half does anything useful without the other — which is really just "A CRD alone does nothing" from the top of this file, restated now that you've seen exactly what fills that gap.
