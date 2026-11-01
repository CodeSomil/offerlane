# Testing

| Suite | Command | What it covers |
|---|---|---|
| Core | `scripts/test.sh core` | state machine (all transitions), store, Keychain, AI JSON handling, résumé parsing (PDF, DOCX, LaTeX), visa rules, careers-URL detection, all 6 ATS adapters (recorded responses), ranking, Find Jobs end to end with stubbed sites (offline, cancellation, decline never returns), guard, tailoring, rendering and page fit, email tracking, IMAP (scripted server), export / delete-all |
| UI | `scripts/test.sh ui` | onboarding forward/back with data kept, upload success and error, approve/decline/undo, review edit + rebuild + approve, applications board, settings round trip across relaunch, screenshots in light and dark |
| Apply | `scripts/test.sh apply` | 14 checks on mock Workday and simple sites: account gate, Keychain password, six pages, stops before Submit, never submits, confirmation detection, sign-in on the next visit, upload, consent left unticked, honeypots skipped |
| Real sites | `scripts/test.sh real` | fills live Greenhouse, Lever and Ashby forms and reaches Workday's account step; **never submits, never creates an account** |
| Live AI | `OFFERLANE_LIVE=1 swift test --filter Live` (in `Packages/OfferlaneCore`) | a real Claude CLI call and a live Find Jobs run |

Tests that need a real data folder from the previous (Python) version are opt-in: set `OFFERLANE_LEGACY_DIR`. Fixtures derived from personal data belong in `Tests/OfferlaneCoreTests/Fixtures/private/`, which is git-ignored.

The test fixtures under `Fixtures/ats/` are trimmed, publicly available job-board API responses, kept only to test parsing.
