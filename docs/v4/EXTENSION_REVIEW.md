# Extension store review checklist (Chrome Web Store, MV3)

Written in v4 P3.9 against `apps/extension/vite.config.ts` `manifest()` (production build: `OFFERLANE_WEB_ORIGINS=https://<web app> pnpm build`).
Each item names the test or file that proves it. ✅ met · ⛔ HUMAN BLOCKER.

## 1. Single purpose
✅ The single purpose: help the person apply to jobs. It saves the job on the current page to Offerlane and shows that person's own answers beside the application form, ready to copy. The manifest `description` says this and says it never fills or submits a form.

## 2. Minimal permissions (justification text for the store form)
| Permission | Why | Proof |
|---|---|---|
| `activeTab` | Reads the tab the person clicked the toolbar button on, only then, and no other tab. | `test/source.test.ts` "no host access" |
| `scripting` | Runs the read-only page reader (`src/page.ts` `readPage`) in that tab once per click. | `src/background.ts` `readTab` |
| `storage` | Keeps saved jobs and the answers sent from the web app (`local`) and the last-read page (`session`). | `src/store.ts` |
| `sidePanel` | Shows the saved job and copy-ready answers beside the form. (The human approved this as the 4th permission, P3.8.) | manifest `side_panel` |
| `externally_connectable` | Only the Offerlane web app's origin can send answers and fetch saved jobs. Each message is checked against the exact `sender.origin` and validated (`libs/core` `toExtension`). | `e2e/extension.e2e.ts` "another origin can't talk to the extension" |

✅ `chrome.tabs.onUpdated` (`src/background.ts`) reads only `info.status` to drop the last-read page when its tab navigates. That needs no `tabs` permission.
✅ No `host_permissions`, `optional_host_permissions`, `content_scripts`, `tabs`, `cookies`, `webRequest` or `<all_urls>`. The test-only `127.0.0.1` grant exists only in `dist-test/` (`test/source.test.ts`).

## 3. No remote code
✅ Everything is bundled, minify is off (so reviewers can read it), and there are no remote script URLs, `eval` or `new Function` (source scan in `test/source.test.ts`).
✅ The built bundle is checked as well: `scripts/test.sh web` fails if `dist-test/` contains `eval(`, `new Function` or `importScripts`.
ℹ️ For reviewers: the bundle includes shared `@offerlane/core` code that names AI provider URLs and calls `fetch`. The extension never calls it, and `connect-src 'none'` blocks it anyway. Say this in the review notes.
✅ The extension pages' CSP is `script-src 'self'; connect-src 'none'`, so the extension cannot fetch anything at all.

## 4. User data: handling and disclosure
✅ **Data it reads:** the clicked tab's full address, title, main heading, JSON-LD blocks (to find a JobPosting), and form-field labels, names, placeholders and option lists, including same-origin frames (`src/page.ts`). It never reads field values.
✅ **Where it goes:** stored on the device only. No server, analytics or third party gets it.
✅ **Never fills or submits anything:** the fixture form in the e2e test records every event and change and must see none, and a source scan bans click/submit/value writes (D4, Protocol 11).
✅ **Dashboard answers (data use):** declare "personally identifiable information" (contact details, work history), "health information" (the optional EEO disability answer), "financial information" (current and expected salary) and "website content". The EEO answers (gender, race, veteran, disability, sexual orientation) come from the profile the web app sends (`apps/web/src/extension.ts` `sendAnswers`). They are kept unencrypted in `chrome.storage.local` so they can be shown beside EEO questions. It does not sell the data or use it for unrelated purposes, advertising or creditworthiness.
✅ **Privacy policy text:** `docs/PRIVACY.md` → "Browser extension". ⛔ It needs legal review and a public URL (hosting, P2 H3) before it can be entered in the store form.

## 5. Listing assets
✅ Icons 16/32/48/128 (`public/icons/`, made from the Mac AppIcon set; `test/source.test.ts` checks the sizes).
⛔ Store screenshots (1280×800), a small promo tile (440×280) and the store description text need human choice and approval.
⛔ A developer account (one-time fee), the production web origin for `OFFERLANE_WEB_ORIGINS`, and submission itself are human tasks.

## 6. Known limits a reviewer may ask about
- ✅ Upload a zip of `dist/` from `pnpm build` with OFFERLANE_WEB_ORIGINS set. `build:dev` writes to `dist-dev/`, and any build other than dev or test refuses to run without origins.
- ⛔ The web app's production build falls back to the dev extension id when `VITE_EXTENSION_ID` is unset (as with its VITE_OIDC_* and VITE_API_ORIGIN defaults). Hosting must set it to the store id (P2 H3).
- ✅ The store build has no `key` (only dev and test builds pin the unpacked id; `test/source.test.ts`). Hosting must set the web's `VITE_EXTENSION_ID` to the id the store assigns.
- Match patterns in `externally_connectable` can't name a port. The exact `sender.origin` check is the real gate.
- Chrome only. Firefox and Safari builds are not in P3.
