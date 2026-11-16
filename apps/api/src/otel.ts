// OpenTelemetry (P2.7). Import this module FIRST in an entry point: the http and pg instrumentations can only
// patch modules loaded after they start. Off unless OTEL_EXPORTER_OTLP_ENDPOINT is set (the standard OTLP env vars apply).
import { OTLPTraceExporter } from "@opentelemetry/exporter-trace-otlp-proto";
import { HttpInstrumentation } from "@opentelemetry/instrumentation-http";
import { PgInstrumentation } from "@opentelemetry/instrumentation-pg";
import { NodeSDK } from "@opentelemetry/sdk-node";
import { SimpleSpanProcessor, type ReadableSpan, type SpanExporter } from "@opentelemetry/sdk-trace";

// D3: nothing that can come from a profile or identify a person leaves the process. The /v1/jobs query string holds
// title and city words; IPs and user agents identify people; error messages can quote SQL values.
const DROP = /^(url\.query|url\.full|http\.url|http\.target|client\.address|network\.peer\.address|network\.peer\.port|user_agent\.original|http\.user_agent|exception\.message|exception\.stacktrace|db\.postgresql\.values)$/;
const clean = (a: ReadableSpan["attributes"]) => Object.fromEntries(Object.entries(a).filter(([k]) => !DROP.test(k)));

function scrubSpan(s: ReadableSpan): ReadableSpan {
  // The span stays the prototype, so its methods (spanContext()) keep working; only these fields are replaced.
  return Object.create(s, {
    attributes: { value: clean(s.attributes), enumerable: true },
    events: { value: s.events.map((e) => ({ ...e, ...(e.attributes ? { attributes: clean(e.attributes) } : {}) })), enumerable: true },
    status: { value: { code: s.status.code }, enumerable: true }, // the status message is the error text
  }) as ReadableSpan;
}

/** Wraps an exporter so every span is scrubbed on its way out. */
export function scrubbed(inner: SpanExporter): SpanExporter {
  return {
    export: (spans, done) => inner.export(spans.map(scrubSpan), done),
    shutdown: () => inner.shutdown(),
    ...(inner.forceFlush ? { forceFlush: () => inner.forceFlush!() } : {}),
  };
}

/** testExporter: tests pass an in-memory exporter; otherwise OTLP (http/protobuf, configured by the OTLP env vars). */
export function startTelemetry(testExporter?: SpanExporter): NodeSDK {
  const sdk = new NodeSDK({
    serviceName: "offerlane-api",
    ...(testExporter
      ? { spanProcessors: [new SimpleSpanProcessor({ exporter: scrubbed(testExporter) })], metricReaders: [], logRecordProcessors: [] }
      : { traceExporter: scrubbed(new OTLPTraceExporter()) }),
    instrumentations: [
      // No header or body attributes (the default captures neither); health probes would only be noise.
      new HttpInstrumentation({ ignoreIncomingRequestHook: (req) => req.url === "/healthz" || req.url === "/readyz" }),
      // The default keeps SQL text with $n placeholders and never records the bound values (rows, ciphertext).
      new PgInstrumentation({ enhancedDatabaseReporting: false }),
    ],
  });
  sdk.start();
  return sdk;
}

export const telemetry = process.env.OTEL_EXPORTER_OTLP_ENDPOINT ? startTelemetry() : null;
