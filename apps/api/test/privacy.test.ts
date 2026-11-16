import { spans, traceText } from "./telemetry.js"; // first: the instrumentations must load before pg and http
import { execFileSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { PassThrough } from "node:stream";
import pg from "pg";
import { afterAll, beforeAll, describe, expect, test } from "vitest";
import { buildApp } from "../src/app.js";
import { dbUsers } from "../src/auth.js";
import { migrate } from "../src/db/migrate.js";
import { dbIdempotency } from "../src/idempotency.js";
import { dbJobs } from "../src/jobs.js";
import { dbLimits } from "../src/ratelimit.js";
import { dbSync } from "../src/sync.js";
import { formatRecoveryKey, importAccountKey, makeAccountKey, makeKeyId, makeRecoveryKey, openBlob, sealBlob, syncAAD, unwrapAccountKey, wrapAccountKey } from "@offerlane/core";
import { audience, fakeIssuer, issuer } from "./fakeIssuer.js";
import { adminUrl, freshDatabase } from "./testdb.js";

// P2 gate: "the server cannot read resume text". A client encrypts a canary resume as docs/v4/SYNC_CRYPTO.md says,
// pushes it, and the canary must not appear in a pg_dump, the server logs, the OTel traces, or any response (nor the
// bearer token). Requests go over real HTTP so the http instrumentation's server spans are part of the traces.
const { subtle } = globalThis.crypto;
const iss = await fakeIssuer();
const canary = `CANARY-${randomBytes(8).toString("hex")} Jane Q. Example, Staff Engineer at Acme Corp, 4 Privet Drive`;
const searchCanary = `SEARCHCANARY${randomBytes(4).toString("hex")}`;
const enc = new TextEncoder();
const aad = (userId: string, kind: string, version: number, keyId = "k1") => enc.encode(`offerlane-sync-v1|${userId}|${kind}|${version}|${keyId}`);

async function seal(key: CryptoKey, plaintext: string, ad: Uint8Array<ArrayBuffer>): Promise<Buffer> {
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const ct = new Uint8Array(await subtle.encrypt({ name: "AES-GCM", iv: nonce, additionalData: ad }, key, enc.encode(plaintext)));
  return Buffer.concat([Buffer.from([1]), nonce, ct]);
}
async function open(key: CryptoKey, blob: Buffer, ad: Uint8Array<ArrayBuffer>): Promise<string> {
  expect(blob[0]).toBe(1);
  const pt = await subtle.decrypt({ name: "AES-GCM", iv: new Uint8Array(blob.subarray(1, 13)), additionalData: ad }, key, new Uint8Array(blob.subarray(13)));
  return new TextDecoder().decode(pt);
}

// pg_dump inside the Postgres container: its version always matches the server (local compose and the CI service).
function pgDump(dbUrl: string): string {
  const id = execFileSync("docker", ["ps", "-q", "--filter", "ancestor=pgvector/pgvector:pg17"], { encoding: "utf8" }).trim().split("\n")[0];
  if (!id) throw new Error("no running pgvector/pgvector:pg17 container to run pg_dump in");
  return execFileSync("docker", ["exec", id, "pg_dump", "-U", "postgres", new URL(dbUrl).pathname.slice(1)], { encoding: "utf8", maxBuffer: 64 << 20 });
}

describe.skipIf(!adminUrl)("server cannot read resume text", () => {
  let db: Awaited<ReturnType<typeof freshDatabase>>;
  let pool: pg.Pool;
  let app: ReturnType<typeof buildApp>;
  let logs = "";
  beforeAll(async () => {
    db = await freshDatabase();
    await migrate(db.url, "up");
    pool = new pg.Pool({ connectionString: db.url });
    const logStream = new PassThrough();
    logStream.on("data", (c) => { logs += c.toString(); });
    app = buildApp({ auth: { issuer, audience, jwks: iss.jwks }, users: dbUsers(pool), sync: dbSync(pool), jobs: dbJobs(pool),
      idempotency: dbIdempotency(pool), limits: dbLimits(pool), logStream });
    base = await app.listen({ port: 0, host: "127.0.0.1" });
  });
  let base = "";
  // Real HTTP, the same shape as inject()'s reply for the checks below.
  const call = async (method: string, url: string, headers: Record<string, string>, payload?: object) => {
    const r = await fetch(base + url, { method, headers: { ...headers, ...(payload ? { "content-type": "application/json" } : {}) }, ...(payload ? { body: JSON.stringify(payload) } : {}) });
    const body = await r.text();
    return { statusCode: r.status, body, json: () => JSON.parse(body) };
  };
  afterAll(async () => { await app.close(); await pool.end(); await db.drop(); });

  test("a pushed canary resume is not in the dump, logs, traces or responses", async () => {
    const authorization = `Bearer ${await iss.sign({ sub: "privacy-user" })}`;
    const userId = (await call("GET", "/v1/me", { authorization })).json().id as string;
    const key = await subtle.importKey("raw", crypto.getRandomValues(new Uint8Array(32)), "AES-GCM", false, ["encrypt", "decrypt"]);
    const blob = await seal(key, canary, aad(userId, "resumes", 1));
    const put = (headers: Record<string, string>, payload: object) =>
      call("PUT", "/v1/sync/resumes", { authorization, ...headers }, payload);

    const responses = [
      await put({ "if-none-match": "*", "idempotency-key": "privacy-1" }, { keyId: "k1", ciphertext: blob.toString("base64") }),
      await put({ "if-none-match": "*" }, { keyId: "k1", ciphertext: blob.toString("base64") }), // 409
      await put({ "if-none-match": "*" }, { keyId: "k1", ciphertext: blob.toString("base64"), plaintext: canary }), // a buggy client: 400
      await call("GET", "/v1/sync/resumes", { authorization }),
      // A search built from the profile, sent through a proxy: the query, client IP and user agent must not be kept.
      await call("GET", `/v1/jobs?q=${searchCanary}&location=Privet+Drive`, { authorization, "x-forwarded-for": "203.0.113.77", "user-agent": "UA-CANARY/1.0" }),
      await put({ "if-none-match": "*", "idempotency-key": "privacy-1" }, { keyId: "k1", ciphertext: blob.toString("base64") }), // replay
    ];
    expect(responses.map((r) => r.statusCode)).toEqual([200, 409, 400, 200, 200, 200]);
    const got = Buffer.from(responses[3]!.json().ciphertext, "base64");
    expect(await open(key, got, aad(userId, "resumes", 1))).toBe(canary); // the format round-trips for the owner
    await expect(open(key, got, aad(userId, "resumes", 2))).rejects.toThrow(); // a relabelled version fails
    await expect(open(key, got, aad(userId, "resumes", 1, "k2"))).rejects.toThrow(); // and so does a swapped key id

    const dump = pgDump(db.url);
    await new Promise((r) => setImmediate(r)); // let the log stream flush
    expect(dump).toContain(blob.toString("hex")); // the haystacks are real: the blob is in the dump...
    expect(logs).toContain("/v1/sync/resumes"); // ...and requests were logged
    const needles = [searchCanary, "203.0.113.77", "UA-CANARY", canary, "Privet Drive", Buffer.from(canary).toString("base64"), Buffer.from(canary).toString("hex"), authorization.slice(7)];
    const traces = traceText();
    // ...and so are the traces: a server span for the sync PUT and a pg span for its SQL.
    const names = spans.getFinishedSpans().map((s) => s.name);
    expect(names).toContain("PUT");
    expect(spans.getFinishedSpans().some((s) => s.attributes["url.path"] === "/v1/jobs")).toBe(true); // the search was traced
    expect(names.some((n) => n.startsWith("pg.query"))).toBe(true);
    const haystacks = { dump, logs, traces, responses: responses.map((r) => r.body).join("\n") };
    for (const [where, text] of Object.entries(haystacks))
      for (const n of needles) expect(text.includes(n), `${where} contains "${n.slice(0, 24)}…"`).toBe(false);
    // Logs and traces must not carry even the ciphertext (sync bodies are never logged or traced).
    for (const [where, text] of Object.entries({ logs, traces }))
      expect(text.includes(blob.toString("base64")) || text.includes(blob.toString("hex")), `${where} holds the ciphertext`).toBe(false);
    // Traces hold no bound SQL values at all (pg would record a bytea as raw text, which the needles above can't spot):
    // the user id is bound into every sync query, so it is the canary for that.
    expect(traces.includes(userId), "traces hold bound SQL values").toBe(false);
    for (const s of spans.getFinishedSpans()) expect(Object.keys(s.attributes).filter((k) => /values|body|header/i.test(k))).toEqual([]);
  });

  // P3.7: the same gate for blobs made by the web client's own code (@offerlane/core sync.ts), keyring included.
  test("a canary encrypted by the web sync client is not in the dump, logs, traces or responses", async () => {
    const authorization = `Bearer ${await iss.sign({ sub: "privacy-web-user" })}`;
    const userId = (await call("GET", "/v1/me", { authorization })).json().id as string;
    const webCanary = `WEBCANARY-${randomBytes(8).toString("hex")} John R. Example, 12 Grimmauld Place`;
    const ak = makeAccountKey(), rk = makeRecoveryKey(), keyId = makeKeyId();
    const ring = Buffer.from(await wrapAccountKey(ak, keyId, rk, userId, 1, "rk-1"));
    const blob = Buffer.from(await sealBlob(await importAccountKey(ak), enc.encode(JSON.stringify({ a: { updated: "x", note: webCanary } })),
      syncAAD(userId, "applications", 1, keyId)));
    const responses = [
      await call("PUT", "/v1/sync/keyring", { authorization, "if-none-match": "*", "idempotency-key": crypto.randomUUID() }, { keyId: "rk-1", ciphertext: ring.toString("base64") }),
      await call("PUT", "/v1/sync/applications", { authorization, "if-none-match": "*", "idempotency-key": crypto.randomUUID() }, { keyId, ciphertext: blob.toString("base64") }),
      await call("GET", "/v1/sync/keyring", { authorization }),
      await call("GET", "/v1/sync/applications", { authorization }),
    ];
    expect(responses.map((r) => r.statusCode)).toEqual([200, 200, 200, 200]);
    // A second device with only the recovery key gets the data back.
    const { key: back } = await unwrapAccountKey(new Uint8Array(Buffer.from(responses[2]!.json().ciphertext, "base64")), rk, userId, 1, "rk-1");
    const got = new Uint8Array(Buffer.from(responses[3]!.json().ciphertext, "base64"));
    expect(new TextDecoder().decode(await openBlob(back, got, syncAAD(userId, "applications", 1, keyId)))).toContain(webCanary);

    const dump = pgDump(db.url);
    await new Promise((r) => setImmediate(r));
    expect(dump).toContain(blob.toString("hex"));
    expect(dump).toContain(ring.toString("hex"));
    const rkText = formatRecoveryKey(rk);
    const needles = [webCanary, "Grimmauld", Buffer.from(webCanary).toString("base64"), Buffer.from(webCanary).toString("hex"), Buffer.from(ak).toString("hex"),
      Buffer.from(ak).toString("base64"), Buffer.from(rk).toString("hex"), rkText, rkText.replaceAll("-", "")];
    const haystacks = { dump, logs, traces: traceText(), responses: responses.map((r) => r.body).join("\n") };
    for (const [where, text] of Object.entries(haystacks))
      for (const n of needles) expect(text.includes(n), `${where} contains "${n.slice(0, 24)}…"`).toBe(false);
  });
});
