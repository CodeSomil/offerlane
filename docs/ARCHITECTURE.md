# Architecture

```
Offerlane/
  project.yml                XcodeGen spec → Offerlane.xcodeproj
  Packages/OfferlaneCore/    SwiftPM library: all logic, no UI, XCTest
  App/                       SwiftUI app (macOS 14+, universal)
    Resources/autofill.js    field engine injected into the Apply browser
    Resources/SelfTest/      mock career sites for the in-app apply tests
  UITests/                   XCUITest (light + dark screenshots)
  Branding/                  logo source (SVG) and exports
  scripts/                   build, test, package, fetch-tectonic
```

## OfferlaneCore
| Area | Types | Notes |
|---|---|---|
| Storage | `Store` (GRDB, WAL, migrations) | jobs, events, key-value documents, résumé versions, accounts, seen emails, usage |
| Workflow | `JobStatus`, `StateMachine` | `found → tailoring → review → ready → applying → [account / needsYou] → prefilled → applied → …`; every transition validated |
| AI | `LLMClient`, `AI`, `ClaudeCLIClient`, `AnthropicClient`, `OpenAICompatibleClient`, `FakeLLM` | JSON with one repair retry; every call metered |
| Discovery | `HTTP`, `ATS`, `Discovery`, `Ranking`, `FindJobs` | 6 ATS adapters, slug resolution with cache, 8 boards at a time, per-host rate limit, 429 back-off |
| Résumés | `Extract`, `LaTeX`, `ResumeParser` | PDF / DOCX / TXT / TeX; LaTeX bullets taken verbatim from `\item` lines |
| Tailoring | `Tailor`, `TailorQueue`, `PlanApplier`, `Guard`, `Builder`, `ResumePDF`, `LaTeXRender` | the no-fabrication guard, page fit, ATS check |
| Apply | `AnswerRules` | which answer goes in which field; work authorization per job location |
| Visa | `Visa` | authorized countries, JD sponsorship wording, UK/NL sponsor registers |
| Email | `IMAPClient`, `Tracking`, `Mime` | rules first, one batched AI call for ambiguous mail |
| Security | `Keychain`, `Vault` | per-company account approval; passwords only in Keychain |

## App
- `AppModel`: app state, Find Jobs, tailoring queue, inbox.
- `OnboardingModel` + step views: the 7-step setup wizard (Back/Next everywhere; nothing lost).
- `ApplyController`, `ApplyEngine`, `WebPage`: one application at a time in a `WKWebView` with a persistent cookie store. The engine ports a Workday handler (account gate, multi-page flow, listbox dropdowns) and a generic multi-step handler, and stops on the Submit page.
- Screens: To Do, Matches, Review (diff + PDF), Résumés, Applications (board + table), Activity, Settings.

## Design choices
- **WKWebView, not Playwright.** Résumé upload works by assigning a `File` through `DataTransfer`. Verified on Greenhouse, Lever, Ashby and Workday pages, so no Node or Chrome needs to ship.
- **Core Text for the standard template.** It's deterministic and in-process, and the PDFs have selectable text. LaTeX résumés use bundled tectonic with a pre-warmed package cache.
- **Self-tests inside the app** for anything that needs WebKit (`OFFERLANE_SELFTEST=apply|real|package`).
