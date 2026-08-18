# Working in this repository

This repository is the whole Conduck app for Apple platforms — iPhone, iPad,
Mac, Apple Watch and CarPlay — and no functional code is held back — what is not here is the real brand artwork, the signing identity, and Apple's per-team CarPlay entitlement, none of which is code. It is
a native client for an AI the user brings: a gateway they run themselves, or a
hosted model under their own key. There is no server of ours anywhere in it.

This file is a router. It tells you what to read, how to run the tests, and what
a passing run does not prove. Everything else is in the documents it points at,
and those are the copy of record.

## Read these, in this order

1. [`README.md`](README.md), and inside it the
   [glossary](README.md#the-words-this-project-uses) — not optional. Several
   words here are narrower than their industry sense and *gateway* is nearly
   the opposite one, so skipping it means consistently misreading which layer a
   decision is about.
2. [`docs/ai-context/spec.md`](docs/ai-context/spec.md) — the decisions, the
   boundaries, and the alternatives that were deliberately rejected. It is the
   part the code cannot tell you, and it is short enough to read whole.
3. [`docs/ai-context/project-structure.md`](docs/ai-context/project-structure.md)
   — the folder and build-target map, ending in a "Where to start" table that
   takes a kind of change to a directory.
4. [`CONTRIBUTING.md`](CONTRIBUTING.md) — what a change has to satisfy before it
   can land: the licence header, the sign-off, the header comment every source
   file carries, the logging rule, and the two prohibitions on adding to the
   documents above.

Then read the file you are about to change, and its tests. **Every source file
opens with a header comment** saying what it is for and, where the design is not
self-evident, why it is that way — the constraint being worked around, the
approach that did not work, the thing that breaks if someone simplifies it. The
two architecture documents deliberately do not describe individual files, so
that header is where the detail lives, and the test suite is the other half of
it.

## Running the tests

Two simulator suites, both run from the repository root.
[`CONTRIBUTING.md`](CONTRIBUTING.md#running-tests) covers the same ground for a
human contributor and adds the one suite these commands do not reach; the
commands themselves are repeated here so that running the tests never costs you
a second file.

Pick real simulators first — device names change with every Xcode release, so
drive the destinations by UDID rather than by name:

```bash
xcrun simctl list devices available
```

Take an iPhone UDID and an Apple Watch UDID out of that listing, then:

```bash
xcodebuild test \
  -project Conduck/Conduck.xcodeproj \
  -scheme Conduck \
  -destination 'platform=iOS Simulator,id=<iphone-simulator-udid>'
```

```bash
xcodebuild test \
  -project Conduck/Conduck.xcodeproj \
  -scheme ConduckWatchTests \
  -destination 'platform=watchOS Simulator,id=<watch-simulator-udid>'
```

The main suite belongs on an iOS Simulator and nowhere else; `spec.md` explains
why running it against macOS kills the test host intermittently, and takes a
different suite down each time.

**Read the log, not the exit status.** `xcodebuild` can exit 0 on a run whose
tests did not pass, or did not run at all. The two strings that settle it are
`** TEST SUCCEEDED **` and `Executed N tests, with 0 failures` — if neither is
in the output, you do not have a passing run whatever the shell reported. Do not
add `-quiet`: it drops the `Executed …` line, which is the one carrying the
count. Some cases skip themselves on an unsigned simulator build; skips are
expected, failures are not.

The guard scripts in [`scripts/`](scripts/) — the ones the `guards` job of
[`.github/workflows/apple-tests.yml`](.github/workflows/apple-tests.yml) runs
first — need no Xcode and finish in seconds. Run them before you propose a
change; they fail on things a reviewer should never have to notice.

## What a green run does not prove

- **Both bundles are unit tests.** There is no UI-test target, by decision.
  Verifying the interface is a human step, so hand back a list of what to open
  and what should now be true rather than claiming a screen works.
- **An unsigned simulator build cannot write the Keychain.** A gateway added
  there does not persist, so anything downstream of a stored credential cannot
  be exercised that way — see [`docs/qa/qa-mode.md`](docs/qa/qa-mode.md) for the
  launch arguments that stand in.
- **The certificate-trust suite needs a real signing identity.** It is
  `#if os(macOS)`, so the simulator jobs compile it out entirely; start it with
  [`scripts/run-live-tls-tests.sh`](scripts/run-live-tls-tests.sh) on a machine
  that has one. `CONTRIBUTING.md` says what that suite covers and what it
  cannot.
- **A new file in `ConduckWatchTests` compiles nowhere until it is added to that
  target by hand**, and the suite stays green having silently skipped it.
  `project-structure.md` describes that footgun and the shared-source list
  behind it.

`spec.md` closes with a section on what nothing checks. Read it before writing
"verified".

## Before you hand work back

- Every source file you add carries an SPDX licence tag — `// SPDX-License-Identifier:
  Apache-2.0` as the first line of a `.swift` or `.js` file, the `#` form immediately
  after the shebang in a `.py` or `.sh` script, since the shebang has to stay first —
  and a header comment under it. `scripts/add-spdx-headers.sh` stamps the tag; the
  header comment is yours to write.
- Every commit carries a `Signed-off-by` trailer (`git commit -s`).
  `git config core.hooksPath .githooks` adds it for you.
- Most changes should touch neither architecture document. When one genuinely
  has to, the two rules governing what may be added are stated at the top of
  `spec.md` and again in `CONTRIBUTING.md`. Both are prohibitions rather than
  prompts: they exist to stop writing. Asked whether the docs need updating, the
  wrong answer is a new paragraph.
