import { defineConfig, normalizePath, type Plugin } from "vite";
import react from "@vitejs/plugin-react";
import { fileURLToPath } from "node:url";
import { webEnv } from "../web/vite.config.js";

const webSrc = normalizePath(fileURLToPath(new URL("../web/src/", import.meta.url)));
const shellPlatform = normalizePath(fileURLToPath(new URL("./src/platform.ts", import.meta.url)));

/** apps/web inside the shell (P4.3): the same UI, with apps/web/src/platform.ts replaced by the shell's. */
export const swapPlatform: Plugin = {
  name: "shell-platform", enforce: "pre",
  resolveId: (id: string, importer?: string) => (id === "./platform.js" && importer?.startsWith(webSrc) ? shellPlatform : null),
};

// No inline scripts or data: assets: tauri.conf.json's CSP is script-src 'self' (test/shell.test.ts pins it to the web's).
export default defineConfig(({ mode }) => ({
  base: "./",
  plugins: [react(), swapPlatform],
  define: webEnv(mode).define,
  build: { outDir: "dist", target: "es2022", minify: false, assetsInlineLimit: 0 },
}));
