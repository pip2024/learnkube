#!/bin/sh
# Demonstrates encryption at rest for Secrets: configures the API server's
# --encryption-provider-config so Secret values are actually encrypted
# (not just base64'd) before being written to etcd. Companion to the
# ../secrets/README.md note that "base64 is encoding, not encryption" --
# this is the mechanism that closes that gap.
#
# Based on the Kubernetes task "Encrypting Confidential Data at Rest"
# (kubernetes.io/docs/tasks/administer-cluster/encrypt-data/).
#
# Like kind-with-cluster-level-baseline-pod-security.sh, this bakes the
# config in at cluster-creation time via a kind kubeadmConfigPatch, rather
# than editing a running control plane's static pod manifest -- simpler and
# more reliable for a throwaway demo cluster, at the cost of not being able
# to show a genuine "before" (unencrypted) state on the same cluster. See
# the note at the very bottom for what that comparison looks like in
# principle.

set -e

mkdir -p /tmp/enc

# A real 32-byte AES key, base64-encoded for the YAML field below. This
# script owns its *entire* lifecycle end-to-end: generated here, written to
# a plaintext file below, read by exactly one throwaway API server, and
# destroyed by `rm -rf /tmp/enc` in cleanup along with the only copy that
# ever existed. There's no rotation, no backup, no distribution to other
# control-plane replicas -- none of that is needed for a single disposable
# demo cluster, but it's *not* how you'd manage this key for real. See the
# note on the `kms` provider at the bottom of this script.
KEY=$(head -c 32 /dev/urandom | base64)

# EncryptionConfiguration: encrypt Secrets with aescbc using the key above.
# "identity" (no-op, plaintext) is listed second only as a decrypt-time
# fallback for reading data written before this config existed -- the
# *first* provider in the list is what's used to encrypt new/updated
# writes, so aescbc has to come first for this to actually do anything.
cat <<EOF > /tmp/enc/encryption-config.yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: ${KEY}
      - identity: {}
EOF

# Same recipe as the cluster-level PSS script: patch kubeadm's
# ClusterConfiguration to pass --encryption-provider-config to the API
# server, and mount the host directory containing that file into the node
# so the API server container can actually read it.
cat <<EOF > /tmp/enc/cluster-config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: ClusterConfiguration
    apiServer:
        extraArgs:
          encryption-provider-config: /etc/config/encryption-config.yaml
        extraVolumes:
          - name: enc
            hostPath: /etc/config
            mountPath: /etc/config
            readOnly: false
            pathType: "DirectoryOrCreate"
  extraMounts:
  - hostPath: /tmp/enc
    containerPath: /etc/config
    readOnly: false
    selinuxRelabel: false
    propagation: None
EOF

kind create cluster --name secrets-encryption-at-rest --config /tmp/enc/cluster-config.yaml
kubectl cluster-info --context kind-secrets-encryption-at-rest

# Wait for 15 seconds (arbitrary) ServiceAccount Admission Controller to be available
sleep 15

# Create a Secret whose value we can go looking for directly in etcd.
kubectl create secret generic encrypted-demo --from-literal=password=super-secret-value

# Look up the etcd static pod's name dynamically -- it depends on the node
# name, which depends on the --name passed to `kind create cluster` above.
ETCD_POD=$(kubectl get pods -n kube-system -l component=etcd -o jsonpath='{.items[0].metadata.name}')

echo "--- raw etcd value for the Secret we just created ---"
kubectl exec -n kube-system "$ETCD_POD" -- sh -c '
  ETCDCTL_API=3 etcdctl \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/apiserver-etcd-client.crt \
    --key=/etc/kubernetes/pki/apiserver-etcd-client.key \
    get /registry/secrets/default/encrypted-demo
' | od -An -c | head -5
# Expect to see the literal bytes "k8s:enc:aescbc:v1:" followed by
# unreadable ciphertext -- NOT the plaintext "super-secret-value" anywhere,
# and not its base64 form either. Base64 only ever shows up in the
# Kubernetes API's own JSON/YAML representation -- `kubectl get secret -o
# yaml` always displays `.data` as base64, *regardless* of whether
# encryption at rest is on, because that's a completely separate layer
# underneath the API. This script's whole point is that the two are
# independent: "base64 in `kubectl get -o yaml`" tells you nothing about
# whether the value is actually protected at rest.

# Await input
sleep 1
( bash -c 'true' 2>/dev/null && bash -c 'read -p "Press any key to continue... " -n1 -s' ) || \
    ( printf "Press Enter to continue... " && read ) 1>&2

# Clean up
printf "\n\nCleaning up:\n" 1>&2
kind delete cluster --name secrets-encryption-at-rest
rm -rf /tmp/enc

# Note on what a genuine "before" comparison would show: if you instead ran
# `kind create cluster` with no encryption config at all, created a Secret,
# and ran the same etcdctl/od command against it, you'd find the literal
# plaintext value ("super-secret-value") sitting directly in the raw etcd
# bytes -- no decoding step needed. That's because Secret.Data is stored as
# raw bytes at the protobuf/etcd layer; base64 only exists at the API's
# client-facing JSON/YAML layer, one level up. Also worth knowing: enabling
# encryption on an already-running cluster does NOT retroactively
# re-encrypt Secrets written before the config changed -- existing ones
# stay in whatever form they were last written in until something
# rewrites them (e.g. `kubectl get secrets --all-namespaces -o json |
# kubectl replace -f -`, per the upstream task doc).
#
# Note on key lifecycle: the `aescbc` provider used above (and `aesgcm`,
# `secretbox`) all put the raw key straight into this config file, which
# makes *you* responsible for generating, distributing an identical copy to
# every API server replica, backing up, and manually rotating it (add the
# new key first, keep the old one later in the list for decrypting existing
# data, force a rewrite of all Secrets, then remove the old key). For
# anything beyond a disposable demo, the `kms` provider (KMS v2, stable
# since ~1.29) is the better answer: it hands key generation, rotation,
# access policy and audit logging off to an external KMS (AWS KMS, GCP
# Cloud KMS, Azure Key Vault, Vault Transit, etc.) via a small plugin -- the
# API server never even holds the raw key, only a wrapped data-key it asks
# the KMS to unwrap on demand.
