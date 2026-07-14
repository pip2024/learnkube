#!/bin/sh
# Companion to kind-with-cluster-level-baseline-pod-security.sh: demonstrates
# the *namespace-level* alternative to cluster-level Pod Security Admission
# (PSA) -- labeling a Namespace object instead of configuring the API
# server's admission plugin directly. Same effective policy as the sibling
# script (enforce baseline, audit + warn restricted), but scoped to one
# namespace instead of the whole cluster, and applied to an already-running
# cluster rather than baked in at cluster-creation time.
#
# Based on the Kubernetes tutorial "Apply Pod Security Standards at the
# Namespace Level" (kubernetes.io/docs/tutorials/security/ns-level-pss/).
#
# Unlike the sibling script, this doesn't create its own kind cluster --
# PodSecurity admission reads labels straight off any Namespace object and
# is enabled by default on any modern (1.25+) cluster, so it works as-is
# against the minikube cluster from this project's README (step 1).

set -e

NAMESPACE=example

kubectl create ns "$NAMESPACE"

# Step 1: warn-only. This never blocks anything -- it just adds a
# client-side warning to `kubectl apply` output for pods that violate
# "baseline" in this namespace. No audit-log entry, no enforcement, yet.
kubectl label --overwrite ns "$NAMESPACE" \
  pod-security.kubernetes.io/warn=baseline \
  pod-security.kubernetes.io/warn-version=latest

# Step 2: the comprehensive version -- the same three-tier policy as the
# sibling script's cluster-wide AdmissionConfiguration, just expressed as
# six namespace labels instead of one YAML file handed to the API server:
#   enforce=baseline   -> actually rejects pods that violate baseline
#   warn=restricted    -> extra client-side warning for restricted violations
#   audit=restricted   -> extra audit-log entry for restricted violations
kubectl label --overwrite ns "$NAMESPACE" \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/enforce-version=latest \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/warn-version=latest \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/audit-version=latest

# A plain pod with no securityContext: satisfies "baseline" (so enforce
# admits it in either namespace below) but fails "restricted" (missing
# runAsNonRoot / allowPrivilegeEscalation / capabilities.drop / seccompProfile).
cat <<'EOF' > /tmp/example-baseline-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx
spec:
  containers:
    - image: nginx
      name: nginx
      ports:
        - containerPort: 80
EOF

echo "--- applying to '$NAMESPACE' (enforce=baseline, warn/audit=restricted) ---"
kubectl apply -n "$NAMESPACE" -f /tmp/example-baseline-pod.yaml
# Expect this to succeed but print a restricted-policy warning: enforce only
# checks against baseline, which this pod satisfies, so it's still created.

echo "--- applying the same pod to 'default' (no PodSecurity labels at all) ---"
kubectl apply -n default -f /tmp/example-baseline-pod.yaml
# Expect this to succeed with *no* warning: "default" was never labeled, so
# no policy applies there at all. This is the point of the comparison, and
# the key difference from the sibling script: that one's policy applies
# cluster-wide (kube-system aside); this one only applies to the one
# namespace we explicitly labeled.

# Await input
sleep 1
( bash -c 'true' 2>/dev/null && bash -c 'read -p "Press any key to continue... " -n1 -s' ) || \
    ( printf "Press Enter to continue... " && read ) 1>&2
# Pauses so you can inspect the warning output above (and diff the two
# `kubectl apply` runs) before teardown. Same bash/POSIX `read` fallback as
# the sibling script, since the shebang here is also #!/bin/sh.

# Clean up
printf "\n\nCleaning up:\n" 1>&2
kubectl delete pod nginx -n default --now
kubectl delete ns "$NAMESPACE"
rm -f /tmp/example-baseline-pod.yaml
# Deleting the namespace removes the copy of the pod inside it too, so only
# the "default" copy needs an explicit `kubectl delete pod`. Unlike the
# sibling script, there's no `kind delete cluster` here -- we never created
# one, so nothing further needs tearing down.
