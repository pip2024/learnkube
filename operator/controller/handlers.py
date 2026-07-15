# Technical notes on the CRD/handler lifecycle (see ../README.md for the
# plain-language version -- this is the "what's actually happening on the
# wire and in kopf's internals" version).
#
# kopf doesn't poll. On startup it does one LIST against
# /apis/{GROUP}/{VERSION}/{PLURAL} (cluster-wide here, since the Dockerfile
# runs `kopf run --all-namespaces`) to seed its in-memory cache, then opens
# a watch (GET with `?watch=1&resourceVersion=<from the list>`), which is a
# long-lived HTTP connection the API server streams newline-delimited JSON
# events over -- each one `{"type": "ADDED"|"MODIFIED"|"DELETED"|"BOOKMARK",
# "object": {...full resource...}}`. When that connection is closed by the
# server (watches are time-bounded server-side) or drops, kopf reconnects
# using the last-seen resourceVersion so no events are missed in between --
# this whole LIST-then-WATCH-then-relist pattern is the same "informer"
# design client-go gives Go operators for free; kopf reimplements it here.
#
# Each incoming event is classified into a "cause" before any handler
# runs, and that's what @kopf.on.create/.update/.resume actually match on
# -- not the raw ADDED/MODIFIED/DELETED types directly:
#   - create: an ADDED event for an object kopf has never processed before
#     AND that arrived while this operator process was already watching.
#   - update: a MODIFIED event where the object's meaningful state (kopf
#     diffs against its own stored "last-handled-configuration" annotation,
#     not just resourceVersion) actually changed.
#   - resume: fired instead of create for objects that already existed the
#     moment this operator process started/restarted and haven't been
#     handled yet (no diffbase annotation on them) -- i.e. "I just now
#     started watching, and this was already here."
#
# This file registers create and update onto the same function, but there
# is no @kopf.on.resume handler. Practical consequence: if you restart the
# operator's pod (or install the operator after LearnKubeApp objects
# already exist), those pre-existing objects will NOT get reconciled again
# on startup -- only a genuinely new create, or the next update to an
# existing object's spec, will trigger reconcile() after that point. A
# production operator would normally also register @kopf.on.resume(...)
# pointing at the same function to cover that gap; this example leaves it
# out to keep the handler surface small.
#
# On an unhandled exception, kopf retries the same cause with exponential
# backoff (not a fixed interval), logging each attempt -- there's no
# explicit retry/backoff code anywhere below because kopf provides it for
# every handler by default.

import kopf
import kubernetes

# These three constants are the exact (group, version, plural) triple from
# crd.yaml's spec.group / spec.versions[].name / spec.names.plural. kopf
# uses them to build the watch URL above -- get any of them wrong (or out
# of sync with a future crd.yaml edit) and kopf simply never sees any
# events for this resource; there's no error, it just silently watches a
# path with nothing on it.
GROUP = "learnkube.dev"
VERSION = "v1"
PLURAL = "learnkubeapps"


def _upsert(create_fn, patch_fn, namespace, name, body):
    try:
        create_fn(namespace=namespace, body=body)
    except kubernetes.client.exceptions.ApiException as e:
        # kubernetes.client.exceptions.ApiException is the generic
        # exception the generated Python client raises for *any* non-2xx
        # response; `.status` is just the raw HTTP status code copied off
        # the response (`.reason`/`.body` would carry the human-readable
        # reason and the full `Status` kind body, if we needed them).
        #
        # 409 Conflict is the standard HTTP status code (not
        # Kubernetes-specific) that a Kubernetes `create` (HTTP POST)
        # returns when an object with this exact name already exists in
        # this namespace -- the apiserver enforces name uniqueness at the
        # storage/etcd key level and refuses to silently overwrite it,
        # because `create` and `update` are deliberately distinct
        # operations in the API (create assigns a fresh resourceVersion/uid
        # and requires the object not exist; update/patch requires it to
        # already exist and enforces optimistic concurrency).
        #
        # We deliberately try create() first instead of checking existence
        # with a GET first: a GET-then-decide approach still has a race
        # between the GET and the write (something else could create it in
        # between), so it doesn't actually avoid needing to handle 409
        # anyway -- it would just add a second round-trip on every single
        # call instead of only on the (rarer) already-exists case.
        if e.status == 409:
            # patch_namespaced_* sends this dict as a *strategic merge
            # patch*, not a full replace/PUT -- only the top-level keys we
            # actually supplied (metadata.name/labels, spec, ...) are
            # merged in. Fields the live object already has that aren't in
            # our dict (status, metadata.resourceVersion/uid, anything the
            # API server or another controller set) are left untouched.
            # That's what makes calling this on every reconcile safe and
            # idempotent rather than clobbering server-managed state.
            patch_fn(name=name, namespace=namespace, body=body)
        else:
            raise


@kopf.on.create(GROUP, VERSION, PLURAL)
@kopf.on.update(GROUP, VERSION, PLURAL)
def reconcile(spec, name, namespace, body, logger, **kwargs):
    # kopf inspects this function's parameter names via introspection and
    # injects only the ones it declares -- a form of dependency injection.
    # `spec` here is `body["spec"]`, `**kwargs` swallows the rest of what
    # kopf makes available that we don't use (`meta`, `status`, `patch`,
    # `diff`, `old`, `new`, `retry`, `memo`, ...). `logger` is a
    # kopf-provided logger already bound to this specific object's
    # namespace/name/uid, so log lines are traceable to the resource that
    # triggered them without us formatting that in by hand.
    #
    # crd.yaml declares OpenAPI `default:` values for these three fields,
    # which the API server applies at write time (structural defaulting)
    # before the object is ever stored -- so `spec` should already have
    # them filled in by the time we get here. The `.get(..., fallback)`
    # calls are a defensive backstop (e.g. against an object that predates
    # the schema gaining that default), not the primary defaulting path.
    replicas = spec.get("replicas", 1)
    greeting = spec.get("greeting", "Hello")
    image = spec.get("image", "learnkube:v1")

    app_name = f"{name}-learnkube"
    config_name = f"{name}-config"
    labels = {"app": app_name}

    configmap = {
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": {"name": config_name},
        "data": {"greeting": greeting},
    }

    deployment = {
        "apiVersion": "apps/v1",
        "kind": "Deployment",
        "metadata": {"name": app_name, "labels": labels},
        "spec": {
            "replicas": replicas,
            "selector": {"matchLabels": labels},
            "template": {
                "metadata": {"labels": labels},
                "spec": {
                    "containers": [{
                        "name": "learnkube",
                        "image": image,
                        "imagePullPolicy": "IfNotPresent",
                        "ports": [{"containerPort": 8080}],
                        "volumeMounts": [{
                            "name": "config",
                            "mountPath": "/etc/config",
                            "readOnly": True,
                        }],
                    }],
                    "volumes": [{
                        "name": "config",
                        "configMap": {"name": config_name},
                    }],
                },
            },
        },
    }

    service = {
        "apiVersion": "v1",
        "kind": "Service",
        "metadata": {"name": app_name},
        "spec": {
            "selector": labels,
            "ports": [{"port": 8080, "targetPort": 8080}],
        },
    }

    # kopf.adopt() mutates each manifest's metadata in place: it sets
    # ownerReferences (apiVersion/kind/name/uid of `body`, our LearnKubeApp,
    # plus controller=true and blockOwnerDeletion=true) and, since this CRD
    # is Namespaced, copies the parent's namespace onto the child if it
    # isn't set already. ownerReferences are what let Kubernetes' own
    # garbage collector cascade-delete all three of these the moment the
    # LearnKubeApp is deleted -- the same mechanism that deletes a
    # ReplicaSet's Pods when you delete the Deployment. No on.delete
    # handler is needed anywhere in this file as a result.
    for manifest in (configmap, deployment, service):
        kopf.adopt(manifest, owner=body)

    core = kubernetes.client.CoreV1Api()
    apps = kubernetes.client.AppsV1Api()

    _upsert(core.create_namespaced_config_map, core.patch_namespaced_config_map,
            namespace, config_name, configmap)
    _upsert(apps.create_namespaced_deployment, apps.patch_namespaced_deployment,
            namespace, app_name, deployment)
    _upsert(core.create_namespaced_service, core.patch_namespaced_service,
            namespace, app_name, service)

    logger.info(f"reconciled {app_name}: replicas={replicas} greeting={greeting!r}")

    # Whatever JSON-serializable value a kopf handler returns gets written
    # to `status.<handler-id>` on the object -- `<handler-id>` defaults to
    # the function's own name, so this lands at `.status.reconcile`
    # (visible via `kubectl get learnkubeapp demo -o yaml`). Concretely,
    # kopf does this with its own PATCH call against the *same* main
    # object endpoint used above -- because crd.yaml doesn't declare
    # `subresources: { status: {} }`, there's no separate /status endpoint
    # for kopf to target instead (see README.md's "Subresources" section
    # for what would change if it did).
    return {"configmap": config_name, "deployment": app_name, "service": app_name}
