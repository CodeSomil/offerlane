import { defineConfig, normalizePath, type Plugin } from "vite";
import react from "@vitejs/plugin-react";
import { fileURLToPath } from "node:url";
import { webEnv } from "../web/vite.config.js";

// Windows paths differ in drive-letter case between tools, so compare without case there.
const fold = (p: string) => (process.platform === "win32" ? p.toLowerCase() : p);
const webSrc = fold(normalizePath(fileURLToPath(new URL("../web/src/", import.meta.url))));
const shellPlatform = normalizePath(fileURLToPath(new URL("./src/platform.ts", import.meta.url)));
let swapped = false;

/** apps/web inside the shell (P4.3): the same UI, with apps/web/src/platform.ts replaced by the shell's. */
export const swapPlatform: Plugin = {
  name: "shell-platform", enforce: "pre",
  resolveId: (id: string, importer?: string) => {
    if (id !== "./platform.js" || !importer || !fold(normalizePath(importer)).startsWith(webSrc)) return null;
    swapped = true;
    return shellPlatform;
  },
};
/** A build where the swap never happened would ship the browser's platform (key in IndexedDB, no apply): refuse it. */
const swapHappened: Plugin = {
  name: "shell-platform-check", apply: "build",
  buildEnd(err) { if (!err && !swapped) this.error("apps/web's platform.ts was not swapped for the shell's; the build would ship the browser version"); },
};

// No inline scripts or data: assets: tauri.conf.json's CSP is script-src 'self' (test/shell.test.ts pins it to the web's).
export default defineConfig(({ mode }) => ({
  base: "./",
  plugins: [react(), swapPlatform, swapHappened],
  define: webEnv(mode).define,
  build: { outDir: "dist", target: "es2022", minify: false, assetsInlineLimit: 0 },
}));
