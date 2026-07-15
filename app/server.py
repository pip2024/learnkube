import logging
import os
import socket
import time

from flask import Flask
from opentelemetry import metrics, trace
from opentelemetry._logs import set_logger_provider
from opentelemetry.exporter.otlp.proto.grpc._log_exporter import OTLPLogExporter
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor

app = Flask(__name__)

APP_VERSION = os.environ.get("APP_VERSION", "v1")
GREETING_FILE = os.environ.get("GREETING_FILE", "/etc/config/greeting")
LOG_FILE = os.environ.get("LOG_FILE", "/var/log/learnkube/app.log")
COUNTER_FILE = os.environ.get("COUNTER_FILE", "/data/counter.txt")

os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
os.makedirs(os.path.dirname(COUNTER_FILE), exist_ok=True)

# The OpenTelemetry API below (tracer/meter/logger, spans, counters) is
# always used unconditionally -- it's safe to do so because the API falls
# back to no-op implementations until an SDK provider is actually
# registered. Only if OTEL_EXPORTER_OTLP_ENDPOINT is set do we register a
# real SDK exporting to it; every other example in this project never sets
# that variable, so this block never runs for them and every call below
# stays a free no-op -- no collector dependency, no export errors, no
# behavior change.
#
# All of this -- provider setup, the span in hello(), the counter/histogram
# calls -- is hand-written explicit code, on purpose, for teaching clarity
# (see otel/README.md). A production service more commonly gets this same
# instrumentation from a wrapper or agent instead of code like this: e.g.
# running the process via `opentelemetry-instrument gunicorn ...` (which
# monkey-patches Flask/requests/etc. at startup to emit spans automatically)
# or a language-specific auto-instrumentation agent, with manual spans like
# the one below reserved only for business-specific signals the wrapper
# can't infer on its own.
OTEL_ENDPOINT = os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT")

app_logger = logging.getLogger("learnkube")
app_logger.setLevel(logging.INFO)

if OTEL_ENDPOINT:
    resource = Resource.create({
        "service.name": os.environ.get("OTEL_SERVICE_NAME", "learnkube"),
        "service.version": APP_VERSION,
    })

    tracer_provider = TracerProvider(resource=resource)
    tracer_provider.add_span_processor(
        BatchSpanProcessor(OTLPSpanExporter(endpoint=OTEL_ENDPOINT, insecure=True))
    )
    trace.set_tracer_provider(tracer_provider)

    meter_provider = MeterProvider(
        resource=resource,
        metric_readers=[PeriodicExportingMetricReader(
            OTLPMetricExporter(endpoint=OTEL_ENDPOINT, insecure=True)
        )],
    )
    metrics.set_meter_provider(meter_provider)

    # Logs are the third signal, alongside the tracer/meter above -- same
    # OTLP endpoint (the otel-lgtm image's bundled collector routes logs it
    # receives to its embedded Loki, exactly like it routes traces to Tempo
    # and metrics to Prometheus), same "only if configured" gating. This
    # runs alongside log_request()'s plain file write below, not instead of
    # it -- that file is still what the logshipper sidecar in helm/learnkube
    # tails (root README step 10); this is a separate, additive path that
    # only exists when OTEL_ENDPOINT is set.
    logger_provider = LoggerProvider(resource=resource)
    logger_provider.add_log_record_processor(
        BatchLogRecordProcessor(OTLPLogExporter(endpoint=OTEL_ENDPOINT, insecure=True))
    )
    set_logger_provider(logger_provider)
    app_logger.addHandler(LoggingHandler(logger_provider=logger_provider))

tracer = trace.get_tracer("learnkube")
meter = metrics.get_meter("learnkube")

request_counter = meter.create_counter(
    "learnkube.requests",
    description="Number of requests served",
)
request_duration = meter.create_histogram(
    "learnkube.request.duration",
    unit="ms",
    description="Request duration in milliseconds",
)


def get_greeting():
    try:
        with open(GREETING_FILE) as f:
            return f.read().strip()
    except FileNotFoundError:
        return "Hello"


def log_request():
    with open(LOG_FILE, "a") as f:
        f.write(f"request from {socket.gethostname()}\n")


def next_count():
    try:
        with open(COUNTER_FILE) as f:
            count = int(f.read().strip())
    except (FileNotFoundError, ValueError):
        count = 0
    count += 1
    with open(COUNTER_FILE, "w") as f:
        f.write(str(count))
    return count


@app.route("/")
def hello():
    start = time.time()
    with tracer.start_as_current_span("hello") as span:
        log_request()
        count = next_count()
        greeting = get_greeting()
        span.set_attribute("learnkube.greeting", greeting)
        span.set_attribute("learnkube.request_count", count)
        app_logger.info(
            "request from %s (request #%d, greeting=%r)",
            socket.gethostname(), count, greeting,
        )
        response = (
            f"{greeting} Kubernetes {APP_VERSION} from pod {socket.gethostname()} "
            f"(request #{count})\n"
        )

    request_duration.record((time.time() - start) * 1000)
    request_counter.add(1, {"greeting": greeting})

    return response


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 8080)))
