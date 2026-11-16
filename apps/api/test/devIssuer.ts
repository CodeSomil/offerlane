// DEV ONLY: a local OIDC issuer for the preview stack, the image smoke check, the load test (scripts/load_test.sh) and web sign-in.
// Handler and rules: devIssuerApp.ts. Never run it next to real data.
// It shares the API container's network namespace, so the API reaches it as http://localhost (auth.ts allows that, nothing else).
import { createServer } from "node:http";
import { devIssuerHandler } from "./devIssuerApp.js";
import { audience, fakeIssuer } from "./fakeIssuer.js";

const port = Number(process.env.ISSUER_PORT ?? 9000);
const iss = `http://localhost:${port}/`;
const { jwk, sign } = await fakeIssuer();
const webOrigins = (process.env.WEB_ORIGINS ?? "").split(",").map((s) => s.trim()).filter(Boolean);

createServer(devIssuerHandler({ iss, sign, jwk, webOrigins })).listen(port, "0.0.0.0", () => console.log(`dev issuer ${iss} (aud ${audience})`));
