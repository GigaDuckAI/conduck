# fix2-recorder — C1 + audio#2 / #4 / #8 / #9 + test-lens t#1 / t#7. All four findings CONFIRMED and fixed; nothing refuted.

No commits/pushes/stash/checkout. `Identity-Override.xcconfig` untouched. Nothing under
`docs/qa/desk-cloudkit/` touched. **No `.xcstrings` opened.** No `.pbxproj` edit. No mirror triplet
touched. Only my four owned files plus the ONE additive probe edit contract C5 grants me.

Files changed (5):
- `Conduck/Conduck/Services/Workboard/WorkVoiceCaptureCoordinator.swift` — C1
- `Conduck/Conduck/Services/InAppAudioRecorder.swift` — audio#2, audio#4 (recorder half), audio#9, the three test seams
- `Conduck/Conduck/Views/Workboard/WorkboardVoiceCaptureView.swift` — audio#4 (button half)
- `Conduck/ConduckTests/WorkboardAudioCaptureTests.swift` — 13 cases → 19
- `Conduck/Conduck/Services/ConversationStore+Workboard.swift` — **only** the C5 probe fields (diff is 2 fields + 2 populate lines + a 3-line comment, nothing else)

---

## C1 — final signatures, verbatim

In `Conduck/Conduck/Services/Workboard/WorkVoiceCaptureCoordinator.swift`, inside `#if !os(watchOS)`:

```swift
typealias WorkVoiceAttachOutcome = WorkVoiceCaptureCoordinator.WorkVoiceAttachOutcome

enum WorkVoiceCaptureCoordinator {

    enum WorkVoiceAttachOutcome: Sendable, Equatable {
        case attached
        case recordingMissing
        case notAudio
    }

    @discardableResult
    static func publishRecording(
        captureID: UUID,
        audio: Data,
        fileExtension: String,
        mimeType: String,
        createdAt: Date = Date(),
        store: ConversationStore = .shared
    ) async throws -> WorkMaterialRecord

    @discardableResult
    static func attachTranscript(
        _ transcript: String,
        toRecording captureID: UUID,
        store: ConversationStore = .shared
    ) async throws -> WorkVoiceAttachOutcome

    static func fallbackNoteID(forCapture id: UUID) -> UUID
}
```

Also new in that file (used by the recorder to surface the failure):

```swift
enum WorkVoiceCaptureError: LocalizedError, Equatable { case deskWriteFailed }
```

**Notes for consumers.**
1. The enum is NESTED and a module-scope `typealias` re-exports it, so BOTH `WorkVoiceAttachOutcome`
   and `WorkVoiceCaptureCoordinator.WorkVoiceAttachOutcome` compile. That is why it is two
   declarations, not one.
2. `publishRecording` already threw before this wave — the C1 clause "throws instead of returning
   nil" needed no change; what changed is its DOC and every caller's duty: a throw means the
   recording is not on the desk, so keep the bytes and retry, never proceed to a text-only path.
3. `attachTranscript` throws ONLY on a store failure (`ensureLoaded`/`save`). `.recordingMissing`
   and `.notAudio` are the only outcomes that permit a fallback publish; that publish must use
   `fallbackNoteID(forCapture:)`.
4. **`fallbackNoteID` is a wire value in all but name.** UUIDv5 (SHA-1) over the compile-time
   namespace `DE5C0F00-0000-4000-A000-000000000001` and the capture's 16 bytes, version+variant
   stamped per RFC 4122 §4.3. `fallbackNoteID(forCapture: 9F2C7A10-4B31-4E52-9A77-0C1D5E6F8A03)`
   == `D08E8FB3-6044-50B7-BCFD-3E88E0770438`, pinned by test. Changing the namespace duplicates
   every offline replay.
5. **Empty transcript**: `attachTranscript("")` writes nothing and reports what the id NAMES —
   `.attached` when a recording is standing (nothing was asked for, and a fallback publication of
   silence beside a healthy card is worse than none), `.recordingMissing` / `.notAudio` otherwise.
   Production callers all guard non-empty before calling, so this is a defined edge, not a path.

---

## Findings

### audio#2 — publication and attach failures silently fell back to text. CONFIRMED, fixed.
Verified against the tree first: `InAppAudioRecorder.finishAndUpload`'s phase-1 `catch` set
`workRecordingMaterialID = nil` and continued into STT, and phase 2's `(try? …) ?? false` collapsed
a store failure into the same nil, after which `WorkboardVoiceCaptureView.handle(.success)` handed
the transcript to the composer. Both halves held exactly as written.

**Fix — `InAppAudioRecorder`, symbols `VoiceCapture`, `pendingWorkCapture`, `finishAndUpload(resuming:)`,
`failPendingWorkCapture(_:)`, `preserveForRetry(error:capture:preferredLanguage:ignoringTaxonomy:)`.**
A capture is now a value (`VoiceCapture`: id, compressed bytes, transcription-copy URL, the card id
once published, the transcript once recognized). The Work lane holds it in `pendingWorkCapture` until
a card owns the words. Publication failure and attach failure both go to `failPendingWorkCapture`,
which keeps the capture, parks the bytes durably under the capture id
(`PendingRetryStore`, `destination: .work`, `ignoringTaxonomy: true` — the STT taxonomy is an answer
about speech, and a desk write is not one), and surfaces
`AppError.unknown(WorkVoiceCaptureError.deskWriteFailed)` — retryable, so the sheet shows a retry.
Only `.recordingMissing` / `.notAudio` clear `workRecordingMaterialID`, which is the single condition
under which the sheet still hands words to the composer.

**Regression tests.** `testAPublicationFailureIsARetryableErrorRatherThanATextFallback` (publication
refused ⇒ `.failure`, `isRetryable`, the speech hop never ran, capture still retryable) and
`testAnAttachFailureHoldsTheWordsAndTheRetryFinishesTheSameCard` (card published, store broken
between the phases ⇒ `.failure`, transcript HELD on the capture, desk row still wordless; then the
retry attaches it with **no second transcription** and one card remains).
*How I know they bite:* on the old code both paths return `.success` with `workRecordingMaterialID`
nil, which is exactly the `guard case .failure` these two cases fail on. I also MEASURED that shape:
my first run used a "broken" store fixture that quietly worked, the code took the success path, and
both cases failed with those messages (`test-1.log`, 2 failures). The fixture is now a store whose
URL is a directory, and each test asserts the fixture really refuses a write before using it.

### audio#4 — "Try Again" recorded a NEW capture. CONFIRMED, fixed.
Verified: the button called `dismissError()` + `startRecording()`, and `startRecording()` cleared the
claim while `finishAndUpload` minted a fresh `UUID()` — a second card beside the first, with the
first's pending-retry entry still standing.

**Fix — two parts.** `InAppAudioRecorder.retryWorkCapture()` re-enters `finishAndUpload(resuming:)`
with the pending capture: it stops nothing, compresses nothing, publishes only if no card landed, and
transcribes only if no words were recovered. `WorkboardVoiceCaptureView.controls` now routes the
existing **Try Again** to `retryWorkCapture()` whenever `recorder.canRetryWorkCapture`, and adds a
second, secondary **Record Again** button (new source key) for a deliberately new recording. Both
stay inside the existing `if error.isRetryable` gate, so `ErrorSurfaceDriftGuardTests`' registry row
for this file still holds (verified: that suite passes).

**Regression tests.** `testRetryingAFailedTranscriptionFinishesTheSameCard` — the stub hop fails once
then succeeds; the retry re-transcribes the SAME pending bytes (`hops == 2`), the words land on the
card the first attempt published, and the desk still has exactly one material.
*How I know it bites:* on the old code there is no `retryWorkCapture` at all, and the behaviour it
replaces (`startRecording`) cannot run without a microphone — which is precisely why the old suite
could not see this bug. The assertion that discriminates is
`recorder.workRecordingMaterialID == firstCardID` together with `desk.materials.count == 1`.

### audio#8 — attach was not idempotent. CONFIRMED, fixed.
Verified: `applyWorkVoiceTranscript` created a `Date()`, rewrote every row, saved, bumped the desk and
posted a change on EVERY delivery, including one that changed nothing.

**Fix — `ConversationStore.applyWorkVoiceTranscript` (fileprivate extension in the coordinator file).**
It now returns the outcome, and after classifying the rows it returns `.attached` without a save when
the transcript is empty or every physical row already holds the requested `title` + `textContent`.
`postDidChange()` fires only when the write actually saved (the `perform` block reports it; I do not
read `context.hasChanges` off-queue).

**Regression test.** `testAnIdenticalSecondDeliveryOfTheTranscriptWritesNothing` — after a first
attach, an identical second one leaves every row's `updatedAt` and the desk's own `updatedAt`
unchanged, and a genuinely different transcript afterwards still lands.
*How I know it bites:* an argument from the assertion — the old code assigned `now` to every row and
to the desk row unconditionally, so both stamp comparisons fail by construction.

### audio#9 — a failed non-atomic write stranded a partial file. CONFIRMED, fixed.
Verified: `uploadData.write(to:)` had no `options`, its `catch` returned without removing the file,
and the four explicit `removeItem(at: audioFileURL)` calls all sat on later paths.

**Fix — `InAppAudioRecorder.finishAndUpload`.** ONE `defer { try? FileManager.default.removeItem(at:
audioFileURL) }` declared immediately after the URL, and the write is `[.atomic]`. The four scattered
removals and the nested `defer` in the Apple-engine arm are gone — one owner, every path. The URL is
now `VoiceCapture.transcriptionFileURL`, named from the capture id (still
`conduck-inapp-*`, so `TempScratchSweeperTests` is unaffected — verified, it passes).

**Regression test.** `testARefusedTranscriptionCopyStrandsNothingAndKeepsTheCard` — a directory is
created at the pending capture's `transcriptionFileURL`, so the retry's write cannot succeed; the run
fails with `.audioMissingData`, **nothing remains at that path**, and the card is untouched.
*How I know it bites:* argument from the assertion — the only code that can remove `audioFileURL` on
the write-failure path is that `defer`; the old code returned from the `catch` with nothing else
running, so the leftover would still be there. (This test is only expressible after the change,
because the old URL carried a fresh random UUID that no test could predict.)

---

## Test lens

**t#1 — the vacuous copy-vs-move test.** Confirmed: `publishRecording` takes `Data`, so the
"temporary still exists" assertion could not fail. **Deleted**, and replaced by two recorder-driven
cases built on a real seam:
- `testTranscriptionBeginsOnlyAfterTheRecordingIsADurableReadableCard` — the stub hop, standing where
  the provider stands, reads the desk back: the card is already `.audio` and
  `loadWorkMaterialPayload` already returns the exact bytes, and the transcription copy is on disk.
- `testAFailedTranscriptionCleansTheTemporaryFileAndLeavesTheCardStanding` — the same stub then
  fails; the recorder-owned temp file is gone, the card stands with its payload, the capture is still
  retryable, and `pendingWorkCapture.id == workRecordingMaterialID` (which is also the id the retry
  lane carries — the behavioural form of the deleted identity guard).

**t#7 — attach tested on one row.** Confirmed. Using C5's probe fields:
`testTheTranscriptReachesEveryPhysicalRowOfADuplicatedCard` seeds a NEWER duplicate row via
`_duplicateWorkMaterialRowForTesting(id:updatedAt:)`, attaches once, and asserts both physical rows
carry the title and the text while the logical card count stays one. Said plainly: **this one is
coverage, not a counterfactual** — the all-rows loop was already correct (audio-capture §6.5 flagged
it as unverifiable), and this test would pass on the old code too. The idempotency half of t#7 is
`testAnIdenticalSecondDeliveryOfTheTranscriptWritesNothing`, which does bite.

## Guard verdicts

- `testTheRecordingIsPublishedBeforeTheTranscriptionHop` — **converted, then DELETED.** Its subject is
  now `testTranscriptionBeginsOnlyAfterTheRecordingIsADurableReadableCard`, which reads the desk from
  inside the orchestration instead of counting tokens.
- `testOneCaptureIdentityNamesBothTheCardAndThePendingRetryRecord` — **converted, then DELETED.** Its
  subject is now the identity assertions at the end of
  `testAFailedTranscriptionCleansTheTemporaryFileAndLeavesTheCardStanding` (the card id IS the
  pending capture's id after a failed transcription). Honest limit: I assert the id the recorder
  holds, not a `PendingRetryStore` round trip — the App Group slot is a process-global singleton and
  a test that wrote to it would race every other capture test in the bundle. The write itself is one
  line (`preserveForRetry`), and `PendingRetryDestinationTests` already pins the metadata shape.
- `testEveryRetrySurfaceRepairsTheRecordingBeforeItPublishes` — **KEPT as a source guard** (rated
  "convert"). A real conversion needs spies inside `ContentView`'s SwiftUI action and
  `MenuBar/DictationService`, neither of which this suite can mount (there is no UI test target, by
  decision) and neither file is mine this wave. Kept, with its doc comment now saying why it is
  source-scoped.

---

## Test seams added (all `#if CONDUCK_TESTING`, all on `InAppAudioRecorder`)

One block with one shared header comment saying why each must exist:
`capturedAudioForTesting: Data?` (no microphone on a simulator) ·
`transcriptionHopForTesting: (@MainActor (URL) async -> Result<String, AppError>)?` (no speech
provider, and the ordering claim is invisible to anything that cannot stand between the two phases) ·
`workStoreForTesting: ConversationStore?` (the lane must not write the real store) ·
`_finishCaptureForTesting()` (the entry point, because `stopAndUpload()` refuses unless the mic is
live). The hop is consulted at ONE point — after the card exists and the transcription copy is
written — and everything downstream of it (silence check, retry preservation, state, both Work
phases) is the production path, shared through `settle(_:capture:preferredLanguage:)`.

## Decisions

1. **`finishAndUpload` stayed ONE function.** I first extracted the speech hop into its own method;
   `STTKeyBlackoutLaneTests` scopes its lane assertions to `body(ofFunction: "finishAndUpload")` and
   would have gone red. Re-entrancy is a `resuming:` parameter instead, so `STTKeyReadiness.resolve`,
   `.sttMissingAPIKey`, `.sttKeyUnreadable` and `preserveForRetry(` all still live inside that body.
   Verified: `STTKeyBlackoutLaneTests` 11/0.
2. **The desk-write failure rides `AppError.unknown`.** `AppError.swift` is not mine and the taxonomy
   has no storage case; `.unknown` is the only arm that is `isRetryable`. The message comes from
   `WorkVoiceCaptureError.deskWriteFailed`, so the sheet renders "An unexpected error occurred: Work
   couldn't save this recording just now." — honest but clumsy. See §Requests 2.
3. **`.notAudio` in the recorder is treated like `.recordingMissing`** (drop the claim, let the words
   reach the composer) rather than as a retryable error. The brief names `.recordingMissing` as the
   only composer path; `.notAudio` here means the id this capture published an `.audio` card under
   now names something else, which no amount of retrying can repair — a "Try Again" that cannot work
   is worse than the words landing where the person can see them. Stated as a deviation.
4. **`preserveForRetry` stays the ONE preservation site**, now with `ignoringTaxonomy:` rather than a
   second store write elsewhere.
5. **Durability of the WORDS is partial, and I will not overstate it.** The bytes are durable under
   the capture id (`PendingRetryStore`), and the in-flight transcript is retained in the recorder so
   the sheet's Try Again attaches without a second STT round trip. A transcript does NOT survive the
   app being killed: `PendingRetryMetadata` has no transcript field and `PendingRetryStore.swift` is
   not mine. What survives that is the recovery path — the same bytes, the same capture id, so the
   canonical retry surface re-transcribes and attaches to the same card. §Requests 1.
6. **No Codex consult.** The one hard call (which `AppError` carries a storage failure) is an
   ownership question, not a technical one.

## Deviations

- The `.unknown`-wrapped error (decision 2) instead of a dedicated `AppError` case.
- `preferredLanguage: nil` in the pending-retry record written by a desk-write failure: the settings
  read happens after publication, and moving it earlier would put another `await` between the
  compressed bytes and the card. A nil language means the retry uses the current setting.
- `VoiceCapture.transcriptionFileURL` is named from the capture id rather than a fresh UUID per
  write. One capture, one file; it is also what makes audio#9's regression test expressible.
- The sheet's two-button split is not unit-tested: mounting the view is out of scope for this suite
  (AGENTS.md: no UI test target, verifying the interface is a human step). Founder QA item below.

---

## Gates — what I actually ran

Slug `fix2-recorder`. DerivedData under `~/Library/Caches/gigaduck-builds/fix2-recorder/{DerivedData,DerivedDataMac}`,
every log written there and grepped for `': error: '` and the verdict strings — never judged from
tail or exit code. No `-configuration` passed anywhere. Sim `6C3FB33E-D89F-4D1E-9F0D-3FAC0C089228`.

- **iOS `build-for-testing`** → `ios-bft-5.log` (final): `grep -c ': error: '` = **0**,
  `** TEST BUILD SUCCEEDED **`. Zero warnings in any of my five files (all builds).
  (`ios-bft-1.log` failed first with 4 `'async' call in an autoclosure` errors, all mine, all in the
  new test file — fixed by hoisting the awaits.)
- **iOS `test-without-building`**, ten quoted `-only-testing:` flags → `test-5.log`,
  `** TEST EXECUTE SUCCEEDED **`, `Executed 103 tests, with 0 failures (0 unexpected) in 5.887 (5.909) seconds`:

| Class | Result |
|---|---|
| `ErrorSurfaceDriftGuardTests` | `Executed 7 tests, with 0 failures (0 unexpected) in 2.942 (2.944) seconds` |
| `PendingRetryDestinationTests` | `Executed 3 tests, with 0 failures (0 unexpected) in 0.006 (0.006) seconds` |
| `STTKeyBlackoutLaneTests` | `Executed 11 tests, with 0 failures (0 unexpected) in 1.678 (1.680) seconds` |
| `TempScratchSweeperTests` | `Executed 11 tests, with 0 failures (0 unexpected) in 0.370 (0.372) seconds` |
| `WorkboardAudioCaptureTests` | `Executed 19 tests, with 0 failures (0 unexpected) in 0.484 (0.488) seconds` |
| `WorkboardBlobPublicationTests` | `Executed 15 tests, with 0 failures (0 unexpected) in 0.104 (0.107) seconds` |
| `WorkboardChatCaptureTests` | `Executed 7 tests, with 0 failures (0 unexpected) in 0.059 (0.060) seconds` |
| `WorkboardDeskUpsertTests` | `Executed 11 tests, with 0 failures (0 unexpected) in 0.118 (0.121) seconds` |
| `WorkboardPersistenceTests` | `Executed 7 tests, with 0 failures (0 unexpected) in 0.038 (0.039) seconds` |
| `WorkboardVoiceLaneTests` | `Executed 12 tests, with 0 failures (0 unexpected) in 0.088 (0.090) seconds` |

  (Beyond the two the brief names, I ran every class that could scope my files: the lane guard over
  `InAppAudioRecorder`, the error-surface registry over the sheet, the temp-file sweeper, the
  pending-retry shape, the four probe consumers, and fix2-voice-lanes' own C1 consumer suite.)
- **macOS `build -destination 'platform=macOS'`** → `mac-2.log`: 0 `error:`,
  `** BUILD SUCCEEDED **`, `Signing Identity: "Apple Development: Peter Krueck (Z4PNDLZK98)"`.
  **Signed through the identity override; no `CODE_SIGNING_ALLOWED=NO` fallback needed.**
  `DictationService` (C1's other consumer) compiles against the new signature.
- `bash scripts/check-storage-seam.sh` → `✓ storage seam intact — 780 Swift files scanned…`, exit 0.
- `git diff --check` → clean, exit 0. `git status --short` for `*.xcstrings`, `*.pbxproj`,
  `Conduck/Configs`, `docs/qa` → **empty**.
- **NOT run: the full iOS suite and the watch suite.** Neither is in my brief, no watch sim is
  assigned to me, and six other agents are editing this tree — a full run now would report their
  in-flight state as mine. The watch target compiles none of my files (`InAppAudioRecorder.swift`,
  `WorkVoiceCaptureCoordinator.swift` and `WorkboardVoiceCaptureView.swift` are absent from the
  `ConduckWatch Watch App` membership-exception list; the latter two are `#if !os(watchOS)` besides).
  Expect **+6** on the iOS executed count from this file (13 → 19).
- Build cache removed at end of task with `.claude/scripts/clean-build-cache.sh fix2-recorder`, so
  the logs no longer exist; re-run if you need them.

---

## Catalog

**Keys I ADDED in source (2)** — both `String(localized:defaultValue:)` / `LocalizedStringResource`,
main app catalog, NOT spliced by me:

```
workboard.voice.recordAgain    = Record Again
workboard.voice.error.deskWrite = Work couldn’t save this recording just now.
```

- `workboard.voice.recordAgain` — `WorkboardVoiceCaptureView.controls`, the secondary button beside
  Try Again on a retryable error. It exists so Try Again can mean "finish this capture".
- `workboard.voice.error.deskWrite` — `WorkVoiceCaptureError.deskWriteFailed.errorDescription`.
  Rendered inside `AppError.unknown`'s "An unexpected error occurred: %@" wrapper (§Requests 2).
  Note the curly apostrophe `’`, matching the sheet's other copy.

**Keys I made DEAD: NONE.** I deleted no code carrying a key. `workboard.voice.tryAgain` keeps its
value and its place; only what the button DOES changed.

---

## Requests

1. **Owner of `Services/PendingRetryStore.swift` — the words are not durable, only the bytes are.**
   `PendingRetryMetadata` has no transcript field, so a transcript recovered but not yet attached
   (the desk refused the write, then the app was killed) is re-derived by re-transcribing the same
   bytes rather than restored. That is correct-but-wasteful, and it spends a second provider call.
   An optional `transcript: String?` on `PendingRetryMetadata` (additive, decodes as nil for every
   existing record, exactly like `destination`) would close it; the recorder would fill it in
   `preserveForRetry` and the retry surfaces would attach it directly.
2. **Owner of `Models/AppError.swift` — a desk-write failure has no case of its own.** It currently
   rides `.unknown`, which renders as "An unexpected error occurred: Work couldn't save this
   recording just now." A dedicated case (next free code, `isRetryable` true,
   `shouldPreserveForRetry` true, a `recoverySuggestion` naming storage) would let
   `failPendingWorkCapture` drop its `ignoringTaxonomy:` argument and would read properly on the
   sheet. I did not add it: `AppError.swift` is not mine and the catalog is frozen this phase.
3. **fix2-voice-lanes (C1 consumer) — one recovery path is still text-only, and it is not a
   contract violation, just a gap.** When a `.work` pending retry is recovered after a
   PUBLICATION failure (no card was ever written), `attachTranscript` correctly answers
   `.recordingMissing` and the fallback publishes a NOTE at `fallbackNoteID(forCapture:)` — but the
   retry record also carries the AUDIO, and the desk could have the recording back. If you want it:
   on `.recordingMissing` for a `.work` record with audio bytes, call
   `WorkVoiceCaptureCoordinator.publishRecording(captureID: pending.metadata.id, audio:
   pending.audioData, …)` first and then `attachTranscript` under that same id; both are idempotent,
   so a replay is safe. Your call — it changes what a recovered capture looks like.
4. **Nobody move the phase-1 publication after the speech hop, and nobody re-collapse
   `attachTranscript` to a Bool.** The two behavioural tests that hold the first
   (`testTranscriptionBeginsOnlyAfterTheRecordingIsADurableReadableCard`,
   `testAFailedTranscriptionCleansTheTemporaryFileAndLeavesTheCardStanding`) read the desk from
   inside the orchestration, so they cannot be satisfied by re-spelling the source; the second is
   what keeps a failed write from being mistaken for a missing card.
5. **Nobody give `finishAndUpload` a second UUID.** `VoiceCapture.id` is the capture's single
   identity — card id, pending-retry id, transcription-file name — and a second one anywhere in
   that chain is what makes recovered words unable to find the recording they came from.
6. **Docs agent — two facts are settled by code now.** (a) A Work voice capture completes only when
   a card owns the words; a desk write that fails is a retryable error and the recording's bytes are
   parked under the capture id until it succeeds. (b) A fallback publication for a capture that owns
   no recording lands under a DERIVED id (UUIDv5 of the capture id), never the capture id, because
   the desk write is idempotent by id.
7. **Founder QA (Gate 2) — three items this slice adds**, none of them reachable by a unit test:
   (a) On the Work desk, record a voice note with airplane mode ON. The sheet must offer **Try
   Again** *and* **Record Again**. Try Again must fill the words into the SAME card once you are back
   online — no second card. (b) Record Again must leave the first (wordless, playable) card standing
   and start a fresh recording that becomes a second card. (c) Simulate a storage failure if you can
   (a full device): the sheet must show a retryable error and the composer must stay EMPTY — the
   words must never appear as typed text with no card behind them.

## Refuted

**None.** All four findings held against the current tree when traced by call path; I changed code
for every one.
