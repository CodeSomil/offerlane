// JobStatus + StateMachine.allowed and PipelineHints (Swift). The status table is pinned by core_expected.json "status",
// the hints by Fixtures/core/pipeline_cases.json; both ports run the same files.
import { ageDays } from "./text.js";

export const STATUSES = ["found", "tailoring", "review", "ready", "applying", "account", "needs_you", "prefilled", "applied", "acknowledged",
  "assessment", "screen", "interview", "offer", "declined", "rejected", "withdrawn"] as const;
export type JobStatus = (typeof STATUSES)[number];
/** JobStatus.tracked: submitted applications, the Pipeline board's columns in order. */
export const TRACKED = ["applied", "acknowledged", "assessment", "screen", "interview", "offer"] as const satisfies readonly JobStatus[];
/** JobStatus.inFlight: approved, not yet submitted. */
export const IN_FLIGHT: readonly JobStatus[] = ["tailoring", "review", "ready", "applying", "account", "needs_you", "prefilled"];
export const STATUS_TITLE: Record<JobStatus, string> = {
  found: "New match", tailoring: "Tailoring", review: "Review resume", ready: "Ready to apply", applying: "Applying", account: "Account approval",
  needs_you: "Needs you", prefilled: "Ready to submit", applied: "Applied", acknowledged: "Acknowledged", assessment: "Assessment", screen: "Screen",
  interview: "Interview", offer: "Offer", declined: "Declined", rejected: "Rejected", withdrawn: "Withdrawn",
};
const tracked: readonly JobStatus[] = TRACKED;
const ALLOWED: Record<JobStatus, readonly JobStatus[]> = {
  found: ["tailoring", "declined"], declined: ["found", "tailoring"], tailoring: ["review", "declined"], review: ["ready", "tailoring", "declined"],
  ready: ["applying", "review", "declined"], applying: ["account", "needs_you", "prefilled", "applied", "ready", "declined"],
  account: ["applying", "needs_you", "declined"], needs_you: ["applying", "prefilled", "applied", "declined"], prefilled: ["applied", "applying", "needs_you", "declined"],
  rejected: [...tracked, "withdrawn"], withdrawn: [...tracked, "rejected"],
  // Submitted applications: the board lets the user drag them anywhere on it, or out to rejected/withdrawn.
  ...Object.fromEntries(tracked.map((s) => [s, [...tracked.filter((x) => x !== s), "rejected", "withdrawn"]])) as Record<(typeof TRACKED)[number], JobStatus[]>,
};
export const isStatus = (s: string): s is JobStatus => (STATUSES as readonly string[]).includes(s);
/** StateMachine.canMove */
export const canMove = (from: string, to: string) => isStatus(from) && isStatus(to) && ALLOWED[from].includes(to);

/** PipelineHints: card age in calendar days, quiet after 14 days waiting on the employer, one template next step. No AI call. */
export const STALE_DAYS = 14;
export const pipelineAge = (updated: string, now = new Date()) => Math.max(0, ageDays(updated, now));
export const isStale = (status: string, updated: string, now = new Date()) => (status === "applied" || status === "acknowledged") && pipelineAge(updated, now) >= STALE_DAYS;
export function nextStep(status: string, updated: string, now = new Date()): string {
  const days = pipelineAge(updated, now);
  switch (status) {
    case "applied": case "acknowledged":
      return isStale(status, updated, now) ? "Send a short follow-up" : days < 7 ? "Nothing to do yet" : "Wait; replies usually come in 7–10 days";
    case "assessment": return "Complete the assessment";
    case "screen": case "interview": return "Prepare your STAR stories";
    case "offer": return "Compare offers";
    default: return "Open it to see what's next";
  }
}
