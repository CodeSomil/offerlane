// Error reports (P2.7). Off unless SENTRY_DSN is set. Only 500s are reported, and only as error type + code +
// stack: a Postgres message can quote a row, and requests carry tokens and ciphertext.
import * as Sentry from "@sentry/node";
import type { ErrorEvent } from "@sentry/node";

type Transport = NonNullable<Parameters<typeof Sentry.init>[0]>["transport"];

/** Starts Sentry when a DSN is given. transport: tests only. */
export function initSentry(dsn: string | undefined, transport?: Transport): boolean {
  if (!dsn) return false;
  Sentry.init({
    dsn,
    // No automatic integrations: no request data, breadcrumbs, local variables or tracing. We capture explicitly.
    defaultIntegrations: false,
    // Collect nothing about users or requests even if an integration is added later (scrub is the backstop).
    dataCollection: { userInfo: false, cookies: false, httpHeaders: false, httpBodies: [], urlQueryParams: false, databaseQueryData: false },
    beforeBreadcrumb: () => null,
    beforeSend: scrub,
    ...(transport ? { transport } : {}),
  });
  return true;
}

/** Keeps what locates a bug (exception type, code, stack frames without variables); drops anything that can quote data. */
export function scrub(e: ErrorEvent): ErrorEvent {
  const code = e.tags?.code;
  const out: ErrorEvent = { ...e, tags: code === undefined ? {} : { code } };
  for (const k of ["message", "request", "user", "breadcrumbs", "extra", "contexts", "logentry"] as const) delete out[k];
  if (e.exception?.values) {
    out.exception = {
      values: e.exception.values.map((x) => ({
        ...x,
        value: String(code ?? "error"),
        ...(x.stacktrace?.frames ? { stacktrace: { frames: x.stacktrace.frames.map(({ vars: _v, ...f }) => f) } } : {}),
      })),
    };
  }
  return out;
}

/** Called by the 500 handler. A no-op when Sentry is off. */
export function reportError(err: unknown, code: string | undefined) {
  Sentry.captureException(err, { tags: { code: code ?? "error" } });
}
