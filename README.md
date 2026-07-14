# learnKube

A minimal project for working through the [Kubernetes Basics tutorial](https://kubernetes.io/docs/tutorials/kubernetes-basics/), using a Python app, a Helm chart, and Terraform. Steps below also show how to deploy with plain `kubectl` instead, for comparison.

```
app/         Python (Flask) app that reports its pod hostname and version
helm/        Helm chart that deploys the app
terraform/   Terraform config that installs the Helm chart onto your cluster
k8s/         Plain Deployment/Service manifests, for deploying with kubectl directly
```

## Prerequisites

- [minikube](https://minikube.sigs.k8s.io/) (or any local cluster) + `kubectl`
- [Helm](https://helm.sh/)
- [Terraform](https://www.terraform.io/) with the `hashicorp/helm` provider (installed automatically on `terraform init`)
- Docker

## 1. Start a cluster

```sh
minikube start
```

## 2. Build the image and load it into the cluster

```sh
docker build -t learnkube:v1 app/
```

Test it locally before loading it into the cluster:

```sh
docker run --rm -p 8080:8080 learnkube:v1
curl http://localhost:8080
```

You should see `Hello Kubernetes v1 from pod <container-id>`. Stop the container (Ctrl+C) once confirmed, then load the image into minikube:

```sh
minikube image load learnkube:v1
```

Confirm it loaded:

```sh
minikube image ls | grep learnkube
```

You should see `learnkube:v1` in the output.

## 3. Deploy (tutorial: "Create a Cluster" / "Deploy an App")

Pick one of the following. They all end up creating the same Deployment/Service; use whichever fits how you're working.

**Option A: Terraform**

```sh
cd terraform
terraform init
terraform plan
terraform apply
```

This runs `helm install` under the hood using the chart in `helm/learnkube`.

**Option B: Helm CLI**

Installs the same chart Terraform uses, but directly via Helm, without Terraform:

```sh
helm install learnkube helm/learnkube
```

**Option C: kubectl + plain manifests**

Applies the standalone manifests in `k8s/` directly — no Helm or Terraform involved:

```sh
kubectl apply -f k8s/
```

## 4. Explore the app (tutorial: "Explore Your App")

```sh
kubectl get deployments
kubectl get pods
kubectl logs <pod-name>
```

## 5. Test the app

Port-forward straight to the pod to confirm it's actually serving traffic, before setting up any external access:

```sh
kubectl port-forward deployment/learnkube-learnkube 8080:8080   # Options A/B
kubectl port-forward deployment/learnkube 8080:8080             # Option C
```

In another terminal:

```sh
curl http://localhost:8080
```

You should see `Hello Kubernetes v1 from pod <pod-name>`. Stop the port-forward (Ctrl+C) once confirmed.

`port-forward` against a Deployment resolves its label selector to matching pods and tunnels straight to one specific pod (arbitrarily chosen) — there's no load balancing, so every `curl` in this step hits that same pod even if there are multiple replicas. That's different from going through the Service in step 6, where kube-proxy load-balances across all matching pods on every request.

## 6. Expose the app (tutorial: "Expose Your App Publicly")

A `Service` is the general Kubernetes object that gives a stable address to a set of pods (pods themselves are ephemeral and get replaced with new IPs on every restart/rollout). `NodePort` is one of several *types* a Service can be:

- `ClusterIP` (the default type) — reachable only from inside the cluster
- `NodePort` — additionally opens the same port on every node's IP, so it's reachable from outside the cluster too; this is what our chart/manifests use
- `LoadBalancer` — additionally provisions an external cloud load balancer in front of the NodePort (not applicable on minikube without `minikube tunnel`)

So NodePort isn't a separate thing from Service — it's a Service with `spec.type: NodePort`, which is why `minikube service` below works: it looks up the Service's NodePort and gives you a reachable URL.

All options default to a `NodePort` Service. Reach it via:

```sh
# Terraform / Helm CLI (release name "learnkube" -> service "learnkube-learnkube")
minikube service learnkube-learnkube --url

# Plain kubectl manifests (service "learnkube")
minikube service learnkube --url
```

If you're using the `docker` driver on **Windows or macOS**, minikube prints a warning that the terminal running this command needs to stay open. That's because Docker Desktop runs containers inside a hidden VM there, so minikube has to open a foreground tunnel process to forward a local port into that VM — closing the terminal kills the tunnel and the URL stops working. On **Linux**, Docker runs natively, so the minikube container gets a real, directly routable IP on the host's Docker network — no tunnel process involved, and the URL keeps working even after you close the terminal it was printed from.

If a pod backing this Service is killed, you don't need to restart anything here. The Service selects pods by label rather than by identity, and Kubernetes maintains an `Endpoints` object listing the current matching pod IPs: the Deployment controller replaces the dead pod, the new pod gets added to `Endpoints` once it's `Ready`, and kube-proxy updates its routing accordingly — all automatically. The Service's NodePort, ClusterIP, and DNS name never change, so the URL above stays valid; you'll just see brief connection failures while the replacement pod starts. This is unlike the `port-forward` tunnel from step 5, which breaks outright when its specific pod dies since it bypasses the Service/kube-proxy layer.

## 7. Scale the app (tutorial: "Scale Your App")

```sh
# Terraform
terraform plan -var="replica_count=4"
terraform apply -var="replica_count=4"

# Helm CLI
helm upgrade learnkube helm/learnkube --set replicaCount=4

# kubectl + plain manifests
kubectl scale deployment/learnkube --replicas=4

kubectl get pods
```

## 8. Update the app (tutorial: "Update Your App")

Make a change in `app/server.py`, then rebuild and load the new image:

```sh
docker build -t learnkube:v2 app/
minikube image load learnkube:v2
```

Then roll it out:

```sh
# Terraform
terraform plan -var="image_tag=v2"
terraform apply -var="image_tag=v2"

# Helm CLI
helm upgrade learnkube helm/learnkube --set image.tag=v2 --set appVersion=v2

# kubectl + plain manifests
kubectl set image deployment/learnkube learnkube=learnkube:v2

kubectl rollout status deployment/learnkube-learnkube   # Options A/B
kubectl rollout status deployment/learnkube             # Option C
```

`kubectl apply` (or `kubectl set image`, which is really just a targeted patch) is what *causes* the update: it changes the Deployment object's desired state — here, the pod template's image. Kubernetes' Deployment controller notices that diff and automatically starts a rolling update in response, replacing old pods with new ones a few at a time. You don't invoke a separate command to "start the rollout" — updating the Deployment's spec is the trigger.

`kubectl rollout` is a different set of subcommands for observing and managing that rollout process, not for causing it:
- `kubectl rollout status` — blocks and streams progress until the rollout finishes (or fails)
- `kubectl rollout history` — lists past revisions of the Deployment
- `kubectl rollout undo` — reverts to a previous revision (itself just applies an old pod template, triggering another rollout)
- `kubectl rollout restart` — forces new pods without changing the image/config, useful for picking up a changed ConfigMap/Secret

So `apply` changes *what* should be running, while `rollout` observes or steers *how* the cluster gets there.

## Clean up

```sh
# Terraform
cd terraform && terraform destroy

# Helm CLI
helm uninstall learnkube

# kubectl + plain manifests
kubectl delete -f k8s/

minikube stop
```
