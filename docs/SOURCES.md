> **NEEDS LEGAL REVIEW** for the terms readings below (v4 P0.5 checklist). "Allowed" is our reading, not legal advice.

# Job sources (P3, terms read 2026-11-10)

Code: `Discovery/Sources.swift` (`JobSources.all`). Each source has an on/off switch (Search step → Job sources), a minimum
interval, and a terms note. Company career-site boards (Greenhouse, Lever, Ashby, Workable, SmartRecruiters, Workday CXS) are
always checked for the watchlist and for boards learned along the way.

| Source | Status | Why |
|---|---|---|
| Remotive (`remotive.com/api/remote-jobs`) | **On** | No key. Terms (README + live notice): link back to the Remotive URL and name Remotive as source (done: "via Remotive" link on each result); >2 requests/min blocked, ~4/day asked → one request per run, ≥6 h apart. Jobs are 24 h delayed. |
| Adzuna (`api.adzuna.com/v1/api/jobs/{country}/search`) | **Off by default** (v4 P1.10, human approved) | Free key, "personal job search" allowed. The user's own app_id/app_key go in the profile Keychain (Search step → Job sources); skipped until both are set. Terms: an "Adzuna" label ≥116×23 on each advert, linked to the Adzuna country site its `redirect_url` is on (adzuna.co.uk if that link isn't an Adzuna site; v4 P1.11) (done: "Jobs by Adzuna", UI-tested), each advert links to Adzuna (`redirect_url`), descriptions are snippets. At most 4 requests per run, ≥6 h apart (free plan ~250/day). One country per search (picker; default from the Mac's region). Not yet run against the live API. |
| Arbeitnow | Hidden (unverified) | No terms, rate limits or query params published (only a blog post). |
| The Muse | Hidden (unverified) | Developer docs returned 403. |
| JobSpy | Excluded | Python scraper of Indeed/LinkedIn/Glassdoor/ZipRecruiter; their terms forbid scraping, and it needs a Python runtime. |
| LinkedIn | Excluded | Invariant: no LinkedIn scraping. |

## Career-site boards: terms checklist (v4 P0.5)
Offerlane reads only public job listings from these, for roles the user chose to watch, at most once per run, and never
submits without the user's click. Readings below are from the public developer docs; each row needs a human/legal check.

| Source | Endpoint Offerlane uses | What the terms/docs allow (our reading) | Offerlane's behaviour | Check |
|---|---|---|---|---|
| Greenhouse | Job Board API `boards-api.greenhouse.io/v1/boards/<slug>/jobs` (GET, no key) | Documented public API for showing a company's published jobs. Application POST needs the company's key: not used. | Read listings; apply through the company's own form in the app's browser. | [ ] |
| Lever | Postings API `api.lever.co/v0/postings/<slug>` (GET, no key) | Documented public API for published postings. | Read listings; apply through the hosted form. | [ ] |
| Ashby | Posting API `api.ashbyhq.com/posting-api/job-board/<slug>` (GET, no key) | Documented public job-board API. | Read listings; apply through the hosted form. | [ ] |
| SmartRecruiters | Posting API `api.smartrecruiters.com/v1/companies/<id>/postings` (GET, no key) | Documented public Posting API. | Read listings; apply through the hosted form. | [ ] |
| Workable | Widget endpoint `apply.workable.com/api/v1/widget/accounts/<slug>` | Public, but meant for the company's own careers widget; no published terms for third-party use. **Unclear.** | Read listings for watched companies only, low rate. | [ ] decide |
| Workday | CXS endpoint `<tenant>.myworkdayjobs.com/wday/cxs/.../jobs` (POST search) | Not a documented public API; it backs each company's career site. **Unclear; highest risk.** | Watched companies only, one search per run, no account creation without the user. | [ ] decide |
| Company sites (other) | The careers page itself | Each company's site terms apply. | Opened in the app's browser at the user's request. | n/a |

Human decisions needed: keep Workable and Workday on, put them behind a per-source switch that's off by default, or drop them.
