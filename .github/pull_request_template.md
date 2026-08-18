## Summary

<!-- What changes, and what a user sees differently afterward. -->

## Linked issue

<!-- e.g. Closes #123. For anything large, discuss in an issue first. -->

## Checklist

- [ ] Commits are signed off with `git commit -s` (DCO 1.1, no CLA) — see [CONTRIBUTING.md](https://github.com/gigaduckai/conduck/blob/main/CONTRIBUTING.md#sign-off-your-commits-dco).
- [ ] Both simulator suites pass locally — `ConduckTests` and `ConduckWatchTests`. CI runs both on every pull request, and the Watch compiles a subset of main-app files, so a change that looks unrelated can still break it.
- [ ] Tests added or updated where behavior changed.
- [ ] No endpoint URLs/hostnames (a gateway, a hosted model, a voice endpoint, a file server — any of them), API keys, tokens, transcripts, replies or file names added to any log, error message or notification; new `print`/`debugPrint`/`dump` calls are inside `#if DEBUG` — see [CONTRIBUTING.md](https://github.com/gigaduckai/conduck/blob/main/CONTRIBUTING.md#logging-and-privacy).
- [ ] No brand artwork or trademarks added; placeholder art only — see [TRADEMARKS.md](https://github.com/gigaduckai/conduck/blob/main/TRADEMARKS.md).
- [ ] Docs under `docs/` updated in present tense if this change affects them.
