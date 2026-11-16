import { useEffect, useRef, useState } from "react";
import { AuthError, session, signIn, signOut, signedIn } from "./auth.js";
import { ExtensionError, bringSaved, sendAnswers } from "./extension.js";
import { SyncError, createKeyring, forgetSync, restoreKeyring, setupState, syncNow, type Setup } from "./sync.js";

type Status = { ok: boolean; text: string } | undefined;
const message = (e: unknown, fallback: string) => (e instanceof SyncError || e instanceof AuthError || e instanceof ExtensionError ? e.message : fallback);
const when = (iso: string) => new Date(iso).toLocaleString();
const kept = (r: { replaced: string[] }) => (r.replaced.length ? " This device's earlier profile and resume were replaced by the synced ones; a copy is kept in this browser." : "");

export function Settings() {
  const [user, setUser] = useState(() => session());
  const [setup, setSetup] = useState<{ setup: Setup; last?: string } | undefined>();
  const [status, setStatus] = useState<Status>();
  const [busy, setBusy] = useState(false);
  const [rk, setRK] = useState<string | undefined>();
  const [saved, setSaved] = useState(false);
  const [typed, setTyped] = useState("");
  const rkHeading = useRef<HTMLHeadingElement>(null), syncHeading = useRef<HTMLHeadingElement>(null), leftRK = useRef(false);

  // A sign-in that just came back from the provider (started in main.tsx before the first render).
  useEffect(() => {
    void signedIn().then((s) => { if (s) { setUser(s); setStatus({ ok: true, text: "Signed in." }); } },
      (e: unknown) => setStatus({ ok: false, text: message(e, "Sign-in didn't complete. Try again.") }));
  }, []);
  const refresh = async () => {
    try { setSetup(await setupState()); } catch (e) { setSetup(undefined); setStatus({ ok: false, text: message(e, "Couldn't read the sync setup.") }); }
  };
  useEffect(() => { if (user) void refresh(); }, [user]);
  // Focus follows the screen: onto the key when it appears, back to Sync when the user continues.
  useEffect(() => { if (rk) { rkHeading.current?.focus(); leftRK.current = true; } else if (leftRK.current) { leftRK.current = false; syncHeading.current?.focus(); } }, [rk]);

  const run = async (f: () => Promise<string | void>, fallback: string) => {
    setBusy(true); setStatus(undefined);
    try { const t = await f(); if (t) setStatus({ ok: true, text: t }); }
    catch (e) { setStatus({ ok: false, text: message(e, fallback) }); }
    finally { setBusy(false); }
  };
  const sync = () => run(async () => {
    const r = await syncNow();
    await refresh();
    return (r.pushed + r.pulled === 0 ? "Everything is up to date." : `Synced: ${r.pulled} updated here, ${r.pushed} sent.`) + kept(r);
  }, "Sync didn't finish. Try again.");

  if (rk) return (
    <section className="stack" aria-labelledby="rk-h">
      <h2 id="rk-h" ref={rkHeading} tabIndex={-1}>Your recovery key</h2>
      <p>Write this key down or print it, and keep it somewhere safe. You need it to turn on sync on another device.</p>
      <p className="card rk"><code>{rk}</code></p>
      <p className="bad"><strong>If you lose every signed-in device and this key, your synced data is gone.</strong> It's encrypted on your devices before it's sent, so Offerlane can't read it or get it back for you.</p>
      <div className="row">
        <button type="button" className="secondary" onClick={() => void navigator.clipboard.writeText(rk).then(() => setStatus({ ok: true, text: "Copied." }), () => setStatus({ ok: false, text: "This browser wouldn't copy it. Select the key and copy it yourself." }))}>Copy</button>
        <button type="button" className="secondary" onClick={() => window.print()}>Print</button>
      </div>
      <label className="radio"><input type="checkbox" checked={saved} onChange={(e) => setSaved(e.target.checked)} /> I've saved my recovery key somewhere safe</label>
      <button type="button" disabled={!saved || busy} onClick={() => { setRK(undefined); void sync(); }}>Continue and sync</button>
      <p role={status && !status.ok ? "alert" : "status"} className={status ? (status.ok ? "ok" : "bad") : undefined}>{status?.text}</p>
      <div className="print-only"><h1>Offerlane recovery key</h1><p><code>{rk}</code></p><p>If you lose every signed-in device and this key, your synced data is gone. Offerlane can't recover it.</p></div>
    </section>
  );

  return (
    <div className="stack">
      <section className="card stack" aria-labelledby="acct-h">
        <h2 id="acct-h">Account</h2>
        {user ? <>
          <p>Signed in{user.sub ? ` as ${user.sub}` : ""}.</p>
          <button type="button" className="secondary" onClick={() => { signOut(); setUser(undefined); setSetup(undefined); setStatus({ ok: true, text: "Signed out. Your data stays on this device." }); }}>Sign out</button>
        </> : <>
          <p className="muted">Signing in adds Offerlane's job index and lets you sync between devices. Without it, everything stays on this device.</p>
          <button type="button" disabled={busy} onClick={() => void run(async () => { await signIn(); }, "Couldn't start sign-in.")}>Sign in</button>
        </>}
      </section>
      {user && (
        <section className="card stack" aria-labelledby="sync-h">
          <h2 id="sync-h" ref={syncHeading} tabIndex={-1}>Sync</h2>
          <p className="muted">Your profile, resume and pipeline are encrypted on this device before they're sent. The server stores only data it can't read.</p>
          {!setup ? <p className="muted">Checking sync…</p>
          : setup.setup === "new-account" ? <button type="button" disabled={busy} onClick={() => void run(async () => { setRK(await createKeyring()); setSaved(false); }, "Couldn't turn on sync.")}>Turn on sync</button>
          : setup.setup === "needs-key" ? (
            <form className="stack" onSubmit={(e) => { e.preventDefault(); void run(async () => { await restoreKeyring(typed); setTyped(""); const r = await syncNow(); await refresh(); return `Sync is on. ${r.pulled} updated here, ${r.pushed} sent.${kept(r)}`; }, "Couldn't turn on sync."); }}>
              <p>This account already syncs from another device. Enter the recovery key you saved when you turned sync on.</p>
              <p className="muted">The synced profile and resume replace the ones on this device (a copy of these is kept in this browser); pipelines are merged.</p>
              <label>Recovery key <input type="text" autoComplete="off" spellCheck={false} value={typed} onChange={(e) => setTyped(e.target.value)} placeholder="ABCD-EFGH-…" required /></label>
              <button type="submit" disabled={busy}>Use recovery key</button>
            </form>)
          : setup.setup === "other-account" ? <>
              <p>This browser syncs with a different Offerlane account. Turn sync off here to use this one.</p>
              <button type="button" className="secondary" disabled={busy} onClick={() => void run(async () => { await forgetSync(); await refresh(); return "Sync is off on this device."; }, "Couldn't turn sync off.")}>Turn sync off on this device</button>
            </>
          : <>
              <p>{setup.last ? `Last synced ${when(setup.last)}.` : "Sync is on."}</p>
              <div className="row">
                <button type="button" disabled={busy} onClick={() => void sync()}>{busy ? "Syncing…" : "Sync now"}</button>
                <button type="button" className="secondary" disabled={busy} onClick={() => void run(async () => { await forgetSync(); await refresh(); return "Sync is off on this device. Your data here and on your other devices is kept."; }, "Couldn't turn sync off.")}>Turn sync off on this device</button>
              </div>
            </>}
        </section>
      )}
      <section className="card stack" aria-labelledby="ext-h">
        <h2 id="ext-h">Browser extension</h2>
        <p className="muted">The extension saves jobs from any job page and shows your answers beside application forms for you to copy. It never fills in or sends a form. It talks only to this page, on this device.</p>
        <div className="row">
          <button type="button" disabled={busy} onClick={() => void run(async () => { const n = await sendAnswers(); return `Sent your profile and the answers for ${n} role${n === 1 ? "" : "s"} in Review or Ready.`; }, "Couldn't reach the extension.")}>Send my answers</button>
          <button type="button" className="secondary" disabled={busy} onClick={() => void run(async () => { const n = await bringSaved(); return n === 0 ? "No new saved jobs." : `Added ${n} saved job${n === 1 ? "" : "s"} to Discover.`; }, "Couldn't reach the extension.")}>Bring in saved jobs</button>
        </div>
      </section>
      <p role={status && !status.ok ? "alert" : "status"} className={status ? (status.ok ? "ok" : "bad") : undefined}>{status?.text}</p>
    </div>
  );
}
