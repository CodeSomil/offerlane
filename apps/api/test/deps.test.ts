import { readdirSync, readFileSync } from "node:fs";
import { builtinModules } from "node:module";
import { expect, test } from "vitest";

// The production image installs `dependencies` only (Dockerfile), so a src import of a devDependency crashes at start.
test("src imports only runtime dependencies", () => {
  const pkg = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8")) as { dependencies: Record<string, string> };
  const dir = new URL("../src/", import.meta.url);
  const files = readdirSync(dir, { recursive: true, encoding: "utf8" }).filter((f) => f.endsWith(".ts"));
  const missing = files.flatMap((f) =>
    // Static `import x from`, `export … from` (not type-only) and dynamic `import("…")`.
    [...readFileSync(new URL(f, dir), "utf8").matchAll(/^\s*(?:import|export)\s+(?!type\b)(?:[^"';]*?\sfrom\s+)?["']([^"'.][^"']*)["']|\bimport\(\s*["']([^"'.][^"']*)["']/gm)]
      .map((m) => m[1] ?? m[2]!).map((s) => s.startsWith("@") ? s.split("/").slice(0, 2).join("/") : s.split("/")[0]!)
      .filter((name) => !name.startsWith("node:") && !builtinModules.includes(name) && !(name in pkg.dependencies))
      .map((name) => `${f}: ${name}`));
  expect(missing).toEqual([]);
});
