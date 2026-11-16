// Load generator for the H4 target (scripts/load_test.sh starts the stack and runs this).
// Open model: requests start on a fixed schedule (RATE/s) whether or not earlier ones have finished, so a slow server
// shows up as latency instead of being hidden by fewer requests. Mix: 40% GET sync, 20% PUT sync, 40% job search.
// Prints one JSON line and exits 1 unless p95 < P95_MS, there are no errors, and the achieved rate is >= 95% of RATE.
import { randomBytes, randomUUID } from "node:crypto";

const env = (k: string, d: string) => process.env[k] ?? d;
const BASE = env("BASE", "http://127.0.0.1:18787"), ISSUER = env("ISSUER", "http://127.0.0.1:19000");
const RATE = Number(env("RATE", "50")), SECONDS = Number(env("DURATION", "60")), USERS = Number(env("USERS", "200")), P95_MS = Number(env("P95_MS", "300"));
const words = ["engineer", "senior", "product", "designer", "data", "remote", "backend", "manager", "swift", "analyst"];
const blob = () => randomBytes(6 * 1024).toString("base64"); // a small encrypted profile (8 KB of base64)

type User = { auth: string; version: number; busy: boolean };
const users: User[] = [];
for (let i = 0; i < USERS; i++) {
  const { token } = (await (await fetch(`${ISSUER}/token?sub=load-${i}-${randomUUID()}`)).json()) as { token: string };
  const u: User = { auth: `Bearer ${token}`, version: 0, busy: false };
  // Setup, not measured: every user starts with a stored blob, so GETs are 200s and PUTs replace.
  const r = await fetch(`${BASE}/v1/sync/profile`, { method: "PUT", headers: { authorization: u.auth, "content-type": "application/json", "if-none-match": "*" }, body: JSON.stringify({ keyId: "k1", ciphertext: blob() }) });
  if (r.status !== 200) throw new Error(`setup PUT failed: ${r.status}`);
  u.version = ((await r.json()) as { version: number }).version;
  users.push(u);
}

const lat: number[] = [];
const errors: Record<string, number> = {};
let jobItems = 0, searches = 0; // proof the searches hit a real index, not an empty table
async function one(i: number) {
  const u = users[i % USERS]!;
  const turn = i + Math.floor(i / USERS); // shifts every round, so each user gets every request type and search word over time
  // A user has one sync request in flight at most (a real client does too), so a PUT's If-Match is never stale;
  // a busy user's sync turn becomes a job search.
  const pick = turn % 5 <= 2 && u.busy ? 3 : turn % 5; // 0,1 = GET sync; 2 = PUT sync; 3,4 = jobs
  let req: Request;
  if (pick <= 1) req = new Request(`${BASE}/v1/sync/profile`, { headers: { authorization: u.auth } });
  else if (pick === 2) req = new Request(`${BASE}/v1/sync/profile`, { method: "PUT", body: JSON.stringify({ keyId: "k1", ciphertext: blob() }),
    headers: { authorization: u.auth, "content-type": "application/json", "if-match": `"v${u.version}"`, "idempotency-key": randomUUID() } });
  else req = new Request(`${BASE}/v1/jobs?limit=20&q=${words[turn % words.length]}${turn % 3 === 0 ? "&remote=true" : ""}`, { headers: { authorization: u.auth } });
  if (pick <= 2) u.busy = true;
  const t0 = performance.now();
  try {
    const res = await fetch(req);
    const body = await res.text();
    lat.push(performance.now() - t0);
    if (res.status !== 200) errors[res.status] = (errors[res.status] ?? 0) + 1;
    else if (pick === 2) u.version = (JSON.parse(body) as { version: number }).version;
    else if (pick >= 3) { searches++; jobItems += (JSON.parse(body) as { items: unknown[] }).items.length; }
  } catch (e) {
    lat.push(performance.now() - t0);
    errors[(e as Error).name] = (errors[(e as Error).name] ?? 0) + 1;
  } finally { if (pick <= 2) u.busy = false; }
}

const total = RATE * SECONDS, gap = 1000 / RATE, start = performance.now();
const inflight: Promise<void>[] = [];
for (let i = 0; i < total; i++) {
  const wait = start + i * gap - performance.now();
  if (wait > 0) await new Promise((r) => setTimeout(r, wait));
  inflight.push(one(i));
}
await Promise.all(inflight);
const elapsed = (performance.now() - start) / 1000;
lat.sort((a, b) => a - b);
const pct = (p: number) => Math.round(lat[Math.min(lat.length - 1, Math.floor((p / 100) * lat.length))]! * 10) / 10;
const result = { target: `${RATE} req/s for ${SECONDS}s, ${USERS} users`, requests: lat.length, achievedRps: Math.round((lat.length / elapsed) * 10) / 10,
  p50: pct(50), p95: pct(95), p99: pct(99), max: pct(100), errors, avgJobsPerSearch: Math.round((jobItems / Math.max(1, searches)) * 10) / 10 };
const pass = result.p95 < P95_MS && Object.keys(errors).length === 0 && result.achievedRps >= RATE * 0.95 && result.avgJobsPerSearch > 0;
console.log(JSON.stringify({ ...result, pass }));
process.exit(pass ? 0 : 1);
