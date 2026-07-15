# Secrets example

Based on [Secrets](https://kubernetes.io/docs/concepts/configuration/secret/). A `Secret` is mechanically almost identical to a `ConfigMap` (see the main [README](../README.md)'s step 9) — same two consumption methods, same live-update-via-volume-vs-stale-via-env behavior — but intended for sensitive values, with different storage/access semantics.

```
secrets/
  secret.yaml        the Secret itself (simulated DB credentials)
  pod-env.yaml        consumes it as environment variables
  pod-volume.yaml      consumes it as mounted files
```

## `stringData` vs `data`

`secret.yaml` uses `stringData`, which accepts plain text and lets the API server base64-encode it for you on write. You can also write `data` directly with values you've already base64-encoded yourself — both end up identical once stored; `stringData` is purely a write-time convenience, never how it's actually persisted.

## Base64 is encoding, not encryption

This is the most important thing to understand about Secrets: base64 is trivially reversible (`base64 -d`), not a form of protection. What actually restricts access to a Secret's contents is:

- **RBAC** — anyone with `get`/`list`/`watch` on `secrets` in a namespace (or `exec` access into a pod that mounts one) can read it in plaintext.
- **Encryption at rest** — by default, a Secret's value is stored in etcd as literal raw bytes — not even base64, since that's only a JSON/YAML client-representation artifact, one layer above etcd. Anyone with direct etcd access (or an etcd snapshot/backup) can find the plaintext value with a plain `grep`/`strings`, no decoding at all. Enabling [encryption at rest](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/) is a separate, cluster-admin-level step, not something a Secret object does automatically — see `../security/kind-with-encryption-at-rest.sh` for a runnable demonstration of the difference.

So treat a Secret as "access-controlled configuration," not "encrypted configuration," unless you've specifically configured encryption at rest on top of it.

## Try it

Create the Secret and both test pods:

```sh
kubectl apply -f secrets/secret.yaml -f secrets/pod-env.yaml -f secrets/pod-volume.yaml
```

See how it's actually stored (base64, not plaintext, not encrypted):

```sh
kubectl get secret learnkube-db-credentials -o yaml
```

Decode a field yourself to prove it's just encoding:

```sh
kubectl get secret learnkube-db-credentials -o jsonpath='{.data.password}' | base64 -d
```

**Windows PowerShell** has no `base64` command — either run this in Git Bash/WSL instead (recommended, since the rest of this project's `sh` code blocks assume a POSIX shell), or use the native equivalent:

```powershell
[System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String((kubectl get secret learnkube-db-credentials -o jsonpath='{.data.password}')))
```

### As environment variables

```sh
kubectl exec secret-env-demo -- printenv DB_USERNAME DB_PASSWORD
```

### As mounted files

```sh
kubectl exec secret-volume-demo -- cat /etc/secrets/username /etc/secrets/password
```

### Updating a Secret behaves exactly like updating a ConfigMap

Change the password and re-apply:

```sh
kubectl patch secret learnkube-db-credentials -p '{"stringData":{"password":"new-password"}}'
```

Wait roughly a minute (same kubelet sync delay as ConfigMap volumes), then check both pods again:

```sh
kubectl exec secret-volume-demo -- cat /etc/secrets/password   # updated, no restart needed
kubectl exec secret-env-demo -- printenv DB_PASSWORD            # still shows the OLD password
```

Same rule as step 9's ConfigMap example: a mounted volume's files are synced live by the kubelet; an environment variable is only ever read once, at container start, so an already-running pod never sees the new value until it's actually restarted (e.g. `kubectl delete pod secret-env-demo` followed by re-applying `pod-env.yaml`).

## Clean up

```sh
kubectl delete -f secrets/secret.yaml -f secrets/pod-env.yaml -f secrets/pod-volume.yaml
```
