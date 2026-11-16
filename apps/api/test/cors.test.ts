import { expect, test } from "vitest";
import { buildApp } from "../src/app.js";
import { audience, fakeIssuer, issuer, memorySync, memoryUsers } from "./fakeIssuer.js";

const WEB = "https://app.offerlane.example";
const app = async (webOrigins?: string[]) => buildApp({ ...(webOrigins ? { webOrigins } : {}), auth: { issuer, audience, jwks: (await fakeIssuer()).jwks }, users: memoryUsers(), sync: memorySync() });
const preflight = { method: "OPTIONS" as const, url: "/v1/jobs", headers: { origin: WEB, "access-control-request-method": "GET", "access-control-request-headers": "authorization" } };

test("preflight from the web origin is answered before auth, with no wildcard and no credentials", async () => {
  const a = await app([WEB]);
  const r = await a.inject(preflight);
  expect(r.statusCode).toBe(204);
  expect(r.headers["access-control-allow-origin"]).toBe(WEB);
  expect(r.headers["access-control-allow-headers"]).toContain("authorization");
  expect(r.headers["access-control-allow-methods"]).toBe("GET, PUT");
  expect(r.headers["access-control-allow-credentials"]).toBeUndefined();
  expect(r.headers.vary).toContain("Origin");
  await a.close();
});

test("an actual call from the web origin gets the header even when refused (so the browser can read the 401)", async () => {
  const a = await app([WEB]);
  const r = await a.inject({ method: "GET", url: "/v1/me", headers: { origin: WEB } });
  expect(r.statusCode).toBe(401);
  expect(r.headers["access-control-allow-origin"]).toBe(WEB);
  expect(r.headers["access-control-expose-headers"]).toContain("etag");
  await a.close();
});

test("other origins, look-alikes and no configured origins get no CORS headers", async () => {
  for (const [origins, origin] of [[[WEB], "https://evil.example"], [[WEB], `${WEB}.evil.example`], [[WEB], "null"], [undefined, WEB], [[], WEB]] as const) {
    const a = await app(origins as string[] | undefined);
    for (const r of [await a.inject({ ...preflight, headers: { ...preflight.headers, origin } }), await a.inject({ method: "GET", url: "/healthz", headers: { origin } })]) {
      expect(r.headers["access-control-allow-origin"]).toBeUndefined();
      expect(r.headers["access-control-allow-methods"]).toBeUndefined();
    }
    await a.close();
  }
});
