import { defineConfig, loadEnv, type Plugin } from "vite";
import react from "@vitejs/plugin-react";
import { fileURLToPath } from "node:url";

export default defineConfig(({ mode }) => {
  // SHORTCUT: the API origin defaults to the local dev API; hosting (P2 H3) must set VITE_API_ORIGIN (env or .env.production) before a real deploy.
  const env = loadEnv(mode, fileURLToPath(new URL(".", import.meta.url)), "VITE_");
  const api = env.VITE_API_ORIGIN ?? "http://localhost:8787";
  // SHORTCUT: sign-in defaults to the local dev issuer (compose.dev.yml); the real provider (P2 H2) sets these two.
  const oidc = env.VITE_OIDC_ISSUER ?? "http://localhost:9000/", clientId = env.VITE_OIDC_CLIENT_ID ?? "offerlane-api";
  // Strict CSP (H3): no inline script or style, and the page can only talk to the API and the two curated AI hosts.
  // The AI hosts are libs/core ai.ts OPENROUTER_BASE / ANTHROPIC_BASE (Node cannot load that .ts here); e2e/shell.e2e.ts pins them.
  const csp = [
    "default-src 'self'", "script-src 'self'", "style-src 'self'", "img-src 'self' data:", "font-src 'self'",
    `connect-src 'self' ${api} ${new URL(oidc).origin} https://openrouter.ai https://api.anthropic.com`,
    "object-src 'none'", "base-uri 'none'", "form-action 'none'",
  ].join("; ");
  const headers = { "Content-Security-Policy": `${csp}; frame-ancestors 'none'`, "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer" };
  // The meta tag goes in the built page only: Vite's dev server injects an inline React-refresh script that the CSP would block.
  const cspMeta: Plugin = { name: "csp-meta", apply: "build",
    transformIndexHtml: () => [{ tag: "meta", attrs: { "http-equiv": "Content-Security-Policy", content: csp }, injectTo: "head-prepend" }] };
  // The same headers ship as dist/_headers (Netlify / Cloudflare Pages format) so a static host serves them; a meta tag can't carry frame-ancestors.
  const hostHeaders: Plugin = { name: "host-headers", apply: "build",
    generateBundle() { this.emitFile({ type: "asset", fileName: "_headers", source: `/*\n${Object.entries(headers).map(([k, v]) => `  ${k}: ${v}`).join("\n")}\n` }); } };

  // The extension's id (P3.8): the store assigns it; the default is the pinned unpacked dev id (apps/extension/dev-key.pub.b64).
  const extensionId = env.VITE_EXTENSION_ID ?? "ifhcpkmhnnlojhhddfdklkcffjjihfed";
  return {
    plugins: [react(), cspMeta, hostHeaders],
    define: { __API_ORIGIN__: JSON.stringify(api), __OIDC_ISSUER__: JSON.stringify(oidc), __OIDC_CLIENT_ID__: JSON.stringify(clientId), __EXTENSION_ID__: JSON.stringify(extensionId) },
    // Only what the app imports from outside its folder (tokens.css, the shared registries), not the whole repo.
    server: { fs: { allow: [".", "../../libs/core", "../../libs/contract", "../../Packages/design-tokens", "../../Packages/OfferlaneCore/Sources/OfferlaneCore/Resources"] } },
    preview: { headers },
    build: { assetsInlineLimit: 0 },  // inlined data: scripts would need a CSP exception
  };
});
