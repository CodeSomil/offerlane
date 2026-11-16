// Import FIRST in a test file: starts the real instrumentations with an in-memory exporter (see src/otel.ts).
// The exporter receives spans after scrubbing, i.e. exactly what would leave the process.
import { InMemorySpanExporter } from "@opentelemetry/sdk-trace";
import { startTelemetry } from "../src/otel.js";

export const spans = new InMemorySpanExporter();
export const sdk = startTelemetry(spans);
/** Every exported span (names, attributes, events, status) as one searchable string. */
export const traceText = () => JSON.stringify(spans.getFinishedSpans().map((s) => ({ n: s.name, a: s.attributes, e: s.events, st: s.status })));
