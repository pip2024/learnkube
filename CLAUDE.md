# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A hands-on scaffold for working through kubernetes.io's `/docs/tutorials/` tree against a local minikube cluster, rather than just reading the docs. Every concept gets a runnable example that mostly reuses one shared Python app instead of throwaway nginx/busybox snippets, so later examples build on earlier ones. There is no application build/test/lint pipeline — "running" a change means deploying it to a real (or local) Kubernetes cluster and observing behavior with `kubectl`.

The root `README.md` has a "## Examples in this repo" section that is the canonical table of contents and recommended reading order. **Whenever a new example subdirectory is added, add it there too** — that section is the single source of truth for reading order, and it's easy to forget.

## Core commands

```sh
minikube start
docker build -t learnkube:v1 app/
minikube image load learnkube:v1        # required before any deploy path below will find the image
minikube image ls | grep learnkube      # verify it actually loaded
```

**`minikube image load` can silently no-op.** If minikube's internal image cache already has *something* tagged `learnkube:v1` (from any earlier session), re-running `minikube image load learnkube:v1` after a code change can fail to actually overwrite it — no error, it just keeps serving the stale image, so pods restart with old code and the tag/digest looks unchanged. Symptom: behavior doesn't match the code you just wrote, no matter how many times you rebuild/redeploy. Confirm you're not hitting this before debugging anything else:
```sh
docker images learnkube:v1 --no-trunc                              # local image ID
minikube image ls --format table | grep learnkube                  # what minikube actually has cached
kubectl get pod -l app=<app> -o jsonpath='{.items[0].status.containerStatuses[0].imageID}'  # what the running pod uses
```
If these three don't match, force a real reload — scale to 0 first, since `minikube image rm` fails while any pod references the image:
```sh
kubectl scale deployment/<name> --replicas=0
minikube image rm learnkube:v1
minikube image load learnkube:v1
kubectl scale deployment/<name> --replicas=1
```

Three parallel, equivalent ways to deploy `helm/learnkube` into the `default` namespace (all documented in root `README.md` as Options A/B/C at each step):

```sh
# A: Terraform (wraps helm_release)
cd terraform && terraform init && terraform apply

# B: Helm CLI directly
helm install learnkube helm/learnkube

# C: plain kubectl manifests (k8s/), no Helm/Terraform involved
kubectl apply -f k8s/
```

**Naming gotcha**: Options A/B (Helm-based) produce objects named `learnkube-learnkube` (`<release-name>-learnkube`, since the chart's templates prefix everything with `{{ .Release.Name }}`); Option C's plain manifests just use `learnkube`. Most later steps show both forms side by side (`# Options A/B` / `# Option C` comments in command blocks) — check which deploy path is actually running before copy-pasting a `kubectl` command from the README.

Each example subdirectory (`secrets/`, `security/`, `stateful/`, `argocd/`, `operator/`, `otel/`) is self-contained with its own manifests and its own `README.md` walkthrough — read that file rather than guessing, each has its own prerequisites and cleanup steps.

**Windows**: run all `sh`-labeled commands and every `security/*.sh` script in Git Bash or WSL, never PowerShell/cmd.exe — they use heredocs, `base64`, `od`, `head -c /dev/urandom`, none of which exist there. A few READMEs (`secrets/`, `argocd/`) include PowerShell-native equivalents where this actually comes up (base64 decode of a Secret's value).

## Architecture

**The shared app** (`app/server.py`, image `learnkube:v1`, built from `app/Dockerfile`) is a small Flask server whose behavior is driven entirely by file/env inputs, not application logic — this is deliberate, so different examples can exercise different Kubernetes mechanisms against the exact same image:
- `APP_VERSION` env var — read once at container start (used to demonstrate that env-var-backed config needs a pod restart to pick up changes)
- `GREETING_FILE` (default `/etc/config/greeting`) — read fresh on every request from a ConfigMap volume mount (demonstrates that mounted-file config updates live, no restart needed)
- `LOG_FILE` (default `/var/log/learnkube/app.log`) — appended on every request; read by the `logshipper` sidecar container in `helm/learnkube`'s Deployment
- `COUNTER_FILE` (default `/data/counter.txt`) — incremented on every request, persisted to whatever's mounted at `/data` (a PVC in most examples), used to prove storage survives pod deletion/rescheduling
- `OTEL_EXPORTER_OTLP_ENDPOINT` — unset by default (every example except `otel/` leaves it unset). The app always uses the OpenTelemetry API unconditionally (a span + counter + histogram per request), which is a safe no-op until this var is set and a real SDK provider gets registered — so instrumentation code runs everywhere, but only actually exports anywhere in `otel/`. Same "inert unless configured" pattern as the other three inputs.

If you change `app/server.py` or `app/requirements.txt`, **rebuild and reload the image** (`docker build ...; minikube image load learnkube:v1`) — every example shares this one image tag, so a stale cached image silently masks code changes.

**`helm/learnkube`** is the canonical chart (Deployment + Service + ConfigMap + PVC, plus a native sidecar `initContainer` with `restartPolicy: Always`) that Terraform, the Helm CLI, and `argocd/` all point at. `k8s/` is a hand-maintained plain-YAML mirror of the same shape (no templating) for the `kubectl`-only deploy path — if you change one, check whether the other needs the equivalent change.

**Example subdirectories each isolate one concept**, generally by reusing `learnkube:v1` rather than introducing new app code:
- `secrets/` — Secrets via two dedicated busybox pods (env var vs. volume mount), paired with the ConfigMap lesson in the root README's step 9 (same live-update-vs-restart-needed asymmetry).
- `security/` — three standalone `.sh` scripts: Pod Security Admission at the cluster level (bakes an `AdmissionConfiguration` into a throwaway `kind` cluster at boot) vs. namespace level (labels a `Namespace` on the existing minikube cluster, no special bootstrapping), plus an encryption-at-rest demo that reads Secret bytes directly out of etcd via `etcdctl` to show the difference between unencrypted (literal plaintext, not even base64) and encrypted (`k8s:enc:aescbc:v1:`-prefixed) storage.
- `stateful/` — `learnkube:v1` run as a StatefulSet with `volumeClaimTemplates` (one PVC per pod ordinal, named `data-<pod-name>`), contrasted against the root README's Deployment + single shared PVC.
- `argocd/` — a fourth deploy path for the same `helm/learnkube` chart, via an ArgoCD `Application` pointed at this repo's own GitHub remote, deployed into its own `learnkube-gitops` namespace specifically to avoid colliding with whatever's in `default` from the other three deploy paths. The core point of this example is contrasting ArgoCD's pull/reconcile model against the push model of every other deploy path.
- `operator/` — a custom `LearnKubeApp` CRD plus a Python controller (`kopf`) that reconciles it into a ConfigMap+Deployment+Service, explicitly framed as "the same CRD+controller mechanism `argocd/` already relies on," built from scratch for a toy resource. Notably has no `@kopf.on.resume` handler (pre-existing objects aren't picked up on operator restart) and no `subresources: { status: {} }` on the CRD (spec and status share one PATCH endpoint) — both are called out inline as deliberate simplifications, not oversights.
- `otel/` — deploys Grafana's all-in-one `grafana/otel-lgtm` image (Loki+Grafana+Tempo+Mimir+an OTel Collector in one container, no persistence — intentionally not how production LGTM is deployed) and points the shared app's OTLP exporters (traces + metrics + logs, all three signals) at it via `OTEL_EXPORTER_OTLP_ENDPOINT`. The only example that actually touches `app/server.py`'s behavior rather than just its deployment shape — rebuild/reload `learnkube:v1` after pulling changes here.

Recurring cross-cutting themes worth knowing before touching any example: the ConfigMap/Secret env-var-vs-volume-mount update asymmetry (shows up in root README step 9 and `secrets/`), ownerReference-driven garbage collection vs. deliberately-retained PVCs (Deployment/Service cascade-delete automatically in `operator/`; PVCs in `stateful/` do **not** auto-delete with their StatefulSet, by design), and the push-vs-pull deploy model split (`argocd/` vs. everything else).
