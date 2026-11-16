import { PassThrough } from "node:stream";
import { expect, test } from "vitest";
import { buildApp } from "../src/app.js";
import { audience, fakeIssuer, issuer, memorySync, memoryUsers } from "./fakeIssuer.js";

const iss = await fakeIssuer();

test("secrets a handler logs by mistake are redacted, and request logs carry no headers or bodies", async () => {
  let logs = "";
  const logStream = new PassThrough();
  logStream.on("data", (c) => { logs += c.toString(); });
  const app = buildApp({ auth: { issuer, audience, jwks: iss.jwks }, users: memoryUsers(), sync: memorySync(), logStream });
  app.post("/oops", async (req) => {
    req.log.info({ req: { headers: req.headers }, body: req.body }, "careless");
    req.log.info({ headers: req.headers, ciphertext: "CT-SECRET" }, "careless 2");
    req.log.info({ authorization: req.headers.authorization, nested: { deep: { cookie: "c=COOKIE-SECRET" } } }, "careless 3");
    return { ok: true };
  });
  const token = await iss.sign();
  await app.inject({ method: "POST", url: "/oops", headers: { authorization: `Bearer ${token}`, cookie: "s=COOKIE-SECRET" }, payload: { ciphertext: "BODY-SECRET" } });
  await app.inject({ method: "PUT", url: "/v1/sync/profile", headers: { authorization: `Bearer ${token}`, "if-none-match": "*", "idempotency-key": "IDEM-SECRET" }, payload: { keyId: "k1", ciphertext: Buffer.from("SYNC-SECRET").toString("base64") } });
  await app.close();
  await new Promise((r) => setImmediate(r));
  expect(logs).toContain("careless 3"); // the logs are real
  expect(logs).toContain("/v1/sync/profile");
  // SHORTCUT: the wildcard paths reach three levels deep; anything deeper isn't redacted, so never log raw objects.
  for (const n of [token, "BODY-SECRET", "CT-SECRET", "COOKIE-SECRET", "IDEM-SECRET", Buffer.from("SYNC-SECRET").toString("base64")])
    expect(logs.includes(n), n.slice(0, 20)).toBe(false);
});
