# fix-mac-r2-menubar — Codex MAC-R2 findings on the Mac menu-bar Work lane

Round 2 over `docs/qa/work-usability/design/mac-work-destination.md` (⌘⇧1 Ask · ⌘⇧2 Screenshot &
Ask · ⌃⌘W Capture to Work). Ten findings; **seven fixed, three declined on ownership with the
follow-up named.**

Files touched:

- `Conduck/Conduck/MenuBar/MenuBarCoordinator.swift` (P1-B, P1-C)
- `Conduck/Conduck/MenuBar/DictationService.swift` (P1-D)
- `Conduck/Conduck/AppDelegate.swift` (P1-E, one guard)
- `Conduck/Conduck/Services/InAppAudioRecorder.swift` (P2-B, one hoisted check)
- `Conduck/Conduck/Services/PendingRetryStore.swift` (P1-E, one `try?` → `try`)
- `Conduck/ConduckTests/MacMenuBarWorkShortcutDriftGuardTests.swift`,
  `MenuBarWorkCaptureStateTests.swift`, `MenuBarEscCancellationContractTests.swift`,
  `WorkboardAudioCaptureTests.swift`

**Catalog rows: none.** No new user-visible string.

---

## MAC-R2-P1-B — Chat Retry could still send the screenshot being committed to Work · **fixed**

Real. `saveQuickDraftToWork` consumed the picture on the way BACK from the publication, so for the
whole commit the bytes sat in `pendingCaptureImage` — and every SEND reads the slot, not the
in-flight flag. The R1 fix guarded `sendQuickTypedDraft` (Return); it cannot see the footer's
**Retry** or a ⌘⇧1 transcript, both of which reach `handleQuickSend`, which attaches
`pendingCaptureImage.map { [.image($0)] }`. A picture filed privately then rode a gateway turn.

Fix: the picture leaves the composition **synchronously, at the commit** — one `switch aimAtCommit`
above the `Task` — and the bytes travel in `screenshotAtCommit` alone. The failure arm puts it back,
into an EMPTY slot only (a screenshot staged during the await belongs to the next capture). That is
a transfer, not a discard, and it closes every door at once rather than one per door.

Guard: `MenuBarWorkCaptureStateTests.testTheDeskCommitTakesThePictureFromTheSlotItsAimOwns` —
the synchronous consume asserted as one shape and ordered above `publishAppCapture`, the post-await
consume refused **by name in both aims**, the restore asserted whole, and the flag pinned by COUNT
(`= true` once, `= false` once), which is what rejects the `true → false` mutation the verifier
named.

## MAC-R2-P1-C — cancellation still destroyed state hidden by the popover router · **fixed**

Real, in both directions, and the cause was one reading: `askMicrophoneIsLive` answers about the
MICROPHONE, and the popover routes by SURFACE.

- Forward: a parked Work draft + Ask stopped → `.processing` → `askMicrophoneIsLive` is false, so
  Esc deleted a Work composition hidden under the working view.
- Reverse: a parked Work error + Ask stopped → the Work HUD is drawn (its arm wins whenever the Ask
  mic is not `.recording`), and Esc ran `dictationService.cancelRecording()`, which after R1's P2-B
  fix invalidates a `.processing` transcription — one the HUD's own ✕ leaves alone.

Fix: `MenuBarCoordinator.visibleBailOwner` — `.workCapture` / `.askCapture` / `.composition`,
mirroring `DictationPopoverView.content`'s first three arms — resolved ONCE, first, and used for the
whole teardown. Esc over the Work HUD now IS the ✕: `cancelWorkVoiceCapture()` and `return`. Esc over
either capture leaves both compositions alone. Esc over the compose surface behaves exactly as
before. The screenshot-press generation bump stays unconditional and above every arm.

Guards: `MacMenuBarWorkShortcutDriftGuardTests.testABailTakesOnlyTheSurfaceThatIsShowing`
(the owner read is the FIRST statement and appears once; the Work arm is one shape that RETURNS and
precedes the Ask teardown; the composition arm is one shape; `discardWorkOnlyCompose()` and
`quickDraft = ""` each appear EXACTLY ONCE — which is what rejects an unconditional discard beside
the conditional one) and `testTheVisibleOwnerMirrorsThePopoversRenderOrder` (the owner's arms
asserted whole, anchored to the popover's own first arm, with the microphone-only reading as the
control).

## MAC-R2-P1-D — stale completions could overwrite a newly started Ask recording · **fixed**

Real, and the new interleaving the verifier found is the same shape as the one R1 closed:
`preserveForRetry` SUSPENDS, and the write under it was unconditional.

Fix, three parts:

- `preserveForRetry` takes the `generation` and re-checks it after the save. A cancelled run's entry
  is retired **by the id it just wrote** — `claim(id: captureID)` then `clear` — under the store's
  own lease, so a capture another surface has since taken over is left alone.
- Both call sites re-check the token AFTER the preservation, before `lastError` / `state`.
- `retryLast` takes a token and hands it to `attemptRetry`, which re-checks after every suspension:
  the settings/key hop, the provider round trip (the one that stands between the answer and BOTH
  `settleAfterFinishing` and `onTranscript`), and each failure arm. A cancelled Retry answers
  `false`, which is already the "still waiting" answer — the reservation goes back and the capture
  stays queued for the next tap. The R1 residual is closed: "Esc always cancels the request" is now
  true of a Retry as well as of a stop.

Guards: `MenuBarEscCancellationContractTests` gains three cases —
`testTheStalenessCheckComparesTheTokenWithTheServicesGeneration` (the helper's body pinned WHOLE,
which is what rejects `token == token`), `testACancelDuringThePreservationWritesNothingAndParksNothing`,
and `testARetryCarriesTheSameCancellationIdentity`.

## MAC-R2-P1-E — the quit guard permitted termination without durable bytes · **partly fixed**

Two of the three sub-claims are fixed; the third is declined below with its reason.

- **The bounded wait's timeout** (fixed). `applicationShouldTerminate`'s deferred reply consulted
  only `quitGuardPermitsTermination()`, which counts gateway turns and by construction cannot see a
  Work capture — so a compression or desk write that outlasted five seconds was answered by an empty
  registry and the recording went with the process. The reply now re-reads the count and refuses
  (`NSApp.reply(toApplicationShouldTerminate: false)`) when the wait ended with a publication still
  in flight. That is not a hang: the deferral is over, the next ⌘Q waits again — by which time the
  write has almost certainly landed — and a logout or restart never reaches the branch
  (`isPowerOffInProgress`).
- **The swallowed screenshot write** (fixed, shared store).
  `PendingRetryStore.save`'s `try? workImageData.write(...)` armed an entry whose picture was never
  written, so `InAppAudioRecorder.preserveForRetry` set `armedDurableRetryID` believing the whole
  capture was parked. It now propagates, exactly as the recording's write one line above does and
  for the identical reason — the comment there already states it. Affects every caller of the shared
  store, which is the point.
- **A preservation that FAILED still releases the count** — declined, see Residuals.

Guards: `MacMenuBarWorkShortcutDriftGuardTests.testTheQuitGuardWaitsForAWorkCaptureThatHasNotReached
TheDesk` gains the refusal asserted as one shape and ordered between the wait and the gateway answer,
plus the THRESHOLD pinned in both files — the delegate's `> 0, !isPowerOffInProgress` condition and
`waitForWorkPublications`'s body asserted whole, which is what rejects the `> 0` → `> 1` mutation
that leaves the single-capture case (the only case this lane has) unprotected.

## MAC-R2-P2-B — "Cancel transcription" could attach a successful result · **fixed**

Real, and shared: the same recorder backs the Mac popover and the phone desk sheet. `settle`'s
`.success` arm asked nothing about cancellation, so a provider answer landing after the ✕ walked into
phase two and attached its words; `settleOwedScreenshot`'s later check only changed what the person
was TOLD, after the write.

Fix: the cancellation check is asked BEFORE the outcome — hoisted above the switch, where the doc
comment already claimed the "cancel check" lived — and removed from the failure arm, where it is now
redundant. The recording stays (the press was aimed at the words); the transcript does not.

Guard: `WorkboardAudioCaptureTests.testCancellingTheTranscriptionKeepsTheRecordingAndRefusesTheWords`
— a REAL run through the recorder's own seams, with the press landing inside the speech hop, plus an
uncancelled control so the case cannot pass on a phase two that never runs. **Verified as a negative
control**: with the check moved back onto the failure arm the case fails on
`XCTAssertNil(card.textContent)` with "the words nobody waited for".

## MAC-R2-P2-D — the stand-down's visibility was unpinned · **fixed (test)**

Real. Every assertion was about the CALL; flipping `if !popover.isShown` to `if popover.isShown`
made the refused press return with its explanation behind a closed popover — the silent no-op the
stand-down exists to replace. The helper's body is now asserted WHOLE (it is one statement, and
there is one right form of it), with the inverted guard as the control.

## MAC-R2-P2-E — the queued receipt's KIND was unpinned · **fixed (test)**

Real. The sentence checks could not see `kind`, and `kind` is what the row is BUILT from: `.saved`
draws a button whose tooltip says "Open Work and see the new card"; `.queued` draws an inert label.
Relabelling the false arm `.saved` kept every assertion green and made the queued receipt clickable.
Both arms are now asserted as one shape including their kinds, `kind: .queued` is pinned by count,
and the relabelled ternary is present as the control. `testTheSavedAcknowledgementOpensTheDesk` also
now asserts that `Button(action: openWorkboard)` appears exactly once and that `.queued` / `.failed`
are `Label` arms.

---

## Declined, with evidence

- **MAC-R2-P1-A (automated entry points start or publish Work captures)** — every file named is
  outside this lane: `Intents/RecordWorkNoteIntent.swift`, `Intents/ConverseIntent.swift`,
  `Intents/CaptureWorkboardIntent.swift`, `Views/Workboard/WorkboardCaptureCanvas.swift`,
  `Views/Workboard/WorkboardVoiceCaptureView.swift`. The lane's file list is `MenuBar/**`,
  `ScreenCapture/**`, the Mac shortcut rows in `Views/Settings/**`, and the three shared services.
  Adjudicated twice by the shortcuts lane (`fix-r3-shortcuts.md`); the boundary dispute — "no
  implicit headless REROUTING to Work" vs "no headless trigger reaches Work" — is a founder call
  about `design/watch-work-destination.md:39`, not an implementation defect this lane can settle.

- **MAC-R2-P2-A (a returned drain does not prove the typed card exists)** — the prescribed fix needs
  per-capture identity out of the drain, and `WorkCaptureDrainer.Report`
  (`Conduck/Conduck/Services/Workboard/WorkCaptureDrainer.swift:52`) carries only counts:
  `importedCaptureCount`, `replayedCaptureCount`, `invalidCaptureCount`, `importedMaterialCount`.
  That file is not this lane's, and neither is `WorkCaptureInbox.swift`. Standing on the record:
  design decision 9 and the Open-risks entry, with the founder's call in `handoff.md`. The residual
  is a receipt that is EARLY — the envelope stays queued and the next drain imports it — never one
  that is false about the note's survival.
  **Follow-up, one change in the drainer's own lane:** add `importedCaptureIDs: Set<UUID>` to
  `Report`; `saveQuickDraftToWork` already holds the id `publishAppCapture` returns, so the receipt
  becomes `drained && report.importedCaptureIDs.contains(published)`.

- **MAC-R2-P2-C (the Watch promises phone transcription recovery without creating an entry)** —
  `Services/AppleSpeechRelayCoordinator.swift`, `ConduckWatch Watch App/Services/
  AppleRelayPendingQueue.swift` and the WATCH catalog. None is this lane's, and the fix is a choice
  between persisting a `.work`/`.published` retry entry and changing wrist copy — the watch lane's
  call, and the copy half needs a catalog this lane may not edit.

## Residuals

- **A preservation that FAILED still gives the quit-guard count back.** When phase one's desk write
  and `retryLane.save` both fail, `failPendingWorkCapture` returns and the function-scope `defer`
  releases the window while the bytes are memory-only. Not fixed, deliberately: holding the count
  there is unbounded by construction — nothing is going to become durable by waiting, so the guard
  would refuse every ⌘Q until the person found the ✕, invisibly. The honest fix is a DECISION
  ("your recording has not been saved — quit anyway?"), which is new copy, a new alert arm on
  `QuitGuard`, and a founder call about what ⌘Q does when storage is broken. The state is already
  surfaced: the HUD stands with its Try Again and its ✕. **Open item for the founder.**
- `finishWorkRetry`'s desk writes are not gated on the retry token. A Work retry cancelled during
  its DESK write still lands the card it was writing — which is the outcome the person would want
  anyway, and unwinding a partial publication is a bigger change than the cancel is worth.

## Nobody undo

- **The committed screenshot leaves the composition SYNCHRONOUSLY, at the commit.** Every sender
  reads the slot, never the in-flight flag: the footer's Retry and a ⌘⇧1 transcript both reach
  `handleQuickSend` without passing `sendQuickTypedDraft`'s guard. Consuming on the way back closes
  one door and leaves the rest open. The restore on failure is gated on an EMPTY slot, or a failed
  commit steals the next capture's picture.
- **`visibleBailOwner` is resolved ONCE, as the first statement, and routes the whole teardown.**
  Two readings let two halves of one press disagree about which surface it belonged to — which is
  exactly how the microphone reading got `.recording` right and `.processing` wrong in both
  directions. It mirrors the popover's render order; if that order changes, this changes with it.
- **Esc over the Work HUD returns.** It is the ✕ typed instead of clicked, and falling through
  reaches `dictationService.cancelRecording()`, which now answers for `.processing` — invalidating a
  transcription the person cannot see and the ✕ does not touch.
- **The cancellation identity is carried THROUGH the preservation, and the entry is retired by the
  id that call just wrote.** A blanket clear would take a capture another surface is finishing; a
  check only before the save cannot see a cancel that lands inside it.
- **A cancelled Retry answers `false`.** That is the "still waiting" answer the caller already acts
  on — the reservation goes back and the capture stays queued. Answering `true` would retire an
  entry nobody finished.
- **The quit guard re-reads the count after its bounded wait and REFUSES when it is still positive.**
  The gateway registry is empty for every Work capture there has ever been, so answering from it
  alone turns a slow write into a silent deletion.
- **`PendingRetryStore.save` propagates the work-image write failure.** A swallowed one arms an entry
  whose picture was never written, and the recovery it promises then finds nothing to republish.
- **`settle` asks about cancellation BEFORE it looks at the outcome.** Inside the success arm only,
  the check that runs is the one after the write, which changes the sentence and not the desk.
