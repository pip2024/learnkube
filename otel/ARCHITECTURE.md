# How OTel actually talks to Loki, Tempo, and Grafana

`otel/README.md` covers how to run this example. This file is for understanding what's actually happening on the wire and inside `otel-lgtm` — the mechanics behind why the queries in the README's "Example queries" section are shaped the way they are, and why the three backends behave so differently from each other despite receiving data through the exact same collector.

```
learnkube pod                 otel-lgtm pod
┌─────────────────┐           ┌──────────────────────────────────────────────┐
│ OTLP SDK         │  OTLP    │  OTel Collector           Tempo   (traces)     │
│ (traces/metrics/ ├─────────►│  receiver: otlp   ─────►  Prometheus (metrics) │
│  logs)           │ :4317    │  exporter: otlphttp ────► Loki    (logs)       │
└─────────────────┘           │                                                │
                               │  Grafana ──queries──► Tempo/Prometheus/Loki   │
                               └──────────────────────────────────────────────┘
```

## The wire protocol: OTLP is one protocol, three services

Everything `server.py` sends goes out as [OTLP](https://opentelemetry.io/docs/specs/otlp/) — a protobuf-defined format, sendable over gRPC or HTTP. What actually makes it "three signals" rather than one blob is that OTLP defines three *separate* service/endpoint definitions, multiplexed over the same port:

- Traces → gRPC `TraceService/Export`, or HTTP `POST /v1/traces`
- Metrics → gRPC `MetricsService/Export`, or HTTP `POST /v1/metrics`
- Logs → gRPC `LogsService/Export`, or HTTP `POST /v1/logs`

That's why `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-lgtm:4317` in `otel/app-deployment.yaml` is a single value that works for all three exporters in `server.py` (`OTLPSpanExporter`, `OTLPMetricExporter`, `OTLPLogExporter`) — gRPC routes by service name over one connection, so one port/endpoint serves all three without collision.

## The Collector: a router, not a passthrough

The bundled OTel Collector (`otel-lgtm`'s `/otel-lgtm/otelcol-config.yaml`) receives OTLP on `4317`/`4318` and deserializes each signal into Go-native in-memory structures (`ptrace.Traces`, `pmetric.Metrics`, `plog.Logs`) — three completely distinct types, which is why its `service.pipelines` config has three separate pipelines (`traces:`, `metrics:`, `logs:`), each with its own `receivers`/`processors`/`exporters` list. A span can never accidentally end up in the logs pipeline; the pdata type system doesn't allow it.

Each pipeline re-serializes back to OTLP and forwards to a *different* internal backend, over three different ports, because each backend implements OTLP ingestion differently:

```yaml
otlphttp/traces:
  endpoint: http://localhost:4418   # Tempo's own OTLP-native receiver
otlphttp/metrics:
  endpoint: http://localhost:9090/api/v1/otlp   # Prometheus's OTLP receiver (newer, opt-in feature)
otlphttp/logs:
  endpoint: http://localhost:3100/otlp   # Loki's OTLP-native receiver
```

(This is the config we read directly via `kubectl exec ... cat /otel-lgtm/otelcol-config.yaml` while debugging the Loki issue — see the troubleshooting history in this session for how we confirmed each of these actually works.)

## Same wire format in, three completely different data models out

This is the part that actually explains the debugging session: each backend takes the same OTLP shape and translates it into a *fundamentally different* internal storage model, with different rules about what's cheap vs. expensive to query.

### Tempo: keeps almost everything, as-is

A trace is inherently a self-contained, one-off object — there's no "cardinality" cost to worry about the way there is with metrics or logs, so Tempo's TraceQL can query on essentially any attribute at any level, with a `resource.` prefix distinguishing resource-level attributes (shared across every span in the trace, e.g. `resource.service.name`) from span-level ones (specific to one span, e.g. `span.learnkube.greeting`, from `span.set_attribute(...)` in `server.py`). Nothing gets flattened or dropped.

### Prometheus/Mimir: everything becomes a flat label set, and cardinality is the whole game

Prometheus's data model is fundamentally: a metric name + a flat set of `label=value` pairs identifies one time series. Every *unique combination* of label values is a distinct series that gets stored and scraped forever (until retention expires) — so the OTLP→Prometheus translation intentionally throws away most of what would otherwise be rich per-event attributes, keeping only resource-level and deliberately-chosen metric attributes as labels. Our `request_counter.add(1, {"greeting": greeting})` becomes `learnkube_requests_total{greeting="Hello"}` specifically because `greeting` only takes a handful of values — had we labeled by `request_count` instead (unbounded, ever-increasing), that would be a textbook cardinality-explosion mistake, since Prometheus would create a brand new permanent time series for every single request. This is also why `histogram_quantile()` exists as a *query-time* function at all: OTel's structured Histogram type gets flattened into a set of `_bucket`/`_sum`/`_count` suffixed series (the classic Prometheus histogram convention) rather than preserved as one rich object — percentiles are computed from those bucket counts on read, not stored precomputed.

### Loki: labels must stay low-cardinality; everything else lives in the log line

Loki deliberately does *not* build a full-text index the way Elasticsearch does — it only indexes a small set of low-cardinality **stream labels**, and everything else (the log line body, plus optional "structured metadata" — indexed key-value pairs that aren't part of stream identity) is found by scanning within a stream *after* you've already narrowed down to it via labels. That's precisely why LogQL requires at least one label matcher — `{}` alone is invalid, unlike TraceQL — the whole architecture assumes "pick a cheap, indexed stream first, then search within it," not "search everything." This is also exactly why our debugging trail found `service_name` (not `service.name`) as the actual label: Loki's OTLP ingestion path has its own convention for promoting a handful of resource attributes into indexed stream labels, sanitizing the name (dots aren't legal in label names, same restriction Prometheus has) in the process. Our custom per-request details (`request from %s (request #%d, greeting=%r)`) stay in the log line body, not as labels — which is why the README's LogQL examples filter the body with `|=`/`| logfmt` rather than a label matcher.

## Batching happens twice, independently

There are two separate batching stages between "the app calls `.info()`/`start_as_current_span()`/`.add()`" and "the data is queryable":

1. **In the app's SDK** (`server.py`): `BatchSpanProcessor`/`BatchLogRecordProcessor` buffer on a ~5-second timer by default; `PeriodicExportingMetricReader` buffers on a 60-second timer by default. This is why metrics take up to a minute to show up in Grafana even under constant load (see the "real-time" discussion in this project's session history).
2. **In the Collector**: the `batch` processor in `otelcol-config.yaml`'s pipelines re-batches *again* before handing off to the `otlphttp` exporters, with its own independent size/timeout thresholds.

Neither stage is configurable from this example without editing config (the app's intervals are hardcoded in `server.py`; the collector's are baked into the bundled image), but knowing there are two independent buffering stages — not one — explains why "I just made a request, why isn't it there yet" always has some real, structural latency behind it, not just a UI refresh setting.

## Cross-signal correlation is already happening, just unremarked-upon

Look at `server.py`'s `hello()`: `app_logger.info(...)` is called *inside* `with tracer.start_as_current_span("hello") as span:`. Because there's an active span at that point, the OTel logging bridge (`LoggingHandler`) automatically attaches that span's `trace_id`/`span_id` onto the emitted log record. This is what lets Grafana's Explore view offer "jump from this trace to its correlated logs" (or vice versa) as a real feature — it's only possible because the trace ID is a field both Tempo and Loki end up storing, put there by the same app code emitting both signals from within the same request. Nothing extra had to be configured for this to work; it's a consequence of where the logging call happens to sit in the code.

## Grafana itself stores and computes nothing

Everything above happens without Grafana in the picture at all. Grafana is purely a **query federation UI**: it holds datasource configs (pre-provisioned in this image) pointing at Tempo's own query API, Prometheus's PromQL API, and Loki's LogQL API, and gives you one UI (Explore) to hit all three — plus the trace↔log correlation feature described above, which is itself just Grafana configured to build a Loki query from a `trace_id` field it finds on a Tempo span, or vice versa. Delete Grafana entirely and all three backends still have all the data and are still independently queryable via their own APIs (exactly how we diagnosed the Loki issue in this project — by curling Loki's own `/loki/api/v1/label` API directly, bypassing Grafana entirely).
