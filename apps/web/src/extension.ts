// The web side of the extension bridge (H5, P3.8): chrome.runtime.sendMessage to the Offerlane extension, which accepts
// this origin only (externally_connectable). The web hands over the answer set and takes the jobs saved there.
import { MAX_ANSWERS, MAX_JOBS, savedReply, type ToExtension } from "@offerlane/core";
import { loadProfile } from "./data.js";
import { addFound, loadSaved } from "./jobs.js";

declare const __EXTENSION_ID__: string;
export class ExtensionError extends Error {}
const MISSING = "Offerlane's browser extension isn't installed in this browser (or is turned off). Add it, then reload this page.";

type Runtime = { sendMessage(id: string, msg: unknown, cb: (reply: unknown) => void): void; lastError?: unknown };
function send(msg: ToExtension): Promise<Record<string, unknown>> {
  // chrome.runtime only exists on this page when an installed extension lists this origin.
  const rt = (globalThis as { chrome?: { runtime?: Runtime } }).chrome?.runtime;
  if (typeof rt?.sendMessage !== "function") return Promise.reject(new ExtensionError(MISSING));
  return new Promise((resolve, reject) => {
    try {
      rt.sendMessage(__EXTENSION_ID__, msg, (reply) => {
        const r = reply as Record<string, unknown> | undefined;
        if (rt.lastError || !r || r.ok !== true) reject(new ExtensionError(rt.lastError || !r ? MISSING : "The extension didn't accept that. Update it and try again."));
        else resolve(r);
      });
    } catch { reject(new ExtensionError(MISSING)); }
  });
}

export const extensionReady = () => send({ type: "ping" }).then(() => true, () => false);

/** The profile plus every role in Review or Ready with its answers. Returns how many roles were sent. */
export async function sendAnswers(): Promise<number> {
  const [profile, saved] = await Promise.all([loadProfile(), loadSaved()]);
  if (profile.personal.email === "" && profile.personal.full_name === "") throw new ExtensionError("Add your details in Profile first; the extension answers from them.");
  const jobs = Object.values(saved).filter((s) => s.status === "review" || s.status === "ready").slice(0, MAX_JOBS)
    .map((s) => ({ job: s.job, answers: (s.answers ?? "").slice(0, MAX_ANSWERS) }));
  await send({ type: "answers", profile, jobs });
  return jobs.length;
}

/** Jobs saved with the extension join Discover; the extension forgets them only after they're stored here. */
export async function bringSaved(): Promise<number> {
  const jobs = savedReply(await send({ type: "saved" }));
  if (!jobs) throw new ExtensionError("The extension sent something unexpected. Update it and try again.");
  const added = await addFound(jobs);
  if (jobs.length > 0) await send({ type: "clear", ids: jobs.map((j) => j.id) });
  return added;
}
