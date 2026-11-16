// What changes when apps/web runs inside the Windows shell (v4 P4.3). The browser build uses this file;
// apps/windows/vite.config.ts swaps in apps/windows/src/platform.ts for every "./platform.js" import in this folder.
import type { AIConfig, Answer, Job, Outcome, Profile } from "@offerlane/core";

export type Platform = {
  name: "web" | "windows";
  /** Where "remember this key" keeps the AI config when not in IndexedDB (the shell: Credential Manager). */
  secrets?: { save(c: AIConfig): Promise<void>; load(): Promise<AIConfig | undefined>; forget(): Promise<void> };
  /** Fill this role's application in an apply window and stop before Submit (the shell only). `approve`: the human allowed
   *  an account for this company. */
  fill?: (job: Job, profile: Profile, answers: Answer[], approve: boolean) => Promise<Outcome>;
  /** A system notification (use notify.ts, which only shows it while the app is in the background). */
  notify?: (title: string, body: string) => Promise<void>;
};
export const platform: Platform = { name: "web" };
