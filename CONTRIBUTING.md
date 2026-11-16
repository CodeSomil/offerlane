# Contributing

Thanks for helping! A few ground rules:

1. Run the tests for what you touched before opening a PR: `scripts/test.sh core`, `ui` and `apply` for the Mac app; `scripts/test.sh cloud` and `web` for `apps/` and `libs/` (TypeScript, plus the Windows shell's Rust tests). New logic needs tests (`OfferlaneCore`, `libs/core`).
2. **Never commit personal data**: résumés, profiles, real job-search exports, API keys, or screenshots with real names. Use the fake data in `DemoData` and the test fixtures. Put anything derived from real data in the git-ignored `Fixtures/private/`.
3. Keep the human gates. PRs that auto-submit applications, bypass CAPTCHAs or hide automation won't be merged.
4. The Xcode project is generated: edit `project.yml`, then run `xcodegen generate`.
5. By contributing you agree your work is released under the MIT License.
