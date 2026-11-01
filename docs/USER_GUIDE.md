# Offerlane: user guide

Offerlane finds roles on your target companies' career sites, scores them, tailors your resume for the ones you approve, fills in the application at a human pace, and stops so **you** click Submit. Replies from employers update each application automatically.

Nothing is tailored, applied for, or created without your say-so. Offerlane never submits an application, never solves CAPTCHAs, and never logs in to LinkedIn.

## Install
1. Open **Offerlane.dmg** and drag **Offerlane** into **Applications**.
2. Open Offerlane from Applications. If macOS says it can't check the developer, right-click the app → **Open** → **Open**. You only need to do this once; the app isn't notarized yet.

## First run (about 5 minutes)
1. **AI**: pick one.
   - **Claude account** (recommended): click **Install** if asked, then **Sign In…**; a browser window opens for your Claude login and the sheet closes by itself. Calls count toward your plan's usage limits.
   - **Claude API key**: click **Get a Key**, paste it, then **Test Key**. Spend is shown in Settings.
   - **Ollama** (free, runs on your Mac): **Install Ollama…**, then **Download Model**. It's slower and gives lower-quality tailoring.
2. **Resumes**: drop in one or more resumes (PDF, Word, text or LaTeX) and give each a name, such as "IC" or "Manager". If you used previous-version (v2), click **Import** to bring over everything, including your LaTeX versions.
3. **About you**: check the details used to fill forms, especially the countries where you can work without sponsorship.
4. **Search**: the AI suggests titles and 40–60 companies. Edit the chips, add a company by name or by pasting its careers-page link, and set the score threshold.
5. **Email** (optional): connect your inbox with an *app password* (use the "How to get an app password" link), then **Test Connection**.
6. **Notifications**: allow them. Optionally scan the QR code to get alerts on your phone through the free ntfy app.

## Everyday use
1. **Find Jobs** (⌘F) checks every career site and scores new roles. It takes about a minute.
2. **Matches**: **Approve** the roles worth applying to and **Decline** the rest. Declined roles never come back. Weaker matches sit under "Show weaker matches".
3. Offerlane tailors a resume for each approved role in the background, then notifies you.
4. **Review** (from To Do):
   - The screen shows every change: the original in red, the tailored text in green.
   - If the AI tried to invent a number, the change was blocked and your original kept.
   - **Edit** lets you change wording, reorder, restore, or add a left-out bullet; then click **Rebuild PDF**.
   - You can also **Redo with Note…** or **Use My Resume As-Is**.
   - When it's right, click **Approve & Apply**.
5. **Apply window**: Offerlane opens the application and fills every page.
   - If the site needs an account, it asks first ("Create a Workday account at … with your email?"). The password it creates is saved in your Keychain.
   - It stops on the page with **Submit**. Check everything, then click Submit yourself.
   - If something needs you (a CAPTCHA, an unusual question, a failed sign-in), the banner says what. Do it, then press **Continue**.
6. **Applications**: a board of everything you've submitted. Email replies move cards automatically (interview, assessment, offer). Rejections are hidden but counted; tick **Show removed** to see them. Drag a card, or right-click → **Move to**, to change its status yourself.

## Settings
- **AI**: change provider; see calls and estimated cost per day.
- **Edit Resumes / About You / Search**: re-opens those setup steps.
- **Career-site accounts**: **Show Password** (asks for Touch ID or your Mac password), or **Forget** a saved password.
- **Your data**: **Export Everything…** (JSON plus all PDFs; passwords aren't included) and **Delete All My Data…**.

## Where things live
- Data: `~/Library/Application Support/Offerlane/`. Tailored resumes and answers are under `Applications/`.
- Passwords and keys: your Mac's Keychain only.
- Logs: `~/Library/Logs/Offerlane/` (personal details redacted).
- Only your resume text and job descriptions go to your AI provider, and only form answers go to the career sites you apply to. There's no telemetry.

## Known limits
- You submit every application yourself (by design), and CAPTCHAs need you.
- Some custom career sites may stop at "Needs you" for a question Offerlane can't answer.
- A Claude subscription is used through the Claude Code tool and counts toward your plan's limits.
- Without a Developer ID the app isn't notarized, so macOS asks once on first open.
