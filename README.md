<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Branding/offerlane-wordmark-dark.svg">
    <img alt="Offerlane" src="Branding/offerlane-wordmark-light.svg" width="420">
  </picture>
</p>

<p align="center">
  <b>Your lane from résumé to offer.</b><br>
  A Mac app that finds roles on company career sites, tailors your résumé for each one, fills in the application,
  and stops so <b>you</b> click Submit. You approve every step.
</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111827?logo=apple">
  <img alt="Version 0.2.0" src="https://img.shields.io/badge/version-0.2.0-4F46E5">
  <img alt="Apple silicon and Intel" src="https://img.shields.io/badge/Apple%20silicon%20%2B%20Intel-universal-34D399">
</p>

<p align="center"><img alt="The Find screen" src="docs/screenshots/find-light.png" width="860"></p>

## How it works

```mermaid
flowchart LR
    A["🔎 Find Jobs<br/>checks your companies'<br/>career sites"] --> B["Free local pre-score<br/>title, skills, location,<br/>seniority filters"]
    B --> C["🤖 AI scores the best 25<br/>in one batched call<br/>(answers cached)"]
    C --> D{"👤 You approve<br/>or decline"}
    D -- declined --> X["Never shown again"]
    D -- approved --> E["🤖 AI tailors your résumé<br/>reorders + rephrases your<br/>own bullets, drafts answers"]
    E --> F{"👤 You review<br/>every change<br/>(invented numbers blocked)"}
    F -- redo / edit --> E
    F -- approve --> G["🖥️ Offerlane fills the form<br/>in its own browser,<br/>at a human pace"]
    G --> H["⏸ Stops at Submit"]
    H --> I["👤 You click Submit"]
    I --> J["📬 Replies in your inbox<br/>move the application:<br/>interview → offer"]
```

Nothing is tailored, applied for or created without your say-so. Offerlane never presses Submit, never solves CAPTCHAs and never logs in to LinkedIn.

## Get started in four steps

| 1. Sign in | 2. Connect an AI | 3. Add your résumé | 4. Find jobs |
|---|---|---|---|
| <img src="docs/screenshots/welcome-light.png" width="200" alt="Welcome screen"> | <img src="docs/screenshots/1-ai-light.png" width="200" alt="Choose your AI"> | <img src="docs/screenshots/2-resumes-light.png" width="200" alt="Add resumes"> | <img src="docs/screenshots/3-ready-light.png" width="200" alt="Ready to find jobs"> |
| Email and password; Touch ID optional (Continue with Google is coming) | Claude account, Claude API key, or free local Ollama | PDF, Word, text or LaTeX; several versions welcome | Titles and companies are drafted from your résumé; change anything later |

## What's new in 0.2.0
- **A fresh design**: calmer layout, full dark mode, faster screens, and a short tour on first launch.
- **Profiles that stay signed in**:
  - email and password, with optional Touch ID (Continue with Google is built in and will be switched on in a later release);
  - several people can share one Mac;
  - your 0.1 data is brought across, with a backup made first.
- **Setup Center**:
  - installs Claude Code or Ollama for you, checking each download's checksum and publisher signature before it runs;
  - a health dot shows what needs attention, and **Repair Everything** fixes it in one click.
- **Help in the app** (⌘?): searchable answers, plus **Send Diagnostics**, a report with personal details removed that you see in full before sharing.
- **Lower AI costs**: answers are cached locally, a per-run limit stops spending, and a live meter shows usage.
- **Accessibility**: VoiceOver labels, full keyboard use, 4.5:1 contrast everywhere, and Reduce Motion respected.
- **Security review**:
  - saved career-site passwords are only typed into their own site;
  - email verification links are checked before opening;
  - shipped builds are hardened, with no special permissions.
- **Gmail (preview)**: read-only, for invited testers. IMAP stays the default.

## A closer look

| | |
|---|---|
| <img src="docs/screenshots/review-light.png" alt="Reviewing a tailored résumé" width="420"><br>**Review every change.** Your original in red, the tailored text in green, with a live PDF preview. | <img src="docs/screenshots/applications-light.png" alt="Applications board" width="420"><br>**Track every application.** Email replies move cards along by themselves. |
| <img src="docs/screenshots/setup-center-dark.png" alt="Setup Center" width="420"><br>**Setup Center.** Checks your AI, internet, storage and Mac, and fixes problems with one click. | <img src="docs/screenshots/help-light.png" alt="In-app Help" width="420"><br>**Help built in.** Search answers, replay the tour, or create a diagnostics report. |

## Install
1. Download **Offerlane-0.2.0.dmg** (or the .pkg) from [Releases](../../releases), and check it against `SHA256SUMS.txt` if you like.
2. Open the DMG and drag **Offerlane** into **Applications**.
3. Open Offerlane and follow the four steps above. It takes about five minutes.

Requires macOS 14 (Sonoma) or later, on Apple silicon or Intel. There's nothing else to install by hand: the Setup Center handles the AI.

## Choose your AI
| | Cost | Notes |
|---|---|---|
| **Claude account** (recommended) | Your Claude Pro or Max plan | Uses the official Claude Code tool, installed and verified for you |
| **Claude API key** | Pay per use: about $0.001 per Find Jobs run, about $0.03 per tailored résumé | Daily usage in Settings; per-run limit |
| **Ollama** | Free; runs on your Mac | Slower; needs a few GB of disk; the model is picked for your Mac's memory |

## Privacy
Everything stays on your Mac, and passwords and keys stay in your Keychain. Only résumé text and job descriptions go to the AI you choose, and only form answers go to the career sites you apply to. There's no telemetry. Read the [privacy policy](docs/PRIVACY.md).

## Help and feedback
- **In the app:** Help → Offerlane Help (⌘?).
- **Online:** the [user guide](docs/USER_GUIDE.md).
- **Bugs:** [open an issue](../../issues/new/choose) and attach a report from Help → Send Diagnostics….
- **Security issues:** see [SECURITY.md](SECURITY.md).

## License
See [LICENSE](LICENSE).
