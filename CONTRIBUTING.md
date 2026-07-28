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

Rather than rely on remembering the flag, enable the tracked hook once per clone:

```
git config core.hooksPath .githooks
```

`.githooks/prepare-commit-msg` then adds the trailer for you. It is keyed on the
commit **author** (the person who can certify the change, and not always the
committer), skipped for merge and squash messages, and idempotent — so
`git commit -s` keeps working and never produces a duplicate line.

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
- Certificate trust has one suite that neither of those runs:
  `RemoteAgentLiveTLSTrustTests` drives a real loopback HTTPS server, so an
  untrusted chain being refused, a pin mismatch, a cross-origin redirect, and
  the file lane's task-carried pin are exercised through a genuine TLS
  handshake rather than a stubbed transport. Start it with
  `scripts/run-live-tls-tests.sh`: the macOS test host is a sandboxed app and
  the App Sandbox denies `bind()` to it and to anything it spawns, so the
  script stands the server up outside the sandbox. **Run it after touching
  anything under `Services/RemoteAgent/`** — a broken trust decision is
  invisible to every other test, because requests still succeed.

  In short: **compiled on every PR, executed only where a signing identity
  exists.** That file is `#if os(macOS)`, so the simulator jobs compile it out
  entirely — and a file nothing compiles can never fail. CI therefore builds
  the macOS test bundle unconditionally, which is the real guard, and runs the
  suite only when the runner has an Apple Development certificate, saying so
  loudly when it does not. A GitHub-hosted runner **cannot** execute it: the
  test host is the Conduck app itself, and its App Group / iCloud KVS /
  CloudKit entitlements cannot be granted by ad-hoc signing, so the host dies
  at launch before the first test. Running it for real needs your own signed
  machine (or a self-hosted runner). Do not read a green CI run as proof the
  trust layer still works.

Some tests skip themselves in community builds: cases that touch the live
Keychain skip on unsigned simulator builds, and the official-identity lock
tests skip under the community identity. Skips there are expected — failures
are not. Please keep the suite green. Pull requests and pushes to `main` run
both complete simulator suites in GitHub Actions, plus the macOS compile of
the live-TLS bundle.

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

## Logging and privacy

Conduck talks to a gateway that **you** run, so the things it handles are about
as private as software gets: your gateway's address, your API keys, and every
word you say to it. One rule follows from that, and it is not negotiable:

> **Never log a gateway URL or hostname, an API key or bearer token, a
> transcript, a reply, or a file name — not even at debug level.**

Hostnames count as private data here. A self-hosted gateway is usually named
after the machine it runs on (`box.local`, `mini.tail9f2c.ts.net`), so logging
it publishes the shape of someone's home network or VPN. And logs are not as
transient as they look: entries at `notice` and `error` level persist in the
system log, which means they end up inside any sysdiagnose a user later attaches
to a public bug report.

What that means in practice:

- **`print`, `debugPrint` and `dump` must sit inside `#if DEBUG` … `#endif`.**
  They write to stdout with no privacy controls at all.
- **Prefer `os.Logger` (or `WatchLog` on watchOS) and log a reduction, not the
  value.** A count, a duration, an enum case name, an HTTP status, an error
  code, or a short correlation prefix tells you what you need for debugging and
  cannot identify anyone.
- **Be careful with `privacy:`.** In `os_log` string interpolations, strings are
  redacted by default — but other types are **public** by default, and an
  explicit `privacy: .public` overrides the default either way. If you log
  something that could be identifying, annotate it `privacy: .private`.
- **Don't log an error's `localizedDescription` on a network path.** A
  certificate error embeds the server's hostname in its message text, so that
  one string is enough to leak the gateway address.
- **User-visible error text follows the same rule.** Notifications and alerts
  use fixed copy for network failures rather than passing an underlying error
  through — a lock-screen notification is readable by anyone standing nearby.

`ConduckTests/LoggingPrivacyDriftGuardTests` enforces the mechanical parts of
this by scanning the source, so CI will tell you if a change trips it. Its
failure messages explain what it found and how to fix it. It is a safety net,
not the whole rule — it cannot recognise every way a transcript might be spelled,
so the judgement is still yours.

## Style and dependencies

- Match the surrounding code. Consistency with the file you're editing beats
  any external style guide.
- **No new dependencies without prior discussion in an issue.** Every
  dependency is a long-term maintenance commitment, so additions are deliberate.
- **Adding or bumping a dependency? Update `THIRD_PARTY_NOTICES.md`.** A test
  checks that every `Package.resolved` pin is named there, but it cannot see
  third-party code or assets embedded *inside* a package (bundled JavaScript,
  vendored C++, fonts). Those live in the notices under "Components embedded via
  dependencies" and need a manual look — reproducing their notices is an
  obligation of every distributed build, not a one-time write.

## License and trademarks

Contributions are licensed under the **Apache License 2.0**, the project's code
license. The Conduck™ name and the duck-character brand artwork are trademarks
and brand assets of GigaDuck OÜ and are **not** covered by that license — which
is why this repository ships placeholder art and community builds display
"Conduck Community".
