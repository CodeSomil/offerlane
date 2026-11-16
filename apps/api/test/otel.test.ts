import { InMemorySpanExporter } from "@opentelemetry/sdk-trace";
import type { ReadableSpan } from "@opentelemetry/sdk-trace";
import { expect, test } from "vitest";
import { scrubbed } from "../src/otel.js";

test("exported spans lose error text, queries, IPs and user agents but keep the rest", async () => {
  const mem = new InMemorySpanExporter();
  const span = {
    name: "pg.query:SELECT",
    spanContext: () => ({ traceId: "t", spanId: "s", traceFlags: 1 }),
    attributes: { "db.query.text": "SELECT $1", "url.query": "q=CANARY", "client.address": "CANARY-IP", "user_agent.original": "CANARY-UA", "http.response.status_code": 500 },
    events: [{ name: "exception", time: [0, 0], attributes: { "exception.type": "DatabaseError", "exception.message": "invalid input syntax: \"CANARY\"" } }],
    status: { code: 2, message: "invalid input syntax for type uuid: \"CANARY\"" },
  } as unknown as ReadableSpan;
  await new Promise<void>((r) => scrubbed(mem).export([span], () => r()));
  const [out] = mem.getFinishedSpans();
  expect(JSON.stringify({ a: out!.attributes, e: out!.events, s: out!.status })).not.toContain("CANARY");
  expect(out!.attributes).toEqual({ "db.query.text": "SELECT $1", "http.response.status_code": 500 });
  expect(out!.status).toEqual({ code: 2 });
  expect(out!.events[0]!.attributes).toEqual({ "exception.type": "DatabaseError" });
  expect(out!.spanContext().spanId).toBe("s"); // methods survive the wrapper
  expect(out!.name).toBe("pg.query:SELECT");
});
