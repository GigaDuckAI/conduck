# fix-r3-shortcuts — Codex R3 finding on the Shortcuts slice

Findings file: `verify/codex-r3-shortcuts.json` — one open finding, R1 (minor). Round-1
re-reads R1 and R2 came back `closed` and need nothing.

---

## R1 (minor) — the snapshot copy enforced no byte limit · FIXED

**Verified, not refuted.** `perform()` admitted a set on the sizes its sources *declared*,
then `snapshot(_:into:)` read to EOF and wrote every chunk with no ceiling in the loop. The
measured refusal ran only after the copy finished. A source replaced between the stat and the
copy — an editor, a file provider, a sync client owns that file — was therefore written whole
before anything measured it: with disk to spare it eventually said `fileTooLarge`, and
without it consumed the free space and said `unreadableFile`. Fixed-size reads bound MEMORY,
never bytes written.

**What changed** — `Conduck/Conduck/Intents/AddFilesToWorkIntent.swift` only:

- **`snapshot(_:into:fileCeiling:setBudget:)`** — two new parameters, defaulted to
  `WorkCaptureEnvelope.maximumFileBytes` / `.maximumEnvelopeBytes`, so every existing call
  site keeps the production limits without naming them. Inside the loop, each chunk's
  `projected = byteCount + chunk.count` is checked BEFORE the write: over `fileCeiling` →
  `.fileTooLarge(name:)`, over `setBudget` → `.setTooLarge`. Both are the refusals preflight
  already raises; no catalog row added.
- **Immediate reclaim** — a `staged` flag and the existing `defer`: on any exit that is not a
  completed snapshot, the destination is removed (`FileManager.removeItem`) inside this
  process's own scratch leaf. Abandoned partials never wait for `perform()`'s root cleanup or
  for `TempScratchSweeper`.
- **`snapshot(_:bytes:into:fileCeiling:setBudget:)`** — the same two parameters, asked once
  before the single write. Nothing can have grown here, but an EARLIER file in the set can
  have, which makes the remaining budget smaller than this one's own size.
- **`perform()`** — `var remainingSetBytes = WorkCaptureEnvelope.maximumEnvelopeBytes`,
  passed as `setBudget:` to each staging call and spent down by
  `max(0, staged.input.byteCount)` after each. Without the decrement the aggregate binds
  nothing: twenty-four files would each be handed the whole envelope ceiling.

**The bound this buys.** Peak written per file is now the per-file ceiling plus at most one
256 KB chunk, and per set the envelope ceiling plus one chunk — regardless of what the
sources actually hold. The documented ~1 GB peak of the snapshot stage is again a ceiling
rather than a hope.

**Untouched, deliberately.** The identity derivation (`captureIdentity`, the UUIDv5 shape,
the namespace, order-sensitivity, the `name ‖ 0x00 ‖ bigEndian(size) ‖ digest` layout), the
publish ordering, the `unreadableFile` refusal and its wording, the launch hook,
`WorkCaptureInbox`, `WorkCaptureDrainer`, `AppShortcuts.swift`, `RecordWorkNoteIntent.swift`
and `AppDelegate.swift`. No wire string, no envelope schema, no `.xcdatamodeld`, no catalog
row. The post-copy `refusal(for: inputs)` stays where it was — it is now a second net rather
than the only one.

**Tests that pin it** — `Conduck/ConduckTests/WorkShortcutIntentsTests.swift`:

- `testASourceThatOutgrewItsDeclaredSizeIsRefusedMidCopyAndLeavesNothingStaged` — a 768 KB
  source declaring 5 bytes: `refusal(for:)` passes (the premise), the snapshot under a
  300 KB ceiling throws `.fileTooLarge(name: "video.mov")`, and the destination does not
  exist afterwards. The ceiling sits ABOVE one 256 KB chunk on purpose, so the abort happens
  part way through the copy — the half a result-time check cannot see.
- `testASnapshotThatWouldExhaustTheRemainingSetBudgetIsRefusedAsASet` — the same source under
  a 300 KB `setBudget` throws `.setTooLarge` and stages nothing; the same source under an
  exact-fit 768 KB budget stages whole, so the budget is spendable to its last byte and a
  full set is not a false refusal.
- `testTheStagingLoopSpendsTheSetBudgetDownFileByFile` — source-shaped over `perform()`'s
  body: the budget exists, travels as `setBudget:`, and is decremented by what each snapshot
  actually held. Source-shaped because that loop needs an intent process, an App Group and a
  filesystem to reach.

The ceiling is INJECTED rather than reached: the production limit is 256 MB and no unit test
should stage that. The parameters carry the real limits as defaults, so the injection cannot
weaken production.

Red before the fix in the compile sense — `fileCeiling:` and `setBudget:` did not exist, and
the source guard's three assertions had nothing to match.

## Measured

Slug `fix3-shortcuts`, all under `~/Library/Caches/gigaduck-builds/fix3-shortcuts/`, no
`-configuration` flag, cleaned with `.claude/scripts/clean-build-cache.sh fix3-shortcuts`.

| Run | Result |
|---|---|
| iOS `build-for-testing` (sim `04DEF4F5`) | exit 0, **0** `: error: ` |
| macOS `build` (`platform=macOS`) | exit 0, **0** `: error: ` |
| `WorkShortcutIntentsTests` | Executed 30, **0** failures |
| `WorkCaptureFileCaptureTests` | Executed 10, **0** failures |
| `WorkCaptureInboxTests` | Executed 29, **0** failures |
| `TempScratchSweeperTests` | Executed 11, **0** failures |

All four `Test Suite … started` lines present in `test.log` (80 tests total), so no filter
passed vacuously.

## Open items

1. The snapshot still doubles peak scratch for a URL-backed set (fix-r2-shortcuts open item
   1, unchanged) — but that peak is now BOUNDED by the ceilings rather than by the source's
   real size.
2. A source that shrinks after preflight is still fine: it stages what is there and the
   envelope carries the measured size.

## Founder QA (delta only)

1. Run the shortcut over an ordinary set of files. Expected: unchanged — cards land, one per
   file, nothing new in the refusals.
2. Point a shortcut at a very large file (over 256 MB). Expected: `"x" is too big to keep in
   Work.`, nothing on the desk, and no leftover copy in the app's temp — the same sentence as
   before, reached without writing the file first.
3. A set that adds up past 512 MB. Expected: `Those files are too big to add at once. Add
   them in smaller batches.`

---

## MAC-R1-P1-A — "Siri and Shortcuts can start Work captures without a deliberate press" · REFUTED

Routed here by the Mac menu-bar fixer because every file it names is this slice's. **No code
changed.** The finding is `verify/codex-r1-mac-work-destination.md`'s first P1 re-raised
verbatim — same four file:line anchors, same "smallest fix" wording (stop intent-driven
navigation at an unarmed surface; reject `.work` in `ConverseIntent`). It was never written
down as adjudicated, which is why it came back; that is what this section fixes.

**The boundary it tests against is not the boundary this product states.**

- `docs/ai-context/spec.md:428` — "Work is one desk per person… **no code path leads from it
  to a gateway**." The invariant is about what leaves Work, not about what may put something
  on it. `spec.md:434` documents the Shortcut lanes as shipped behaviour.
- `design/watch-work-destination.md:39` states it exactly: "**no implicit or hands-free
  trigger REROUTES to Work** — the only hands-free door to the desk is the one that names
  Work in its own phrase," and `:202` records that wording as accepted.
- Codex's own design-round verifier already reached the same answer —
  `verify/codex-design-watch-r1.md:55`: "the accurate boundary is **no implicit headless
  rerouting to Work**, not 'no hands-free trigger can reach Work.'" The round-1 finding's own
  text agrees, calling these routes ones that "disprove the hard hands-free boundary" — it
  was an argument for correcting the DOC, and the doc was corrected.

**The phrase is the press.** "Record a note to Work" names the destination and the act.
`RecordWorkNoteIntent` is `supportedModes = [.foreground]` and owns no recorder: it sets the
route and reveals the desk. What the person then sees is a sheet with a level meter, elapsed
time, a Cancel button and `interactiveDismissDisabled` only while busy. A capture nobody can
see is the thing the boundary is about, and this is not one.

**Making the auto-start conditional on the route would harm the in-app button.**
`WorkboardCaptureCanvas.swift:538` — the "Add by voice" mic button — sets `showsVoiceCapture
= true`, the identical state `consumeVoiceCaptureLaunchRoute()` sets at `:222`. The `.task`
auto-start at `WorkboardVoiceCaptureView.swift:60-66` therefore belongs to the MIC BUTTON
first: a person who taps a microphone has already pressed the record button. Arming only the
intent's presentation inverts that — the spoken request would record and the deliberate tap
would need a second tap.

**`ConverseIntent(destination: .work)` opens no microphone.** Its `audioFile: IntentFile`
(`:169-174`) is audio the shortcut ALREADY holds; the intent receives a file exactly as
`AddFilesToWorkIntent` does, and `WorkVoiceCaptureCoordinator.publishRecording` writes it to
the desk. Rejecting `.work` there deletes a shipped, publicly documented feature — `README.md:55`
advertises both Shortcuts actions and CarPlay's "one spoken note, hands free" onto Work — to
enforce a rule the spec does not make.

**What would change the answer:** a founder decision that the desk may only be written by a
surface the person is looking at when they trigger it. That is a product call, not a defect,
and it would retire the CarPlay Work row and the `.work` destination along with it.
