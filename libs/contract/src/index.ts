// The API contract (P2.8): one zod schema per request/response shape. apps/api validates with these,
// scripts/gen.ts turns them into openapi.json (+ the TS client types), and the Swift client is generated from that file.
import { extendZodWithOpenApi, OpenAPIRegistry, OpenApiGeneratorV31 } from "@asteasolutions/zod-to-openapi";
import { z } from "zod";
import type { paths } from "./schema.js";

extendZodWithOpenApi(z);

/** The fixed list from docs/v4/SYNC_CRYPTO.md (also a DB CHECK): caps each user at KINDS.length x 8 MiB. */
export const KINDS = ["keyring", "profile", "resumes", "applications", "contacts", "settings"] as const;
/** The six public ATS job-board APIs (apps/api/src/ats.ts). */
export const ATS = ["greenhouse", "lever", "ashby", "workable", "smartrecruiters", "workday"] as const;

// Requests. Strict objects: unknown fields are a 400, not silently dropped.
export const SyncParams = z.object({ kind: z.enum(KINDS) });
export const SyncPutBody = z.strictObject({
  keyId: z.string().regex(/^[A-Za-z0-9_-]{1,64}$/), // an opaque id; no room for names or control bytes
  ciphertext: z.string().min(4).openapi({ description: "Standard base64 (padded) of the client-encrypted blob, at most 8 MiB decoded." }),
});
export const JobsQuery = z.strictObject({
  q: z.string().min(1).max(200).optional().openapi({ description: "Full-text search (websearch syntax) over title, company and description." }),
  location: z.string().min(1).max(100).optional(),
  remote: z.boolean().optional(),
  ats: z.enum(ATS).optional(),
  posted_since: z.string().regex(/^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$/).optional().openapi({ description: "YYYY-MM-DD; must be a real day." }),
  limit: z.int().min(1).max(100).default(25),
  cursor: z.string().min(1).max(200).optional().openapi({ description: "The `next` value of the previous page." }),
});

// Responses. Error codes are a closed list per response: a new code is an API change (old clients can't decode it).
const errorBody = <const C extends readonly [string, ...string[]]>(codes: C) => z.object({ error: z.enum(codes) });
export const Health = z.object({ ok: z.literal(true) }).openapi("Health");
export const Me = z.object({ id: z.string() }).openapi("Me");
export const SyncBlob = z.object({ version: z.int().min(1), keyId: z.string(), ciphertext: z.string() }).openapi("SyncBlob");
export const SyncPutResult = z.object({ version: z.int().min(1) }).openapi("SyncPutResult");
export const Job = z.object({
  id: z.string(), ats: z.enum(ATS), title: z.string(), company: z.string(), location: z.string(), remote: z.boolean(),
  url: z.string(), applyUrl: z.string(), description: z.string(),
  postedAt: z.string().nullable().openapi({ description: "YYYY-MM-DD (UTC), or null when the board gives no date." }),
}).openapi("Job");
export const JobPage = z.object({ items: z.array(Job), next: z.string().nullable() }).openapi("JobPage");

/** Fastify's ajv takes JSON Schema; "input" keeps defaulted fields optional (limit). */
export const jsonSchema = (s: z.ZodType) => z.toJSONSchema(s, { target: "draft-7", io: "input" });

const json = (schema: z.ZodType, description: string, headers?: z.ZodObject) =>
  ({ description, content: { "application/json": { schema } }, ...(headers ? { headers } : {}) });
const err = <const C extends readonly [string, ...string[]]>(description: string, codes: C, headers?: z.ZodObject) => json(errorBody(codes), description, headers);
const etag = z.string().openapi({ description: 'The blob version, as "v<n>".', example: '"v3"' });
// A retried PUT with the same Idempotency-Key gets the stored response back, marked with this header.
const replayed = z.literal("true").optional().openapi({ description: "Present when this is the stored answer to an earlier request with the same Idempotency-Key." });
const authed = {
  401: err("Missing, invalid or expired bearer token.", ["unauthorized"], z.object({ "www-authenticate": z.string() })),
  429: err("Per-user rate limit.", ["rate_limited"], z.object({ "retry-after": z.string().openapi({ description: "Seconds to wait." }) })),
  500: err("Internal error; no detail is ever sent.", ["internal"]),
};

export function openapiDocument() {
  const r = new OpenAPIRegistry();
  const bearer = r.registerComponent("securitySchemes", "bearer", { type: "http", scheme: "bearer", bearerFormat: "JWT" });
  const security = [{ [bearer.name]: [] }];
  r.registerPath({ method: "get", path: "/healthz", operationId: "health", responses: { 200: json(Health, "Up.") } });
  r.registerPath({
    method: "get", path: "/readyz", operationId: "ready",
    responses: { 200: json(Health, "Ready: the database answers and its newest migration is applied."), 503: err("Not ready; take this instance out of rotation.", ["not_ready"]) },
  });
  r.registerPath({ method: "get", path: "/v1/me", operationId: "getMe", security, responses: { 200: json(Me, "The caller's opaque user id."), ...authed } });
  r.registerPath({
    method: "get", path: "/v1/sync/{kind}", operationId: "getSync", security, request: { params: SyncParams },
    responses: { 200: json(SyncBlob, "The stored ciphertext.", z.object({ etag })), 400: err("Unknown kind.", ["bad_request"]), 404: err("Nothing stored yet.", ["not_found"]), ...authed },
  });
  r.registerPath({
    method: "put", path: "/v1/sync/{kind}", operationId: "putSync", security,
    request: {
      params: SyncParams,
      headers: z.object({
        "if-match": z.string().regex(/^"v[1-9]\d{0,15}"$/).optional().openapi({ description: 'Replace: the version you read, "v<n>". Send this or If-None-Match.' }),
        "if-none-match": z.literal("*").optional().openapi({ description: "Create only." }),
        "idempotency-key": z.string().regex(/^[\x21-\x7e]{1,255}$/).optional().openapi({ description: "Safe retries for 24 h. Use a new key after a 4xx." }),
      }),
      body: { content: { "application/json": { schema: SyncPutBody } } },
    },
    responses: {
      200: json(SyncPutResult, "Stored; the server set the new version.", z.object({ etag, "idempotent-replayed": replayed })),
      400: err("Bad body, base64, precondition or Idempotency-Key.", ["bad_request", "bad_precondition", "bad_ciphertext", "bad_idempotency_key"], z.object({ "idempotent-replayed": replayed })),
      409: json(z.object({
        error: z.enum(["conflict", "idempotency_key_in_flight"]),
        version: z.int().nullable().optional().openapi({ description: "`conflict` only: the current version (null if the blob doesn't exist)." }),
      }), "Version conflict, or the same Idempotency-Key is still running.", z.object({ "idempotent-replayed": replayed })),
      413: err("Ciphertext over 8 MiB.", ["too_large"], z.object({ "idempotent-replayed": replayed })),
      415: err("Body is not JSON.", ["unsupported_media_type"]),
      422: err("Idempotency-Key reused for a different request.", ["idempotency_key_reused"]),
      428: err("Neither If-Match nor If-None-Match.", ["precondition_required"], z.object({ "idempotent-replayed": replayed })),
      ...authed,
    },
  });
  r.registerPath({
    method: "get", path: "/v1/jobs", operationId: "listJobs", security, request: { query: JobsQuery },
    responses: { 200: json(JobPage, "One page, newest first."), 400: err("Bad filter or cursor.", ["bad_request", "bad_cursor"]), ...authed },
  });
  return new OpenApiGeneratorV31(r.definitions).generateDocument({
    openapi: "3.1.0",
    info: { title: "Offerlane API", version: "1", description: "Sync blobs are end-to-end encrypted; the server never sees readable resume or profile text." },
  });
}

export { apiClient } from "./client.js";
export type { paths };
