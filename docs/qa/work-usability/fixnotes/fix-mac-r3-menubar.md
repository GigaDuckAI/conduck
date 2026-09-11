# fix-mac-r3-menubar — Codex MAC-R3 findings on the Mac menu-bar Work lane

Round 3 over `docs/qa/work-usability/design/mac-work-destination.md` (⌘⇧1 Ask · ⌘⇧2 Screenshot &
Ask · ⌃⌘W Capture to Work). Thirteen findings; **eleven fixed, two declined on ownership with the
follow-up named.**

Files touched:

- `Conduck/Conduck/MenuBar/DictationService.swift` (P1-B, P1-F, P2-E, P2-H)
- `Conduck/Conduck/MenuBar/MenuBarCoordinator.swift` (P1-D, P1-E, P2-A, P2-D, P2-E)
- `Conduck/Conduck/MenuBar/MenuBarController.swift` (P2-F)
- `Conduck/Conduck/MenuBar/QuitGuard.swift` (P1-C, the pure verdict + its copy)
- `Conduck/Conduck/AppDelegate.swift` (P1-C, one branch and one helper)
- `Conduck/Conduck/Services/InAppAudioRecorder.swift` (P1-C, P2-B caller arm, one test seam)
- `Conduck/Conduck/Services/Workboard/WorkVoiceCaptureCoordinator.swift` (P2-B, one check)
- `Conduck/ConduckTests/`: `MenuBarEscCancellationContractTests`, `MenuBarWorkCaptureStateTests`,
  `MacMenuBarWorkShortcutDriftGuardTests`, `WorkboardAudioCaptureTests`,
  `PendingRetryOwnershipHandoffTests`

**Catalog rows: four, requested — not written.** This lane does not own `Localizable.xcstrings`.
See §Catalog requests.

---

## MAC-R3-P1-B — a cancel landing inside the settlement still sent · **fixed**

Real, twice over. `attemptRetry`'s check at the provider's return is the LAST one on the path:
`settleAfterFinishing` then suspends (the queue clear, the count refresh, the backlog read) and
writes `.idle` or a banner unconditionally, and `onTranscript` — a SEND — followed with no second
reading. `finishWorkRetry` had no token at all, so its four sentences were written after three more
suspensions.

Fix, three parts:

- `settleAfterFinishing` takes the `generation` and gates its SURFACE half only. The retirement, the
  deferred notice and the count are facts about the queue and settle whatever was pressed; the state
  is a description of a run. Two checks, because there are two suspensions under it.
- `attemptRetry` re-checks after the settlement, before the hand-off, and answers `true` there — the
  entry IS retired, so the capture is not still waiting and the caller must not hand a reservation
  back. What is dropped is the transcript, which is what the cancel was aimed at.
- `finishWorkRetry` takes the token and routes every sentence through one gate,
  `presentRetryOutcome`. The desk writes below it are deliberately NOT gated (R2's standing
  residual: a card half-written is worse than a card the person stopped waiting for).

Guard: `MenuBarEscCancellationContractTests.testTheSettlementCannotWriteASurfaceAfterACancel` — the
signatures pinned whole, the check ordered between the count refresh and both writes, a second check
required for the backlog hop, the re-check ordered above the hand-off, `state = .error(` refused **by
name** inside `finishWorkRetry`, and `presentRetryOutcome`'s body asserted WHOLE (which is what
rejects a gate that checks nothing).

## MAC-R3-P1-C — a failed preservation still permitted a silent quit · **fixed**

Real, and it is R2's declared residual. When phase one's desk write and `retryLane.save` both fail,
`preserveForRetry` returns silently and the function-scope `defer` gives the in-flight window back —
so ⌘Q consulted a gateway registry that is empty for every Work capture there has ever been and
terminated with the only copy of a recording. The same hole covers a SCREENSHOT whose publication and
preservation both failed while the audio landed.

R2 declined it because holding the in-flight count there is unbounded by construction: nothing
becomes durable by waiting, so the guard would refuse every ⌘Q invisibly. That reasoning is right
about the WAIT and wrong about the choice — the answer is to ask, not to refuse.

Fix:

- `InAppAudioRecorder.noteWorkDurability(_:audioInFlight:)` — one predicate over BOTH artifacts,
  read after every step that can change it: the screenshot's publication, phase one, and every exit
  of `preserveForRetry` (registered as a `defer` ABOVE its early returns, which are exactly the exits
  that park nothing). `audioInFlight` keeps "being saved" and "unsaved" apart: the first is answered
  by waiting, the second by the person.
- A separate `unsavedWorkCaptureCount`, released by durable preservation, by the HUD's ✕
  (`discardPendingWorkCapture`), by a capture replaced with a new recording
  (`abandonPendingWorkCapture`), and by a capture that finished.
- `QuitGuard.unsavedCaptureVerdict` + `UnsavedCapturePrompt` — pure, same shape as the gateway
  verdict, power-off winning unconditionally for the identical reason. `AppDelegate` asks it on BOTH
  the deferred and the direct path, destructive button first with no key equivalent.

Guard: `MacMenuBarWorkShortcutDriftGuardTests.testAQuitCannotSilentlyDiscardACaptureNothingDurable
WouldTake` — both halves of the predicate, the hold/release shape, the `defer`'s position above the
first early return, the release on both discard paths, the question asked twice in the delegate, the
modal actually run, and the verdict's body asserted whole.

## MAC-R3-P1-D — a failed typed save could delete its transferred screenshot · **fixed**

Real (and older than R2: pre-transfer, a slot claimed during the await overwrote the picture just as
completely). The synchronous transfer is correct and stays; what was missing was somewhere for the
bytes to go when the restore found the slot occupied.

Fix: `stalledWorkSaveImage` — a holding place, never a second composition. Nothing renders it, and it
has exactly two ways out: the next commit of the words it belongs to (the failure leaves those words
in the composition, untouched), or an explicit discard of those words
(`discardWorkOnlyCompose`, and the chat arm of `cancelActiveCapture`). One picture, because one
composition can only have one save in flight. The commit consumes it synchronously, above the
publication, so a second commit cannot file it twice.

Guard: extended `MenuBarWorkCaptureStateTests.testTheDeskCommitTakesThePictureFromTheSlotItsAim
Owns` — the failure arm asserted whole INCLUDING both `else` branches, the pick-up
(`stagedAtCommit ?? stalledWorkSaveImage`) and the ordered clear, with the no-`else` arm as the
control.

## MAC-R3-P1-E — a Work save's completion could re-aim a newer Ask · **fixed**

Real. The commit ends with `resetQuickDestinationAfterTurn()` when the composition looks empty — but
an empty composition says nothing about a ⌘⇧1 armed DURING the publication, which froze its own
destination. Fix: `armAtCommit` is read synchronously with the words and the picture, and the reset
is gated on `armAtCommit == armGeneration`. `armQuickCapture` moves that generation on every arm,
including the direct-response freeze.

Guard: `MenuBarWorkCaptureStateTests.testTheDeskCommitCannotResetADestinationArmedAfterIt` — the read
ordered above the `Task`, the gated condition asserted as one shape, the composition-only reset as
the control.

## MAC-R3-P1-F — a cancelled Ask start still brought a microphone up · **fixed**

Real. An Ask start suspends twice before there is anything to cancel — the Speech-Recognition
preflight and `AudioRecorder.startRecording()`'s own permission hop — and through the first the
service reads `.idle`, the one state `cancelRecording()` has no arm for.
`AudioRecorder.cancelRecording()` returns immediately while `audioRecorder` is still nil, so the
press invalidated nothing and the microphone came up behind the popover that same Esc had closed,
live until the duration cap with no surface to stop it.

Fix: `recordingStartToken`, the same shape as the Work lane's `workVoiceStartToken` and for the same
reason. Moved FIRST and unconditionally by `cancelRecording()` (above the switch, because the state
it has to reach has no arm), taken by `startRecording()`, checked after the preflight and again after
`recorder.startRecording()` — where the microphone is now live and has to be torn down. The teardown
is gated on `state != .recording` so a NEW capture started after the bail keeps the recorder it
rightfully owns. Both catch arms answer the token too: a withdrawn press draws no banner.

Guard: `MenuBarEscCancellationContractTests.testAnAskStartCarriesACancellationIdentity`.

## MAC-R3-P2-A — a successful EMPTY drain still printed "Added to Work" · **fixed**

Real, and R2's declined follow-up is no longer needed: the drain's report carries no identities, but
the CAPTURE ID does. `publishAppCapture` returns it, and the desk material carrying it is
deterministic — with a picture the image entry IS that id, without one the visible note takes it — so
one desk read answers for both shapes.

Fix: `deskHoldsWorkMaterial(_:)` on the coordinator, asked after the drain;
`landed = drained ? await deskHoldsWorkMaterial(published) : false`. A store that will not open reads
as NOT on the desk, which is the honest direction. `.saved` now means a card was read back; `.queued`
covers everything else, and the envelope is durable in both.

Guard: extended `MenuBarWorkCaptureStateTests.testTheDeskCommitDrainsBeforeItClaimsTheCardIsThere` —
the id bound, the confirmation asserted by shape, the desk read ordered after the drain, with the
drain-only receipt as the control.

## MAC-R3-P2-B — the transcript WRITE itself was ungated · **fixed**

Real, and shared with the phone desk sheet. R2 hoisted the cancellation check above `settle`'s
outcome switch, which closes the provider-return race; it cannot close the attachment's own
suspensions — `ensureLoaded()` opens a store on first use, and the Core Data operation is queued
behind it.

Fix: `try Task.checkCancellation()` inside `applyWorkVoiceTranscript`, between `ensureLoaded()` and
the write. It throws rather than reporting an outcome — nothing was attempted, so there is no
attachment verdict — and the recorder's phase-two catch maps a cancellation to `.idle` with no
banner and no retry save, exactly as `settle` already does one step earlier. The capture keeps its
debt and its Try Again.

Guard: `WorkboardAudioCaptureTests.testCancellingAfterTheWordsArriveStillKeepsThemOffTheCard` — a
REAL run through the recorder's own seams, with the press landing after recognition and before the
write, plus an uncancelled control. A new `transcriptAttachPauseForTesting` seam stands exactly in
that gap; the production path has no statement there.
**Verified as a negative control:** with `try Task.checkCancellation()` removed the case fails on
`XCTAssertNil(card.textContent)` with "the words nobody waited for".

## MAC-R3-P2-D — Esc could not reach the hand-off before dispatch · **fixed**

Real. Between the transcript and `sendUserTurn` there is no request to cancel and no recording to
stop, so `cancelActiveCapture` found nothing and the send resumed. Fix: `quickSendGeneration`, taken
at the top of `handleQuickSend` and re-checked at the commit point — below the mint, which is the
longest suspension on the path. Moved by `cancelActiveCapture` BELOW the Work-HUD return, because an
Ask send suspended underneath is not what that press was aimed at.

Guard: `MenuBarEscCancellationContractTests.testTheHandoffIsCancellableBeforeDispatch` — the check
ordered below the mint and above the dispatch, and the bump ordered below the Work-HUD return.

## MAC-R3-P2-E — Chat Retry borrowed the live composition's screenshot · **fixed**

Real (underlying U-46). The footer's Retry replays a recording captured minutes — or launches — ago,
and `handleQuickSend` read the slot, so it attached a picture staged for a different question and
emptied that slot on the way out.

Fix: `DictationService.onRecoveredTranscript`, a separate terminal hook used only by `attemptRetry`
and defaulting to `onTranscript`. The coordinator wires it to `handleRecoveredTranscript`, which
calls `handleQuickSend(carriesComposition: false)` — no attachment read, no slot cleared. The STASH
replay is deliberately untouched: it is the SAME capture resuming and its screenshot is its own.

Guard: `MenuBarWorkCaptureStateTests.testAQueuedRetryCarriesNoCompositionOfItsOwn`, plus the
hand-off anchor in the Esc contract tests.

## MAC-R3-P2-F — text-mode ⌃⌘W silently dropped a completed drag · **fixed**

Real (U-48). The pre-overlay stand-down exempts text mode; the post-await guard did not, so a typed
Work capture made during an Ask recording raised the crosshair, took the drag and returned with no
composition and no explanation. Fix: `textMode || dictationService.state != .recording`. The
Work-lane conditions stay unconditional — two Work captures at once is still one too many.

Guard: extended `MacMenuBarWorkShortcutDriftGuardTests.testTheWorkHandlerStopsSavesAndBranchesOn
InputMode`, with the unconditional form as the control.

## MAC-R3-P2-G — the shortcut and click guards did not pin the routing · **fixed (test)**

Real, both mutations. (1) The registration guard asked whether both strings appeared ANYWHERE in
`setup()`, which the swapped handlers satisfy — ⌃⌘W would start an Ask capture that can reach a
gateway. Each shortcut is now read one trailing closure at a time, and each closure is refused the
other lanes' handlers by name. (2) The secondary-click guard read only the caller; `isSecondaryClick`
itself is now asserted WHOLE, with the `.leftMouseUp` mutation as the control.

## MAC-R3-P2-H — the STT guard accepted a check before the provider · **fixed (test)**

Real. Every assertion was "the check is above the hand-off", which a check hoisted to just BEFORE
`STTClient.transcribe` also satisfies — while reading a token nothing has had the chance to move. The
guard now pins it BETWEEN `STTClient.shared.transcribe(` and `onTranscript(trimmed)`.

## MAC-R3-P2-I — durability coverage missed compression and the image write · **fixed (test)**

Real, both halves. (1) The runtime measurements are taken during the picture pipeline and at the
speech hop, so a declaration moved below the stop and the compression reads identically — and no
runtime seam in this bundle stands inside `AudioCompressor`. The declaration's POSITION is now
asserted from source, ordered above `recorder.stopRecording()` and above
`AudioCompressor.compress(audioData)`; a source guard also runs in every suite, which the macOS-only
measurement does not. (2) `try workImageData.write(...)` is pinned as a whole shape and `try?` is
refused by name.

## MAC-R3-P2-J — the typed-save guards proved neither ownership nor inertness · **fixed (test)**

Real, both mutations. (1) The flag raise and the slot consume are now ordered above
`Task { @MainActor [weak self] in`, not merely above `publishAppCapture` — a send arriving before the
task's first resumption would otherwise see the old composition and a false flag. (2) `Label(` is a
shape, not proof of inertness: the receipt row is now asserted to carry NO interaction beyond its
single saved-arm `Button(action:)` — no `onTapGesture`, no `gesture(`, and exactly one mention of
`openWorkboard`.

---

## Declined, with evidence

- **MAC-R3-P1-A (automated entry points start microphones and publish to Work)** — every file named
  is outside this lane: `Intents/RecordWorkNoteIntent.swift:69`, `Intents/ConverseIntent.swift:346`,
  `Intents/CaptureWorkboardIntent.swift:79`, `Views/Workboard/WorkboardCaptureCanvas.swift:217`,
  `Views/Workboard/WorkboardVoiceCaptureView.swift:60`. The lane owns `MenuBar/**`,
  `ScreenCapture/**`, the Mac shortcut rows in `Views/Settings/**`, and three shared services.
  Adjudicated twice by the shortcuts lane (`fix-r3-shortcuts.md`) and once here (R2). The dispute —
  "no implicit headless REROUTING to Work" versus "no headless trigger reaches Work" — is a founder
  call about `design/watch-work-destination.md:39`, not a defect this lane can settle. **Open item
  for the founder**; the shortcuts lane owns the change if the answer is the stricter reading.

- **MAC-R3-P2-C (the Watch promises phone transcription recovery without creating an entry)** —
  `Services/AppleSpeechRelayCoordinator.swift:538,763` and
  `ConduckWatch Watch App/Services/AppleRelayPendingQueue.swift:664,1178`, plus the WATCH catalog.
  None is this lane's, and the fix is a choice between persisting a `.work`/`.published` retry entry
  before acknowledging a wordless completion and changing the wrist copy — the watch lane's call, and
  the copy half needs a catalog this lane may not edit.

- **MAC-R3-P3-A (README names "Record to Work…")** — `README.md:55` is the docs lane's file and two
  docs passes are live in this session. The correction is one phrase: "Record to Work…" →
  "Capture to Work…", matching the shipped menu item and the Settings action. **Handed to the docs
  lane.**

## Residuals

- **A cancel that lands after the queue entry is RETIRED drops the transcript.** The window is the
  `clear` hop itself, and the standing rule is R1's: a cancelled run keeps nothing (`stillCurrent`
  gates the preservation too, so a first-time capture behaves identically). Re-parking a transcript
  the person just threw away would resurrect the Retry card they dismissed.
- **`finishWorkRetry`'s desk writes are still not gated on the retry token.** Unchanged from R2, and
  deliberately: unwinding a partial publication is a bigger change than the cancel is worth, and the
  card is the outcome the person wanted anyway.
- **The attachment's cancellation check cannot reach INSIDE the Core Data queue hop.** The check sits
  immediately before `context.perform`; the enqueue-to-execute gap remains, and closing it would need
  a cancellation token readable off the main actor. `Task.isCancelled` inside a queue-dispatched
  closure reads the wrong task and would answer `false` always — a check that looks right and is not.

## Catalog requests (`Conduck/Conduck/Localizable.xcstrings`, not this lane's)

| Key | Default value |
|---|---|
| `quitGuard.unsaved.single.title` | `A recording hasn’t reached your desk` |
| `quitGuard.unsaved.multiple.title` | `%lld recordings haven’t reached your desk` |
| `quitGuard.unsaved.body` | `Quitting now loses what was recorded. Try Again is still on the capture.` |
| `quitGuard.unsaved.button.keep` | `Keep the Recording` |

`quitGuard.button.quit` ("Quit Anyway") is REUSED rather than duplicated: `QuitGuard.quitAnywayTitle`
is now the single definition both prompts read.

## Nobody undo

- **`settleAfterFinishing` gates its SURFACE half only, and asks TWICE.** The retirement and the
  count are queue facts and settle regardless; the state is a description of a run. One check cannot
  cover two suspensions — the clear/refresh pair and the backlog read each need their own.
- **A cancelled Retry that already retired its entry answers `true`.** `false` means "still waiting",
  and the caller hands a reservation back for a capture that no longer exists.
- **Every sentence a Work retry prints goes through `presentRetryOutcome`.** Four call sites writing
  `state` directly is four places to forget the token, and each of them follows a different
  suspension.
- **`recordingStartToken` moves FIRST and unconditionally in `cancelRecording()`.** The state a
  suspended start reads is `.idle`, which has no arm — a bump inside the switch reaches nothing.
- **The start teardown is gated on `state != .recording`.** The recorder is shared: a NEW Ask started
  after the bail owns the microphone this call brought up, and tearing it down stops the capture the
  person is watching.
- **`quickSendGeneration` moves BELOW the Work-HUD return in `cancelActiveCapture`.** Above it, an
  Esc typed over the Work HUD cancels an Ask hand-off the person cannot see — the same mistake
  `visibleBailOwner` exists to stop the teardown making.
- **A recovered transcript takes NO composition.** The slot's contents were staged for a question
  still being composed; the stash replay is the opposite case and keeps its own picture, which is why
  `carriesComposition` defaults to `true`.
- **The typed receipt asks the DESK by name.** A drain that returned proves only that this drainer
  found nothing claimable — the desk's own observer may have claimed the envelope and then failed.
- **`noteWorkDurability` distinguishes `audioInFlight` from unsaved.** A wait cannot resolve bytes
  nothing will take, and a question has no business interrupting a write that is about to land.
- **The unsaved-capture quit is a QUESTION, not a refusal.** A ⌘Q that silently does nothing leaves
  the person no way out and no reason why; a ⌘Q that silently quits is the data loss.
- **`stalledWorkSaveImage` is a holding place, not a composition.** Nothing renders it, and it dies
  with the words it belongs to — at the NEXT commit whether or not that commit took it, because a
  hold kept past the filing of its own words would hang an old screen on whatever note is written
  next. A picture that reappeared in the slot on its own would resurrect itself over a composition
  the person had moved on from.
- **The transcript's cancellation check sits after `ensureLoaded()` and before `context.perform`.**
  Above the load it answers about a moment that has passed; inside the `perform` closure it reads a
  task that is not this one.
