# Offerlane privacy policy

*Last updated: 11 November 2026 · applies to Offerlane 0.3.0 for macOS*

Offerlane is a desktop app. **It has no server and no account system of its own, and it collects no analytics or telemetry.** We (the developer) never receive your data.

## What stays on your Mac
- **Your data:** resumes, profile, job search settings, roles, applications and notes. These are kept in your user folder under `~/Library/Application Support/Offerlane/`, one folder per profile.
- **Secrets:** your Offerlane password check, your AI key, your email app password, Google sign-in tokens, and passwords Offerlane creates for career sites. These are kept only in the macOS Keychain.
- **Logs:** kept in `~/Library/Logs/Offerlane/`, with names, emails, phone numbers and keys removed.

## What leaves your Mac, and where it goes
| Data | Sent to | When |
|---|---|---|
| Resume text, job descriptions, your search preferences | The AI you connect (for example OpenRouter, Google Gemini, Groq, Cloudflare or Anthropic), or Ollama on your own Mac. A backup AI gets it only when the first one can't answer | When reading a resume, scoring roles, tailoring |
| Your answers to application questions, your resume PDF | The career site you're applying to | Only when you approve an application |
| Requests for public job listings | Career-site job boards (Greenhouse, Lever, Ashby, Workable, SmartRecruiters, Workday) and the Remotive remote-jobs feed | When you click Find Jobs |
| Your name and email (from Google) | Google | If you choose **Continue with Google** |
| Email headers and snippets | Read *from* your mailbox (IMAP or Gmail, read-only); never sent anywhere | If you turn on email tracking |
| Notification text | ntfy.sh | Only if you set up phone notifications |
| Download requests | downloads.claude.ai, github.com (Ollama) | Only when you install an AI in the Setup Center |

## Google user data
If you connect Gmail, Offerlane requests **read-only** access (`gmail.readonly`). It uses it only to recognise replies from employers about applications you're tracking, and to find account-verification emails from career sites.

Gmail data:
- is processed on your Mac;
- is not stored beyond what's needed to update an application's status;
- is never sent to us or used for advertising;
- is never transferred to anyone else.

The one exception: when a reply is unclear, its subject and a short snippet go to the AI you chose, so it can classify the reply.

Offerlane's use of information received from Google APIs adheres to the [Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy), including the Limited Use requirements.

## Your choices
- **Export everything:** Settings → Your data → **Export Everything…**.
- **Delete everything:** Settings → Your data → **Delete All My Data…**. This also removes the Keychain secrets, saved career-site sign-ins and backups.
- **Disconnect Gmail:** Settings → Email → **Use IMAP Instead**. This also revokes access at Google.
- **Signing out** revokes Gmail access too.
- **Diagnostics:** **Help → Send Diagnostics…** creates a report with personal details removed. You see all of it, and you decide whether to share it. Offerlane never sends it.

## Contact
Questions: open an issue on the Offerlane GitHub repository. For security matters, see SECURITY.md.
