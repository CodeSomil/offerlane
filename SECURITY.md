# Security policy

Offerlane keeps job-search data, saved passwords and email access on your Mac, so we take security reports seriously.

## Reporting a vulnerability
Please **don't open a public issue**. Use GitHub's private reporting instead: the **Security** tab → **Report a vulnerability**.

Include:
- what you found;
- how to reproduce it;
- the Offerlane version (Offerlane → About).

We aim to reply within 5 working days, and to ship a fix or mitigation for serious issues within 30 days. We'll credit you in the release notes unless you'd rather we didn't.

## Supported versions
Only the latest release gets security fixes.

## What's in scope
- The Offerlane app and its installers.
- How it stores secrets (Keychain), its sign-in (local password, Touch ID, Google), the in-app application browser, email tracking, and the AI setup downloads.

**Out of scope:**
- Third-party services: career sites, Google, the AI providers you connect (such as OpenRouter, Groq, Cloudflare, Anthropic), Ollama.
- Attacks that need someone who is already signed in to your Mac account with your password, unless Offerlane makes things worse.

## How Offerlane protects you (0.3)
- **Secrets:** your AI key, email app password, career-site passwords and Google tokens live only in the macOS Keychain. They are never written to files, logs, exports or diagnostics.
- **Saved passwords:** a career-site password is only ever typed into the site it was saved for. Showing one needs Touch ID or your Mac password.
- **Submit:** Offerlane never presses Submit or a combined "create account and apply" button. It stops and you click.
- **Email links:** verification links from email are opened only when they are HTTPS on the application's own site (or Workday) and come from that site.
- **The apply browser:** loads web pages only. Offerlane's form filler runs in its own isolated script space.
- **AI-written text:** escaped before it reaches the LaTeX engine, so it can't run commands or read files. LaTeX runs in tectonic's `--untrusted` mode.
- **Installing an AI:** Ollama is downloaded only from their official servers over HTTPS. Its checksum and its publisher's code signature are verified before anything runs.
- **Sign-in:**
  - Google uses PKCE with full ID-token checks and asks only for your name and email. Gmail access is a separate, read-only opt-in, revoked when you sign out.
  - Local passwords use PBKDF2 (600k rounds) with lockout.
- **Shipped builds:** hardened runtime, no special permissions, and stripped of build-machine paths; a privacy check runs on every installer.
- **Privacy:** no telemetry. Logs and diagnostics remove emails, phone numbers, keys, tokens and web addresses.
