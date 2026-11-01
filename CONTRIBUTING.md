# Contributing

Thanks for helping! A few ground rules:

1. Run `scripts/test.sh core`, `scripts/test.sh ui` and `scripts/test.sh apply` before opening a PR. New logic in `OfferlaneCore` needs tests.
2. **Never commit personal data**: résumés, profiles, real job-search exports, API keys, or screenshots with real names. Use the fake data in `DemoData` and the test fixtures. Put anything derived from real data in the git-ignored `Fixtures/private/`.
3. Keep the human gates. PRs that auto-submit applications, bypass CAPTCHAs or hide automation won't be merged.
4. The Xcode project is generated: edit `project.yml`, then run `xcodegen generate`.
5. By contributing you agree your work is released under the MIT License.
