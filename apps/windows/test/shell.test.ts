// The shell hosts apps/web (P4.3b). These pin the two places that must agree with the web build: the CSP's connect-src
// and the sign-in origin the main window may navigate to, and check the build swaps in the shell's platform module.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { normalizePath } from "vite";
import { describe, expect, it } from "vitest";
import { webEnv } from "../../web/vite.config.js";
import { swapPlatform } from "../vite.config.js";

const conf = JSON.parse(readFileSync(new URL("../src-tauri/tauri.conf.json", import.meta.url), "utf8"));
const csp: string = conf.app.security.csp;
const directive = (name: string) => csp.split(";").map((d) => d.trim().split(/\s+/)).find((d) => d[0] === name)?.slice(1);

describe("shell CSP", () => {
  it("lets the page reach IPC plus exactly what the web build allows", () => {
    expect(directive("connect-src")).toEqual(["ipc:", "http://ipc.localhost", ...webEnv("production").connect]);
  });
  it("keeps the web's strict rules", () => {
    for (const d of ["default-src", "script-src", "style-src", "font-src"]) expect(directive(d)).toEqual(["'self'"]);
    expect(directive("object-src")).toEqual(["'none'"]);
    expect(directive("base-uri")).toEqual(["'none'"]);
    expect(directive("form-action")).toEqual(["'none'"]);
  });
  it("builds the main window in code (with its navigation guard), not from the config", () => {
    expect(conf.app.windows).toEqual([]);
  });
});

describe("main window sign-in origin", () => {
  it("matches the web's issuer", () => {
    const nav = readFileSync(new URL("../src-tauri/src/nav.rs", import.meta.url), "utf8");
    const list = /pub const SIGN_IN: &\[&str\] = &\[([^\]]*)\]/.exec(nav)?.[1]?.match(/"[^"]+"/g)?.map((s) => JSON.parse(s));
    expect(list).toEqual([new URL(webEnv("production").oidc).origin]);
  });
});

describe("platform swap", () => {
  const web = normalizePath(fileURLToPath(new URL("../../web/src/store.ts", import.meta.url)));
  const resolve = swapPlatform.resolveId as (id: string, importer?: string) => string | null;
  it("gives apps/web the shell's platform module", () => {
    expect(resolve("./platform.js", web)).toBe(normalizePath(fileURLToPath(new URL("../src/platform.ts", import.meta.url))));
  });
  it("leaves every other import alone", () => {
    expect(resolve("./store.js", web)).toBeNull();
    expect(resolve("./platform.js", normalizePath(fileURLToPath(new URL("../src/main.ts", import.meta.url))))).toBeNull();
    expect(resolve("./platform.js")).toBeNull();
  });
});
