> **NEEDS LEGAL REVIEW.** Draft written from what the code does (v4 P0.5). Not final until a lawyer has reviewed it.

# Offerlane privacy policy

*Last updated: 11 November 2026 · applies to Offerlane 0.3.0 and later for macOS, and to the Offerlane browser extension (Chrome)*

> **NEEDS LEGAL REVIEW (P3.9):** the Offerlane web app and cloud service (job index sign-in, end-to-end encrypted sync) are not covered yet; this policy must add them before the web app or the extension is published.

The Offerlane Mac app is a desktop app. **It has no server and no account system of its own, and it collects no analytics or telemetry.** We (the developer) never receive your data.

## What stays on your Mac
- **Your data:** resumes, profile, job search settings, roles, applications and notes. These are kept in your user folder under `~/Library/Application Support/Offerlane/`, one folder per profile.
- **Secrets:** your Offerlane password check, your AI key, your email app password, Google sign-in tokens, and passwords Offerlane creates for career sites. These are kept only in the macOS Keychain.
- **Logs:** kept in `~/Library/Logs/Offerlane/`, with names, emails, phone numbers and keys removed.

## What leaves your Mac, and where it goes
| Data | Sent to | When |
|---|---|---|
| Resume text, job descriptions, your search preferences | The AI you connect (for example OpenRouter, Google Gemini, Groq, Cloudflare or Anthropic), or Ollama on your own Mac. A backup AI gets it only when the first one can't answer | When reading a resume, scoring roles, tailoring |
| Your answers to application questions, your resume PDF | The career site you're applying to | Only when you approve an application |
| Requests for public job listings | Career-site job boards (Greenhouse, Lever, Ashby, Workable, SmartRecruiters, Workday) and the Remotive remote-jobs feed; Adzuna only if you turn it on and add your own Adzuna key (it receives your search titles, locations and your key) | When you click Find Jobs |
| Your name and email (from Google) | Google | If you choose **Continue with Google** |
| Email headers and snippets | Read *from* your mailbox (IMAP or Gmail, read-only); never sent anywhere | If you turn on email tracking |
| Notification text | ntfy.sh | Only if you set up phone notifications |
| Download requests | downloads.claude.ai, github.com (Ollama) | Only when you install an AI in the Setup Center |
| Update check: app version, macOS version, your IP address (as for any web request) | The Offerlane update feed | Only when you click **Check for Updates…** in Settings (never automatically) |

## How each AI provider handles your data
These notes come from each provider's published terms (Offerlane's provider list, `providers.json`). Providers change their terms; check theirs before you connect. Offerlane shows the same note when you pick a provider.

| Provider | May train on what you send | Notes |
|---|---|---|
| Google Gemini API | Yes | On the free tier Google uses your prompts and responses (your resume and job posts) to improve its products, and human reviewers may read them. |
| Groq | No | Groq does not train on your inputs and keeps no inference data by default (abuse logs up to 30 days). |
| Cerebras | Not confirmed | Cerebras says it does not retain inference inputs and outputs. |
| OpenRouter | Yes | Some free models' providers keep and train on your prompts (shown per model). OpenRouter has a separate privacy setting for free models. |
| Mistral | Not confirmed | Training use of free-mode API data is not confirmed. |
| Cloudflare Workers AI | No | Cloudflare does not train on your content and does not keep inputs or outputs for standard requests. |
| Hugging Face Inference Providers | Not confirmed | Data use depends on the underlying provider; not confirmed. |
| Ollama (on this Mac) | No | Everything stays on this Mac. |
| Anthropic API | No | Paid API: Anthropic may not train models on your content (Commercial Terms). |
| OpenAI API | No | API data is not used for training unless you opt in; abuse logs kept up to 30 days. |
| Codex CLI (ChatGPT sign-in) | Not confirmed | Not confirmed. |
| Custom OpenAI-compatible endpoint | Not confirmed | Your data goes to the endpoint you enter; check its terms. |

Offerlane sends your resume content only to the AI you connect, using your own key or account. The Claude Code (Claude Pro/Max sign-in) connection is not offered.

## Google user data
If you connect Gmail, Offerlane requests **read-only** access (`gmail.readonly`). It uses it only to recognise replies from employers about applications you're tracking, and to find account-verification emails from career sites.

Gmail data:
- is processed on your Mac;
- is not stored beyond what's needed to update an application's status;
- is never sent to us or used for advertising;
- is never transferred to anyone else.

The one exception: when a reply is unclear, its subject and a short snippet go to the AI you chose, so it can classify the reply.

Offerlane's use of information received from Google APIs adheres to the [Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy), including the Limited Use requirements.

## Browser extension (Chrome)
> **NEEDS LEGAL REVIEW** (added v4 P3.9). The Chrome Web Store needs this policy at a public URL before submission.

- **What it reads:** only the tab you click the Offerlane toolbar button on, once per click: its full address, title and main heading, the structured data the page publishes (JSON-LD, used to find the job posting), and the labels, names, placeholders and listed options of the form fields on it, including frames from the same site. It never reads other tabs, your browsing history or the values you type.
- **What it keeps, on this device only:** jobs you save, and the profile and answers you send it from the Offerlane web app (`chrome.storage.local`, not encrypted). The profile includes your contact details, work history, current and expected salary, and, if you filled them in, your equal-opportunity answers (gender, race, veteran status, disability, sexual orientation), so the extension can show them beside the questions that ask for them. It also keeps the page it last read (`chrome.storage.session`, cleared when that tab navigates or the browser closes).
- **What it sends:** nothing to any server. It has no network access. It talks only to the Offerlane web app open in your own browser, and only when you click **Send my answers** or **Bring in saved jobs** there. Saved jobs are removed from the extension once the web app has stored them.
- **What it never does:** fill in, click or submit a form; sell, share or use your data for advertising or credit decisions. It has no analytics.
- **Remove it:** uninstalling the extension deletes everything it kept.

## Your choices
- **Export everything:** Settings → Your data → **Export Everything…**.
- **Delete everything:** Settings → Your data → **Delete All My Data…**. This also removes the Keychain secrets, saved career-site sign-ins and the copies Offerlane keeps when you restore a backup. Backup files you saved yourself stay where you put them; delete those yourself.
- **Encrypted backups:** Settings → Your data → **Back Up…** saves one file, encrypted on your Mac with a passphrase you choose (AES-256-GCM). It never leaves your Mac unless you move it. Without the passphrase it can't be opened, by you or by us.
- **Crash reports (off by default):** if you turn on **Save crash reports**, Offerlane saves a short technical report on your Mac after a crash: app and macOS version, the error type, and where in the code it stopped. It never includes your resume, jobs, emails, names, file paths or keys. Nothing is sent; you can read each report and share it yourself.
- **Disconnect Gmail:** Settings → Email → **Use IMAP Instead**. This also revokes access at Google.
- **Signing out** revokes Gmail access too.
- **Diagnostics:** **Help → Send Diagnostics…** creates a report with personal details removed. You see all of it, and you decide whether to share it. Offerlane never sends it.

## Contact
Questions: open an issue on the Offerlane GitHub repository. For security matters, see SECURITY.md.
