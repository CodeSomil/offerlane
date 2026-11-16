import { expect, test, type Browser, type Page } from "@playwright/test";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { join } from "node:path";
import { applySelfTest, cdpPage, MemoryVault, type CDPOn, type CDPSend } from "@offerlane/core";

// v4 P4.1: the Mac's 14 apply self-tests (SelfTest.swift) on the same mock sites, driven over CDP in Chromium. The Windows
// spike runs this exact list over WebView2; this run proves the TypeScript engine and the CDP page before Windows is involved.
const res = join(import.meta.dirname, "../../../App/Resources");

test("apply self-test: 14 checks on the mock sites, nothing submitted", async ({ browser }) => {
  test.setTimeout(180_000);
  const script = await readFile(join(res, "autofill.js"), "utf8");
  const pages = new Set(["workday.html", "simple.html", "honeypot.html"]);
  const server = createServer(async (req, rsp) => {
    const name = (req.url ?? "").replace(/^\/|\?.*$/g, "");
    if (!pages.has(name)) { rsp.writeHead(404).end(); return; }
    rsp.writeHead(200, { "content-type": "text/html; charset=utf-8" }).end(await readFile(join(res, "SelfTest", name)));
  });
  await new Promise<void>((ok) => server.listen(0, "127.0.0.1", ok));
  const { port } = server.address() as { port: number };
  // One context per page, like WebPage(persistent: false): nothing carries over except the vault.
  const contexts: Awaited<ReturnType<Browser["newContext"]>>[] = [];
  const pageErrors: string[] = [];
  const opened: Page[] = [];
  const lines: string[] = [];
  try {
    const results = await applySelfTest({
      base: `http://127.0.0.1:${port}`, vault: new MemoryVault(), log: (l) => lines.push(l),
      newPage: async () => {
        const ctx = await browser.newContext({ viewport: { width: 1200, height: 900 } }); contexts.push(ctx);
        const pg = await ctx.newPage(); opened.push(pg);
        pg.on("pageerror", (e) => pageErrors.push(e.message));
        const s = await ctx.newCDPSession(pg);
        return cdpPage(s.send.bind(s) as unknown as CDPSend, script, s.on.bind(s) as unknown as CDPOn);
      },
    });
    console.log(lines.join("\n"));
    expect(results.length).toBe(14);
    for (const r of results) expect.soft(r.ok, r.what).toBe(true);
    expect(pageErrors).toEqual([]);
    // The engine lives in its own world: the career site's scripts never see window.__ja.
    for (const pg of opened) expect(await pg.evaluate(() => typeof (window as unknown as { __ja?: unknown }).__ja)).toBe("undefined");
  } finally {
    for (const c of contexts) await c.close();
    server.close();
  }
});
