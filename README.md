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
  <img alt="Version 0.3.0" src="https://img.shields.io/badge/version-0.3.0-4F46E5">
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
| Email and password; Touch ID optional (Continue with Google is coming) | A free option (Ollama on your Mac, one-click OpenRouter sign-in, or a free Gemini, Groq or Cloudflare key) or a paid Claude API key | PDF, Word, text or LaTeX; several versions welcome | Titles and companies are drafted from your résumé; change anything later |

## What's new in 0.3.0
- **Connect any AI in one click**: **Sign in with OpenRouter** for free models, or paid ones once you add credit. Or connect Ollama, Gemini, Groq, Cloudflare, a Claude API key or your own endpoint, with backups that take over when the first AI is down.
- **Wider search**: your company list boosts matches instead of limiting them.
- **Skill gaps and learning plans** based on real postings and verified links.
- **Career tools**: goals and paths, interview prep, resume health and ATS checks, insights, networking drafts, offer comparison and market trends.
- **Clearer errors**: every failure says what happened and what to do.

Earlier releases: [release notes](docs/RELEASE_NOTES.md).

## A closer look

| | |
|---|---|
| <img src="docs/screenshots/review-light.png" alt="Reviewing a tailored résumé" width="420"><br>**Review every change.** Your original in red, the tailored text in green, with a live PDF preview. | <img src="docs/screenshots/applications-light.png" alt="Applications board" width="420"><br>**Track every application.** Email replies move cards along by themselves. |
| <img src="docs/screenshots/setup-center-dark.png" alt="Setup Center" width="420"><br>**Setup Center.** Checks your AI, internet, storage and Mac, and fixes problems with one click. | <img src="docs/screenshots/help-light.png" alt="In-app Help" width="420"><br>**Help built in.** Search answers, replay the tour, or create a diagnostics report. |

## Install
1. Download **Offerlane-0.3.0.dmg** (or the .pkg) from [Releases](../../releases), and check it against `SHA256SUMS.txt` if you like.
2. Open the DMG and drag **Offerlane** into **Applications**.
3. The first time only: Offerlane isn't notarized by Apple yet, so macOS says it can't check it. Control-click Offerlane in Applications and choose **Open**, then **Open** again. On macOS 15 or later, go to **System Settings → Privacy & Security** and click **Open Anyway**. After that it opens normally.
4. Open Offerlane and follow the four steps above. It takes about five minutes.

Requires macOS 14 (Sonoma) or later, on Apple silicon or Intel. There's nothing else to install by hand: the Setup Center handles the AI.

## Choose your AI
Offerlane suggests three options for your Mac. The easiest is **Sign in with OpenRouter**: one click, no key to copy, and it covers free models plus paid models from many AI companies once you add credit. The other options connect to one provider directly.

| | Cost | What happens to your data |
|---|---|---|
| **Ollama** | Free; runs on your Mac | Everything stays on your Mac. Slower, and needs a few GB of disk |
| **Google Gemini** | Free key; limits shown in Google AI Studio | On the free tier Google may use your prompts to improve its products, and human reviewers may read them. Not offered in the EEA, Switzerland or the UK |
| **OpenRouter** (sign in) | Free models: 20 requests a minute, 50 a day. Paid models: pay per use with OpenRouter credit | Some free models' providers keep and train on prompts; OpenRouter shows this per model |
| **Groq** | Free plan, no card; limits per model shown in the Groq console | Doesn't train on your inputs or keep inference data by default (abuse logs up to 30 days) |
| **Cloudflare Workers AI** | Free key; 10,000 Neurons a day | Doesn't train on your content or keep standard requests |
| **Claude API key** | Pay per use: about $0.001 per Find Jobs run, about $0.03 per tailored résumé | Anthropic doesn't train on paid API content |
| **Your own endpoint** | Depends on the endpoint | Goes to the endpoint you enter; check its terms |

The app shows the same note before you connect, and **Help → What does each AI do with my data?** lists it for every option. Terms and limits change, so they come from an updatable list ([docs/PROVIDERS.md](docs/PROVIDERS.md)). This table was checked on 2026-11-11.

## Privacy
Everything stays on your Mac, and passwords and keys stay in your Keychain. Only résumé text and job descriptions go to the AI you choose, and only form answers go to the career sites you apply to. There's no telemetry. Read the [privacy policy](docs/PRIVACY.md).

## Other platforms
Offerlane is built and tested for the Mac only. **Windows, Android and iOS are experimental and not built yet**: there's no installer or app for them, only a plan ([docs/WINDOWS_PLAN.md](docs/WINDOWS_PLAN.md)).

## Help and feedback
- **In the app:** Help → Offerlane Help (⌘?).
- **Online:** the [user guide](docs/USER_GUIDE.md).
- **Bugs:** [open an issue](../../issues/new/choose) and attach a report from Help → Send Diagnostics….
- **Security issues:** see [SECURITY.md](SECURITY.md).

## License
See [LICENSE](LICENSE).
