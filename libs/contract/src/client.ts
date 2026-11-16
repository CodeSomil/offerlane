// The typed client alone (openapi-fetch + generated types), so a browser bundle doesn't pull in zod or the OpenAPI builder.
import createClient from "openapi-fetch";
import type { components, paths } from "./schema.js";

/** Typed client generated from openapi.json (src/schema.d.ts). */
export const apiClient = (baseUrl: string, init: Omit<Parameters<typeof createClient>[0], "baseUrl"> = {}) => createClient<paths>({ baseUrl, ...init });
export type ApiJob = components["schemas"]["Job"];
export type { paths };
