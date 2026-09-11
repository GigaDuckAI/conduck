# fix-r1-carplay — Codex R1 findings on the CarPlay "Add to Work" lane

Source: `docs/qa/work-usability/verify/codex-r1-carplay.json` (3 findings: 1 major, 2 minor).
Slice fixnote under review: `fixnotes/e-carplay.md`.
All three were verified against the code and all three are **fixed**. Nothing refuted, nothing
left open.

Files touched (ownership only):

| File | Why |
|---|---|
| `Conduck/Conduck/CarPlay/CarPlayRecordingService.swift` | S1, S2 |
| `Conduck/Conduck/CarPlay/CarPlaySceneDelegate.swift` | S3 |
| `Conduck/ConduckTests/CarPlayWorkNoteTests.swift` | three new cases (18 → 21) |
| `Conduck/Conduck/Localizable.xcstrings` | ONE new row, S3's hint wording |

---

## S1 — major — a stale capture can overwrite a retry's transcript · **FIXED**

### Verified, and the slice fixnote's reasoning is superseded

`e-carplay.md` §Open questions 3 argued the check was unnecessary because "`attachTranscript`
is idempotent by capture id (a second delivery writes nothing)". **That is false as written.**
`WorkVoiceCaptureCoordinator.applyWorkVoiceTranscript` (`WorkVoiceCaptureCoordinator.swift:553`)
only short-circuits when EVERY row already carries the same `textContent` AND `title`:

```swift
guard !transcript.isEmpty, rows.contains(where: { row in
    row.value(forKey: "textContent") as? String != transcript
        || row.value(forKey: "title") as? String != title
}) else { return (.attached, false) }
```

Differing words fall through to `row.setValue(transcript, forKey: "textContent")`. So the attach
is idempotent for IDENTICAL words only — a second delivery of DIFFERENT words is a full
overwrite. The second half of the argument ("the disarm goes through the reservation and is
refused") is true and irrelevant: refusing the disarm cannot undo a write that already
happened.

Reachability is real, not theoretical. `PendingRetryGuard.renew` is best-effort inside a
detached `Task` whose result is discarded (`CarPlayRecordingService.swift:~1443`), the speech
hop can outlast the reservation window, and once the hold lapses the phone's retry card can
claim the same capture, transcribe the same bytes and save transcript B. The CarPlay listen is
still live, so `isCurrentListen` passes — it answers session identity, not queue ownership —
and transcript A lands on top of B. `ConverseIntent.swift:617` asks exactly this question
before its own Work write, for exactly this reason.

**Open question 3 of `e-carplay.md` is therefore superseded by this fix.** Its final sentence
("if a future Work lane ever gains a non-idempotent terminal step, it has to be added") was
already the right rule; the premise that this lane had no such step was wrong.

### What changed

`CarPlayRecordingService.attachWorkNoteTranscript(_:transcript:attemptID:)` — the function now
opens with the ownership gate, then re-checks staleness across that suspension, before it
touches the desk:

```swift
guard await PendingRetryGuard.stillOwnsCapture(capture.guardToken) else {
    Self.log.info("CarPlay Work capture overtaken; transcript not attached")
    guard isCurrentListen(attemptID) else { return }
    endSession(speak: Self.workNoteAcknowledgement(for: .savedWithoutWords))
    return
}
guard isCurrentListen(attemptID) else { return }
```

Nothing is written and nothing is disarmed on the refusal: the entry belongs to whichever
surface holds it, and that surface's verdict is the one that counts (the same rule
`recordPublicationState` already follows).

**Spoken line: `.savedWithoutWords`, and no new copy.** The recording IS on the desk — phase one
published it and recorded `.published` — so `.notSaved` would be false and `.saved` would claim
an attachment this process cannot verify. "Saved to Work. Add the words on your iPhone." is
true in the only way that matters at the wheel (the note is safe; the phone is where its words
are being finished) and it is the line the whole lane already speaks for every below-the-fork
outcome.

Also rewritten: the lease-renewal comment above the renewal `Task`, which asserted the same
false idempotence claim.

### Test that pins it

`CarPlayWorkNoteTests.testTheWordsAreNotWrittenUnlessThisProcessStillHoldsTheCapture` — reads
the comment-stripped body of `attachWorkNoteTranscript` and asserts, over the slice BEFORE
`WorkVoiceCaptureCoordinator.attachTranscript(`: `stillOwnsCapture(capture.guardToken)` is
present, an `isCurrentListen(` follows it (the suspension is covered), there are ≥2 staleness
checks (both exits from the gate), and `PendingRetryGuard.disarm(` appears nowhere in the
refusal path.

### Invariants held

Durable-before-hop untouched (this is phase 2). One desk write — this fix REMOVES a second
writer, it does not add one. Nothing reaches a gateway. `disarm` is still the single site inside
`.attached` (`testTheQueueEntryIsReleasedOnlyWhenTheWordsActuallyLanded` still green). No wire
strings, no catalog keys, no model, no envelope.

**Nobody-undo compatibility.** `e-carplay.md`'s "isCurrentListen after every suspension" entry
names one deliberate exception — the disarm running BEFORE its staleness check inside
`.attached`. That is untouched: the new gate sits above the attach, not between the disarm and
its check.

---

## S2 — minor — pre-transcription exits leave temporary recordings behind · **FIXED**

### Verified

`secureWorkNote` writes `carplay_work_<id>.<ext>` and only `STTClient.transcribe` deletes it
(its own `defer`, `STTClient.swift:217`). Every exit that returns before that call leaked the
file:

* inside `secureWorkNote` — the post-arm staleness check, the publish throw, the post-publish
  staleness check (all `return nil`, all after the write);
* inside `processRecording` between the fork and the speech hop — the custom-endpoint refusal,
  the post-readiness staleness check, `.notConfigured`, `.unreadable`.

`endSession` removes `recordingURL` (the container CAF) only. The `carplay_` launch sweep does
eventually collect it, but it excludes files younger than 24 h, so it is a backstop and not
ownership. `ConverseIntent` does the explicit `try? removeItem(at: audioFileURL)` at each of its
own equivalent exits, so the lane was inconsistent with the pattern it was modelled on.

**Confirmed safe to delete** (the verifier's caution, checked before writing the fix): the
pending-retry lane keeps its OWN copy of the compressed bytes — `PendingRetryGuard.arm(audio:)`
writes the App Group payload, and the in-app retry re-materialises a fresh temp file from
`pending.audioData` (`ContentView.swift:1743-1752`), explicitly because "`metadata.audioFileURL`
was defer-deleted by the ORIGINAL transcribe". The metadata URL is bookkeeping, never read back.

### What changed

Two owners, both `defer`s, so a refusal added later inherits the cleanup instead of having to
remember it:

* `CarPlayRecordingService.secureWorkNote(compression:containerURL:attemptID:)` — `var handedOff
  = false` + `defer { if !handedOff { try? FileManager.default.removeItem(at: audioFileURL) } }`,
  armed immediately after the write; `handedOff = true` only on the line that returns the
  `WorkNoteCapture`.
* `CarPlayRecordingService.processRecording()` — `var workUploadHandedToSTT = false` + a `defer`
  removing `workCapture.audioFileURL`, armed at the fork; the flag flips where `uploadURL` is
  bound from the capture, which is after every below-the-fork refusal and immediately before
  `STTClient.shared.transcribe(` takes ownership.

The chat lane is untouched: its `carplay_upload_` file is written immediately before
`transcribe`, so it has no leak window.

### Test that pins it

`CarPlayWorkNoteTests.testTheCompressedScratchCopyIsDeletedOnEveryExitThatNeverReachesTheSpeechHop`
— asserts the removal is a `defer` (not a per-exit statement) in both functions, that the
hand-off precedes `return WorkNoteCapture(` in phase one, and that in `processRecording` the
caller's `defer` is armed before the hand-off, the hand-off precedes
`STTClient.shared.transcribe(`, and the LAST `endRefusalBelowFork(` still sits before the
hand-off (i.e. every refusal is inside the covered window).

`TempScratchSweeperTests` re-run green — the `carplay_` prefix backstop is unchanged.

---

## S3 — minor — Work microphone failures are silent without a gateway · **FIXED**

### Verified

`refreshPicker`'s no-gateway branch built `[setupHint, workRow]`, updated the sections and
returned before reaching the `oneShotStartFailureHint` renderer, which lives only in the
configured branch. The flag itself is wired correctly (`onCaptureStartFailed` sets it,
`startWorkNote` clears it at `CarPlaySceneDelegate.swift:473`), and a start failure ends the
session with `speak: nil` — so with no gateway configured the modal vanished and the picker
looked untouched. The hint row is the ONLY feedback that failure gets, and this branch became
reachable precisely because "Add to Work" made the no-gateway picker startable at all.

### What changed

`CarPlaySceneDelegate.refreshPicker()` — the no-gateway branch renders the same hint row
(`mic.slash.fill`, inert handler, inserted at index 0, above the setup row) with the retry
sentence that names the row this state actually draws.

**Row budget.** Nothing to re-price. `recentRowBudget(maximumItemCount:showsStartFailureHint:)`
already charges a row for the hint, and it is consumed only by the recent list, which this
branch does not draw: the no-gateway section is a fixed three rows at most (hint + setup +
Work), far under `CPListTemplate.maximumItemCount`. The test asserts the branch fetches no
recents, which is the reason the arithmetic does not apply here.

### New catalog row (I wrote it myself — see below)

`carplay.hint.captureStartFailed.detail` reads "Tap New voice chat to try again.", and that row
does not exist in this state. Reusing it would point a driver at a row that is not on the
screen, which is worse than silence. Reworded copy = new key, so:

| key | defaultValue | comment |
|---|---|---|
| `carplay.hint.captureStartFailed.detail.work` | `Tap Add to Work to try again.` | Detail line of the CarPlay one-shot "mic couldn't start" hint, in the picker state where no AI is set up and "Add to Work" is the only row that can start a session. Read at a glance from the driver's seat. |

Added by me to `Conduck/Conduck/Localizable.xcstrings` in the file's exact existing shape —
`extractionState: "manual"`, single `en` unit, `state: "new"` — matching its sibling
`carplay.hint.captureStartFailed.detail` byte for byte in structure, inserted in key order
between `.detail` and `.title`. This wave has no serial copy agent following it, and the brief
names me as the only writer of the catalog. The row is English-only, exactly like the two
sibling hint rows (unlike the `carplay.work.*` SPOKEN lines, which the copy pass localised —
this one is READ, not heard, and matches the hint rows it stands beside).

`carplay.*` is outside `WorkboardCopyTruthGuardTests`' `catalogPrefixes` (`workboard.`,
`pendingRetry.`), so neither direction of rule (4) applies; the guard was re-run green anyway.

**Concurrency note:** another fixer edited `Localizable.xcstrings` in the same window
(`intent.workAddFiles.error.noteTooLong`, `intent.workRecordNote.*` → `intent.workVoiceNote.*`).
Our edits are in different regions and both are present in the tree; re-verified after my last
test run that `carplay.hint.captureStartFailed.detail.work` is still there and the file still
parses as JSON with 2,294 rows.

### Test that pins it

`CarPlayWorkNoteTests.testTheMicCouldNotStartHintIsRenderedInTheNoGatewayPickerToo` — two
renders of `carplay.hint.captureStartFailed.title` in `refreshPicker`, and — scoped to the
no-gateway branch alone (the slice from `configuredRefs.isEmpty` to the `gatewayBadgeRoster(`
call that follows its `return`) — that the branch reads `oneShotStartFailureHint`, uses the
`.detail.work` key, offers `makeWorkNoteItem(`, and fetches no recents.

---

## Measured

Build: `xcodebuild build-for-testing` (iOS Simulator `04DEF4F5`, no `-configuration`,
`-derivedDataPath ~/Library/Caches/gigaduck-builds/fix-carplay/dd`) — **`** TEST BUILD
SUCCEEDED **`, 0 `: error: `**.

The FIRST build attempt failed on another fixer's in-flight file
(`Views/Workboard/PersonalWorkbenchView.swift:413` `type 'Self' has no member
'currentDeskCard'`, `:421` `cannot infer contextual base in reference to member 'syncPending'`)
— not mine, not touched, waited and retried per the brief; the retry was clean.

`test-without-building`, one invocation, exit 0:

```
CarPlayAttemptCancellationOutcomeTests   Executed  4 tests, 0 failures
CarPlayConversationLabelTests            Executed 17 tests, 0 failures
CarPlayConverseTrustVerdictTests         Executed  8 tests, 0 failures
CarPlayEmptyTurnPolicyTests              Executed 12 tests, 0 failures
CarPlayVADQuantizationTests              Executed 15 tests, 0 failures
CarPlayVoiceTimingContractTests          Executed 22 tests, 0 failures
CarPlayWorkNoteTests                     Executed 21 tests, 0 failures   ← 18 + 3 new
ErrorSurfaceDriftGuardTests              Executed  7 tests, 0 failures
TempScratchSweeperTests                  Executed 11 tests, 0 failures
WorkboardCopyTruthGuardTests             Executed 10 tests, 0 failures
─────────────────────────────────────────────────────────────────────
                                         Executed 127 tests, 0 failures (0 unexpected)
```

Second invocation (the new `log.info` line): `LoggingPrivacyDriftGuardTests` — Executed 4 tests,
0 failures.

Watch suite not run: no watch file touched. macOS build not run: both edited source files are
`#if os(iOS)`, and the shared catalog compiled clean in the iOS build.

Build cache cleaned with `.claude/scripts/clean-build-cache.sh fix-carplay`.

## Founder QA additions

Three steps to fold into `e-carplay.md`'s existing script:

1. **After step 5 (STT key removed).** With the key still removed, tap **Add to Work** and speak
   — then, while the car is still "Thinking…", tap **Retry** on the phone's retry card. Expect
   the words to land ONCE, from whichever surface got there first, and no overwrite afterwards.
   The car speaks "Saved to Work. Add the words on your iPhone." if the phone won the race.
2. **Scratch files.** After running steps 5 and 6 a few times, nothing named
   `carplay_work_*.m4a` should be accumulating in the app's temp directory (it is deleted on
   every exit now, not swept 24 h later).
3. **Step 4 (no gateway configured), new failure case.** Force a mic start failure in that state
   (deny/revoke the CarPlay Simulator's microphone mid-drive, or reproduce the `engine.start`
   FourCC failure). The picker must come back showing **Mic couldn't start** /
   *Tap Add to Work to try again.* above the setup row — not a silently unchanged picker.

## Nobody undo (adds to `e-carplay.md`'s list)

- **`stillOwnsCapture` before the attach, and the staleness re-check after it.** The attach is
  idempotent only for identical words; different words overwrite. Removing the gate re-opens a
  silent transcript overwrite that no diff and no test failure would show.
- **The two scratch-file `defer`s stay `defer`s.** The whole point is that a refusal added later
  between the fork and the speech hop inherits the cleanup. Converting either into a per-exit
  `removeItem` puts the leak one edit away.
- **The no-gateway hint uses `.detail.work`, not `.detail`.** The shared sentence names
  "New voice chat", a row that state does not draw.
