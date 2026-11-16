// What changes when apps/web runs inside the Windows shell (v4 P4.3). The browser build uses this file;
// apps/windows/vite.config.ts swaps in apps/windows/src/platform.ts for every "./platform.js" import in this folder.
export type Platform = { name: "web" | "windows" };
export const platform: Platform = { name: "web" };
