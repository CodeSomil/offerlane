// v4 P3.8 guarantees (D4, Protocol 11, H5) checked on the source and the built manifest:
// the extension never fills, clicks or submits anything, loads no remote code, and asks for the approved permissions only.
import { readdirSync, readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { manifest } from "../vite.config.js";

const dir = new URL("../src/", import.meta.url);
// The panel setting its OWN page's theme is the one allowed write; it is never the job site's page.
const files = readdirSync(dir).filter((n) => /\.(ts|tsx)$/.test(n))
  .map((n) => [n, readFileSync(new URL(n, dir), "utf8").replace("document.documentElement.dataset.theme =", "")] as const);

describe("never fills or submits", () => {
  it.each(files)("%s", (_, src) => {
    for (const bad of [/\.click\s*\(/, /\.submit\s*\(/, /requestSubmit/, /dispatchEvent/, /\.(value|checked|selectedIndex|innerHTML|outerHTML|textContent)\s*=[^=]/,
      /dataset\.\w+\s*=[^=]/, /setAttribute\s*\(/, /\.focus\s*\(/, /insertAdjacent|appendChild|\.append\(|\.remove\(\)/, /execCommand/, /dangerouslySetInnerHTML/,
      /\beval\s*\(/, /new Function/, /https?:\/\/(?!127\.0\.0\.1|localhost)/, /\bfetch\s*\(/, /XMLHttpRequest|WebSocket/])
      expect(src).not.toMatch(bad);
  });
});

describe("manifest", () => {
  const m = manifest(["https://app.offerlane.example"], false);
  it("asks only for the approved permissions and no host access", () => {
    expect(m.permissions).toEqual(["activeTab", "scripting", "storage", "sidePanel"]);
    expect(m).not.toHaveProperty("host_permissions");
    expect(m).not.toHaveProperty("content_scripts");
    expect(m).not.toHaveProperty("optional_host_permissions");
    expect(m).not.toHaveProperty("key");  // a store upload must not pin the id
    expect(m.externally_connectable).toEqual({ matches: ["https://app.offerlane.example/*"] });
    expect((m.content_security_policy as { extension_pages: string }).extension_pages).toMatch(/script-src 'self';.*connect-src 'none'/);
  });
  it("names the store icons, and each file is a PNG of its size", () => {
    const icons = { 16: "icons/16.png", 32: "icons/32.png", 48: "icons/48.png", 128: "icons/128.png" };
    expect(m.icons).toEqual(icons);
    expect((m.action as { default_icon: unknown }).default_icon).toEqual(icons);
    for (const [size, path] of Object.entries(icons)) {
      const png = readFileSync(new URL(`../public/${path}`, import.meta.url));
      expect(png.subarray(1, 4).toString()).toBe("PNG");
      expect([png.readUInt32BE(16), png.readUInt32BE(20)]).toEqual([Number(size), Number(size)]);  // IHDR width, height
    }
  });
  it("dev and test builds pin the unpacked id", () => {
    expect(manifest([], true).key).toBeTruthy();
    expect(manifest(["http://localhost:5173"], false, true).key).toBeTruthy();
  });
  it("only the test build gets the fixture host", () => {
    expect(manifest(["http://127.0.0.1:4173"], true).host_permissions).toEqual(["http://127.0.0.1/*"]);
  });
});
