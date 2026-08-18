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

Rather than rely on remembering the flag, enable the tracked hooks once per
clone:

```
git config core.hooksPath .githooks
```

That one command installs both of this repository's hooks.
`.githooks/prepare-commit-msg` adds the sign-off trailer for you. It is keyed on
the commit **author** (the person who can certify the change, and not always the
committer), skipped for merge and squash messages, and idempotent — so
`git commit -s` keeps working and never produces a duplicate line.

`.githooks/pre-commit` covers the other thing that is easy to forget: it runs
`scripts/add-spdx-headers.sh --staged`, which stamps the SPDX license tag (see
[Style and dependencies](#style-and-dependencies)) onto the source files your
commit adds or changes and re-stages them, so the tag lands in that same commit
instead of as a stray follow-up. It always prints what it stamped, and it
refuses to stamp a file that has unstaged changes sitting alongside the staged
ones — stamping there would pull those unstaged hunks into your commit.

## Building from source

You need **Xcode 26.5 or later**. The app targets iOS/iPadOS 26.5, macOS 26.5,
and watchOS 26.5.

1. Open `Conduck/Conduck.xcodeproj` in Xcode.
2. Select the **Conduck** scheme and build/run.

That's it — the community build works with **zero configuration**. It uses a
neutral build identity (`com.example.*` bundle identifiers, no signing team),
ships placeholder art, and displays as **"Conduck Community"**. Simulator runs
need no signing setup at all.

One consequence to know before you judge the app by that first run: an unsigned
simulator build cannot write the Keychain, so a gateway you add there will not
persist — the app forgets it. That is the platform, not a bug in the app. Either
run on a device with a signing identity, or launch the simulator with the
arguments in [docs/qa/qa-mode.md](docs/qa/qa-mode.md), which seed a working
gateway into an in-memory override that bypasses the Keychain entirely.

To run on your own hardware, create a gitignored
`Conduck/Configs/Identity-Override.xcconfig` next to
`Conduck/Configs/Identity.xcconfig`, setting `CONDUCK_DEVELOPMENT_TEAM` and your
own `CONDUCK_BUNDLE_ID_BASE`, `CONDUCK_IDENTITY_NAMESPACE`, `CONDUCK_GROUP_ID`
and `CONDUCK_ICLOUD_CONTAINER_ID`. A development team on its own is not enough:
the community `com.example.*` App Group, iCloud container and push capability
cannot provision under another team, so leaving those four identifiers at their
community values fails to sign whichever team you name. `CONDUCK_IDENTITY_NAMESPACE` is not a provisioning identifier, but it is changed alongside them so one build's stored identity never reads another's. The remaining variables
in `Identity.xcconfig` — the display name and the entitlements variant — can
stay as they are; the community entitlements are the ones an arbitrary team can
actually provision. `Identity.xcconfig` includes the override automatically when
the file exists, so nothing in source changes, and nothing you put there is ever
committed.

Two things that are intentional, not broken:

- The community entitlements omit CarPlay (a restricted, Apple-granted
  entitlement); the official App Store build carries it.
- The real Conduck brand art is not in this repository and is not covered by
  its license. What you may do with the name and the duck character — build for
  yourself, redistribute under a name of your own, refer to Conduck truthfully
  in your own docs — is set out in [TRADEMARKS.md](TRADEMARKS.md).

## Running tests

- In Xcode, run **Product ▸ Test** on the **Conduck** scheme — this runs the
  `ConduckTests` bundle (the main app-logic suite) on an iOS Simulator.
- watchOS-only logic has its own bundle: run the **ConduckWatchTests** scheme
  against a watchOS Simulator.
- From a terminal — over SSH, or driving a coding agent — the same two suites
  run through `xcodebuild`. Both need a **simulator UDID** rather than a device
  name, because the names change with every Xcode release; list the ones you
  actually have with `xcrun simctl list devices available` and paste the
  identifier from the parentheses. Run these from the repository root:

  ```
  xcodebuild test \
    -project Conduck/Conduck.xcodeproj \
    -scheme Conduck \
    -destination 'platform=iOS Simulator,id=<iphone-simulator-udid>'

  xcodebuild test \
    -project Conduck/Conduck.xcodeproj \
    -scheme ConduckWatchTests \
    -destination 'platform=watchOS Simulator,id=<watch-simulator-udid>'
  ```

  CI runs these same two commands against simulators it picks the same way,
  adding `-derivedDataPath` to keep the build products inside the runner's
  temporary directory — worth copying if you want yours somewhere other than
  the shared Xcode location.

  **Read the log, not the exit status.** `xcodebuild` can exit 0 on a run whose
  tests failed. Before you believe a run passed, confirm it printed
  `** TEST SUCCEEDED **` and an `Executed N tests, with 0 failures` line — and
  do not pipe the output through `-quiet`, or through a formatter that hides
  everything but errors, because those lines are the first thing they drop.
- Certificate trust has one suite that neither of those runs:
  `RemoteAgentLiveTLSTrustTests` drives a real loopback HTTPS server, so an
  untrusted chain being refused, a pin mismatch, a cross-origin redirect, and
  the file lane's task-carried pin are exercised through a genuine TLS
  handshake rather than a stubbed transport. The fixture listens on loopback,
  which App Transport Security — Apple's platform rule for app network
  traffic — exempts, so the suite proves Conduck's own trust logic and never
  ATS itself. Nothing in the test suite can prove how the app behaves against
  a remote host. Start it with
  `scripts/run-live-tls-tests.sh`: the macOS test host is a sandboxed app and
  the App Sandbox denies `bind()` to it and to anything it spawns, so the
  script stands the server up outside the sandbox. **Run it after touching
  anything under `Services/RemoteAgent/`** — a broken trust decision is
  invisible to every other test, because requests still succeed.

  In short: **compiled on every PR, executed only where a signing identity
  exists.** That file is `#if os(macOS)`, so the simulator jobs compile it out
  entirely — and a file nothing compiles can never fail. Compiling the macOS
  test bundle is therefore the real guard, and it runs wherever the macOS jobs
  run — every pull request, and every push to `main` in the public repository.
  The suite itself runs only when the runner has an Apple Development
  certificate, saying so loudly when it does not. A GitHub-hosted runner **cannot** execute it: the
  test host is the Conduck app itself, and its App Group / iCloud KVS /
  CloudKit entitlements cannot be granted by ad-hoc signing, so the host dies
  at launch before the first test. Running it for real needs your own signed
  machine (or a self-hosted runner). Do not read a green CI run as proof the
  trust layer still works.

  The script honours `CONDUCK_DERIVED_DATA` as a shell override if you want
  the build products somewhere other than the default location — export it
  before running, since no script here ever reads a `.env` file.

Some tests skip themselves in community builds: cases that touch the live
Keychain skip on unsigned simulator builds, and the official-identity lock
tests skip under the community identity. Skips there are expected — failures
are not. Please keep the suite green. Your pull request runs both complete
simulator suites in GitHub Actions, plus the macOS compile of the live-TLS
bundle and the source guards under `scripts/`. Opening the pull request is
what runs them: pushing to a branch in your own fork runs nothing here, so
run the two suites locally before you push rather than using CI to find out.
A push to `main` runs the guards, and the full matrix as well in the public
repository.

### Manual testing against real providers

Nothing in the automated suites calls a cloud speech provider or a live
gateway. To exercise those by hand you supply your own credentials, and there
is no config file to edit: voice keys are entered in the app's own settings
(Settings ▸ Voice → Providers & Keys) and stored in the Keychain, and gateway
bearer tokens go onto the simulator launch arguments described in
[docs/qa/qa-mode.md](docs/qa/qa-mode.md), which also says where to find each
token on your server.

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

## Some of this app's wire surface is shared with another repository

[`conduck-connect`](https://github.com/gigaduckai/conduck-connect) is the
companion setup tool: it walks a user through exposing their gateway over HTTPS
and then prints the pairing code this app scans. It is a separate public
repository, and three things are a contract between the two projects rather than
internal choices here:

- the **pairing payload** this app imports and can re-export;
- **gateway-URL normalisation** — that repository keeps a parity fixture list
  transcribed case by case from `SettingsViewModelGatewayValidationTests`, so
  changing an existing assertion here breaks a tool that has already shipped;
- the **request and reply shapes** the app accepts on the wire, which its
  `--check-server` diagnostic grades other people's servers against.

Adding to any of them is fine. Changing or removing one needs an issue on both
repositories first — otherwise a user ends up with a setup code the app rejects,
or a gateway a green check said would work.

Nothing in this repository's test suite can catch that drift, because nothing
here can see the other side.

## Bugs, feature requests, and security

- Bugs and feature requests: [GitHub issues](../../issues). Include the
  platform, OS version, and steps to reproduce.
- Security vulnerabilities: **never via public issues.** See
  [SECURITY.md](SECURITY.md) for how to report privately.

## Review model

Reviews are best-effort by one person. Expect a response, but not always a fast
one — please be patient, and feel free to ping a quiet PR after a couple of
weeks.

## Logging and privacy

Conduck talks to an AI that is **yours** — a gateway on a machine you keep
online, or a hosted model under your own key — so the things it handles are
about as private as software gets: the address it connects to, your API keys,
and every word you say to it. One rule follows from that, and it is not
negotiable:

> **Never log an endpoint URL or hostname, an API key or token, a transcript,
> a reply, or a file name — not even at debug level.** That covers every
> address the app is given, not only a gateway's: a hosted model endpoint, a
> custom voice endpoint and a file server are all equally the user's business.

Hostnames count as private data here. A self-hosted gateway is usually named
after the machine it runs on (`box.example.com`, `mini.tail9f2c.ts.net`), so
logging it publishes the shape of someone's home network or VPN. And logs are
not as transient as they look: entries at `notice` and `error` level persist in
the system log, which means they end up inside any sysdiagnose a user later
attaches to a public bug report.

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
  one string is enough to leak the address.
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
- **Every source file opens with a header comment.** Say what the file is for,
  and where the design is not self-evident, say why it is that way — the
  constraint you were working around, the approach you tried that did not work,
  the thing that will break if someone "simplifies" it. This is not decoration.
  The architecture document under `docs/ai-context/` deliberately does not
  describe individual files, so the header is the only place that knowledge
  lives, and the next person to open the file is the only reader who needs it.
- **Every source file also carries an SPDX license tag, above that header
  comment.** `// SPDX-License-Identifier: Apache-2.0` is the first line of a
  `.swift` or `.js` file; in a `.py` or `.sh` script the `#` form goes on the
  line straight after the shebang, which has to stay first for the kernel to
  honour it. A blank line follows the tag either way. There is no copyright line
  and no year — the one tag is the whole license header, and
  `scripts/add-spdx-headers.sh` explains why. Run that script to stamp anything
  missing one; re-running it changes nothing, and the `.githooks/pre-commit`
  hook runs it for you at commit time. This is not optional politeness: it is
  the first thing CI checks, on a cheap Linux runner that gates every other job,
  so a file without the tag fails the whole run before a build even starts.
- **No new dependencies without prior discussion in an issue.** Every
  dependency is a long-term maintenance commitment, so additions are deliberate.
- **Adding or bumping a dependency? Update `THIRD_PARTY_NOTICES.md` — and copy
  it verbatim to `Conduck/Conduck/Resources/Legal/`.** The repository root holds
  the canonical text, the app displays the bundled copy, and
  `LegalNoticesResourceTests` fails the build if the two are not byte-identical.
  The same holds for `LICENSE` and `NOTICE`, which the bundle carries under a
  `.txt` extension because the app looks them up by name and extension; the contents still have to
  match to the byte. From the repository root:

  ```
  cp THIRD_PARTY_NOTICES.md Conduck/Conduck/Resources/Legal/THIRD_PARTY_NOTICES.md
  cp LICENSE Conduck/Conduck/Resources/Legal/LICENSE.txt
  cp NOTICE Conduck/Conduck/Resources/Legal/NOTICE.txt
  ```

  A test also checks that every `Package.resolved` pin is named in the notices,
  but it cannot see third-party code or assets embedded *inside* a package
  (bundled JavaScript, vendored C++, fonts). Those live in the notices under
  "Components embedded via dependencies" and need a manual look — reproducing
  their notices is an obligation of every distributed build, not a one-time
  write.

## Documentation

Two documents under `docs/ai-context/` describe the project as a whole:
[`spec.md`](docs/ai-context/spec.md) records the decisions behind the
architecture, and [`project-structure.md`](docs/ai-context/project-structure.md)
maps the folders and build targets. Both are written to be read by people and by
AI coding agents, and both are deliberately small.

Read the [glossary](README.md#the-words-this-project-uses) before either of
them. Several words here are narrower than their industry sense and *gateway*
is nearly the opposite one, so a contributor who skips it will consistently
misread which layer a decision is about.

Keeping them small is the point, so there are two rules about adding to them:

- **A sentence belongs in `spec.md` only if it cannot be confirmed by opening
  one file.** If a reader could check it by reading the code, it belongs in that
  file's header comment instead. Type inventories, method names, UI labels,
  provider model identifiers, and walkthroughs of how something is implemented
  all fail this test.
- **Never write a literal number — name the constant that owns it.** Write
  `Constants.maxCustomGateways`, not the value. A number written into prose goes
  wrong silently the moment someone changes it; a symbol name stays findable and
  stays true.

Most pull requests should not touch either document. Update `spec.md` when a
decision changes — something that was rejected is now the design, or a boundary
moved. Update `project-structure.md` when a folder or a build target appears or
disappears; CI checks that every folder containing Swift source is listed.

## License and trademarks

Contributions are licensed under the **Apache License 2.0**, the project's code
license. The Conduck™ name and the duck-character brand artwork are trademarks
and brand assets of GigaDuck OÜ and are **not** covered by that license — which
is why this repository ships placeholder art and community builds display
"Conduck Community".

[TRADEMARKS.md](TRADEMARKS.md) is the policy itself, and the answer to every
question about that carve-out: what you may do with the placeholder art, why
building for yourself needs no permission at all, and what a build you hand to
other people has to be renamed to.
