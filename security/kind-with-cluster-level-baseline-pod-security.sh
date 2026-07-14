#!/bin/sh
# Demonstrates cluster-level Pod Security Admission (PSA): instead of
# labeling individual namespaces with pod-security.kubernetes.io/enforce
# etc., this configures the API server's built-in PodSecurity admission
# plugin directly, so the policy applies cluster-wide by default. Spins up
# a throwaway kind cluster with that config, tests a pod against it, then
# tears everything down.

mkdir -p /tmp/pss

# AdmissionConfiguration wires up the PodSecurity plugin. `enforce` actually
# blocks non-conforming pods; `audit`/`warn` only record/print a warning but
# still let the pod through. Here audit/warn are stricter (restricted) than
# enforce (baseline), so a pod that passes baseline can still trigger a
# restricted-policy warning without being rejected.
cat <<EOF > /tmp/pss/cluster-level-pss.yaml
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
- name: PodSecurity
  configuration:
    apiVersion: pod-security.admission.config.k8s.io/v1
    kind: PodSecurityConfiguration
    defaults:
      enforce: "baseline"        # rejects pods that violate the baseline profile
      enforce-version: "latest"
      audit: "restricted"        # flags restricted-profile violations in the audit log
      audit-version: "latest"
      warn: "restricted"         # flags restricted-profile violations back to the client
      warn-version: "latest"
    exemptions:
      usernames: []
      runtimeClasses: []
      namespaces: [kube-system]  # kube-system is exempt so core cluster pods aren't blocked
EOF

# kind cluster config: patches the control-plane's kubeadm ClusterConfiguration
# so the API server starts with --admission-control-config-file pointing at
# the file above, and mounts the host dir containing it into the node so the
# API server container can actually read it. This has to be set at cluster
# creation time -- there's no way to hot-patch a running API server's
# admission plugin config the way namespace labels can be applied live.
cat <<EOF > /tmp/pss/cluster-config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: ClusterConfiguration
    apiServer:
        extraArgs:
          admission-control-config-file: /etc/config/cluster-level-pss.yaml
        extraVolumes:
          - name: accf
            hostPath: /etc/config       # path inside the kind node's filesystem
            mountPath: /etc/config      # where the API server container mounts it
            readOnly: false
            pathType: "DirectoryOrCreate"
  extraMounts:
  # bind-mounts the real host's /tmp/pss (created above) into the kind node
  # at /etc/config -- this is what the hostPath/mountPath above reads from.
  - hostPath: /tmp/pss
    containerPath: /etc/config
    # optional: if set, the mount is read-only.
    # default false
    readOnly: false
    # optional: if set, the mount needs SELinux relabeling.
    # default false
    selinuxRelabel: false
    # optional: set propagation mode (None, HostToContainer or Bidirectional)
    # see https://kubernetes.io/docs/concepts/storage/volumes/#mount-propagation
    # default None
    propagation: None
EOF

kind create cluster --name psa-with-cluster-pss --config /tmp/pss/cluster-config.yaml
kubectl cluster-info --context kind-psa-with-cluster-pss

# Wait for 15 seconds (arbitrary) ServiceAccount Admission Controller to be available
sleep 15

# Plain pod, no securityContext: satisfies "baseline" (so enforce admits it)
# but would fail "restricted" (so audit/warn should still flag it, e.g. for
# missing runAsNonRoot/seccompProfile/allowPrivilegeEscalation, even though
# the pod is created successfully).
cat <<EOF |
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
kubectl apply -f -
# Note: applied with no -n/--namespace, so this pod actually lands in
# "default" -- the cleanup step below deletes from an "example" namespace
# that's never created in this script, so it won't match this pod.

# Await input
sleep 1
( bash -c 'true' 2>/dev/null && bash -c 'read -p "Press any key to continue... " -n1 -s' ) || \
    ( printf "Press Enter to continue... " && read ) 1>&2
# Pauses here so you can inspect `kubectl get pods` / the warning output
# above before teardown. Prefers bash's single-keypress `read -p -n1 -s`
# when bash is available, falling back to a plain POSIX `read` otherwise,
# since the shebang is #!/bin/sh and bash isn't guaranteed to be present.

# Clean up
printf "\n\nCleaning up:\n" 1>&2
set -e
kubectl delete pod --all -n example --now
kubectl delete ns example
kind delete cluster --name psa-with-cluster-pss
rm -f /tmp/pss/cluster-config.yaml
# Note: with `set -e` active, if "example" doesn't exist (see note above)
# these two `kubectl delete` calls fail and abort the script before
# `kind delete cluster` runs, leaving the kind cluster behind. Also, only
# cluster-config.yaml is removed here -- cluster-level-pss.yaml is left in
# /tmp/pss.
