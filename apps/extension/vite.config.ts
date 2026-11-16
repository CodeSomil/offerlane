import { defineConfig, loadEnv, type Plugin } from "vite";
import react from "@vitejs/plugin-react";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const here = (p: string) => fileURLToPath(new URL(p, import.meta.url));

/** The production manifest (H5): activeTab, scripting, storage and sidePanel only; no host permissions, no remote code. */
export function manifest(webOrigins: string[], test: boolean, dev = false): Record<string, unknown> {
  // Copied from public/ by Vite; made from the Mac AppIcon set.
  const icons = { 16: "icons/16.png", 32: "icons/32.png", 48: "icons/48.png", 128: "icons/128.png" };
  const pkg = JSON.parse(readFileSync(here("package.json"), "utf8")) as { version: string };
  return {
    manifest_version: 3, name: "Offerlane", version: pkg.version, icons,
    description: "Save jobs to Offerlane and see copy-ready answers beside application forms. It never fills or submits a form.",
    // Pins the unpacked id (dev and e2e builds only) to the one the web build expects; its private key was never kept.
    // A store upload must not carry `key`: the store assigns its own id (the web build then needs VITE_EXTENSION_ID).
    ...(test || dev ? { key: readFileSync(here("dev-key.pub.b64"), "utf8").trim() } : {}),
    permissions: ["activeTab", "scripting", "storage", "sidePanel"],
    // SHORTCUT: test builds only (dist-test/): Playwright can't click the toolbar button that grants activeTab, so the e2e fixture
    // host is granted instead. test/source.test.ts checks the production manifest has no host_permissions.
    ...(test ? { host_permissions: ["http://127.0.0.1/*"] } : {}),
    background: { service_worker: "background.js", type: "module" },
    action: { default_title: "Offerlane: read this page", default_icon: icons },
    side_panel: { default_path: "panel.html" },
    externally_connectable: { matches: webOrigins.map((o) => `${new URL(o).protocol}//${new URL(o).hostname}/*`) },
    content_security_policy: { extension_pages: "default-src 'self'; script-src 'self'; object-src 'none'; base-uri 'none'; connect-src 'none'; form-action 'none'" },
  };
}

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, here("."), "OFFERLANE_");
  // The web origins: a production build must name them (OFFERLANE_WEB_ORIGINS); only the test and development builds
  // fall back to the local web app (dev server and the e2e preview), so a store build can't ship localhost by accident.
  const test = (process.env.OFFERLANE_EXT_TEST ?? "") === "1", set = env.OFFERLANE_WEB_ORIGINS ?? process.env.OFFERLANE_WEB_ORIGINS;
  // Mode "test" is vitest loading this config (it builds nothing).
  if (!set && !test && mode !== "development" && mode !== "test") throw new Error("Set OFFERLANE_WEB_ORIGINS (the web app's origin, e.g. https://app.example) for a store build, or use build:dev.");
  const webOrigins = (set ?? "http://localhost:5173,http://127.0.0.1:4173").split(",").map((x) => new URL(x.trim()).origin);
  const emit: Plugin = { name: "manifest", generateBundle() {
    this.emitFile({ type: "asset", fileName: "manifest.json", source: JSON.stringify(manifest(webOrigins, test, mode === "development"), null, 2) });
  } };
  return {
    plugins: [react(), emit],
    define: { __WEB_ORIGINS__: JSON.stringify(webOrigins) },
    base: "./",
    server: { fs: { allow: [".", "../../libs/core", "../web/src", "../../Packages/design-tokens", "../../Packages/OfferlaneCore/Sources/OfferlaneCore/Resources"] } },
    build: {
      assetsInlineLimit: 0, modulePreload: false, minify: false,  // readable for store review; readPage must stay self-contained
      rollupOptions: { input: { panel: here("panel.html"), background: here("src/background.ts") }, output: { entryFileNames: "[name].js" } },
    },
  };
});
