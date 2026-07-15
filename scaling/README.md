# Scaling: horizontal, vertical, and (conceptually) node-level

"Scaling" in Kubernetes actually means three distinct things, at three different layers, each with a different mechanism:

| Layer | Question it answers | Mechanism | Runs in this example? |
|---|---|---|---|
| Horizontal (pod count) | How many copies of my app should run? | `HorizontalPodAutoscaler` (HPA) | Yes |
| Vertical (pod size) | How much CPU/memory should each copy get? | In-place Pod resize (`kubectl patch --subresource=resize`) | Yes |
| Node-level (cluster size) | Do I have enough machines to run all these pods on? | Karpenter (or the older Cluster Autoscaler) | No — conceptual only, see below |

```
scaling/
  hpa-deployment.yaml   Deployment + Service with CPU requests set (required for HPA)
  hpa.yaml               HorizontalPodAutoscaler targeting that Deployment
  resize-pod.yaml         standalone Pod with a resizePolicy, for the vertical demo
```

## Horizontal: HorizontalPodAutoscaler

Enable the metrics pipeline HPA reads from — without this, the HPA has no CPU data to act on at all:

```sh
minikube addons enable metrics-server
```

Deploy the app (with CPU requests set, per the comment in `hpa-deployment.yaml`) and the HPA:

```sh
kubectl apply -f scaling/hpa-deployment.yaml -f scaling/hpa.yaml
kubectl get hpa learnkube-hpa --watch
```

Initially this should show `0%/50%` and `1` replica — no load yet.

Generate load in another terminal, same pattern as the official [HPA walkthrough](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale-walkthrough/):

```sh
kubectl run -i --tty load-generator --rm --image=busybox:1.28 --restart=Never -- /bin/sh -c "while sleep 0.01; do wget -q -O- http://learnkube-hpa:8080; done"
```

Watch `kubectl get hpa learnkube-hpa --watch` — within a minute or two, CPU utilization should climb well past 50%, and `REPLICAS` should climb from 1 toward 5 (`maxReplicas`). Stop the load generator (Ctrl+C) and watch it scale back down — scale-down is deliberately more conservative/slower than scale-up, to avoid thrashing.

`kubectl get hpa` doing the scaling is really just `kubectl scale`-equivalent behavior driven automatically by a control loop, instead of you running the command by hand (root README step 7).

## Vertical: in-place Pod resize

Deploy the standalone pod:

```sh
kubectl apply -f scaling/resize-pod.yaml
kubectl get pod learnkube-resize-demo -o jsonpath='{.spec.containers[0].resources}{"\n"}'
```

Resize its CPU request live — no restart, since `resizePolicy` marks `cpu` as `NotRequired`:

```sh
kubectl patch pod learnkube-resize-demo --subresource=resize --type='json' -p='[{"op":"replace","path":"/spec/containers/0/resources/requests/cpu","value":"200m"}]'
kubectl get pod learnkube-resize-demo -o jsonpath='{.status.containerStatuses[0].resources}{"\n"}'
```

Confirm the container didn't restart (`RESTARTS` stays `0`):

```sh
kubectl get pod learnkube-resize-demo
```

Now resize memory — this one restarts the container, since `resizePolicy` marks `memory` as `RestartContainer`:

```sh
kubectl patch pod learnkube-resize-demo --subresource=resize --type='json' -p='[{"op":"replace","path":"/spec/containers/0/resources/requests/memory","value":"256Mi"}]'
kubectl get pod learnkube-resize-demo -w
```

You should see `RESTARTS` increment this time.

**Requires Kubernetes 1.33+** (stable as of 1.35) and a `kubectl` client new enough to support `--subresource=resize`. This is the actual built-in mechanism — distinct from the third-party **Vertical Pod Autoscaler (VPA)** project, which this example deliberately doesn't install: VPA isn't part of core Kubernetes, requires its own recommender/updater/admission-controller components installed separately, and has no official kubernetes.io walkthrough — too heavy a dependency for what this example needs to demonstrate. In-place resize is the built-in primitive VPA would ultimately call on your behalf anyway.

## Node-level: Karpenter (conceptual — doesn't run in this project)

Neither HPA nor in-place resize can help if the *nodes themselves* don't have room. If every node is already full and the HPA decides it needs a 6th replica, that pod just sits `Pending` — scheduled nowhere — until either something frees up room or a new node appears. That's the problem [Karpenter](https://karpenter.sh/) solves: it watches for `Pending`/unschedulable pods, and directly provisions right-sized cloud VM instances (calling the cloud provider's API — most mature on AWS EKS) to fit them, then joins those as new Kubernetes nodes. It also does the reverse — consolidating and terminating underutilized nodes once pods no longer need them.

This is a genuinely different kind of scaling from the other two: HPA/resize operate entirely *inside* the cluster (more pods, or bigger pods), while Karpenter operates on the cluster's own underlying infrastructure (more machines, or fewer). **It cannot run against minikube** — minikube is a single local VM/container with no cloud API behind it to provision additional nodes from; there's nothing for Karpenter to call. This isn't a "too heavy, skipped for simplicity" situation like VPA above — it's a structural mismatch, the same reason none of this project's examples touch real cloud infrastructure.

A few things worth knowing about it conceptually:

- **Karpenter vs. the older Cluster Autoscaler**: Cluster Autoscaler scales predefined, fixed-shape node groups (e.g. an AWS Auto Scaling Group of one instance type) up and down by count. Karpenter instead looks directly at what a pending pod actually needs (CPU/memory/architecture/GPU) and picks (or requests) whatever instance type fits best, without needing a pre-defined node group per shape — generally faster to provision and better bin-packed, at the cost of being more tied to a specific cloud provider's API model.
- **How it composes with HPA in a real production stack**: HPA decides *how many* pods should exist based on load; if the existing nodes can't fit that many, some pods go `Pending`; Karpenter watches for exactly that condition and adds nodes to fit them. They're not competing mechanisms — HPA answers "how many pods," Karpenter answers "do we have room to run that many," and in-place resize (or VPA) answers "is each one sized correctly." A real autoscaling setup typically runs some combination of all three, each solving a different layer of the same overall problem.
