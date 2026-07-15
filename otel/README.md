# OpenTelemetry + LGTM stack example

[OpenTelemetry](https://opentelemetry.io/) (OTel) is a vendor-neutral API/SDK for instrumenting an application to emit traces, metrics, and logs. It doesn't store or visualize anything by itself — it just standardizes how signals get produced and shipped (via the OTLP protocol) to whatever backend actually stores/queries them. **LGTM** is Grafana Labs' name for pairing four of their open-source projects as that backend: **L**oki (logs), **G**rafana (visualization/UI), **T**empo (traces), **M**imir (metrics, Prometheus-compatible). This example instruments the shared `learnkube` app with OTel (traces + metrics + logs) and points it at Grafana's all-in-one `otel-lgtm` demo image.

```
otel/
  lgtm.yaml            Deployment + Service for the all-in-one grafana/otel-lgtm image
  app-deployment.yaml   learnkube:v1, with OTEL_EXPORTER_OTLP_ENDPOINT set
```

For how OTLP actually gets translated into Tempo/Prometheus/Loki's very different storage models under the hood (the wire protocol, why each backend's query language looks so different, cardinality, batching latency, cross-signal correlation), see [`ARCHITECTURE.md`](ARCHITECTURE.md).

The instrumentation itself lives in the shared `app/server.py` (see below), not a separate copy of the app — **rebuild and reload the image before trying this example**, since it now depends on that updated code:

```sh
docker build -t learnkube:v1 app/
minikube image load learnkube:v1
```

**If the app's behavior doesn't seem to reflect a `server.py` change no matter how many times you redeploy** (this cost real time to track down while building this example): `minikube image load` can silently fail to actually overwrite an already-cached image under the same tag. Verify the digests actually match before debugging anything else:
```sh
docker images learnkube:v1 --no-trunc
minikube image ls --format table | grep learnkube
kubectl get pod -l app=learnkube-otel -o jsonpath='{.items[0].status.containerStatuses[0].imageID}'
```
If they disagree, force it — `minikube image rm` fails while a pod still references the image, so scale down first:
```sh
kubectl scale deployment/learnkube-otel --replicas=0
minikube image rm learnkube:v1
minikube image load learnkube:v1
kubectl scale deployment/learnkube-otel --replicas=1
```

## Why this doesn't affect any other example in the project

`server.py` always uses the OpenTelemetry *API* unconditionally (a tracer, a span per request, a counter, a histogram) — that's safe because the API is backed by no-op default implementations until an SDK provider is explicitly registered. That registration only happens if `OTEL_EXPORTER_OTLP_ENDPOINT` is set:

```python
OTEL_ENDPOINT = os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT")
if OTEL_ENDPOINT:
    # ...register a real TracerProvider/MeterProvider exporting to it...
```

Every other example in this project (the root README's steps, `stateful/`, `secrets/`, `operator/`) never sets that variable, so this block never runs for them — the tracer/meter calls sprinkled through `hello()` stay inert no-ops, with no dependency on a collector being reachable and no export errors in their logs. Only `otel/app-deployment.yaml` sets it.

## Deploy

Bring up the LGTM stack first:

```sh
kubectl apply -f otel/lgtm.yaml
kubectl get pods -l app=otel-lgtm -w   # wait for Running/Ready
```

Then the instrumented app:

```sh
kubectl apply -f otel/app-deployment.yaml
```

Generate some traffic:

```sh
kubectl port-forward deployment/learnkube-otel 8080:8080   # in one terminal
curl http://localhost:8080                                  # in another; repeat a few times
```

## Look at it in Grafana

```sh
kubectl port-forward deployment/otel-lgtm 3000:3000
```

Open `http://localhost:3000`. The `otel-lgtm` image ships with anonymous access enabled and pre-provisioned Tempo/Prometheus/Loki datasources — you shouldn't need to log in or configure anything.

Each datasource in this stack has its own query language. In Grafana, go to **Explore**, pick the datasource from the dropdown at the top, and switch the query editor to the language shown below (Tempo defaults to a form-based "Search" tab — switch it to **TraceQL** to use these).

### Tempo (TraceQL) — traces

```
{}
```
Broadest possible query: returns any trace regardless of service. Useful as a first sanity check — if this returns nothing, no traces have arrived at all yet (check the app pod's logs and that you rebuilt/reloaded the image, per the troubleshooting above).

```
{ resource.service.name = "learnkube" }
```
Filters to this app specifically, by the `service.name` resource attribute set in `server.py`'s `Resource.create({...})`.

```
{ name = "hello" }
```
Filters by span name instead of service — useful if `resource.service.name` isn't matching what you expect, since it doesn't depend on that attribute at all.

```
{ span.learnkube.greeting = "Hello" }
```
Filters by one of the custom span attributes set in `hello()` — adjust the value if you've changed the ConfigMap-backed greeting.

### Prometheus (PromQL) — metrics

```
learnkube_requests_total
```
The raw counter from `request_counter` in `server.py` (OTLP counters get a `_total` suffix once exported to Prometheus-style storage).

```
sum by (greeting) (learnkube_requests_total)
```
Breaks the counter down by the `greeting` attribute recorded on each increment.

```
rate(learnkube_requests_total[1m])
```
Requests per second over the last minute — more useful than the raw counter once you're generating steady traffic rather than a handful of manual `curl`s.

```
histogram_quantile(0.95, rate(learnkube_request_duration_milliseconds_bucket[5m]))
```
p95 request duration from the `request_duration` histogram (the `_bucket` suffix and `histogram_quantile` are how PromQL computes percentiles out of a Prometheus-style histogram's bucket counts).

### Loki (LogQL) — logs

`server.py` now sends logs too, via a third signal alongside the tracer/meter: a standard Python `logging.Logger("learnkube")` with an OTel `LoggingHandler` attached, exporting through the same `OTEL_EXPORTER_OTLP_ENDPOINT` as traces/metrics. The `otel-lgtm` image's bundled collector routes OTLP logs it receives to its embedded Loki, the same way it already routes traces to Tempo and metrics to Prometheus — no separate log-shipping agent needed.

This is additive, not a replacement: `log_request()`'s plain file write is untouched, and still what the `logshipper` sidecar in `helm/learnkube` tails (root README step 10) — that's a different mechanism for a different example, unaffected by this one.

```
{service_name="learnkube"}
```
LogQL's stream selector syntax — filters to this app by its `service.name` resource attribute, analogous to TraceQL's `resource.service.name` filter above. This should be the first thing you try, to confirm log lines are arriving at all.

```
{service_name="learnkube"} |= "request #"
```
Same stream, filtered further to lines containing that text — LogQL's `|=` is a simple substring match, applied after the stream selector narrows down which log stream to search.

```
{service_name="learnkube"} | logfmt | request_count > 5
```
Parses each line's structured fields (`logfmt` here, since Python's default log formatting is closer to logfmt-style key-value pairs than JSON) and filters on a specific field — adjust `request_count` if your actual log line's fields are named differently once you look at one.

## The instrumentation itself

In `app/server.py`:

```python
with tracer.start_as_current_span("hello") as span:
    ...
    span.set_attribute("learnkube.greeting", greeting)
    span.set_attribute("learnkube.request_count", count)

request_duration.record((time.time() - start) * 1000)
request_counter.add(1, {"greeting": greeting})
```

This is manual instrumentation — the span, its attributes, the counter, and the histogram are all explicit code, not something a wrapper/agent generated behind the scenes. That's deliberate for this project: what OTel is actually doing stays visible and explainable in the same place as the rest of the app's behavior, consistent with how `GREETING_FILE`/`LOG_FILE`/`COUNTER_FILE` are handled elsewhere in this same file.

## Clean up

```sh
kubectl delete -f otel/app-deployment.yaml
kubectl delete -f otel/lgtm.yaml
```

## How a production setup differs from this

This example is deliberately the smallest thing that demonstrates the OTel → LGTM pipeline working end to end. A handful of things a real production setup would do differently:

- **A standalone collector, not a direct app→backend hop.** Here, the app's OTLP exporter talks straight to the all-in-one image's bundled collector. Production typically runs a dedicated [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/) tier (often via the OpenTelemetry Operator, as a Deployment or per-node DaemonSet) between every app and any backend — giving you batching, retries, sampling decisions, PII redaction, and fan-out to multiple backends, all decoupled from any single app's code or any single backend's ingestion endpoint.
- **Distributed, persistent storage, not one container with none.** `grafana/otel-lgtm` runs Loki/Tempo/Mimir/Grafana all in one process with no persistent volume at all — delete the pod and every trace, metric, and dashboard is gone. Production Loki/Tempo/Mimir are each separately deployed, horizontally-scalable distributed systems (their own Helm charts — `grafana/loki`, `grafana/tempo-distributed`, `grafana/mimir-distributed`) backed by object storage (S3/GCS) for durable, long-term retention.
- **Sampling.** This example exports a span for every single request, since traffic here is a handful of manual `curl`s. Real production traffic would make that enormous and expensive — production tracing setups apply head- or tail-based sampling so only a representative (or particularly interesting) fraction of traces are actually kept.
- **Broader instrumentation coverage.** This app has one hand-written span per request. Production teams typically layer OTel's *auto*-instrumentation (agents/libraries that instrument a web framework, HTTP client, DB driver, etc. automatically) across many services first, for broad baseline coverage, and reserve manual instrumentation like this for business-specific signals auto-instrumentation can't know about.
- **Multi-service traces.** Tracing's real value is following one request across service boundaries. This example only has one service, so a trace here is always a single span — there's nothing to actually correlate. A production system typically has the same trace ID propagated across many instrumented services, and Tempo's UI showing the whole call chain.
- **Real auth and RBAC on Grafana.** The demo image intentionally enables anonymous admin access for zero-friction local use. Production Grafana sits behind real authentication (OAuth/SAML/LDAP) with per-team folder/dashboard permissions, and isn't running as a single unmanaged pod.
- **Alerting, not just dashboards.** This example stops at "you can see the data in Grafana." Production pairs the same metrics/traces with actual alerting (Grafana Alerting, or a Prometheus/Mimir ruler) so problems page someone instead of only being visible if a human happens to look.
