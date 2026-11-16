// ApplyPage over the Chrome DevTools Protocol (v4 P4.1). WebView2 speaks the same protocol (CallDevToolsProtocolMethod), so this
// one file drives Chromium in the tests (Playwright CDPSession.send) and WebView2 on Windows (the Tauri shell's send).
import type { ApplyPage } from "./apply.js";

export type CDPSend = (method: string, params?: Record<string, unknown>) => Promise<unknown>;
/** Subscribes to a DevTools event (Playwright CDPSession.on, WebView2 DevToolsProtocolEventReceived). */
export type CDPOn = (event: string, handler: (params: { frameId?: string }) => void) => void;

type Evaluated = { result?: { value?: unknown }; exceptionDetails?: { text?: string } };
type FrameTree = { frameTree: { frame: { id: string; url: string } } };
const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));
const MISSING = "\u0000missing";

/**
 * `script` is autofill.js. It runs in its own isolated world (as WKContentWorld on the Mac): it shares the page's DOM but
 * not its globals, so a career site can't replace window.__ja to read what Offerlane types or fake what Offerlane sees.
 * The page's own scripts never see the code; the world is created per document and the script loaded on first use.
 * `on` lets waitForLoad see a navigation that has started but not committed (WKWebView.isLoading on the Mac).
 * The host owns the navigation policy, as WebPage.swift does: only http(s)/about/blob/data, new windows load in place.
 * The Windows shell (P4.2) must enforce both, and its `send` must never log params: they carry passwords being typed.
 */
export function cdpPage(send: CDPSend, script: string, on: CDPOn, world = "offerlane-autofill"): ApplyPage {
  let loading = false, mainFrame: string | undefined, enabled: Promise<unknown> | undefined;
  const track = (busy: boolean) => (e: { frameId?: string }) => { if (mainFrame === undefined || e.frameId === mainFrame) loading = busy; };
  on("Page.frameStartedLoading", track(true));
  on("Page.frameStoppedLoading", track(false));
  const frame = async () => {
    enabled ??= send("Page.enable");
    await enabled;
    const f = ((await send("Page.getFrameTree")) as FrameTree).frameTree.frame;
    mainFrame = f.id;
    return f;
  };
  const evaluate = async (expression: string, contextId?: number) => {
    const r = (await send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true, ...(contextId === undefined ? {} : { contextId }) })) as Evaluated;
    if (r.exceptionDetails) throw new Error(r.exceptionDetails.text ?? "script error");
    return r.result?.value;
  };
  // Chromium keeps one isolated world per (frame, name), so this returns the same context until the document changes.
  const context = async () => ((await send("Page.createIsolatedWorld", { frameId: (await frame()).id, worldName: world })) as { executionContextId: number }).executionContextId;

  const page: ApplyPage = {
    url: async () => { try { return (await frame()).url; } catch { return ""; } },
    host: async () => { try { return new URL(await page.url()).host; } catch { return ""; } },
    async load(url) { await frame(); loading = true; await send("Page.navigate", { url }); await page.waitForLoad(); },
    async waitForLoad(timeoutMs = 20000) {
      const end = Date.now() + timeoutMs;
      await sleep(150);
      while (Date.now() < end) {
        // Read in the isolated world: the page can't redefine document.readyState there.
        try { if (!loading && (await evaluate("document.readyState", await context())) === "complete") break; } catch { /* mid-navigation */ }
        await sleep(200);
      }
    },
    async call(fn, args = []) {
      // Arguments go in as JSON literals, never as code: page text that ends up in a value can't break out of the string.
      const body = `(async () => { if (!window.__ja) return ${JSON.stringify(MISSING)}; const r = await window.__ja[${JSON.stringify(fn)}](...${JSON.stringify(args)}); return JSON.stringify(r === undefined ? null : r); })()`;
      try {
        const id = await context();
        let s = await evaluate(body, id);
        if (s === MISSING) { await evaluate(script, id); s = await evaluate(body, id); }
        return typeof s === "string" ? (JSON.parse(s) as unknown) : null;
      } catch { return null; }
    },
    async eval(js) { try { return await evaluate(js); } catch { return null; } },
  };
  return page;
}
