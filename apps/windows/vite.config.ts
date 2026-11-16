import { defineConfig } from "vite";

// The shell's own page only (P4.2). No inline scripts: tauri.conf.json's CSP is script-src 'self'.
export default defineConfig({ base: "./", build: { outDir: "dist", target: "es2022", minify: false } });
