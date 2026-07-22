# Contributing to Conduck

This repository is the canonical source for the Conduck app on Apple platforms —
iPhone, iPad, Mac, Apple Watch, and CarPlay. Contributions are welcome from day
one: bug fixes, features, tests, and documentation improvements alike. Thanks
for taking the time.

## Sign off your commits (DCO)

Every commit must carry a `Signed-off-by` line, added with:

```
git commit -s
```

By signing off you certify the
[Developer Certificate of Origin 1.1](https://developercertificate.org) —
in short, that you wrote the change or
otherwise have the right to submit it under the project's open-source license.
That's the whole agreement: there is **no CLA** and no copyright assignment.

Forgot to sign off? `git commit --amend -s` fixes the last commit;
`git rebase --signoff <base>` fixes a branch.

## Building from source

You need **Xcode 26.5 or later**. The app targets iOS/iPadOS 26.5, macOS 26.5,
and watchOS 26.5.

1. Open `Conduck/Conduck.xcodeproj` in Xcode.
2. Select the **Conduck** scheme and build/run.

That's it — the community build works with **zero configuration**. It uses a
neutral build identity (`com.example.*` bundle identifiers, no signing team),
ships placeholder art, and displays as **"Conduck Community"**. Simulator runs
need no signing setup at all. To run on your own hardware, create a gitignored
`Conduck/Configs/Identity-Override.xcconfig` next to
`Conduck/Configs/Identity.xcconfig` defining the same `CONDUCK_*` variables
(including your `CONDUCK_DEVELOPMENT_TEAM`) — see the comments in that file.

Two things that are intentional, not broken:

- The community entitlements omit CarPlay (a restricted, Apple-granted
  entitlement); the official App Store build carries it.
- The real Conduck brand art is not in this repository and is not covered by
  its license — see `branding/README.md`.

## Running tests

- In Xcode, run **Product ▸ Test** on the **Conduck** scheme — this runs the
  `ConduckTests` bundle (the main app-logic suite) on an iOS Simulator.
- watchOS-only logic has its own bundle: run the **ConduckWatchTests** scheme
  against a watchOS Simulator.

Some tests skip themselves in community builds: cases that touch the live
Keychain skip on unsigned simulator builds, and the official-identity lock
tests skip under the community identity. Skips there are expected — failures
are not. Please keep the suite green.

## Pull requests

- Keep PRs **small and focused** — one change per PR reviews faster and lands
  faster.
- In the description, say what a **user sees differently** after the change,
  not just what the code does.
- **Add or update tests** where behavior changes.
- If your change affects the docs under `docs/`, update them in **present
  tense** — they describe the current design, not the history of changes.
- Sign off every commit (see above).

For anything large — new features, refactors, architectural changes — please
open an issue to discuss the direction first. It protects your time.

## Bugs, feature requests, and security

- Bugs and feature requests: [GitHub issues](../../issues). Include the
  platform, OS version, and steps to reproduce.
- Security vulnerabilities: **never via public issues.** See
  [SECURITY.md](SECURITY.md) for how to report privately.

## Review model

Reviews are best-effort by a small maintainer team. Expect a response, but not
always a fast one — please be patient, and feel free to ping a quiet PR after a
couple of weeks.

## Style and dependencies

- Match the surrounding code. Consistency with the file you're editing beats
  any external style guide.
- **No new dependencies without prior discussion in an issue.** Every
  dependency is a long-term maintenance commitment, so additions are deliberate.

## License and trademarks

Contributions are licensed under the **Apache License 2.0**, the project's code
license. The Conduck™ name and the duck-character brand artwork are trademarks
and brand assets of GigaDuck OÜ and are **not** covered by that license — which
is why this repository ships placeholder art and community builds display
"Conduck Community".
