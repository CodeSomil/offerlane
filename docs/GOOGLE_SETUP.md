# Google sign-in and Gmail: setup

This guide covers two features:
- **Continue with Google** asks only for `openid email profile`. Google classes these as *non-sensitive* scopes, so they need no paid review.
- **Connect Gmail** (read-only) uses `gmail.readonly`, which Google classes as a *restricted* scope. Offerlane ships it **only in Testing mode**, for up to 100 people you name. IMAP with an app password stays the default for everyone else.

The client ID goes in **one file**: `App/Resources/OAuthConfig.plist`. Until you fill it in, the Google button stays visible but disabled, with a note.

> Google's console was reorganised in 2025: "OAuth consent screen" now lives under **Google Auth Platform** (Branding, Audience, Data Access, Clients). The old menu names are given in brackets.

## 1. Create the project (about 2 minutes)
1. Open https://console.cloud.google.com and sign in with the Google account that will own the app.
2. Click the project picker in the top bar, then **New Project**.
3. Name it `Offerlane`. Leave Organization as *No organization* unless you have one. Click **Create**, then select the new project.

## 2. Turn on the Gmail API (only needed for Connect Gmail)
1. Go to **APIs & Services → Library**.
2. Search for **Gmail API**, open it and click **Enable**.

## 3. Branding (the consent screen)
1. Go to **Google Auth Platform → Branding** (formerly *APIs & Services → OAuth consent screen*). Click **Get started** if asked.
2. Fill in:
   - **App name**: `Offerlane`.
   - **User support email**: your address.
   - **App logo**: optional. Uploading a logo also triggers brand verification, so leave it empty while testing.
3. Under **Audience**, choose **External**.
4. Enter a **developer contact email**, agree to the policy, then click **Create**.
5. When you go public, also fill in on this page: **App home page**, **Privacy policy link**, **Terms of service link** and **Authorised domains**. Google requires the first two for verification. A ready privacy policy is in `docs/PRIVACY.md` (it covers the Google API Services User Data Policy and Limited Use); host it on your domain and link it here.

## 4. Audience: stay in Testing and add test users
1. Go to **Google Auth Platform → Audience**.
2. Make sure **Publishing status** says **Testing**. Don't click *Publish app* while Gmail is enabled.
3. Under **Test users**, click **Add users** and enter the Gmail addresses of each tester, including yourself. The limit is 100.

Testing mode has two limits:
- Only the listed test users can sign in. Everyone else gets "access blocked".
- Refresh tokens expire after **7 days**. Offerlane then shows "Your Google connection has expired… Fix it", and the tester clicks **Connect Gmail** again.

## 5. Data Access (scopes)
1. Go to **Google Auth Platform → Data Access → Add or remove scopes**.
2. Tick `openid`, `.../auth/userinfo.email` and `.../auth/userinfo.profile`.
3. Only for the Gmail preview: also tick `.../auth/gmail.readonly`. It appears under *Restricted scopes*.
4. Click **Update**, then **Save**.

## 6. Create the Desktop client
1. Go to **Google Auth Platform → Clients → Create client** (formerly *APIs & Services → Credentials → Create credentials → OAuth client ID*).
2. Set **Application type** to **Desktop app** and **Name** to `Offerlane macOS`. Click **Create**.
3. Copy the **Client ID** (ends in `.apps.googleusercontent.com`) and the **Client secret**.
   - For Desktop clients Google treats the secret as **not confidential**: it ships inside the app. The sign-in is actually protected by PKCE, the `state` check and the loopback redirect.
   - Don't confuse it with a Web or Service Account secret. Those must never be shipped.
4. You don't need to add redirect URIs: Desktop clients accept `http://127.0.0.1:<any port>`, which Offerlane uses.

## 7. Put the values in the app
Edit `App/Resources/OAuthConfig.plist`:

| Key | Value |
|---|---|
| `GoogleClientID` | the Client ID from step 6 |
| `GoogleClientSecret` | the Client secret from step 6 |
| `GmailTestingMode` | `true` only for builds given to listed test users; otherwise `false` |

Rebuild with `scripts/build.sh`. Check that **Continue with Google** is enabled on the welcome screen. With `GmailTestingMode` on, **Connect Gmail (Preview)** appears in Settings → Email tracking.

- **Keeping your ID out of the public export:** if you'd rather the public repo not contain your ID, keep the placeholder in git and fill the value in only for release builds. Phase 8's export uses an allowlist, so `App/` never leaves this repo either way.
- **Testing the Gmail preview without editing the plist:** set `OFFERLANE_GMAIL=1` in the environment.

## 8. What Google requires before Gmail can be public
Publishing the app ("In production") with `gmail.readonly` needs all of the following. Google's requirements change, so check the current pages before starting:

1. **Brand verification**:
   - verified domain (Search Console);
   - home page and privacy policy hosted on that domain;
   - the privacy policy must describe Gmail data use and comply with the Google API Services User Data Policy, including the *Limited Use* requirements.
2. **Restricted-scope verification**:
   - a justification for each scope;
   - a demo video showing the consent screen and how Gmail data is used.
3. **A yearly security assessment (CASA)**:
   - done by a Google-approved assessor;
   - **paid by the developer**: Google does not cover it; prices vary by assessor and tier, roughly hundreds to thousands of USD per year;
   - it must be renewed every 12 months.
4. Until all three are approved, the app is limited to Testing mode (100 users, 7-day tokens). This is why IMAP stays the default.

**No review is needed for sign-in alone.** If you ship with `GmailTestingMode=false`, you can publish to production after brand verification only (home page plus privacy policy). That's because `openid email profile` are non-sensitive scopes.

## Security notes (how Offerlane uses Google)
- **Sign-in flow:** authorization code with **PKCE (S256)**, plus random `state` and `nonce`.
  - The redirect lands on a one-shot listener bound to `127.0.0.1` on a random port.
  - The ID token is checked against Google's published keys (RS256 signature) and its claims are verified: `iss`, `aud`, `exp`, `iat`, `nonce` and `email_verified`.
- **Scopes:** sign-in asks only for `openid email profile`. Gmail read access is requested *incrementally*, only when the user clicks **Connect Gmail**.
- **Tokens:**
  - Stored only in the macOS Keychain, readable only on this Mac.
  - Never written to files or logs.
  - Cleared on sign-out; *Use IMAP Instead* also revokes the grant with Google.
- **Gmail reading:** messages are listed with `format=metadata` (sender, subject, snippet). A full body is downloaded only for career-site verification emails while an application is waiting for one.
