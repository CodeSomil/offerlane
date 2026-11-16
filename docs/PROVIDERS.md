# AI providers (P2 spike)

Checked **2026-11-10** against official docs only. Machine-readable version: `Packages/OfferlaneCore/Sources/OfferlaneCore/Resources/providers.json`.
The UI shows a provider only when its status is `verified`. `unverified` entries stay hidden until their gaps are checked. `retired` and `dropped` entries are never shown.
Limits and terms change. Re-check the source links before changing a status.

| Provider | Status | Free? | Trains on your data? | Shown in UI |
|---|---|---|---|---|
| Claude Code (Pro/Max) | **unverified (terms)** | No (subscription) | No | Hidden until human decides |
| Google Gemini API | verified | Yes | **Yes (free tier)** | Yes, except EEA/CH/UK |
| Groq | unverified | Free plan exists, limits unpublished | No | Hidden |
| Cerebras | unverified | No ($5/30-day trial, card needed) | Not confirmed | Hidden |
| OpenRouter (3 curated paid picks, D6) | verified | No (paid per use) | No: every request asks for zero-retention, no-data-collection providers | Yes |
| Mistral | unverified | Free mode, limits unpublished | Not confirmed | Hidden |
| GitHub Models | **retired 2026-07-30** | No | n/a | Never |
| Cloudflare Workers AI | verified | Yes, 10k Neurons/day | No | Yes |
| Hugging Face Inference | unverified | No (free users: no credits) | Not confirmed | Hidden |
| Ollama (local) | verified (install pin unverified) | Yes | No, stays on the Mac | Yes |
| Anthropic API | verified | No | No | Yes |
| OpenAI API | unverified (docs 403) | No | No (unless opt-in) | Hidden |
| Codex CLI | unverified | Unclear | Not confirmed | Hidden |
| Gemini CLI | **dropped** | No longer free | n/a | Never |
| Custom OpenAI-compatible | verified (user-supplied) | n/a | Depends | Yes |

## Claude Code: needs a human decision
- Install: `curl -fsSL https://claude.ai/install.sh | bash`, or `brew install --cask claude-code`. Requires macOS 13 or newer. Source: [setup](https://code.claude.com/docs/en/setup).
- Integrity: each release has a `manifest.json` with SHA256 checksums for every binary. The manifest is GPG-signed (fingerprint `31DD DE24 DDFA B679 F42D 7BD2 BAA9 29FF 1A7E CACE`, from 2.1.89 on). The binary is signed by "Anthropic PBC" and notarized. The release host is `https://downloads.claude.ai/claude-code-releases`, which matches `ClaudeSetup.releasesURL`.
- Sign-in: run `claude` (browser flow) or `claude auth login`. Needs a Pro, Max, Ultra, Team, Enterprise or Console account. The free claude.ai plan does not include Claude Code.
- Restricted call: `claude -p --output-format json --tools ""` (`--tools ""` disables every tool). Source: [cli-reference](https://code.claude.com/docs/en/cli-reference).
- **Terms** ([legal-and-compliance](https://code.claude.com/docs/en/legal-and-compliance)):
  - "Anthropic does not permit third-party developers to offer Claude.ai login into their own applications, or to route requests through Free, Pro, Max, or Ultra plan credentials on behalf of their users."
  - Developers "may not collect, store, or intermediate Claude.ai credentials or session tokens."
  - A user may still sign in to the unmodified Claude Code binary with their own subscription.
- Offerlane never touches the credentials, but it does drive the user's `claude` for app features. That may count as "routing requests on behalf of users", so the status is **unverified**. Sub-step 5 needs the human's decision, or confirmation from Anthropic. The existing `ClaudeCLIClient` is unchanged.

## Google Gemini API
- Free tier: "Free input & output tokens" ([pricing](https://aistudio.google.com/docs/pricing)). Example free model: `gemini-3.8-flash`. Per-model RPM/TPM/RPD are shown only in AI Studio, and limits apply per project ([rate-limits](https://aistudio.google.com/docs/rate-limits)).
- Data: on unpaid services, "Google uses the content you submit … to provide, improve, and develop" its products, and "human reviewers may read" input and output. The privacy note must say this before the user connects ([terms](https://aistudio.google.com/docs/terms)).
- Region: "You may use only Paid Services when making API Clients available to users in the European Economic Area, Switzerland, or the United Kingdom." The free option is hidden in those regions.
- Use: the terms say it is for "professional or business purposes, not for consumer use", and users must be 18 or older.
- OpenAI-compatible base: `https://generativelanguage.googleapis.com/v1beta/openai/`. Key page: <https://aistudio.google.com/apikey>. The docs give no key format.

## Groq
- Base: `https://api.groq.com/openai/v1` ([openai](https://console.groq.com/docs/openai)).
- No training: "Groq is not permitted to use Inputs or Outputs for training" ([services agreement](https://console.groq.com/docs/legal/services-agreement) §4.2). No inference data is kept by default ([your-data](https://console.groq.com/docs/your-data)).
- Verified 2026-11-11. There is a Free plan, and a card is asked for only to upgrade: "To upgrade from the Free tier to the Developer tier, you'll need to provide a valid payment method" ([billing FAQ](https://console.groq.com/docs/billing-faqs)). Free-plan numbers live in the rate-limits page's "Free Plan Limits" tab and the console, so the app says "limits shown in the Groq console" and gives no numbers.
- Terms: §3.1 allows using the APIs in "your Customer Application". Each user signs up with their own key, so no account is resold.

## Cerebras
- Base: `https://api.cerebras.ai/v1`. Models: `gpt-oss-120b`, `qwen-3.8-27b`.
- "Is there a permanently free tier? No." New accounts get $5 in credits, which expire after 30 days and need a payment method. Trial limits: 5 RPM, 1M tokens/day, 64-65K context ([rate-limits](https://inference-docs.cerebras.ai/support/rate-limits)).
- This fails the "free" claim. The training terms are in EULA PDFs that weren't checked.

## OpenRouter (sign in; three curated paid picks, D6 from v4 P1.1)
- Base: `https://openrouter.ai/api/v1` ([quickstart](https://openrouter.ai/docs/quickstart)).
- Every request to an openrouter.ai host carries `provider: {data_collection: "deny", zdr: true, require_parameters: true}`. This is enforced in `OpenAICompatibleClient.request`, by host, so a custom endpoint gets it too. Field names were checked on 2026-11-11 against [provider routing](https://openrouter.ai/docs/features/provider-routing): `zdr` routes only to ZDR endpoints, and `data_collection: deny` uses only providers that don't store data.
- `:free` models are refused for every request, because their providers may train on resume text. Saved v3 settings that use a `:free` model now get a plain error that asks the user to choose a model in Settings → AI.
- Picks (registry `picks`, bundled only, so a remote refresh can't add or qualify one): Recommended = Sonnet-class tailoring + Haiku-class scoring; Cheaper = Haiku-class + an open-weight model for scoring only; Advanced = Opus-class. All are `qualified: false` until `offerlane-modelcheck` passes live, and unqualified picks are never labelled "Recommended". The ids are unconfirmed, because the live models list was stripped on 2026-11-11.
- Prices are read live from `/models` (`pricing.prompt`/`completion`, USD per token) by `OpenRouterCatalog` and cached for 24 h. If a price is missing the card shows "price unavailable". The full list is behind the "Show all models (developer)" toggle, with a warning.

## Mistral
- Base: `https://api.mistral.ai/v1/chat/completions` ([api](https://docs.mistral.ai/api)). Free mode is "intended for evaluation and prototyping" ([help](https://help.mistral.ai/en/articles/698531-why-am-i-hitting-api-rate-limits-and-how-do-i-increase-them)).
- Unverified because the limits are only in the admin console and the docs don't say whether free API data is used for training. The commercial terms §4.2 say no training, but don't say whether they cover free keys.

## GitHub Models: retired
- "As of July 30, 2026, GitHub Models has been fully retired" ([docs](https://docs.github.com/en/github-models/use-github-models/prototyping-with-ai-models)).

## Cloudflare Workers AI
- Free: "10,000 Neurons per day at no charge", resetting at 00:00 UTC ([pricing](https://developers.cloudflare.com/workers-ai/platform/pricing/)). Text generation: 300 requests/min ([limits](https://developers.cloudflare.com/workers-ai/platform/limits/)). Some models need the paid plan.
- Base: `https://api.cloudflare.com/client/v4/accounts/{account_id}/ai/v1`, so the user enters an Account ID plus a token. Tokens start with `cfut_` ([create-token](https://developers.cloudflare.com/fundamentals/api/get-started/create-token/)).
- "Cloudflare does not use Customer Content processed by Workers AI to train AI models", and keeps no data for standard requests ([data-usage](https://developers.cloudflare.com/workers-ai/platform/data-usage/)).
- Open for sub-step 3: the exact token permission name, which is on the [permissions reference](https://developers.cloudflare.com/fundamentals/api/reference/permissions/) (not fetched).

## Hugging Face Inference Providers
- Pricing table: "Free Users: Monthly Credits: None". PRO gets $2/month ([pricing](https://huggingface.co/docs/inference-providers/pricing)). That makes it not free.
- Base: `https://router.huggingface.co/v1`. Token: a fine-grained token with "Make calls to Inference Providers" ([index](https://huggingface.co/docs/inference-providers/index)).

## Ollama (local)
- Download: <https://ollama.com/download/Ollama.dmg>. Requires macOS 14 or newer ([macos](https://docs.ollama.com/macos.md)).
- API: native `http://localhost:11434/api`; OpenAI-compatible `/v1`.
  - `options.num_ctx` sets the context length.
  - `think: false` "requests no thinking output" ([generate](https://docs.ollama.com/api/generate.md)).
  - `/api/pull` streams `status`, `digest`, `total` and `completed` ([pull](https://docs.ollama.com/api/pull.md)).
  - `/api/tags` and `/api/version` also exist.
- **Install pin (verified 2026-11-10):** the app installs the latest GitHub release (`api.github.com/repos/ollama/ollama/releases/latest`, where ollama.com/download points). `Ollama-darwin.zip` must match the release's `sha256sum.txt`, and Ollama.app must be signed by "Developer ID Application: Infra Technologies, Inc (3MU9H2V9Y9)" (checked with `codesign -dvv`).
- The app talks to native `/api/chat` with `options.num_ctx` 16384 (8192 on Macs with 8 GB or less) and `think: false`, so no Modelfile is needed.

## Anthropic API
- Base: `https://api.anthropic.com`, `POST /v1/messages`. Keys start with `sk-ant-api`. Key page: <https://platform.claude.com/settings/keys> ([auth](https://platform.claude.com/docs/en/manage-claude/authentication)).
- "Anthropic may not train models on Customer Content from Services" ([commercial terms](https://www.anthropic.com/legal/commercial-terms)). It's paid, and no free tier is documented.

## OpenAI API
- "Data sent to the OpenAI API is not used to train or improve OpenAI models (unless you explicitly opt in)". Abuse logs are kept up to 30 days ([your-data](https://developers.openai.com/api/docs/guides/your-data)).
- Unverified because platform.openai.com returned 403, so the base URL, key page and key format weren't confirmed this time.

## Codex CLI (spike)
- Install: `brew install --cask codex`, `npm install -g @openai/codex`, or `https://chatgpt.com/codex/install.sh`. Non-interactive use: `codex exec`, with `--json` for JSON Lines ([repo](https://github.com/openai/codex), [non-interactive](https://learn.chatgpt.com/codex/non-interactive-mode)).
- Unverified because the sources disagree on plans. The README says Plus and up. The [pricing](https://learn.chatgpt.com/codex/pricing) page says Free includes Codex, but lists only the desktop app for Free. No terms were found about third-party apps driving Codex with ChatGPT sign-in.

## Gemini CLI (spike): dropped
- "Free individual access and Google AI Pro / Ultra … moved to Antigravity CLI on June 18, 2026" ([repo](https://github.com/google-gemini/gemini-cli)).
- The terms say: "Directly accessing the services powering Gemini CLI … using third-party software … is a violation" ([tos](https://geminicli.com/docs/resources/tos-privacy)).

## Logos (checked 2026-11-11)
A provider's own logo is shown only where its published rules allow it; the others get a neutral SF Symbol. `logo` in providers.json is bundled-only.
- OpenRouter: allowed. https://openrouter.ai/brand offers glyph SVGs; "Please don't stretch, recolor, or remix the marks." Ink (light) and cloud (dark) variants used as-is.
- Cloudflare: not allowed. https://www.cloudflare.com/trademark/: "Use of the Cloudflare logos (other than ... Web Badges) requires our written permission." Word mark only.
- Ollama: not allowed. https://ollama.com/terms §7: "These Terms do not grant you any rights to use our branding without permission."
- Google Gemini: unverified. Brand guidelines are behind the Partner Marketing Hub login; the API terms have no brand clause.
- Anthropic (Claude): unverified. The press kit zip has the Claude Spark SVG but no usage terms for third-party apps.

## What this means for P2
- The free cloud options verified today are **Gemini** (outside EEA/CH/UK, and it trains on data), **OpenRouter free** (rate-limited, model quality varies), and **Cloudflare** (no training).
- **Ollama** is the main free and private path.
- Claude Code's subscription path needs the terms decision above.

## Model qualification (`offerlane-modelcheck`, v4 P1.2)
- Offline: `cd Packages/OfferlaneCore && swift run offerlane-modelcheck --offline`. It runs the five checks (strict JSON, resume parse, ranking against `rank_expected.json`, Guard pass rate, hostile posting) against a well-behaved fake. It is part of `scripts/test.sh core`.
- Live (spends OpenRouter credit): `OFFERLANE_LIVE=1 OPENROUTER_API_KEY=… swift run offerlane-modelcheck [--models a/x,b/y]`. It checks every pick and its scoring model, and writes `models.json` with pass/fail, tokens, seconds and cost. The key is read from the environment only.
- Qualification is never automatic. After a live pass, a human sets `qualified: true` on that pick in `Resources/providers.json` and ships an app update. A downloaded registry can't change picks (`ProviderRegistry.merge`).
