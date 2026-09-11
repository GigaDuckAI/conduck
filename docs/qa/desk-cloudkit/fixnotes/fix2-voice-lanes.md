# fix2-voice-lanes — audio#1 + audio#3. BOTH CONFIRMED, both fixed. Green on both platforms.

Slug `fix2-lanes`. Sim `5C851D88-959C-445E-ACC8-A4C6ADB2876C`. No commits/pushes/stash/checkout.
`Identity-Override.xcconfig` untouched. Nothing under `docs/qa/desk-cloudkit/` touched. **No
`.xcstrings` opened** — I added zero keys. No `.pbxproj` edit (both new files are in synchronized
groups and compiled). No mirror triplet touched.

Files changed — FIVE, of which two are new:

| File | Change |
|---|---|
| `Conduck/Conduck/Intents/ConverseIntent.swift` | +151/−17 — the Work branch's two phases (audio#1) |
| `Conduck/Conduck/ContentView.swift` | +54/−28 — the Work retry path only (audio#3) |
| `Conduck/Conduck/MenuBar/DictationService.swift` | +50/−24 — the Work retry path only (audio#3) |
| `Conduck/Conduck/Services/Workboard/WorkVoiceScreenshotCoordinator.swift` | **NEW**, 117 lines — the screenshot's own identity + publication (deviation §D1) |
| `Conduck/ConduckTests/WorkboardVoiceLaneTests.swift` | **NEW**, 12 cases |

---

## 1. audio#1 — the Shortcuts / Action-Button Work lane discarded its audio. CONFIRMED, FIXED.

**Verified before changing anything.** At `223ac35` the Work branch of `ConverseIntent.perform()`
called `WorkCaptureRetryCoordinator.publish(transcript:rawImageData:captureID:createdAt:)` and
nothing else — no `publishRecording`, no `.audio` draft anywhere on the path. Traced: the intent
never compressed either (`originalAudioData` went straight to the temp file), so the lane had no
bytes it kept and no card to keep them on. The finding holds exactly as written.

### The lane as built (file : symbol)

| Step | Where | What happens |
|---|---|---|
| bytes | `perform()` → `Self.compressForWork(_:)` | ONE compression pass, **Work only**. Its output is the card's payload, the STT upload and the preserved retry copy — one capture, one payload |
| identity | `perform()` — `let captureID = UUID()` | replaces the anonymous `id: UUID()` in `PendingRetryMetadata`; capture id == card id == retry-record id |
| arm | `PendingRetryGuard.arm(audio: uploadData, …)` | preserves the SAME bytes the card holds |
| **PHASE 1** | `perform()` → `WorkVoiceCaptureCoordinator.publishRecording(…)`, gated `destination == .work`, immediately after `arm` and **above** the key verdict | the `.audio` card exists before the key is read and before the upload |
| temp file | unchanged in shape | now named with `format.fileExtension` and written from `uploadData` |
| screenshot | `perform()` → `WorkVoiceScreenshotCoordinator.publish(…)`, first thing in the post-STT Work branch | its own card at a DERIVED id |
| **PHASE 2** | `perform()` → `WorkVoiceCaptureCoordinator.attachTranscript(…)` | `.attached` → done; `.recordingMissing`/`.notAudio` → note under `fallbackNoteID(forCapture:)` |
| disarm | unchanged position | still the second of exactly three, still above the catch chain's gate |

**Phase 1 sits ABOVE the key pre-flight, deliberately.** A key that cannot be read is a
transcription failure, and plan §D's claim is that such a failure leaves a playable card. Same
ordering `InAppAudioRecorder` uses (publish at `:335`, resolve the key at `:410`).

**Phase 1 failure is swallowed (logged, Release-visible, fact-only).** Transcription has not been
attempted at that point, and abandoning it to report a storage error trades the words for the card.
`attachTranscript` answers `.recordingMissing` for that state and the note-shaped fallback carries
the words. Net: strictly better than `223ac35`, where this lane kept no audio at all in ANY case.
This is the one place I did NOT follow fix2-recorder's stronger in-app stance (a publication failure
is a retryable error there) — see §5.1 for why it would cost a round trip and gain nothing here.

**Chat is byte-for-byte unchanged.** The compression is inside `if destination == .work { … } else {
uploadData = originalAudioData; audioFileExtension = "m4a" }`, so a Chat capture writes the
Shortcut's own recording to a `.m4a` temp file exactly as before, and nothing on that branch touches
Workboard persistence. `testTheChatBranchKeepsTheShortcutsOwnRecordingBytes` reads both arms of that
`if` through `RefusalLaneSource.branches(ofIf:)` and asserts it.

### The screenshot's identity — and why the finding UNDERSTATES the collision

`WorkCaptureInbox.publishAppCapture` names its image entry after the envelope it rides
(`WorkCaptureInbox.swift:323`, `id: id`), so publishing the screenshot under the capture id put it at
the recording's id. **I measured what that does** rather than assuming the card is merely dropped:
`publishWorkMaterial`'s repair branch treats bytes arriving at an existing `.syncedPayload` row as a
repair — it stages them, inserts a blob, calls `deleteSupersededBlobRows` and repoints every physical
row. So the screenshot would have **replaced the recording's payload**, leaving a card that says
`kind == .audio` and plays a JPEG.
`testAScreenshotPublishedAtTheCaptureIdWouldReplaceTheRecordingsBytes` asserts that measured
outcome, so the counterfactual is on record rather than argued.

The screenshot therefore gets `WorkVoiceScreenshotCoordinator.materialID(forCapture:)` — UUIDv5 over
its **own** namespace (`5C7E0000-…`), the same shape as C1's `fallbackNoteID` in its namespace
(`DE5C0F00-…`). Three identities per capture, none able to name another.

---

## 2. audio#3 — a thrown attach cleared the retry. CONFIRMED, FIXED, on both surfaces.

**Verified by tracing the whole path**, not by reading the finding: `attachTranscript` is
`async throws` and `applyWorkVoiceTranscript` does `try await ensureLoaded()` +
`try context.fetch/save`, so a transient Core Data failure genuinely throws → `try?` collapsed it to
`attached = false` → `WorkCaptureRetryCoordinator.publish(captureID: pending.metadata.id)` → envelope
id == capture id, no entries, so `WorkCaptureDrainer.noteMaterialID` returns the envelope id → the
drainer upserts a `.note` draft at the id the `.audio` card already holds → `publishWorkMaterial`
carries no bytes, so no repair, no save, and the existing card is returned → `confirmDurablyImported`
finds the id on the desk and the note is not payload-bearing, so the barrier passes → `acknowledge`
deletes the envelope → `PendingRetryStore.clear` deletes the only retry audio. **The words are
written nowhere and the recording they came from is deleted.** Both halves of the finding hold.

Both surfaces now:

```swift
if let screenshot = pending.workImageData { _ = try await WorkVoiceScreenshotCoordinator.publish(…) }
switch try await WorkVoiceCaptureCoordinator.attachTranscript(<words>, toRecording: pending.metadata.id) {
case .attached: break
case .recordingMissing, .notAudio:
    _ = try await WorkCaptureRetryCoordinator.publish(
        transcript: <words>, rawImageData: nil,
        captureID: WorkVoiceCaptureCoordinator.fallbackNoteID(forCapture: pending.metadata.id),
        createdAt: pending.metadata.createdAt)
}
```

**No new error plumbing was needed and none was added.** Both throws land in the enclosing `do`'s
existing catch, which keeps the retry and surfaces the failure:
- `ContentView.runPendingRetry` — a store error is not an `AppError`, so it reaches the generic
  `catch`, which presents `workboard.capture.retry.voice.message` ("Couldn't add this recording to
  Work. Try again.") and never touches `hasPendingRetry`. `clear(ifCurrentID:)` sits BELOW the
  switch inside the same `do`, so the throw skips it.
- `DictationService.retryLast` — same generic `catch`, `state = .error(isRetryable: true)`, and the
  same clear-below-the-switch shape. (Were the error an `AppError`, that arm only calls
  `updateAttemptIfCurrent` — it never clears either.)

**The screenshot moved off the fallback envelope.** Passing `rawImageData: nil` is deliberate: the
picture now has an identity of its own on every surface, so routing it through the fallback envelope
would land it at `fallbackNoteID` on a retry and at `materialID(forCapture:)` in the intent — two
cards for one screenshot. Publishing it first, always, at one derived id, is idempotent in both
halves (`publishAppCapture` refuses an id it already holds; the desk write answers a replayed
material with the card standing there), which `testAScreenshotPublishedTwiceRepairsTheSameCard`
pins.

---

## 3. What the new coordinator is, and why the screenshot rides the queue

`WorkVoiceScreenshotCoordinator` (`Services/Workboard/`, `#if !os(watchOS)`) has two members:
`materialID(forCapture:)` and `publish(_:forCapture:createdAt:inbox:store:sourceDevice:normalize:)`.

Publication goes through `WorkCaptureInbox.publishAppCapture(note: "", imageData: …)` + a
`WorkCaptureDrainer` drain, for the reason `WorkCaptureRetryCoordinator` does: the published envelope
is the durable boundary, so a Core Data failure leaves the bytes queued for the foreground observer
instead of losing them, and the card produced is byte-for-byte the one a shared image produces
(kind, title, storage lane, thumbnail policy) rather than a second mapping I would have had to invent
against the store's staging semantics. An empty note is valid — `validateForPublication` refuses only
an envelope with neither note nor entry — and the drainer's note branch is gated on a non-empty note,
so nothing note-shaped is created.

`inbox`, `store`, `sourceDevice` and `normalize` are injectable (defaults through `nil`, because a
default-argument expression is evaluated in the CALLER's isolation and the intent lane is
nonisolated). `normalize` is what makes the publication behaviourally testable without a real image
encoder; production passes `ImageProcessor.shared.process(_:).jpegData` and keeps the existing
best-effort stance — a picture that will not decode publishes nothing and throws nothing, exactly as
`WorkCaptureRetryCoordinator` already behaved.

---

## 4. The 12 new cases, and how each proves the old code wrong

`ConduckTests/WorkboardVoiceLaneTests.swift`.

**Behavioural (in-memory `ConversationStore`, injected inbox rooted in a temp dir):**
1. `testTheScreenshotTakesAnIdentityOfItsOwn` — derived id ≠ capture id, ≠ `fallbackNoteID(capture)`,
   deterministic across calls, different per capture.
2. `testTheScreenshotBecomesASecondCardBesideTheRecording` — end to end through the real inbox +
   drainer: two cards, the audio card still `.audio` with the recording's bytes read back exactly,
   the image card at `materialID(forCapture:)` with the picture's bytes.
3. `testAScreenshotPublishedTwiceRepairsTheSameCard` — one card after two publications.
4. `testAScreenshotPublishedAtTheCaptureIdWouldReplaceTheRecordingsBytes` — **measured
   counterfactual**: on the old identity the desk answers with one card whose payload is now the
   JPEG and whose bytes are no longer the recording's. Fails on the old code by construction — the
   old code IS this call.
5. `testTheFallbackNoteLandsBesideTheRecordingRatherThanVanishingIntoIt` — **measured
   counterfactual for audio#3's second half**: a `.note` draft at the capture id comes back
   `kind == .audio` with `textContent == nil` (the words written nowhere), and the same draft at
   `fallbackNoteID` becomes a real second card carrying them.

**Source guards over `ConverseIntent.perform()` — comment-stripped, function-scoped:**
6. `testTheShortcutsLanePublishesTheRecordingBeforeItSpendsTheTranscriptionHop` — arm <
   compress < publishRecording < key verdict < transcribe, and publishRecording < attachTranscript.
   Its `XCTUnwrap` on `publishRecording` is what fails on `223ac35`, where the call does not exist.
7. `testOneCaptureIdentityNamesTheCardTheRetryRecordAndTheTranscript` — exactly one
   `let captureID = UUID()`, exactly one `Self.compressForWork(`, exactly one `AudioCompressor.compress`
   in the whole file, `audio: uploadData` exactly twice (the arm and the card), and the id reaching
   the metadata, the card and the attach.
8. `testTheChatBranchKeepsTheShortcutsOwnRecordingBytes` — both arms of the payload `if`.
9. `testTheOrderingCheckDistinguishesPublishAfterTranscriptionFromPublishBefore` — Rule 0 for 6.

**Source guards over both retry surfaces, function-scoped (`runPendingRetry` / `retryLast`):**
10. `testNeitherRetrySurfaceCollapsesAThrownAttachIntoAMissingRecording` — no
    `try? await …attachTranscript`, and `PendingRetryStore.shared.clear(ifCurrentID:` sits below the
    attach so a throw skips it.
11. `testNeitherRetrySurfacePublishesItsFallbackUnderTheCaptureId` — attach before publish,
    `fallbackNoteID(` present, `captureID: pending.metadata.id` **absent**.
12. `testTheRetrySurfaceGuardsDistinguishTheCollapsingShape` — Rule 0 for 10 and 11, driven on the
    literal shipped shape and the literal new one.

---

## 5. Decisions and deviations, each with its reason

### 5.1 Deviations
1. **A NEW production file, beyond my listed ownership.** All three surfaces need the same
   "publish the screenshot at its own derived id" step, `WorkCaptureRetryCoordinator.publish`
   cannot express it (it refuses an empty transcript), and `WorkVoiceCaptureCoordinator.swift` is
   fix2-recorder's file this wave. Duplicating the derivation in three places is exactly the
   divergence a reviewer would flag. It is small, single-purpose and injectable.
2. **ConverseIntent compresses; it did not before.** Required to give the card and the upload one
   payload. Gated on Work, so Chat is untouched; input is already bounded by
   `Constants.maxAudioSize` (15 MB) and `AudioCompressor.compress` never throws.
3. **`PendingRetryGuard.arm` now preserves the COMPRESSED bytes on the Work lane.** Same choice
   `InAppAudioRecorder.preserveForRetry` already makes. It is what makes "capture id names one
   payload" true across a process death.
4. **Phase-1 failure swallowed rather than surfaced** (unlike fix2-recorder's in-app lane). Throwing
   here would skip the STT hop entirely and hand the user a Retry card; that retry does not
   re-publish a recording (see 5.2.2), so it would reach the same `.recordingMissing` fallback one
   round trip and one tap later. Same end state, worse path.

### 5.2 Roads deliberately not taken
1. **The screenshot is NOT published in phase 1.** Publishing it after STT costs nothing — the retry
   record holds it until the capture completes, and every surface republishes idempotently — while a
   pre-STT publication would add a second failure mode above the transcription hop for the least
   valuable artifact.
2. **The retry surfaces do NOT re-publish a missing recording card**, though they hold the bytes and
   the id and could. `WorkVoiceAttachOutcome.recordingMissing` explicitly covers *a person deleting
   the card while STT is in flight*; re-publishing would resurrect a card they deleted. The cost is
   that a phase-1 failure in the intent lands the words as a note and loses the audio — which is
   still strictly better than `223ac35`, where this lane never kept audio at all.
3. **The attach/fallback decision is NOT hoisted into a shared coordinator function**, though the
   test-quality lens asked me to consider it. Two guards in files I do not own require the literal
   calls to stay where they are: `HeadlessRetryGuardSpanTests` `XCTUnwrap`s
   `"WorkCaptureRetryCoordinator.publish"` inside `perform()`'s own body and orders it between
   `transcriptCaptured = true` and the Work disarm, and
   `WorkboardAudioCaptureTests.testEveryRetrySurfaceRepairsTheRecordingBeforeItPublishes` requires
   both `attachTranscript(` and `WorkCaptureRetryCoordinator.publish(` literally in
   `ContentView.swift` and `MenuBar/DictationService.swift`. Hoisting means editing those two files
   first — §Requests 2.
4. **No Codex consult.** The one genuinely hard call — where the screenshot's identity comes from
   given that `publishAppCapture` derives the entry id from the envelope id and neither file is mine
   — is an ownership question with a mechanical answer, not a technical unknown.

### 5.3 One thing I could not close
`PendingRetryStore` writes the recovered bytes to a `conduck_retry_….m4a` temp file on both retry
surfaces regardless of the container they actually hold. Since the in-app recorder already preserves
compressed bytes, a WAV fallback has always been mis-extensioned there; my change extends the same
approximation to the Shortcuts lane. `SourceAudioContainer.sniff` exists and would settle it in one
line, but the temp-file naming is outside my two "Work retry path only" grants. §Requests 5.

---

## Guard verdicts

- **`WorkboardAudioCaptureTests.testEveryRetrySurfaceRepairsTheRecordingBeforeItPublishes`** (rated
  `convert`): **KEEP.** I did not route the two surfaces through one shared tested coordinator
  (§5.2.3), and a real behavioural conversion needs a mounted SwiftUI view and a live `STTClient` on
  one surface and a menu-bar service on the other — a large abstraction, not one honest seam. It
  passes unchanged against my edits (verified, §6). My cases 10–12 now cover the same two files with
  two further properties (no `try?` collapse; no fallback at the capture id) and a negative control,
  so fix2-recorder may wish to consolidate the three — that is a merge, not a retirement.
- **My own new guards (cases 6–12)**: kept as guards for the same reason, each paired with a Rule 0
  control so none of them is an assertion nobody has seen bite.

---

## 6. Gates — WHAT I ACTUALLY RAN

DerivedData under `~/Library/Caches/gigaduck-builds/fix2-lanes/{DerivedData,DerivedDataMac}`, every
log written there and grepped for `': error: '` and the verdict strings — never judged from tail or
exit code. No `-configuration` passed anywhere. **Build cache removed at end of task**
(`clean-build-cache.sh fix2-lanes` → `removed: fix2-lanes`), so the logs no longer exist; re-run if
you need them.

- **iOS `build-for-testing`** — three attempts before green, each failing ONLY outside my files, per
  the parallel rule:
  - `ios-bft-1.log`: `** TEST BUILD FAILED **`, 2 errors, both
    `Conduck/Conduck/Services/InAppAudioRecorder.swift` (`has no member 'completeCapture'`,
    `cannot find 'speechHop' in scope`) — fix2-recorder mid-edit.
  - `ios-bft-2.log` (after ~135 s): `** TEST BUILD FAILED **`, 4 errors, all
    `Conduck/ConduckTests/WorkboardAudioCaptureTests.swift` (`'async' call in an autoclosure`) —
    same agent's test file mid-edit. **Zero errors in my files in both runs.**
  - `ios-bft-3.log` and `ios-bft-4.log`: `grep -c ': error: '` = **0**, `** TEST BUILD SUCCEEDED **`.
- **Warnings: I added none.** The five that name `ConverseIntent.swift` in the final log
  (`maxAudioSize`, `PendingRetryMetadata.init`, `displayName(for:customs:)`,
  `RemoteAgentDiagnostics.log`, `play(mode:)`) are all pre-existing lines at shifted numbers, and the
  `DictationService.swift:679` capture warning is `startDisplayTimer`, at `HEAD:653`. The two
  warnings my first draft of `WorkVoiceScreenshotCoordinator` did introduce (main-actor default
  arguments evaluated in a nonisolated caller) were fixed by defaulting through `nil`, and the two
  `AudioFormat` property reads by the `@MainActor compressForWork` hop.
- **Targeted run** (`test-3.log`, `test-without-building`, one quoted `-only-testing:` per class),
  `** TEST EXECUTE SUCCEEDED **`, `grep -c ': error: '` = 0:

```
Test Suite 'ConduckTests.xctest' passed
	 Executed 167 tests, with 0 failures (0 unexpected) in 3.766 (3.806) seconds
```

| Class | Result line |
|---|---|
| `WorkboardVoiceLaneTests` (**new**) | `Executed 12 tests, with 0 failures (0 unexpected) in 0.143 (0.146) seconds` |
| `WorkboardAudioCaptureTests` | `Executed 19 tests, with 0 failures (0 unexpected) in 0.160 (0.164) seconds` |
| `HeadlessRetryGuardSpanTests` | `Executed 11 tests, with 0 failures (0 unexpected) in 0.039 (0.041) seconds` |
| `WorkCaptureDrainerTests` | `Executed 9 tests, with 0 failures (0 unexpected) in 0.095 (0.097) seconds` |
| `WorkCaptureDrainerDurabilityTests` | `Executed 8 tests, with 0 failures (0 unexpected) in 0.588 (0.589) seconds` |
| `WorkCaptureInboxTests` | `Executed 30 tests, with 0 failures (0 unexpected) in 0.142 (0.148) seconds` |
| `WorkCaptureInboxLeaseTests` | `Executed 14 tests, with 0 failures (0 unexpected) in 0.055 (0.058) seconds` |
| `WorkboardDeskUpsertTests` | `Executed 11 tests, with 0 failures (0 unexpected) in 0.167 (0.170) seconds` |
| `WorkboardBlobPublicationTests` | `Executed 15 tests, with 0 failures (0 unexpected) in 0.236 (0.239) seconds` |
| `SharedInboxDrainerTests` | `Executed 31 tests, with 0 failures (0 unexpected) in 2.054 (2.061) seconds` |
| `AudioCompressorTests` | `Executed 7 tests, with 0 failures (0 unexpected) in 0.088 (0.090) seconds` |

  An earlier run (`test-2.log`) also passed `HeadlessRefusalLaneDriftGuardTests` (5/0) and
  `ErrorSurfaceDriftGuardTests` (7/0). **`HeadlessRetryGuardSpanTests` passing is the one to notice**
  — it counts the disarms in `perform()` (exactly 3) and orders
  `transcriptCaptured = true` < `WorkCaptureRetryCoordinator.publish` < the Work disarm < the catch
  gate, and my restructuring keeps all of it true.
  In `test-1.log`, `WorkboardAudioCaptureTests` was 18 executed / **2 failures**
  (`testAPublicationFailureIsARetryableErrorRatherThanATextFallback`,
  `testAnAttachFailureHoldsTheWordsAndTheRetryFinishesTheSameCard`) — both fix2-recorder's in-flight
  `InAppAudioRecorder` cases, neither touching any file of mine; both green by `test-3.log`.
- **macOS `build -destination 'platform=macOS'`** (`mac-1.log`, `mac-2.log`): `grep -c ': error: '` =
  **0**, `** BUILD SUCCEEDED **`, `Signing Identity: "Apple Development: Peter Krueck (Z4PNDLZK98)"`.
  **Signed through the identity override; no `CODE_SIGNING_ALLOWED=NO` fallback needed.**
- `bash scripts/check-storage-seam.sh` → `✓ storage seam intact — 780 Swift files scanned…`, exit 0.
- `git diff --check` → clean, exit 0.
- `git status --short` for `*.xcstrings`, `*.pbxproj`, `Conduck/Configs`, `docs/qa/desk-cloudkit`,
  `*WorkCaptureEnvelope.swift`, `*ShareTargetsSnapshot.swift` → **empty**.
- **NOT run, plainly: the full iOS suite and the watch suite.** Neither is in my brief, no watch sim
  is assigned to me, and the tree was still being edited by other agents throughout. Expect **+12**
  on the iOS executed count from `WorkboardVoiceLaneTests`. The watch target compiles none of my
  files: `ConverseIntent.swift`, `ContentView.swift`, `MenuBar/DictationService.swift` and
  `Services/Workboard/*` are all absent from the `ConduckWatch Watch App` membership-exception set,
  and the new coordinator carries `#if !os(watchOS)` besides.

---

## Catalog

**Keys I ADDED in source: NONE.** The screenshot card keeps the name the drainer has always given it
(`displayName` = `screenshot.jpg`), the fallback note keeps `workboard.capture.note`, and both retry
surfaces reuse the existing `workboard.capture.retry.voice.message`.

**Keys I made DEAD: NONE.** I deleted no code carrying a string; every branch I replaced kept the
same publication calls and therefore the same keys.

---

## Requests

1. **fix2-recorder — two doc comments in `WorkVoiceCaptureCoordinator.swift` are now stale, and one
   of them names my lane.** `WorkVoiceAttachOutcome.notAudio` says *"the Shortcuts lane gives its
   imported screenshot the capture id too"*, and `fallbackNoteID(forCapture:)` says *"the Shortcuts
   lane's imported screenshot"*. As of this slice the Shortcuts screenshot takes
   `WorkVoiceScreenshotCoordinator.materialID(forCapture:)` and can never stand at the capture id.
   The mechanism is still right and `.notAudio` is still worth having (any card at that id must
   refuse spoken words) — only the example is false. Suggested replacement for both: *"a card the
   capture id names that is not a recording — a legacy per-capture material re-homed onto the desk,
   or a row a merge produced."* **I did not edit your file.**
2. **fix2-recorder + whoever owns `ConduckTests/RemoteAgent/HeadlessRetryGuardSpanTests.swift` — the
   two guards that pin the fallback publication's LOCATION are what stopped me hoisting the
   attach/fallback decision into one shared coordinator (§5.2.3).** If the wave wants that
   consolidation (the test-quality lens rates
   `testEveryRetrySurfaceRepairsTheRecordingBeforeItPublishes` `convert`), both anchors have to move
   together, in this order: (a) `HeadlessRetryGuardSpanTests.testPerformDisarmsOnProvableAbsence…`
   re-anchors `workPublish` from `"WorkCaptureRetryCoordinator.publish"` to whatever the shared entry
   point is called — the ordering it asserts (`transcriptCaptured = true` < the Work publication <
   the Work disarm < the catch gate) is unchanged and must stay; (b)
   `WorkboardAudioCaptureTests.testEveryRetrySurfaceRepairsTheRecordingBeforeItPublishes` then
   asserts the single call on both surfaces instead of the attach/publish pair. **Do not do (a) or
   (b) without the hoist, and not at this gate** — they are the only things holding the two surfaces
   in step today.
3. **Nobody mint a Work voice capture's screenshot or fallback note at the capture id again.** The
   capture id names the RECORDING, and the desk write is idempotent by id: a note published there is
   returned unchanged (the words go nowhere) and a payload published there is treated as a repair
   and **replaces the recording's bytes**. Both are measured in
   `WorkboardVoiceLaneTests.testAScreenshotPublishedAtTheCaptureIdWouldReplaceTheRecordingsBytes` and
   `…testTheFallbackNoteLandsBesideTheRecordingRatherThanVanishingIntoIt`. The two derivations
   (`WorkVoiceCaptureCoordinator.fallbackNoteID`, `WorkVoiceScreenshotCoordinator.materialID`) must
   also keep their **separate namespaces** — sharing one makes a capture's note and its screenshot
   the same card.
4. **Nobody move `WorkVoiceCaptureCoordinator.publishRecording` in `ConverseIntent.perform()` below
   the key pre-flight or the STT hop.** That ordering IS the fix;
   `WorkboardVoiceLaneTests.testTheShortcutsLanePublishesTheRecordingBeforeItSpendsTheTranscriptionHop`
   fails on it. Likewise nobody give `PendingRetryMetadata.id` back an anonymous `UUID()` there, and
   nobody move the compression out of the `destination == .work` arm — Chat's upload must stay the
   Shortcut's own bytes.
5. **Whoever owns `PendingRetryStore` / the two retry surfaces' temp-file naming (next session, not
   this gate).** Both surfaces write the recovered bytes to `conduck_retry_….m4a` whatever container
   they hold, and both lanes now preserve COMPRESSED bytes, which `AudioCompressor` can return as WAV.
   `SourceAudioContainer.sniff(pending.audioData).fileExtension` settles it in one line at each site.
   Pre-existing on the in-app lane; my change extends the same approximation to the Shortcuts lane.
   Not urgent — every provider in the suite sniffs or tolerates the mismatch today — but it is now
   two lanes rather than one.
6. **Docs agent — `spec.md`'s "audio not retained" line has a second lane to name.** A Work capture
   made from a Shortcut or the Action Button now retains its recording exactly as an in-app Work
   voice note does: the compressed bytes become an `.audio` card before speech recognition is
   attempted, the transcript is written onto that card afterwards, and a screenshot wired into the
   same Shortcut becomes a second card beside it. Chat is unchanged — it retains no audio, and its
   upload is still the Shortcut's own recording byte for byte.
7. **Founder QA (Gate 2) — three items this slice adds, none of them reachable by any automated
   test in this suite.**
   (a) Run the bundled Shortcut / Action Button with **Destination = Work** and airplane mode ON: a
   playable **untranscribed** card must appear on the desk, and the in-app Retry card must then fill
   in its words on the SAME card — no second card, no note beside it.
   (b) Same, with a **Take Screenshot** step wired into the Shortcut and airplane mode OFF: exactly
   TWO cards — one playable recording carrying the transcript, one screenshot. The recording must
   still PLAY (if it shows the screenshot instead, the identity derivation has regressed).
   (c) **macOS**: a Work capture that failed STT, recovered from the menu-bar Retry, must land its
   words on the same card and its screenshot as one further card — and if the desk write fails, the
   Retry affordance must still be there afterwards with the recording recoverable.

## Refuted

**Nothing.** Both findings were verified against the current tree by tracing the call path before any
code changed, and both hold. audio#1's evidence is exact. audio#3's is exact and, on the collision
half, conservative — the measured consequence of publishing bytes at the capture id is not a dropped
card but a **replaced payload** (§1).
