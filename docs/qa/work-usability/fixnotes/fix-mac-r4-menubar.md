# fix-mac-r4-menubar — Codex MAC-R4 findings on the Mac menu-bar Work lane

Round 4 over `docs/qa/work-usability/design/mac-work-destination.md` (⌘⇧1 Ask · ⌘⇧2 Screenshot &
Ask · ⌃⌘W Capture to Work). Eighteen findings; **twelve fixed, six outside this lane and named.**

Files touched:

- `Conduck/Conduck/MenuBar/MenuBarCoordinator.swift` (P1-B, P1-C, P2-A, P2-H, P2-I)
- `Conduck/Conduck/MenuBar/DictationService.swift` (P1-D, the stop half)
- `Conduck/Conduck/MenuBar/QuitGuard.swift` (P3-B)
- `Conduck/Conduck/Services/AudioRecorder.swift` (P1-D, the primitive half — **additive**, see below)
- `Conduck/Conduck/Services/InAppAudioRecorder.swift` (P2-D, P2-E)
- `Conduck/Conduck/Services/PendingRetryStore.swift` (P2-E)
- `Conduck/Conduck/Services/Workboard/WorkVoiceCaptureCoordinator.swift` (P2-B)
- `Conduck/ConduckTests/`: `MenuBarEscCancellationContractTests`, `MenuBarWorkCaptureStateTests`,
  `MacMenuBarWorkShortcutDriftGuardTests`, `WorkboardAudioCaptureTests`,
  `PendingRetryOwnershipHandoffTests`, `WorkVoiceRecoveryTests` (lane double),
  `MenuBarQuickDestinationTests` + `MenuBarCoordinatorQuickTypedTests` (call sites)

**Catalog rows: four, requested — not written.** This lane does not own `Localizable.xcstrings`.

`Services/AudioRecorder.swift` is outside the stated ownership list and nobody else's either — the
finding names it and the fix is unreachable without it. Purely additive: one private counter, one
guard after the permission prompt, one bump at the top of each ender.

---

## MAC-R4-P1-B — the holding slot could lose a picture or hand it to Chat · **fixed**

Real, both halves, and NEW in R3. `stalledWorkSaveImage` was a bare `Data?` with no owner:

1. Picture A stalls into the hold; B claims the slot during the publication; the next commit takes
   B and clears the hold unconditionally — A disappears with no publication and no discard.
2. With A held for the DESK, switching to Chat and pressing "Add to Work" for unrelated text picked
   A up (`stagedAtCommit ?? stalledWorkSaveImage`), and that publication's failure arm restored it
   into `pendingCaptureImage`. One Return later a screenshot staged exclusively for the desk was a
   gateway attachment.

Fix: the hold NAMES its composition — `StalledWorkSave { image, aim, text }` — and a commit reaches
it only on an exact match of both halves (`heldForThisCommit`). It is cleared when TAKEN
(`if screenshotAtCommit != nil, stagedAtCommit == nil`), when the words it belongs to are actually
filed (`if filed, aim ==, text ==`), and by the two explicit discards, now aim-scoped through
`discardStalledWorkSave(aimedAt:)`. R3's blanket clear existed because the hold had no identity;
the identity is what makes it unnecessary, and dropping a picture because a newer one exists is the
loss the hold was invented to stop.

Guard: `MenuBarWorkCaptureStateTests.testTheDeskCommitTakesThePictureFromTheSlotItsAimOwns` — the
identity read asserted whole, the conditional clear asserted whole and ordered above the
publication, the `filed`-gated release asserted whole, the scoped discard's body pinned by equality,
both call sites required by aim, plus three controls: the unowned pickup, the unconditional clear,
and the arm with no hold at all.

## MAC-R4-P1-C — a cancelled send still consumed a newer capture · **fixed**

Real, both halves. `handleQuickSend`'s `defer` ran on EVERY exit, the cancelled one included: it
cleared `pendingCaptureImage` (a screenshot staged for the question started AFTER the Esc) and reset
that question's destination. And the four post-await error arms wrote `presentHandoffError` +
`pendingFailedTurn` before the commit-point check, so a cancelled mint that failed resurrected the
withdrawn transcript as a live Retry.

Fix, three parts:

- The `defer` is gated on the send's own identity. `cancelActiveCapture` now clears `turnStarting`
  itself, on the arm that owns the Ask surface — nothing newer exists at that instant, so nothing
  newer can be taken.
- The four failure arms go through ONE gate, `stashQuickHandoffFailure`, which reads the token above
  the error surface and above the stash. The dispatch guard is too late: by then both are on screen.
- The attachment read is gated too, so a withdrawn send cannot publish a newer capture's picture
  through `onQuickTurnAttachments` before the dispatch guard refuses it.

Guard: `MenuBarEscCancellationContractTests.testTheHandoffIsCancellableBeforeDispatch` — the gated
`defer` asserted whole with the ungated form as its control, the gate's body ordered above both
writes, and `presentHandoffError` refused **by name** inside the send.

## MAC-R4-P1-D — Ask startup cancellation established no ownership · **fixed**

Real, both halves.

1. `.recording` is declared before the primitive's permission hop completes. A second press lands in
   `stopAndProcess`, finds no audio, writes `.error` — and left `recordingStartToken` alone, so the
   resumed startup opened a microphone that sat live behind a surface whose only key clears the
   banner. Fix: the stop moves the token, above the arm that answers nil. A stop ENDS the start,
   whichever way it goes.
2. `AudioRecorder.startRecording()`'s `!isRecording` guard is read BEFORE the microphone prompt, so
   two starts can both pass it: the second built a SECOND `AVAudioRecorder` over the live one, and a
   stop then returned the earlier recording. Fix: `sessionGeneration`, taken at entry, re-checked
   after the prompt and above the first line that takes the input, and moved at the TOP of both
   `stopRecording()` and `cancelRecording()` — above their own early returns, which is exactly the
   path a press during the prompt takes.

Guard: `testAnAskStartCarriesACancellationIdentity` + `testTheRunCarriesTheTokenItStartedWith` — the
stale-start block ordered BELOW `await recorder.startRecording()`, the reservation ordered
taken→prompt→checked→built, and both enders' bumps ordered above their early returns.

## MAC-R4-P2-A — a recovered Retry re-acquired a composition through its stash · **fixed**

Real. `handleRecoveredTranscript` correctly passes `carriesComposition: false`, but a busy
destination parks the words in `pendingFailedTurn`, and `.voice(transcript:)` carried no ownership —
so the footer's Retry replayed through `handleTranscript` and the default `true` came back, one
press after the first hop had refused it.

Fix: `PendingFailedTurn.voice(transcript:carriesComposition:)`. `quickStash` takes it,
`retryPendingFailedTurn` reads it and calls `handleQuickSend` directly with the value the stash
carries.

Guard: extended `MenuBarWorkCaptureStateTests.testAQueuedRetryCarriesNoCompositionOfItsOwn` — the
case shape, the replay's call asserted whole, the stash's own arm, and the ownership-free case as
the control.

## MAC-R4-P2-B — the queued transcript write was still ungated · **fixed**

Real, and R3's declared residual. `try Task.checkCancellation()` sits before `context.perform`; the
closure executes later on the store's queue, and `Task.isCancelled` inside it answers about the
QUEUE's task — a check that looks right and always reads `false`.

Fix: `WorkVoiceWriteAuthorization`, a lock-guarded box set from `withTaskCancellationHandler`'s
`onCancel` (on whatever thread delivers it) and read at the MUTATION boundary inside the closure,
where it throws `CancellationError()`. Nothing was attempted, so there is no attachment verdict; the
recorder's phase-two catch already maps a cancellation to `.idle` with no banner and no retry save.

Guard: `WorkboardAudioCaptureTests.testCancellingInsideTheQueuedWriteStillKeepsTheWordsOffTheCard` —
a REAL run through the recorder, with a new `transcriptWritePauseForTesting` seam standing between
`ensureLoaded()` and the queued write, plus an uncancelled control.
**Verified as a negative control:** with the authorization check removed the case fails on
`XCTAssertNil(card.textContent)`.

## MAC-R4-P2-D — a dismissed sheet's declaration was permanent · **fixed**

Real, and NEW in R3. `unsavedWorkCaptureCount` was a number somebody had to decrement, and the Mac
desk sheet releases nothing on the path that matters: its ✕ does nothing in `.error`, and neither
does its disappearance. Every later ⌘Q then asked about a recording whose Try Again had gone with
the surface.

Fix: the count is DERIVED from the recorders still alive to answer for it — a weak
`[ObjectIdentifier: UnsavedWorkCaptureHolder]`, compacted on every write, counted live on every
read. A declaration is a claim about bytes in one recorder's memory, so it can only be true while
that recorder exists; the host needs no new call, and processing that finishes after the dismissal
still holds its own recorder alive, which is the honest answer for that case. (A Swift weak map
rather than `NSHashTable.weakObjects()`: the ObjC bridge autoreleases its members, so the table went
on counting a recorder nothing referenced.)

Guard: `WorkboardAudioCaptureTests.testTheQuitQuestionCountsEveryRecorderHoldingBytesNothingWouldTake`
— the actual count after a failed publication AND a failed preservation, the verdict that reads it,
two recorder instances, an explicit discard, a preservation that LANDS, and the dismissal.
**Verified as a negative control:** with the holder held strongly the dismissal assertion fails.

## MAC-R4-P2-E — a partial retry save let two surfaces claim one recording · **fixed**

Real. `retryLane.save` writes the sidecar, then the audio, then the screenshot, then the index row.
A throw on the screenshot leaves the sidecar and the audio committed — reconciliation adopts them —
while `armedDurableRetryID` stays unset. `reserveDurableRetry` treated that flag as proof of absence
and returned `true` without claiming anything, so this recorder and whoever claimed the adopted
entry could both transcribe and attach different words to one card.

Fix: `PendingRetryReservation { claimed, absent, heldElsewhere }` and
`PendingRetryStore.reserve(id:duration:)`, one pass under the same lock as `claim`. The recorder
asks the QUEUE rather than its own bookkeeping: `.absent` permits (the bytes in hand are the only
copy), `.heldElsewhere` refuses. A lock this process could not take reads as held — the safe
direction. The protocol default answers `.absent` for every refusal, which is right for a double
that never queues anything and is what the real store overrides.

Guard: `PendingRetryOwnershipHandoffTests` — `testAReservationTellsAnAbsentCaptureApartFromOneSomebody
ElseHolds` and `testAPartiallySavedCaptureIsStillAnEntryTheQueueWillHandOut`, the second driving a
real partial save (the container's image path occupied by a non-empty directory).
**Verified as a negative control:** with `.heldElsewhere` collapsed to `.absent` both fail.

## MAC-R4-P2-H — the receipt could confirm a collision occupant · **fixed**

Real. `deskHoldsWorkMaterial` asked only whether SOMETHING stood under the capture id. When both the
primary id and the deterministic escape id are held by cards of another kind, the drainer refuses the
import, retires the capture and returns a successful report — and that unrelated occupant is exactly
what the read found, so the receipt said "Added to Work" about a capture the queue threw away.

Fix: three questions, not one. Either id (a capture that escaped one collision stands under a name
the publication never returned), the KIND this capture published (a kind collision is what the
refusal WAS, so an occupant of the wrong kind is proof of refusal), and the PAYLOAD for the one kind
that is its bytes. The call site names the kind from what it actually published.

Guard: `MenuBarWorkCaptureStateTests.testTheReceiptConfirmsThisCapturesOwnCardRatherThanWhateverHolds
ItsID` — DRIVEN against a real store: an empty desk, an unrelated card under the capture's id, the
capture's own card under the escape id, and an image card with no bytes.
**Verified as a negative control:** with the id-only read restored the case fails.

## MAC-R4-P2-I — a bail before the task started was invisible to it · **fixed**

Real. Every door claimed `turnStarting` synchronously and then read `quickSendGeneration` INSIDE the
send's `Task`. A `cancelActiveCapture` landing in that window had already advanced the generation, so
the send adopted the moved value as its own identity and its final check passed.

Fix: `beginQuickSend()` — the claim and the identity in ONE synchronous step, before the `Task`
exists — and `sendGeneration` travels into `handleQuickSend` as a parameter. All four doors
(`onTranscript`, `onRecoveredTranscript`, `sendQuickTypedDraft`, `retryPendingFailedTurn`) go through
it, and `turnStarting = true` appears nowhere else.

Guard: `testTheHandoffIsCancellableBeforeDispatch` — `beginQuickSend`'s body pinned by equality, the
in-task read refused by name, `turnStarting = true` counted exactly once in the whole coordinator,
and both wiring shapes asserted.

## MAC-R4-P2-J — the cancellation guards accepted a moved check · **fixed (test)**

Three of the four mutations are now pinned against the suspension each check protects: the Ask
startup block ordered BELOW `await recorder.startRecording()`, the stop's token ordered above the
`Task` rather than merely above `processAudio`, and the settlement's second check ordered BELOW
`await pendingErrorCode()`. The fourth (the Work attachment check hoisted above `ensureLoaded()`) is
answered by P2-B instead: the write now carries an authorization read at the mutation boundary, so
where the earlier `Task` check sits no longer decides whether the words land.

## MAC-R4-P2-K / P2-L — the new guards never verified their effect · **fixed (test)**

Both real. The counter's guard asserted the shape of a `+= 1` it could not tell from `+= 0`, and the
receipt's guards required the confirmation helper to be CALLED, not to be right (`==` inverted to
`!=` passed). Both are now measured: see the behavioural cases under P2-D and P2-H, each with its
mutation verified to fail.

## MAC-R4-P3-B — the quit prompt misnamed a screenshot-only loss · **fixed**

Real. The count is capture-neutral — a screenshot whose publication and preservation both failed is
memory-only while the recording is already playable on the desk — and the copy promised to keep a
recording that was never at risk. Four `.v2` keys, capture-neutral, matching the shipped menu item's
own word. See §Catalog requests.

---

## Outside this lane, with evidence

- **MAC-R4-P1-A (automated entry points start microphones and publish to Work)** — every file named
  is outside it: `Intents/RecordWorkNoteIntent.swift`, `Intents/ConverseIntent.swift`,
  `Intents/CaptureWorkboardIntent.swift`, `Views/Workboard/WorkboardCaptureCanvas.swift`,
  `Views/Workboard/WorkboardVoiceCaptureView.swift`. Adjudicated four times now. The dispute — "no
  implicit headless REROUTING to Work" versus "no headless trigger reaches Work" — is a founder call
  about `design/watch-work-destination.md:39`; the shortcuts lane owns the change if the answer is
  the stricter reading. **Still open for the founder.**

- **MAC-R4-P2-C (Cancel Transcription leaves the phone desk sheet showing a startup)** — REAL, and
  the fix is in `Views/Workboard/WorkboardVoiceCaptureView.swift`, which this lane does not own. The
  recorder's answer is correct (`.failure(.unknown(CancellationError()))` with `.idle`); the sheet
  drops the result, and its `.idle` arm renders `workboard.voice.starting` with `EmptyView()` for a
  main action while `canRetryWorkCapture` is still true. **The fix is one arm**: `handle(_:)` must
  treat a `CancellationError` failure as a dismissal (`onCancel()`), or the `.idle` arm must render a
  stopped state carrying Try Again. Desk/voice lane.

- **MAC-R4-P2-F, P2-G, P2-M (Watch relay recovery, republication after deletion, the phase-two
  acknowledgement)** — `Services/AppleSpeechRelayCoordinator.swift` and the watch queue. Not this
  lane's, and P2-F's copy half needs the WATCH catalog. Watch lane.

- **MAC-R4-P3-A (README names "Record to Work…")** — `README.md:55` is the docs lane's file; the
  correction is one phrase, "Record to Work…" → "Capture to Work…". Handed over for the third time.

## Residuals

- **A hold whose words are filed by a commit that did not take it is let go.** Its owner has left
  the composition, so no door can reach it and keeping it would hang an old screen over the next
  note. What is NOT let go is a hold whose words are still being composed — that was the loss.
- **`finishWorkRetry`'s desk writes are still not gated on the retry token.** Unchanged from R2/R3.
- **A capture refused under BOTH ids reads as `.queued` rather than as a failure.** The drainer's
  report carries no identities, so the coordinator can prove arrival and cannot prove refusal. The
  receipt is no longer a lie about a card; it is still optimistic about an envelope that will never
  become one. Closing it needs `WorkCaptureDrainer.Report` to name what it refused.

## Catalog requests (`Conduck/Conduck/Localizable.xcstrings`, not this lane's)

| Key | Default value |
|---|---|
| `quitGuard.unsaved.single.title.v2` | `A capture hasn’t reached your desk` |
| `quitGuard.unsaved.multiple.title.v2` | `%lld captures haven’t reached your desk` |
| `quitGuard.unsaved.body.v2` | `Quitting now loses what was captured. Try Again is still on the capture.` |
| `quitGuard.unsaved.button.keep.v2` | `Keep the Capture` |

The four un-suffixed `quitGuard.unsaved.*` rows are dead and may be retired.

## Nobody undo

- **The stalled hold names its composition — the aim AND the words — and a commit reaches it only on
  an exact match.** Unowned it is a shared drawer, and the door it opens leads from the desk to a
  gateway.
- **The hold is cleared when TAKEN, or when the words it belongs to are filed or discarded.** Never
  because a newer screenshot exists: that picture has no card, no envelope, no retry entry and no
  composition, so the hold is the only place it is.
- **`handleQuickSend`'s exit cleanup is gated on the send's identity, and `cancelActiveCapture`
  clears `turnStarting` itself.** A withdrawn send owns none of that state; a newer one owns all of
  it. The bail is the only press that can be sure nothing newer exists.
- **Every quick-lane failure surface goes through `stashQuickHandoffFailure`, and it reads the token
  ABOVE the error and the stash.** The dispatch guard cannot help: by then the error is drawn and
  the withdrawn transcript is a live Retry.
- **The send identity is taken SYNCHRONOUSLY, in `beginQuickSend`, with the gap-bridge flag.** Read
  inside the task it identifies nothing — the bail has already moved it.
- **`AudioRecorder`'s reservation is checked AFTER the permission prompt and BEFORE the recorder is
  built, and every stop and cancel moves it above its own early return.** The prompt is where two
  starts overlap and where a press has nothing to act on; both facts live on that one line.
- **A stop moves `recordingStartToken`.** A stop ends the start, and the start it ends may still be
  suspended in a system sheet.
- **The transcript write reads an AUTHORIZATION, not `Task.isCancelled`.** Inside `context.perform`
  that flag describes the queue's task and answers `false` for ever.
- **`unsavedWorkCaptureCount` is DERIVED from live holders and never incremented.** A number
  somebody must decrement is a number a dismissed surface forgets, and its guard cannot tell `+= 1`
  from `+= 0`.
- **`reserveDurableRetry` asks the QUEUE, not `armedDurableRetryID`.** A save that threw can still
  have left an entry, and the flag records only saves that landed.
- **The receipt confirms id, KIND and payload.** A kind collision is precisely what a refusal is, so
  an occupant of the wrong kind is proof the capture was refused — never proof that it arrived.
