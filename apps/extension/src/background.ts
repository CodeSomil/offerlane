// The extension's service worker. Toolbar click → open the side panel and read the tab once (activeTab). The web app
// (externally_connectable, and the exact origins checked again here) hands over the answer set and takes saved jobs.
// Nothing here fills, clicks or submits anything on a page.
import { job as decodeJob, toExtension, type Job } from "@offerlane/core";
import { readPage } from "./page.js";
import { getLocal, setLocal } from "./store.js";

declare const __WEB_ORIGINS__: string[];

chrome.sidePanel.setPanelBehavior({ openPanelOnActionClick: false }).catch(() => {});

// Every write to "saved" (the panel's save, the web's clear) runs here, one after another, so neither overwrites the other.
let queue: Promise<unknown> = Promise.resolve();
const serial = <T>(f: () => Promise<T>): Promise<T> => { const r = queue.then(f, f); queue = r.catch(() => {}); return r; };
const saveJob = (j: Job) => serial(async () => {
  const all = await getLocal<Job[]>("saved", []);
  if (all.some((x) => x.id === j.id)) return false;
  await setLocal("saved", [...all, j]);
  return true;
});

async function readTab(tabId: number): Promise<void> {
  try {
    const [r] = await chrome.scripting.executeScript({ target: { tabId }, func: readPage });
    await chrome.storage.session.set({ page: r?.result ?? null, pageError: r?.result ? null : "unreadable", tabId });
  } catch {
    await chrome.storage.session.set({ page: null, pageError: "unreadable", tabId });
  }
}
// The read tab navigated: its old page (and answers) no longer apply, so the panel stops showing them.
chrome.tabs.onUpdated.addListener((id, info) => {
  if (info.status !== "loading") return;
  void chrome.storage.session.get("tabId").then((s) => { if (s.tabId === id) void chrome.storage.session.set({ page: null, pageError: null }); });
});
// The e2e test drives this directly (it can't click the toolbar button).
(globalThis as { readTab?: typeof readTab }).readTab = readTab;

chrome.action.onClicked.addListener((tab) => {
  if (tab.id === undefined) return;
  void chrome.sidePanel.open({ windowId: tab.windowId });  // must run inside the click's user gesture
  void readTab(tab.id);
});

// The panel: "Read this page again" re-reads the tab it read (the click's activeTab grant lasts until that tab navigates),
// and "Save this job" goes through the write queue.
chrome.runtime.onMessage.addListener((msg: unknown, sender, reply) => {
  // Our own pages only (the panel). Web pages can't reach onMessage at all, and this extension has no content scripts.
  if (sender.id !== chrome.runtime.id || !(sender.url ?? "").startsWith(chrome.runtime.getURL(""))) return false;
  const m = (msg ?? {}) as { type?: string; job?: unknown };
  if (m.type === "read") {
    void chrome.storage.session.get("tabId").then(async (s) => { if (typeof s.tabId === "number") await readTab(s.tabId); reply({ ok: true }); });
    return true;
  }
  if (m.type === "save" && m.job !== null && typeof m.job === "object") {
    const j = decodeJob(m.job);
    if (j.id === "") return false;
    void saveJob(j).then((added) => reply({ ok: true, added }), () => reply({ ok: false }));
    return true;
  }
  return false;
});

chrome.runtime.onMessageExternal.addListener((msg: unknown, sender, reply) => {
  // The manifest's match patterns can't name a port, so this exact origin check (scheme, host AND port) is the real gate.
  if (!__WEB_ORIGINS__.includes(sender.origin ?? "")) return false;
  const m = toExtension(msg);
  if (!m) { reply({ ok: false }); return false; }
  void (async () => {
    switch (m.type) {
      case "ping": return reply({ ok: true, version: chrome.runtime.getManifest().version });
      case "answers": await setLocal("answers", { profile: m.profile, jobs: m.jobs, at: new Date().toISOString() }); return reply({ ok: true });
      case "saved": return reply({ ok: true, jobs: await getLocal<Job[]>("saved", []) });
      case "clear": {
        const ids = new Set(m.ids);
        await serial(async () => setLocal("saved", (await getLocal<Job[]>("saved", [])).filter((j) => !ids.has(j.id))));
        return reply({ ok: true });
      }
    }
  })().catch(() => reply({ ok: false }));
  return true;
});
