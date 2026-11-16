import type { FastifyInstance } from "fastify";
import type pg from "pg";
import { jsonSchema, SyncParams, SyncPutBody } from "@offerlane/contract";

// D3 + docs/v4/SYNC_CRYPTO.md: blobs are client-encrypted; the server only stores and versions them, never parses them.
export const MAX_CIPHERTEXT = 8 * 1024 * 1024; // matches the sync_blobs CHECK

export type SyncBlob = { version: number; keyId: string; ciphertext: Buffer };
export type SyncStore = {
  get(userId: string, kind: string): Promise<SyncBlob | null>;
  // expected = null means "create only". On a mismatch, returns the current version (null if there is none).
  put(userId: string, kind: string, expected: number | null, keyId: string, ciphertext: Buffer):
    Promise<{ ok: true; version: number } | { ok: false; version: number | null }>;
};

export function dbSync(pool: pg.Pool): SyncStore {
  const current = async (userId: string, kind: string) =>
    (await pool.query<{ version: string }>("SELECT version FROM sync_blobs WHERE user_id = $1 AND kind = $2", [userId, kind])).rows[0];
  return {
    async get(userId, kind) {
      const r = (await pool.query<{ version: string; key_id: string; ciphertext: Buffer }>(
        "SELECT version, key_id, ciphertext FROM sync_blobs WHERE user_id = $1 AND kind = $2", [userId, kind])).rows[0];
      return r ? { version: Number(r.version), keyId: r.key_id, ciphertext: r.ciphertext } : null;
    },
    async put(userId, kind, expected, keyId, ciphertext) {
      // One statement each, so two racing writers can't both win (compare-and-set on version).
      const r = expected === null
        ? await pool.query<{ version: string }>(
          "INSERT INTO sync_blobs (user_id, kind, version, key_id, ciphertext) VALUES ($1, $2, 1, $3, $4) ON CONFLICT DO NOTHING RETURNING version",
          [userId, kind, keyId, ciphertext])
        : await pool.query<{ version: string }>(
          "UPDATE sync_blobs SET version = version + 1, key_id = $4, ciphertext = $5, updated_at = now() WHERE user_id = $1 AND kind = $2 AND version = $3 RETURNING version",
          [userId, kind, expected, keyId, ciphertext]);
      if (r.rows[0]) return { ok: true, version: Number(r.rows[0].version) };
      const cur = await current(userId, kind);
      return { ok: false, version: cur ? Number(cur.version) : null };
    },
  };
}

export { KINDS } from "@offerlane/contract";
const params = jsonSchema(SyncParams);
const body = jsonSchema(SyncPutBody); // ciphertext is base64, checked in the handler (a grouped regex overflows the stack at 8 MiB)
const etag = (v: number) => `"v${v}"`;

// Registered inside the authenticated /v1 scope, so req.userId is always set.
export function syncRoutes(v1: FastifyInstance, store: SyncStore) {
  v1.get<{ Params: { kind: string } }>("/sync/:kind", { schema: { params } }, async (req, reply) => {
    const b = await store.get(req.userId, req.params.kind);
    if (!b) return reply.code(404).send({ error: "not_found" });
    return reply.header("etag", etag(b.version)).send({ version: b.version, keyId: b.keyId, ciphertext: b.ciphertext.toString("base64") });
  });

  v1.put<{ Params: { kind: string }; Body: { keyId: string; ciphertext: string } }>("/sync/:kind", {
    schema: { params, body },
    bodyLimit: Math.ceil(MAX_CIPHERTEXT / 3) * 4 + 1024, // base64 of the cap plus room for the JSON around it
  }, async (req, reply) => {
    const ifMatch = req.headers["if-match"];
    const ifNone = req.headers["if-none-match"];
    if (ifMatch === undefined && ifNone === undefined) return reply.code(428).send({ error: "precondition_required" });
    let expected: number | null = null;
    if (ifMatch !== undefined) {
      const m = ifNone === undefined ? /^"v([1-9]\d{0,15})"$/.exec(ifMatch) : null;
      if (!m) return reply.code(400).send({ error: "bad_precondition" });
      expected = Number(m[1]);
    } else if (ifNone !== "*") return reply.code(400).send({ error: "bad_precondition" });

    // Strict base64: Buffer.from would silently skip bad characters.
    const b64 = req.body.ciphertext;
    if (b64.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(b64)) return reply.code(400).send({ error: "bad_ciphertext" });
    const ciphertext = Buffer.from(b64, "base64");
    if (ciphertext.length > MAX_CIPHERTEXT) return reply.code(413).send({ error: "too_large" });
    const r = await store.put(req.userId, req.params.kind, expected, req.body.keyId, ciphertext);
    if (!r.ok) return reply.code(409).send({ error: "conflict", version: r.version });
    return reply.header("etag", etag(r.version)).send({ version: r.version });
  });
}
