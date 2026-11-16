import { defineConfig } from "@playwright/test";

// Loads the unpacked TEST build (dist-test: the production manifest plus host access to the 127.0.0.1 fixture host) into
// Chromium, next to the built web app (vite preview, the same server the web e2e uses).
export default defineConfig({
  testDir: "e2e", testMatch: "*.e2e.ts", timeout: 60_000, retries: 0, reporter: "line", workers: 1,
  webServer: {
    command: "npx -y pnpm@11.28.9 -s build:test && cd ../web && npx -y pnpm@11.28.9 -s build && npx -y pnpm@11.28.9 -s preview --host 127.0.0.1 --port 4173 --strictPort",
    url: "http://127.0.0.1:4173", timeout: 180_000, reuseExistingServer: false,
  },
});
