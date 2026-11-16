// What changes when apps/web runs inside the Windows shell (v4 P4.3). The browser build uses this file;
// apps/windows/vite.config.ts swaps in apps/windows/src/platform.ts for every "./platform.js" import in this folder.
import type { AIConfig } from "@offerlane/core";

export type Platform = {
  name: "web" | "windows";
  /** Where "remember this key" keeps the AI config when not in IndexedDB (the shell: Credential Manager). */
  secrets?: { save(c: AIConfig): Promise<void>; load(): Promise<AIConfig | undefined>; forget(): Promise<void> };
};
export const platform: Platform = { name: "web" };
