import type { ErrorEvent } from "@sentry/node";
import * as Sentry from "@sentry/node";
import { afterAll, expect, test } from "vitest";
import { buildApp } from "../src/app.js";
import { initSentry, scrub } from "../src/sentry.js";
import { audience, fakeIssuer, issuer, memorySync, memoryUsers } from "./fakeIssuer.js";

const iss = await fakeIssuer();
afterAll(() => Sentry.close());

test("scrub keeps the error type and code, drops everything that can quote user data", () => {
  const e = {
    message: "row (CANARY) failed",
    request: { url: "/v1/sync/resumes?x=CANARY", data: "CANARY", headers: { authorization: "Bearer CANARY" }, cookies: { s: "CANARY" }, query_string: "x=CANARY" },
    user: { id: "CANARY", ip_address: "1.2.3.4" },
    breadcrumbs: [{ message: "CANARY" }],
    extra: { body: "CANARY" },
    contexts: { state: { v: "CANARY" } },
    tags: { code: "23505", other: "CANARY" },
    exception: { values: [{ type: "DatabaseError", value: "duplicate key value (CANARY)", stacktrace: { frames: [{ function: "put", vars: { x: "CANARY" } }] } }] },
  } as unknown as ErrorEvent;
  const out = JSON.stringify(scrub(e));
  expect(out).not.toContain("CANARY");
  expect(out).toContain("DatabaseError");
  expect(out).toContain("23505");
  expect(out).toContain('"function":"put"'); // the stack trace (code locations) survives
});

test("a 500 reaches Sentry scrubbed: no body, token, ciphertext or error text", async () => {
  const sent: unknown[] = [];
  initSentry("https://public@o0.ingest.sentry.io/0", () => ({
    send: async (env) => { sent.push(env); return {}; },
    flush: async () => true,
  }));
  const broken = { get: memorySync().get, put: async () => { throw Object.assign(new Error("value CANARY-ROW too long"), { code: "22001" }); } };
  const app = buildApp({ auth: { issuer, audience, jwks: iss.jwks }, users: memoryUsers(), sync: broken });
  const token = await iss.sign();
  const r = await app.inject({ method: "PUT", url: "/v1/sync/resumes", headers: { authorization: `Bearer ${token}`, "if-none-match": "*" },
    payload: { keyId: "k1", ciphertext: Buffer.from("CANARY-BODY").toString("base64") } });
  expect(r.statusCode).toBe(500);
  await Sentry.flush(2000);
  await app.close();
  expect(sent.length).toBe(1); // the haystack is real
  const text = JSON.stringify(sent);
  expect(text).toContain("22001");
  for (const n of ["CANARY-ROW", Buffer.from("CANARY-BODY").toString("base64"), token]) expect(text.includes(n), n.slice(0, 16)).toBe(false);
});
