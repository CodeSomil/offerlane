// apps/web's platform.fill in the shell (v4 P4.3d): the human's click opens one apply window (WebView2) and libs/core's
// ApplyEngine fills the form there, stopping before Submit; the window stays open for the human to check and submit.
import { ApplyEngine, cdpPage, type Answer, type ApplyPage, type Job, type Outcome, type Profile } from "@offerlane/core";
import { cdpBridge, CredentialVault, type Approvals, type Invoke, type Listen, type ShellPage } from "./bridge.js";

/** `browserProfile`: the apply window's cookie folder ("default" keeps career-site sign-ins; undefined = throwaway, for tests). */
export function shellFill(invoke: Invoke, listen: Listen, approvals: Approvals, autofill: string, browserProfile: string | undefined = "default") {
  const bridge = cdpBridge(invoke, listen);
  let current: ShellPage | undefined, page: ApplyPage | undefined;
  async function fill(job: Job, profile: Profile, answers: Answer[], approve: boolean): Promise<Outcome> {
    const url = job.apply_url || job.url;
    if (!/^https?:\/\//iu.test(url)) throw new Error("This role has no web link to apply at.");
    await current?.close().catch(() => {});  // one apply window at a time (the human may have closed it already)
    current = await bridge.open(browserProfile);
    page = cdpPage(current.send, autofill, current.on);
    const vault = new CredentialVault(invoke, approvals);
    await page.load(url);
    if (approve) await vault.approve(await page.host(), job.company);
    // SHORTCUT: no resume PDF (the web has no typeset PDF yet); the human attaches it, and the UI says so.
    return new ApplyEngine({ page, job, profile, answers, pdf: null, vault }).run(true);
  }
  return { fill, page: () => page, close: async () => { await current?.close(); current = undefined; } };
}
