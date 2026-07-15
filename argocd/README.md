# ArgoCD example (GitOps)

Deploys the exact same [Helm chart](../helm/learnkube) used by the main [README](../README.md)'s Terraform/Helm CLI options — but through [ArgoCD](https://argo-cd.readthedocs.io/), a controller running *inside* the cluster that continuously reconciles against this repo on GitHub, rather than a command you run from your own machine.

```
argocd/
  application.yaml   ArgoCD Application pointing at helm/learnkube in this repo
```

## Push vs. pull: how this differs from every other deploy path in this project

Every deploy method in the main README — Terraform, the Helm CLI, `kubectl apply` — is a **push** model: state only changes in the cluster at the moment *you* run a command from your machine. Nothing happens in between; if someone else changes the cluster by hand, it just stays changed until you notice and push again.

ArgoCD is a **pull** model: `argocd-application-controller`, running as a pod inside the cluster, continuously polls this repo (every ~3 minutes by default, or immediately via a webhook) and reconciles the live cluster state to match whatever's in Git — with no `kubectl`/`helm`/`terraform` command involved at all once it's set up. This project's `git@github.com:pip2024/learnkube.git` becomes the actual source of truth; the cluster is just a reflection of it.

## 1. Install ArgoCD into minikube

```sh
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml --server-side
```

`--server-side` is required here, not optional. Plain `kubectl apply` records the entire applied object into a `kubectl.kubernetes.io/last-applied-configuration` annotation (used for future 3-way merges), and Kubernetes caps total annotation size on any object at 262144 bytes (256 KiB). The `applicationsets.argoproj.io` CRD in this manifest has an unusually large embedded OpenAPI schema, so that generated annotation blows past the 256 KiB cap and the API server rejects it outright:

```
The CustomResourceDefinition "applicationsets.argoproj.io" is invalid: metadata.annotations: Too long: may not be more than 262144 bytes
```

Server-Side Apply avoids this entirely — it tracks field ownership via `metadata.managedFields` instead of stuffing a JSON copy of the object into an annotation. If you hit this error from a previous attempt without `--server-side` and already have some ArgoCD objects partially applied, add `--force-conflicts` too, since SSA can otherwise complain about fields it doesn't yet consider itself the owner of:

```sh
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml --server-side --force-conflicts
```

Wait for everything to come up:

```sh
kubectl -n argocd get pods -w
```

## 2. Log in

Port-forward the ArgoCD API/UI:

```sh
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

Get the auto-generated initial admin password:

```sh
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

**Windows PowerShell** has no `base64` command — either run this in Git Bash/WSL instead, or use the native equivalent:

```powershell
[System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String((kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}')))
```

Either open `https://localhost:8080` in a browser (username `admin`, the password above — accept the self-signed cert warning), or, if you have the [ArgoCD CLI](https://argo-cd.readthedocs.io/en/stable/cli_installation/) installed:

```sh
argocd login localhost:8080 --username admin --password <password-from-above> --insecure
```

## 3. Point ArgoCD at this repo

```sh
kubectl apply -f argocd/application.yaml
```

`application.yaml`'s `spec.source.repoURL` is this project's own GitHub remote, `spec.source.path` is `helm/learnkube` (the same chart Terraform/Helm CLI use), and `spec.destination.namespace` is `learnkube-gitops` — a separate namespace, specifically so this doesn't collide with anything you deployed via the main README's steps into `default`.

**If this repo is private**, ArgoCD needs credentials to clone it — either `argocd repo add https://github.com/pip2024/learnkube.git --username <user> --password <token>` (a GitHub personal access token), or add a `repo-creds`/`repository` Secret directly; a public repo needs neither.

Watch it sync:

```sh
kubectl -n argocd get application learnkube -w
```

or, with the CLI:

```sh
argocd app get learnkube
```

`spec.syncPolicy.automated` with `prune: true` and `selfHeal: true` means: automatically apply anything new found in Git, delete anything removed from Git, and correct any drift — all without you ever running `argocd app sync` by hand (though that command exists for manual/non-automated setups).

Confirm the app is actually running, in its own namespace:

```sh
kubectl -n learnkube-gitops get pods
```

## 4. See the GitOps loop in action

**A change pushed to Git gets applied automatically, with no deploy command from you:**

```sh
# edit helm/learnkube/values.yaml, e.g. change replicaCount: 1 -> replicaCount: 2
git add helm/learnkube/values.yaml
git commit -m "scale learnkube to 2 replicas"
git push
```

Within a few minutes (or immediately if you configure a GitHub webhook to `/api/webhook`), ArgoCD notices the new commit and reconciles on its own:

```sh
kubectl -n learnkube-gitops get pods -w
```

**Don't want to wait out the poll interval?** Force an immediate re-check instead of waiting up to ~3 minutes:

```sh
kubectl -n argocd annotate application learnkube argocd.argoproj.io/refresh=hard --overwrite
```

This tells the controller to re-fetch the repo and re-diff right now, bypassing its normal cache/poll timing — it doesn't skip `automated.selfHeal`'s own logic, it just triggers the *check* immediately rather than on the next scheduled poll. With the ArgoCD CLI, `argocd app get learnkube --hard-refresh` does the same thing. Note this only forces ArgoCD to notice a change sooner — if nothing actually changed in Git (or it wasn't pushed to `main` yet), a refresh has nothing new to sync.

**Manual drift gets reverted automatically**, because of `selfHeal: true`:

```sh
kubectl -n learnkube-gitops scale deployment/learnkube-learnkube --replicas=5
kubectl -n learnkube-gitops get pods -w   # watch it get scaled back down to match Git
```

This is the concrete difference from every other deploy path in this project: `kubectl scale` against the Deployment from the main README's step 7 sticks until you change it again; here, ArgoCD notices the drift from Git's declared state and un-does it, typically within a few minutes.

## Clean up

```sh
kubectl delete -f argocd/application.yaml
```

The `resources-finalizer.argocd.argoproj.io` finalizer in `application.yaml` makes this cascade-delete everything the Application manages (the `learnkube-gitops` namespace's Deployment/Service/etc.) before the `Application` object itself is removed — a plain `kubectl delete` without that finalizer would only delete ArgoCD's record of the app, leaving the actual deployed resources behind.

Then remove ArgoCD itself:

```sh
kubectl delete namespace argocd
kubectl delete namespace learnkube-gitops
```
