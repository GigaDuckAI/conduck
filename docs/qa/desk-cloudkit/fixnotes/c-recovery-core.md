# c-recovery-core — C6 in full + r3a#4 / r3a#5 / r3a#7 + adjudications O-11 and O-7. All three findings CONFIRMED and fixed; nothing refuted.

Slug `c-recovery`. Sim `6C3FB33E-D89F-4D1E-9F0D-3FAC0C089228`. No commits, pushes, stash, checkout,
reset or index operations. `Identity-Override.xcconfig` untouched. Nothing under
`docs/qa/desk-cloudkit/` touched. **No `.xcstrings` opened.** No `.pbxproj` edit. No mirror triplet
touched. No file outside my ownership edited.

Files changed — six, of which one is new:

| File | Change |
|---|---|
| `Conduck/Conduck/Services/Workboard/WorkVoiceCaptureCoordinator.swift` | **C6**: `recover(_:transcript:store:)`, `WorkVoiceRecoveryOutcome`, `publishFallbackNote`; `WorkVoiceCaptureError` deleted (its copy re-homed onto `AppError`) |
| `Conduck/Conduck/Services/PendingRetryStore.swift` | additive `transcript` + `publicationState`; `PendingRetryRecord`, `PendingRetrySlot`, `PendingRetryAudioFile`, `PendingRetrySlotWriting`, `currentSlot()` |
| `Conduck/Conduck/Models/AppError.swift` | ONE new case, `workDeskWriteFailed` (78) |
| `Conduck/Conduck/Services/InAppAudioRecorder.swift` | r3a#4 (all three clauses), publication verdict + transcript at arm time, `workDeskWriteFailed`, two test seams |
| `Conduck/ConduckTests/PendingRetryDestinationTests.swift` | 3 → 6 cases (wire shape of the two new fields + the file-naming helper) |
| `Conduck/ConduckTests/WorkVoiceRecoveryTests.swift` | **NEW**, 18 cases |

`Views/Workboard/WorkboardVoiceCaptureView.swift` is mine and is **unchanged** — reason under
§Decisions 5.

---

## C6 — final signatures, VERBATIM

`Conduck/Conduck/Services/Workboard/WorkVoiceCaptureCoordinator.swift`, inside `#if !os(watchOS)`:

```swift
typealias WorkVoiceRecoveryOutcome = WorkVoiceCaptureCoordinator.WorkVoiceRecoveryOutcome

enum WorkVoiceCaptureCoordinator {

    enum WorkVoiceRecoveryOutcome: Sendable, Equatable {
        enum RetryKept: Sendable, Equatable {
            case notAWorkCapture
            case noTranscript
        }

        case attached
        case republishedAndAttached
        case fallbackNotePublished
        case retryKept(RetryKept)

        var isTerminal: Bool
    }

    @discardableResult
    static func recover(
        _ pending: PendingRetryRecord,
        transcript: String,
        store: ConversationStore = .shared
    ) async throws -> WorkVoiceRecoveryOutcome
}
```

`Conduck/Conduck/Services/PendingRetryStore.swift` (cross-platform; the Watch target does not
compile this file):

```swift
nonisolated enum PendingRetryPublicationState: String, Codable, Sendable {
    case published
    case phaseOneFailed
}

nonisolated struct PendingRetryMetadata: Codable, Sendable {
    // …the six original fields, then:
    let destination: PendingRetryDestination?
    let transcript: String?                              // NEW, optional
    let publicationState: PendingRetryPublicationState?  // NEW, optional

    init(
        id: UUID,
        createdAt: Date,
        audioFileURL: URL,
        preferredLanguage: String?,
        attemptCount: Int,
        lastErrorCode: Int?,
        destination: PendingRetryDestination? = nil,
        transcript: String? = nil,
        publicationState: PendingRetryPublicationState? = nil
    )
}

nonisolated struct PendingRetryRecord: Sendable {
    let metadata: PendingRetryMetadata
    let audio: Data

    init(metadata: PendingRetryMetadata, audio: Data)
    init(_ loaded: (audioData: Data, metadata: PendingRetryMetadata, workImageData: Data?))
}

nonisolated struct PendingRetrySlot: Sendable, Equatable {
    let id: UUID
    let destination: PendingRetryDestination
    let publicationState: PendingRetryPublicationState?
    var hasDurableRecording: Bool   // destination == .work && publicationState == .published
}

enum PendingRetryAudioFile {
    static func `extension`(for bytes: Data) -> String   // SourceAudioContainer.sniff
}

nonisolated protocol PendingRetrySlotWriting: Sendable {
    func save(audioData: Data, metadata: PendingRetryMetadata, workImageData: Data?) async throws
    @discardableResult func clear(ifCurrentID id: UUID) async -> Bool
    func currentSlot() async -> PendingRetrySlot?
}

actor PendingRetryStore: PendingRetrySlotWriting {
    func currentSlot() async -> PendingRetrySlot?   // NEW, metadata-only, mirrors hasPending()'s expiry purge
}
```

`Conduck/Conduck/Models/AppError.swift`:

```swift
case workDeskWriteFailed   // 78 — the Work desk refused a capture
// errorDescription: String(localized: "workboard.voice.error.deskWrite",
//                          defaultValue: "Work couldn’t save this recording just now.")
// isRetryable = true · maxAttempts = 1 · shouldPreserveForRetry = true · isTroubleshootable = false
// from(errorCode: 78) round-trips to itself.
```

### Notes for c-lanes (the consumer wave)

1. **The whole desk-side decision is ONE call.** A retry surface does:

```swift
switch try await WorkVoiceCaptureCoordinator.recover(
    PendingRetryRecord(pending),           // `pending` is PendingRetryStore.load()'s tuple, verbatim
    transcript: pending.metadata.transcript ?? recoveredFromSTT
) {
case let outcome where outcome.isTerminal:
    _ = await PendingRetryStore.shared.clear(ifCurrentID: pending.metadata.id)
default:
    break                                  // retryKept — the record stays armed
}
```
   Ask `isTerminal`; do NOT match the individual cases to decide whether to clear. A `throw`
   propagates out of `recover` unchanged and must reach the surface's existing `catch`, which keeps
   the record — that is the whole reason it throws rather than answering.

2. **Skip STT when the words are already parked.** `pending.metadata.transcript` is non-nil exactly
   when recognition succeeded and only the desk write failed. Attach it directly; a second provider
   call buys the same answer.

3. **`recover` publishes the fallback note itself.** No surface should keep its own
   `WorkCaptureRetryCoordinator.publish(… fallbackNoteID …)` arm — that is now duplicated logic, and
   the note it produces here is the same card under the same derived id (see §Deviations 3 for the
   one difference: its title).

4. **The screenshot stays the caller's.** `recover` does not touch
   `WorkVoiceScreenshotCoordinator`; publish the picture first, exactly as both surfaces do today.

5. **`PendingRetryAudioFile.extension(for:)` is main-actor isolated**, because
   `SourceAudioContainer.sniff` is. `ContentView.runPendingRetry` and `DictationService.retryLast`
   are already on the main actor; the nonisolated intent lane must `await` it. This closes O-12 at
   the two `conduck_retry_….m4a` sites — one line each.

6. **Nobody give the intent lane a nil publication verdict for free.** `PendingRetryGuard.arm`
   writes `publicationState: nil` today, which `recover` reads as UNKNOWN and handles
   conservatively (correct but weaker). If `ConverseIntent`'s phase-1 publication is made to report
   its outcome, pass `.published` / `.phaseOneFailed` there and the Shortcuts lane gets the same
   republish repair the in-app lane has.

---

## Findings

### r3a#4 (major) — a successful Try Again left the durable retry armed; Record Again discarded the capture before a new mic started. CONFIRMED, fixed in all three clauses.

**Verified first, by call path.** At `801b937` `finishAndUpload`'s `.attached` arm set only
`pendingWorkCapture = nil` and no `clear(ifCurrentID:)` existed anywhere in the recorder;
`startRecording()` cleared `workRecordingMaterialID` and `pendingWorkCapture` on the line after its
`guard`, four `return`s above the successful start. Both halves held exactly as written.

**Fix (a) — release on completion.** `InAppAudioRecorder.releaseDurableRetry(for:)`, called from
`finishAndUpload` once the Work capture is finished (`pendingWorkCapture == nil` after phase 2, which
covers `.attached` AND the `.recordingMissing`/`.notAudio` hand-off). It is gated on a new
`armedDurableRetryID`, so this recorder releases only the claim it took: a slot armed by a previous
process belongs to whichever surface recovers it, and clearing it from here would delete a recording
this recorder is not finishing.

**Fix (b) — release only once the replacement microphone is live.** `startRecording()` no longer
clears anything up front; `abandonPendingWorkCapture()` runs on the single line between the last
refusal path and `state = .recording(startedAt:)`. Every `return` above it now leaves the previous
capture, its card id and its durable record untouched.

**Fix (c) — an unresolved slot is not silently overwritten. Mechanism chosen: DECLINE TO ARM, in the
capture surface, never refuse-with-error in the store.** `preserveForRetry` reads
`retryLane.currentSlot()` first and returns without writing when *this* capture's recording is
already a card on the desk (`publicationState == .published`) and the incumbent's is not
(`!incumbent.hasDurableRecording`, i.e. a Chat record or a Work record whose publication failed).

*Why this and not the finding's two suggestions.* A **queue** means a second durable slot: a new
metadata key, a new `load()` contract and five reader surfaces (`ContentView`, `DictationService`,
`PendingRetryGuard`, Diagnostics, Settings' "Clear pending recording") — a redesign of a persisted
store in a parallel phase, for a collision that is rare. **Refuse-with-error** in `PendingRetryStore`
punishes the wrong party: the newcomer's bytes are dropped even when they are the only copy, and the
store cannot tell which lane can afford it. Declining to arm puts the decision where the facts are:
the recorder knows whether its own recording is already durable. The rule is one sentence — *never
evict a record whose audio exists nowhere else, when this capture's audio exists on the desk* — and
it is symmetric in intent: a Chat incumbent's audio has no other copy, and a `.phaseOneFailed` Work
incumbent's has none either. The cost is bounded and stated: the declining capture's WORDS are held
in memory (the sheet's Try Again finishes it without a second STT hop), so only a process death
costs them; its recording is never at risk.

**Regression tests** (`WorkVoiceRecoveryTests`):
- `testASuccessfulTryAgainReleasesTheDurableRetry` — the lane holds the record after the failed
  attempt and is EMPTY after the retry attaches.
- `testRecordAgainKeepsTheCaptureUntilTheReplacementMicrophoneStarts` — a refused microphone leaves
  `pendingWorkCapture`, `workRecordingMaterialID` and the armed record all intact; the successful
  start clears all three.
- `testACaptureWhoseRecordingIsSafeNeverEvictsTheOnlyCopyOfAnother` — a seeded Chat record survives a
  Work capture's STT failure, and the lane records **zero** save attempts. It carries its own
  negative control: the identical capture against an EMPTY lane does arm, so the assertion is not
  passing because nothing ever preserves.
- `testAPublicationTheDeskRefusedArmsTheSlotWhateverElseHoldsIt` — the other side: bytes that exist
  nowhere else take the slot from a Chat incumbent.

*How I know they bite* — argument from the assertion, in each case against code I can point at:
(a) the old recorder contains no `clear(ifCurrentID:)` at all, so `armed == nil` after the retry is
unreachable; (b) the old `startRecording()` nils both fields above every `return`, so
`pendingWorkCapture?.id == cardID` after a refusal is false by construction; (c) the old
`preserveForRetry` calls `save` unconditionally, so both `armed?.id == chatID` and `saves.isEmpty`
fail. (b) and (c) also require seams that do not exist on the old code.

### r3a#5 (minor, O-9) — a recovered transcript died with the process. CONFIRMED, fixed.

`PendingRetryMetadata.transcript: String?`, additive and nil-decoding, written by `preserveForRetry`
from `capture.transcript` — non-nil exactly when recognition succeeded and only the attach failed.
`updateAttemptIfCurrent` carries it forward with the rest of the record.

**Regression tests.** `WorkVoiceRecoveryTests.testAnAttachFailureParksTheWordsAndTheVerdictWithTheCapture`
(break the store between the phases ⇒ the armed metadata carries the exact words) and
`PendingRetryDestinationTests.testTheRecoveryFieldsSurviveTheirOwnRoundTrip` /
`…testAShippedWorkRecordDecodesWithNoWordsAndNoPublicationVerdict`.
*How I know they bite:* the field does not exist on the old code — the behavioural case cannot even
be spelled there, and its assertion is on a value the old record has no room for.
The CONSUMPTION half (a retry surface skipping STT when it is present) is c-lanes' wave; I persist
it and document the read.

### r3a#7 (minor, O-10) — the desk-write failure rode `AppError.unknown`. CONFIRMED, fixed.

`AppError.workDeskWriteFailed` (78) carries the existing `workboard.voice.error.deskWrite` copy
directly, so the sheet renders *"Work couldn’t save this recording just now."* rather than *"An
unexpected error occurred: …"*. `WorkVoiceCaptureError` had exactly one consumer
(`InAppAudioRecorder:809`) and is **deleted**; its string key moves into the new arm, so the key is
re-homed, not made dead. `failPendingWorkCapture` drops its `ignoringTaxonomy:` argument because
`.workDeskWriteFailed.shouldPreserveForRetry` is true — this discharges the second half of
fix2-recorder §Requests 2.

**Regression test.** `testAPublicationTheDeskRefusedArmsTheSlotWhateverElseHoldsIt` asserts
`error.errorCode == AppError.workDeskWriteFailed.errorCode`.
*How I know it bites:* on the old code the surfaced error is `.unknown`, whose code is 99 — the
assertion compares against 78 and fails outright.

### Adjudication O-11 (DECIDED) — republish only when metadata proves phase one never landed. IMPLEMENTED AS WRITTEN.

`PendingRetryMetadata.publicationState` is written by the recorder at BOTH phase-one outcomes
(`.published` when `capture.materialID != nil`, `.phaseOneFailed` when it is nil on the Work lane;
nil for Chat), and `recover` consumes it: republish-then-attach for `.phaseOneFailed`, attach-then-
fallback-note for `.published`, and the conservative attach-then-fallback-note for nil.

**Regression tests.** `testAKnownFailedPublicationIsRepublishedFromTheParkedBytesAndTakesItsWords`
(an `.audio` card comes back under the capture id with the exact bytes, mime read off the bytes) ·
`testAKnownPublishedRecordingThatIsGoneIsADeletionAndIsNotResurrected` (asserts NO `.audio` card
exists afterwards — the exact resurrection `WorkboardAudioCaptureTests:687-711` demonstrates) ·
`testALegacyRecordWhoseCardIsGoneLandsBesideItRatherThanRepublishingIt` (same for nil) ·
`testAKnownFailedPublicationThatActuallyLandedRepairsTheSameCard` (one card, not two).
Both verdict-writing paths are pinned by `…ArmsTheSlotWhateverElseHoldsIt` (`.phaseOneFailed`) and
`…ParksTheWordsAndTheVerdictWithTheCapture` (`.published`).

### Adjudication O-7 (DECIDED) — the shared attach-or-fallback coordinator. BUILT.

`recover` is that entry point, and it is behaviourally tested end to end (13 of the 18 new cases).
c-lanes routes `ContentView`, `MenuBar/DictationService` and `ConverseIntent` through it next wave;
the guard re-anchoring O-7 sequences is §Requests 2.

---

## Decisions

1. **`recover` writes the fallback note straight to the store, not through the inbox + drainer.**
   The durable copy of those words is the retry record the caller is still holding, so a refused
   write must reach that caller as a throw. Routing it through the App-Group queue would absorb the
   failure, hand back a terminal outcome, and have the caller clear the record while the words sat
   in a queue — a second durability mechanism for a case the first one already covers. It also makes
   the whole decision testable against one injected collaborator.
2. **`retryKept` has exactly two reasons, both defensive.** `notAWorkCapture` (a Chat record must not
   reach the desk at all) and `noTranscript` (recognition still owes this capture its words). Empty
   parked bytes under `.phaseOneFailed` fall through to the note-shaped answer instead of a third
   reason: there is no recording to put back, and the words still land.
3. **The eviction guard lives in the recorder, not in `PendingRetryStore.save`.** The store cannot
   see whether a caller's audio has another copy; the recorder can. Putting the rule in `save` would
   also silently change the Chat lane, which is out of scope.
4. **`armedDurableRetryID` gates both releases.** Without it, a recorder would clear a slot won by
   another capture (or another process) between the arm and the completion. `clear(ifCurrentID:)`
   would refuse anyway; the gate also spares the happy path an App-Group lock round trip.
5. **`WorkboardVoiceCaptureView` is unchanged, deliberately.** Widening its `if error.isRetryable`
   gate to `|| recorder.canRetryWorkCapture` would put a Try Again on `.noSpeechDetected`, where a
   retry re-transcribes the same silence to the same nothing — a button that cannot work, which is
   exactly what the error-surface discipline forbids. After a refused Record Again the sheet shows
   Close, and the retained capture is reachable from the home-screen retry card, whose bytes and now
   whose WORDS are parked. `ErrorSurfaceDriftGuardTests`' registry row for the file is untouched
   (7/0).
6. **No Codex consult.** The one genuinely hard call (which mechanism answers "a second destination
   must not overwrite an unresolved slot") is a product trade with a stated rule, not a technical
   unknown; I wrote the rule and its cost down instead.

## Deviations

1. **`nonisolated` on `PendingRetryMetadata` / `PendingRetryDestination`, beyond "additive fields
   only".** MEASURED reason: with the file's value types main-actor-isolated under the project's
   default isolation, the new cross-actor read (`currentSlot`, and the test double reading a parked
   record) emits *"expression is 'async' but is not marked with 'await'; this is an error in the
   Swift 6 language mode"* — i.e. C6 cannot be written without it. Adding it took
   `PendingRetryStore.swift` from **35 warning lines to 12** (`ios-bft-1.log` → `ios-bft-3.log`) and
   my test file from 2 to 0. The 12 that remain are the pre-existing `DefaultsStore` calls, at
   unchanged lines. It is one keyword, matching `WorkMaterialDraft`'s existing spelling, and changes
   no behaviour.
2. **`WorkVoiceCaptureError` deleted** rather than left beside the new `AppError` case. Two copies of
   one sentence in one lane is how a rewrite ships half. Both its only consumer and its declaration
   are files I own.
3. **The fallback note names itself from the transcript's first line** (`title(forTranscript:)`),
   where the drainer-published note carries `workboard.capture.note` = "Share note". A recovered
   voice capture is not a share-sheet capture, and the recording card names itself the same way, so a
   person sees the same name whether the words landed on the recording or beside it. **No new key**;
   the existing key is simply not used on this path. Flagged for the founder in §Requests 4.
4. **`preserveForRetry` no longer takes `ignoringTaxonomy:`** — the new `AppError` case answers for
   itself. Fewer ways to preserve, one taxonomy.

---

## Gates — what I actually ran

DerivedData under `~/Library/Caches/gigaduck-builds/c-recovery/{DerivedData,DerivedDataMac}`, every
log written there and grepped for `': error: '` and the verdict strings — never judged from tail or
exit code. **No `-configuration` passed anywhere.**

- **iOS `build-for-testing`** → `ios-bft-5.log` (final): `grep -c ': error: '` = **0**,
  `** TEST BUILD SUCCEEDED **`.
- **iOS `test-without-building`**, fourteen quoted `-only-testing:` flags → `test-4.log`:
  `** TEST EXECUTE SUCCEEDED **`,
  `Executed 179 tests, with 0 failures (0 unexpected) in 6.029 (6.119) seconds`,
  `grep -cE '\.swift:[0-9]+: error: '` = **0**.

| Class | Result |
|---|---|
| `WorkVoiceRecoveryTests` (**new**) | `Executed 18 tests, with 0 failures` |
| `WorkboardAudioCaptureTests` | `Executed 19 tests, with 0 failures` |
| `PendingRetryDestinationTests` | `Executed 6 tests, with 0 failures` (was 3) |
| `WorkboardVoiceLaneTests` | `Executed 12 tests, with 0 failures` |
| `AppErrorCodeContractTests` | `Executed 21 tests, with 0 failures` |
| `AppErrorTests` | `Executed 36 tests, with 0 failures` |
| `AppErrorTroubleshootableTests` | `Executed 2 tests, with 0 failures` |
| `DiagnosticsFocusTests` | `Executed 4 tests, with 0 failures` |
| `ErrorSurfaceDriftGuardTests` | `Executed 7 tests, with 0 failures` |
| `HeadlessRetryGuardSpanTests` | `Executed 11 tests, with 0 failures` |
| `RemoteAgentRecoveryCopyLaneTests` | `Executed 12 tests, with 0 failures` |
| `STTKeyBlackoutLaneTests` | `Executed 11 tests, with 0 failures` |
| `TempScratchSweeperTests` | `Executed 11 tests, with 0 failures` |
| `WorkCaptureDrainerTests` | `Executed 9 tests, with 0 failures` |

  Beyond the three classes the brief names I ran every class that could scope a new `AppError` case
  (four of them), the error-surface registry over the voice sheet, the lane guard over
  `InAppAudioRecorder`, the temp-file sweeper, the retry-span guard and the drainer's note branch.
  **`WorkboardVoiceLaneTests` needed nothing from c-lanes: 12/12 green as it stands** — the surfaces
  it guards are untouched this wave.
- **macOS `build -destination 'platform=macOS'`** → `mac-2.log`: 0 `error:`, `** BUILD SUCCEEDED **`,
  `Signing Identity: "Apple Development: Peter Krueck (Z4PNDLZK98)"`. **Signed through the identity
  override; no `CODE_SIGNING_ALLOWED=NO` fallback needed or used.**
- `bash scripts/check-storage-seam.sh` → `✓ storage seam intact — 794 Swift files scanned…`, exit 0.
- `git diff --check` → no output, exit 0. `git status --short` for `*.xcstrings`, `*.pbxproj`,
  `Conduck/Configs`, `docs/qa`, and all three mirror triplets → **empty**. `git diff --cached --stat`
  → **empty**.
- **Warnings: I added none.** Zero in `InAppAudioRecorder.swift`, `WorkVoiceCaptureCoordinator.swift`,
  `Models/AppError.swift`, `WorkboardVoiceCaptureView.swift` and both test files. The 12 remaining in
  `PendingRetryStore.swift` are the pre-existing main-actor `DefaultsStore` calls in `save`,
  `updateAttemptIfCurrent`, `clear`, `decodedMetadata` and `recoverNewestOrphan`, at unchanged lines
  (§Deviations 1 removed 23 others).
- **NOT run, plainly: the full iOS suite and the watch suite.** Neither is in my brief, no watch sim
  is assigned to me, and other agents are editing this tree — a full run now would report their
  in-flight state as mine. Expect **+21** on the iOS executed count from this slice
  (`WorkVoiceRecoveryTests` +18, `PendingRetryDestinationTests` +3).
  **The watch target DOES compile `Models/AppError.swift`** (it is in the `ConduckWatch Watch App`
  membership-exception list), so the new case reaches the wrist build; it compiles there — the arm is
  a plain `String(localized:)` — but I could not run the watch suite to prove the bundle still links.
  `Services/PendingRetryStore.swift`, `InAppAudioRecorder.swift` and `WorkVoiceCaptureCoordinator.swift`
  are all absent from that list, and the last two are `#if !os(watchOS)` besides.
- Build cache removed at end of task with `.claude/scripts/clean-build-cache.sh c-recovery`, so the
  logs no longer exist; re-run if you need them. No bare `rm -rf`, no `/tmp`, no throwaway tree copy
  (I made none).

---

## Catalog

**Keys I ADDED in source: NONE.**

**Keys I made DEAD: NONE.** `workboard.voice.error.deskWrite` = `Work couldn’t save this recording
just now.` is **re-homed**, not retired: it moves from
`WorkVoiceCaptureError.deskWriteFailed.errorDescription` (deleted) to
`AppError.workDeskWriteFailed`'s arm of `errorDescription(in:)`, with the same key, the same value
and the same curly apostrophe. `workboard.capture.note` = `Share note` keeps its value and its place
(the drainer's own note branch); the recovery's fallback note simply does not use it
(§Deviations 3), so the key stays live and referenced.

**No `.xcstrings` file was opened.** Nothing for the serial copy agent to splice from this slice.

**One catalog fact for whoever audits the Watch catalog:** the watch target compiles `AppError.swift`
and therefore the new arm, and `workboard.voice.error.deskWrite` has no row in the Watch catalog. The
case is unreachable on the wrist (there is no Work voice lane there), and the arm falls back to its
`defaultValue`, which is the same behaviour as the dozens of other main-catalog `AppError` keys the
watch build already compiles. No action unless the Watch catalog policy has changed.

---

## Requests

1. **Owner of `ConduckTests/AppErrorCodeContractTests.swift` — code 78 is UNPINNED, and the guard
   that exists to catch that cannot see it.** No test failed (21/21 green), so this is a coverage
   gap, not a gate blocker. `testForwardTableIsExhaustiveOverEmittedCodes` computes its expected set
   as the literal `Set((1...77).filter { $0 != 27 }).union([99])`, which is independent of the table
   **and of the enum**, so a new case with no row leaves both sides equal and the assertion passes —
   the exact event its own comment says it was written for. The fix is four literals:
   - add `("workDeskWriteFailed", .workDeskWriteFailed, 78),` to `forwardTable`, after the
     `insecureConnectionBlocked` row;
   - `(1...77)` → `(1...78)`;
   - the two `77` count literals → `78` (`"Sanity: 1...78 minus the 27 gap plus 99 = 78 distinct
     codes."`, and `forwardTable.count`).
   78 round-trips to itself (`from(errorCode: 78) == .workDeskWriteFailed`), so no
   `collapseToAPIFailure` entry is needed. I did not edit the file: it is not in my ownership and
   this is a parallel phase.
2. **c-lanes + owner of `ConduckTests/RemoteAgent/HeadlessRetryGuardSpanTests.swift` — the two
   guards O-7 sequences must move WITH the routing, in this order.** They pass today and must not be
   touched before the hoist lands.
   (a) `HeadlessRetryGuardSpanTests` re-anchors its `workPublish` needle from
   `"WorkCaptureRetryCoordinator.publish"` to `"WorkVoiceCaptureCoordinator.recover("`; the ordering
   it asserts (`transcriptCaptured = true` < the Work publication < the Work disarm < the catch gate)
   is unchanged and must stay.
   (b) `WorkboardAudioCaptureTests.testEveryRetrySurfaceRepairsTheRecordingBeforeItPublishes`
   (mine, KEPT unchanged this wave — see §Guard verdicts) then asserts the SINGLE call per surface
   instead of the attach/publish pair. Suggested replacement body, per path in
   `["Conduck/ContentView.swift", "Conduck/MenuBar/DictationService.swift"]`:
   `XCTAssertNotNil(text.range(of: "WorkVoiceCaptureCoordinator.recover("))` and
   `XCTAssertNil(text.range(of: "WorkCaptureRetryCoordinator.publish("))` — the second is what stops
   a surface keeping a private fallback arm beside the shared one.
   **Neither half is safe on its own**: until the surfaces route through `recover`, (b) fails, and
   deleting it early leaves nothing holding the two surfaces in step.
3. **Owner of `ConduckTests/AppErrorTroubleshootableTests.swift` — one row for the deny-list.**
   `.workDeskWriteFailed` is `isTroubleshootable == false` in production (Diagnostics reasons about
   connections, gateways, certificates and keys; it has nothing to say about a Core Data write —
   `.settingsLoadFailed` is on the list for the same reason). The test passes without the row (it
   only asserts the listed cases are false), but its doc calls the list "complete, exhaustive", so
   add `("workDeskWriteFailed", .workDeskWriteFailed),` to keep that claim true.
4. **Founder copy call — the recovered-note title.** A Work voice capture whose card is gone lands
   its words as a note titled by their first line, where the share-sheet path titles its note
   "Share note". No key changed either way (§Deviations 3). If you want strict parity with the share
   path instead, it is one line in `WorkVoiceCaptureCoordinator.publishFallbackNote`.
5. **Nobody undo these** — they interlock, so a later tidy-up that looks local is not:
   - `recover` stays the ONLY place the attach-or-fallback decision is made, and it keeps throwing on
     a store failure rather than answering. An outcome there is a caller clearing the only copy of
     the audio.
   - The publication verdict is written at BOTH phase-one outcomes, and `nil` keeps meaning UNKNOWN.
     Reading nil as "published" resurrects deleted cards; reading it as "failed" costs deletions.
   - `PendingRetryMetadata` stays additive-optional forever: a required field strands every recording
     already parked on a device mid-upgrade.
   - The capture is released only BELOW the successful microphone start, and only the claim this
     recorder armed is released.
   - The recorder keeps declining to arm over a record whose audio has no other copy. Moving that
     rule into `PendingRetryStore.save` makes it the store's job to know something the store cannot
     see.
   - `workboard.voice.error.deskWrite` has ONE home (`AppError.workDeskWriteFailed`), and 78 stays
     `isRetryable` + `shouldPreserveForRetry`.
6. **Founder QA (Gate 2) — three items this slice adds, none reachable by a unit test.**
   (a) Record a Work voice note in airplane mode, tap **Record Again**, then let the second capture
   succeed. The first (wordless, playable) card must still be on the desk, and the home-screen retry
   card must be offering the SECOND capture — not the first.
   (b) Record a Work voice note with airplane mode ON, wait for the failure, then **force-quit** the
   app and reopen it. The retry card must finish that capture onto the SAME card — and, if the words
   had already been recognised before the failure, without a second transcription (watch your
   provider's usage, or simply note that it completes instantly offline-to-online).
   (c) With a Work voice capture in the sheet showing a retryable error, start a CHAT voice capture
   that also fails. The Chat retry must be the one offered afterwards, and the Work card must still
   be playable on the desk.

---

## Refuted

**None.** All three findings and both adjudications held against the current tree when traced by call
path before any code changed. One qualification, stated as such rather than as a refusal: r3a#4's
third clause offers "queue, or refuse-with-error"; I implemented neither literally and chose a third
mechanism inside my ownership — the capture surface declines to arm rather than the store refusing —
with the trade written out in §Findings r3a#4 (c). The clause's requirement ("prevent a second
destination from overwriting an unresolved slot") is met in the direction that destroys something
irreplaceable; a slot holding a record whose audio is already safe on the desk is still displaceable
by a capture that needs it, deliberately.

---

## Guard verdicts

- **`WorkboardAudioCaptureTests.testEveryRetrySurfaceRepairsTheRecordingBeforeItPublishes`** (rated
  `convert` in round 2; KEPT by both fix2-recorder and fix2-voice-lanes) — **KEPT, unchanged.** Its
  conversion is exactly O-7's step (b) and is unsatisfiable until c-lanes routes the two surfaces
  through `recover`: today they still carry the literal `attachTranscript(` / `WorkCaptureRetryCoordinator.publish(`
  pair the guard orders, and re-anchoring it now would fail on my own tree while deleting the only
  thing holding `ContentView` and `DictationService` in step. The exact re-anchor, and the order it
  must happen in, is §Requests 2. Verified green against my edits (19/19).
- **`HeadlessRetryGuardSpanTests`** — not mine, not touched, 11/11 green against my edits. Same
  sequencing note.
- **I added no source-text guard.** All 18 new cases are behavioural: 13 drive `recover` against a
  real in-memory store, 5 drive the recorder's own orchestration through the existing injected
  seams. Two carry explicit negative controls (`…NeverEvictsTheOnlyCopyOfAnother`'s free-slot
  control; `testOnlyTheWrittenOutcomesReportThemselvesTerminal` as the truth table behind
  `isTerminal`).
- **Test seams added (2, both `#if CONDUCK_TESTING`, both on `InAppAudioRecorder`, both under the
  existing seam block's header):** `retryLaneForTesting: (any PendingRetrySlotWriting)?` — the real
  slot is a process-global singleton over one App-Group file every capture test in the bundle shares,
  and the claims here are about which capture this class arms, releases and refuses to evict —
  and `microphoneStartForTesting: (@MainActor () async -> Bool)?` — there is no input device on a
  simulator, and the ordering claim (the capture is released only BELOW a successful start) is
  invisible to anything that cannot make a start refuse. The second stands exactly where
  `AudioRecorder.startRecording()` does, inside the same `do`, so every path around it — the speech
  preflight, the macOS lease, the error mapping, the release, the state — is the production path.
  Neither is reachable in a release build.
- **The macOS `SpeechExclusivity` registration/claim regions are byte-for-byte untouched** (c-session
  owns them in C2): `git diff -U2` over `InAppAudioRecorder.swift` matches no line containing
  `SpeechExclusivity`, `acquireMicLease`, `recordingAuthority` or `claim(`.
