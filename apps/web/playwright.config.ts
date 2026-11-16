import { defineConfig, devices } from "@playwright/test";

// Runs against the built app (vite preview), so the CSP meta tag and headers are the production ones.
export default defineConfig({
  testDir: "e2e", testMatch: "*.e2e.ts", timeout: 30_000, retries: 0, reporter: "line",
  use: { baseURL: "http://127.0.0.1:4173", ...devices["Desktop Chrome"] },
  webServer: { command: "npx -y pnpm@11.28.9 -s build && npx -y pnpm@11.28.9 -s preview --host 127.0.0.1 --port 4173 --strictPort", url: "http://127.0.0.1:4173", timeout: 120_000, reuseExistingServer: false },
});
