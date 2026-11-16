import { expect, test } from "vitest";
import { buildApp } from "../src/app.js";
import { audience, fakeIssuer, issuer, memorySync, memoryUsers } from "./fakeIssuer.js";

const app = async () => buildApp({ auth: { issuer, audience, jwks: (await fakeIssuer()).jwks }, users: memoryUsers(), sync: memorySync() });

test("healthz answers ok without a token", async () => {
  const a = await app();
  const res = await a.inject({ method: "GET", url: "/healthz" });
  expect(res.statusCode).toBe(200);
  expect(res.json()).toEqual({ ok: true });
  await a.close();
});

test("unknown route is 404", async () => {
  const a = await app();
  expect((await a.inject({ method: "GET", url: "/nope" })).statusCode).toBe(404);
  await a.close();
});

test("readyz is 200 when ready, 503 when not or when the check throws", async () => {
  const { jwks } = await fakeIssuer();
  for (const [ready, status] of [[async () => true, 200], [async () => false, 503], [async () => { throw new Error("db down"); }, 503]] as const) {
    const a = buildApp({ auth: { issuer, audience, jwks }, users: memoryUsers(), sync: memorySync(), ready });
    const res = await a.inject({ method: "GET", url: "/readyz" });
    expect(res.statusCode).toBe(status);
    expect(res.json()).toEqual(status === 200 ? { ok: true } : { error: "not_ready" });
    await a.close();
  }
});
