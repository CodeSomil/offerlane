import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { afterAll, beforeAll, expect, test } from "vitest";
import { discover } from "../src/auth.js";

// A local discovery endpoint; `claimed` is the issuer the document says it is.
let server: Server;
let base = "";
let claimed = "";
let jwksUri = "";
beforeAll(async () => {
  server = createServer((req, res) => {
    if (req.url === "/.well-known/openid-configuration") {
      res.setHeader("content-type", "application/json");
      res.end(JSON.stringify({ issuer: claimed, jwks_uri: jwksUri || `${base}jwks` }));
    } else { res.statusCode = 404; res.end(); }
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  base = `http://127.0.0.1:${(server.address() as AddressInfo).port}/`;
});
afterAll(() => new Promise<void>((r) => server.close(() => r())));

test("reads the JWKS location from a matching discovery document", async () => {
  claimed = base;
  const cfg = await discover(base, "aud", true);
  expect(cfg.issuer).toBe(base);
  expect(typeof cfg.jwks).toBe("function");
});

test("refuses a document that claims another issuer", async () => {
  claimed = "https://evil.test/";
  await expect(discover(base, "aud", true)).rejects.toThrow(/does not match/);
});

test("refuses a plain-http issuer that isn't localhost", async () => {
  await expect(discover("http://issuer.example/", "aud", true)).rejects.toThrow(/https/);
});

test("refuses plain-http localhost unless explicitly allowed (dev issuer only)", async () => {
  claimed = base;
  await expect(discover(base, "aud")).rejects.toThrow(/https/);
});

test("refuses a jwks_uri that isn't https", async () => {
  claimed = base;
  jwksUri = "http://evil.example/jwks";
  try {
    await expect(discover(base, "aud", true)).rejects.toThrow(/jwks_uri must use https/);
  } finally { jwksUri = ""; }
});
