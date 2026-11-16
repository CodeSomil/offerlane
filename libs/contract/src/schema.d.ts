export interface paths {
    "/healthz": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get: operations["health"];
        put?: never;
        post?: never;
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/readyz": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get: operations["ready"];
        put?: never;
        post?: never;
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/v1/me": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get: operations["getMe"];
        put?: never;
        post?: never;
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/v1/sync/{kind}": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get: operations["getSync"];
        put: operations["putSync"];
        post?: never;
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/v1/jobs": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get: operations["listJobs"];
        put?: never;
        post?: never;
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
}
export type webhooks = Record<string, never>;
export interface components {
    schemas: {
        Health: {
            /** @enum {boolean} */
            ok: true;
        };
        Me: {
            id: string;
        };
        SyncBlob: {
            version: number;
            keyId: string;
            ciphertext: string;
        };
        SyncPutResult: {
            version: number;
        };
        JobPage: {
            items: components["schemas"]["Job"][];
            next: string | null;
        };
        Job: {
            id: string;
            /** @enum {string} */
            ats: "greenhouse" | "lever" | "ashby" | "workable" | "smartrecruiters" | "workday";
            title: string;
            company: string;
            location: string;
            remote: boolean;
            url: string;
            applyUrl: string;
            description: string;
            /** @description YYYY-MM-DD (UTC), or null when the board gives no date. */
            postedAt: string | null;
        };
    };
    responses: never;
    parameters: never;
    requestBodies: never;
    headers: never;
    pathItems: never;
}
export type $defs = Record<string, never>;
export interface operations {
    health: {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description Up. */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": components["schemas"]["Health"];
                };
            };
        };
    };
    ready: {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description Ready: the database answers and its newest migration is applied. */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": components["schemas"]["Health"];
                };
            };
            /** @description Not ready; take this instance out of rotation. */
            503: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @enum {string} */
                        error: "not_ready";
                    };
                };
            };
        };
    };
    getMe: {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description The caller's opaque user id. */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": components["schemas"]["Me"];
                };
            };
            /** @description Missing, invalid or expired bearer token. */
            401: {
                headers: {
                    "www-authenticate": string;
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @enum {string} */
                        error: "unauthorized";
                    };
                };
            };
            /** @description Per-user rate limit. */
            429: {
                headers: {
                    /** @description Seconds to wait. */
                    "retry-after": string;
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @enum {string} */
                        error: "rate_limited";
                    };
                };
            };
            /** @description Internal error; no detail is ever sent. */
            500: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @enum {string} */
                        error: "internal";
                    };
                };
            };
        };
    };
    getSync: {
        parameters: {
            query?: never;
            header?: never;
            path: {
                kind: "keyring" | "profile" | "resumes" | "applications" | "contacts" | "settings";
            };
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description The stored ciphertext. */
            200: {
                headers: {
                    /** @description The blob version, as "v<n>". */
                    etag: string;
                    [name: string]: unknown;
                };
                content: {
                    "application/json": components["schemas"]["SyncBlob"];
                };
            };
            /** @description Unknown kind. */
            400: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @enum {string} */
                        error: "bad_request";
                    };
                };
            };
            /** @description Missing, invalid or expired bearer token. */
            401: {
                headers: {
                    "www-authenticate": string;
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @enum {string} */
                        error: "unauthorized";
                    };
                };
            };
            /** @description Nothing stored yet. */
            404: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @enum {string} */
                        error: "not_found";
                    };
                };
            };
            /** @description Per-user rate limit. */
            429: {
                headers: {
                    /** @description Seconds to wait. */
                    "retry-after": string;
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @enum {string} */
                        error: "rate_limited";
                    };
                };
            };
            /** @description Internal error; no detail is ever sent. */
            500: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @enum {string} */
                        error: "internal";
                    };
                };
            };
        };
    };
    putSync: {
        parameters: {
            query?: never;
            header?: {
                /** @description Replace: the version you read, "v<n>". Send this or If-None-Match. */
                "if-match"?: string;
                /** @description Create only. */
                "if-none-match"?: "*";
                /** @description Safe retries for 24 h. Use a new key after a 4xx. */
                "idempotency-key"?: string;
            };
            path: {
                kind: "keyring" | "profile" | "resumes" | "applications" | "contacts" | "settings";
            };
            cookie?: never;
        };
        requestBody?: {
            content: {
                "application/json": {
                    keyId: string;
                    /** @description Standard base64 (padded) of the client-encrypted blob, at most 8 MiB decoded. */
                    ciphertext: string;
                };
            };
        };
        responses: {
            /** @description Stored; the server set the new version. */
            200: {
                headers: {
                    /** @description The blob version, as "v<n>". */
                    etag: string;
                    /** @description Present when this is the stored answer to an earlier request with the same Idempotency-Key. */
                    "idempotent-replayed"?: "true";
                    [name: string]: unknown;
                };
                content: {
                    "application/json": components["schemas"]["SyncPutResult"];
                };
            };
            /** @description Bad body, base64, precondition or Idempotency-Key. */
            400: {
                headers: {
                    /** @description Present when this is the stored answer to an earlier request with the same Idempotency-Key. */
                    "idempotent-replayed"?: "true";
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @enum {string} */
                        error: "bad_request" | "bad_precondition" | "bad_ciphertext" | "bad_idempotency_key";
                    };
                };
            };
            /** @description Missing, invalid or expired bearer token. */
            401: {
                headers: {
                    "www-authenticate": string;
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @enum {string} */
                        error: "unauthorized";
                    };
                };
            };
            /** @description Version conflict, or the same Idempotency-Key is still running. */
            409: {
                headers: {
                    /** @description Present when this is the stored answer to an earlier request with the same Idempotency-Key. */
                    "idempotent-replayed"?: "true";
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @enum {string} */
                        error: "conflict" | "idempotency_key_in_flight";
                        /** @description `conflict` only: the current version (null if the blob doesn't exist). */
                        version?: number | null;
                    };
                };
            };
            /** @description Ciphertext over 8 MiB. */
            413: {
                headers: {
                    /** @description Present when this is the stored answer to an earlier request with the same Idempotency-Key. */
                    "idempotent-replayed"?: "true";
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @enum {string} */
                        error: "too_large";
                    };
                };
            };
            /** @description Body is not JSON. */
            415: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @enum {string} */
                        error: "unsupported_media_type";
                    };
                };
            };
            /** @description Idempotency-Key reused for a different request. */
            422: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @enum {string} */
                        error: "idempotency_key_reused";
                    };
                };
            };
            /** @description Neither If-Match nor If-None-Match. */
            428: {
                headers: {
                    /** @description Present when this is the stored answer to an earlier request with the same Idempotency-Key. */
                    "idempotent-replayed"?: "true";
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @enum {string} */
                        error: "precondition_required";
                    };
                };
            };
            /** @description Per-user rate limit. */
            429: {
                headers: {
                    /** @description Seconds to wait. */
                    "retry-after": string;
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @enum {string} */
                        error: "rate_limited";
                    };
                };
            };
            /** @description Internal error; no detail is ever sent. */
            500: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @enum {string} */
                        error: "internal";
                    };
                };
            };
        };
    };
    listJobs: {
        parameters: {
            query?: {
                /** @description Full-text search (websearch syntax) over title, company and description. */
                q?: string;
                location?: string;
                remote?: boolean;
                ats?: "greenhouse" | "lever" | "ashby" | "workable" | "smartrecruiters" | "workday";
                /** @description YYYY-MM-DD; must be a real day. */
                posted_since?: string;
                limit?: number;
                /** @description The `next` value of the previous page. */
                cursor?: string;
            };
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description One page, newest first. */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": components["schemas"]["JobPage"];
                };
            };
            /** @description Bad filter or cursor. */
            400: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @enum {string} */
                        error: "bad_request" | "bad_cursor";
                    };
                };
            };
            /** @description Missing, invalid or expired bearer token. */
            401: {
                headers: {
                    "www-authenticate": string;
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @enum {string} */
                        error: "unauthorized";
                    };
                };
            };
            /** @description Per-user rate limit. */
            429: {
                headers: {
                    /** @description Seconds to wait. */
                    "retry-after": string;
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @enum {string} */
                        error: "rate_limited";
                    };
                };
            };
            /** @description Internal error; no detail is ever sent. */
            500: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @enum {string} */
                        error: "internal";
                    };
                };
            };
        };
    };
}
