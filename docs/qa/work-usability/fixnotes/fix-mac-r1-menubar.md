# fix-mac-r1-menubar — Codex MAC-R1 findings on the Mac menu-bar Work lane

Design under verification: `docs/qa/work-usability/design/mac-work-destination.md` (⌘⇧1 Ask ·
⌘⇧2 Screenshot & Ask · ⌃⌘W Capture to Work). Eight findings; **five fixed, three declined with
evidence.**

Files touched:

- `Conduck/Conduck/MenuBar/MenuBarCoordinator.swift` (P1-B, P1-C)
- `Conduck/Conduck/MenuBar/DictationService.swift` (P2-B)
- `Conduck/Conduck/MenuBar/DictationPopoverView.swift` (one comment corrected by P2-B)
- `Conduck/Conduck/Services/InAppAudioRecorder.swift` (P1-D, macOS-gated)
- `Conduck/Conduck/AppDelegate.swift` (P1-D — outside the lane's file list, additive, one
  function split plus one branch)
- `Conduck/ConduckTests/MacMenuBarWorkShortcutDriftGuardTests.swift`,
  `MenuBarWorkCaptureStateTests.swift`, `WorkboardVoiceScreenshotLaneTests.swift`,
  and the new `MenuBarEscCancellationContractTests.swift`

**Catalog rows: none.** No new user-visible string.

---

## P1-B — Return sends words already committed to Work · **fixed**

`saveQuickDraftToWork` commits across an await with the popover interactive and the composition
still in its slot (it is consumed on the way back). The Ask button is `.disabled` for exactly
that window; `.onSubmit` is not, and `sendQuickTypedDraft`'s guards never read
`isSavingQuickDraftToWork` — so on the CHAT surface (whose "Add to Work" button files a ⌘⇧2
screenshot with the words) one Return sent the same words and the same picture as a gateway
turn, under a receipt about to say "Nothing was sent."

Fix: `guard !isSavingQuickDraftToWork else { return }`, second line of `sendQuickTypedDraft`,
above every state change (a blocked send must not eat the composition). Guard:
`MenuBarWorkCaptureStateTests.testTheSendPathRefusesWhileTheDeskCommitIsStillRunning`, with the
aim-only shape as the negative control.

## P1-C — Cancelling Ask deleted a hidden Work draft · **fixed**

Reachable with no settings flip: text mode → ⌃⌘W types a Work note (words + dragged region in
the Work slots, never saved) → the main window's composer takes the microphone → the popover's
router draws `recordingStatusView` over everything → Esc → `cancelActiveCapture` read only the
stored aim (`.work`) and called `discardWorkOnlyCompose()`.

Fix: `if compose.target == .work, !askMicrophoneIsLive { discardWorkOnlyCompose() } else if
compose.target == .chat { quickDraft = "" }`. Same rule P2-A(ii) applies to the parked CAPTURE,
now applied to the parked COMPOSITION: a live Ask microphone means this bail is the Ask lane's,
and it takes that lane's recording, screenshot and draft — nothing the desk owns. The chat arm
is unchanged (that draft belongs to the lane the bail was aimed at). Guard: the composition
assertion inside `MacMenuBarWorkShortcutDriftGuardTests.testABailWhileTheAskMicrophoneIsLive…`,
negative control = the aim-only teardown.

## P1-D — ⌘Q after Stop could destroy the recording · **fixed**

`AudioRecorder.stopRecording()` returns the bytes and DELETES the file, so from the stop until
phase one copies them into the store the recording exists nowhere but memory — across the
compression and the whole picture pipeline (measured at ~1.5 s in the lane's own test).
`applicationShouldTerminate` counts gateway turns only, and by construction a Work capture is
never in that registry, so ⌘Q returned `.terminateNow` and the audio went with the process:
no card, no retry entry, nothing to recover.

Fix, in two additive halves:

- `InAppAudioRecorder.workPublicationsInFlight` (macOS only) — a COUNT, because the menu bar's
  recorder and the desk sheet's are different instances. Raised at the mint for a `.work`
  recorder, released at phase one's success (`materialID` assigned) and by a function-scope
  `defer` on every path that ends earlier (no audio, picture-only, a failure that parks the
  bytes durably). Released at phase one deliberately: after it the desk holds the recording and
  only the WORDS are owed, and those are retryable.
- `AppDelegate.applicationShouldTerminate` returns `.terminateLater` while the count is non-zero,
  waits `InAppAudioRecorder.waitForWorkPublications(timeout: .seconds(5))`, then answers with the
  SAME `quitGuardPermitsTermination()` the direct path uses (the switch is split into that
  helper so a delayed quit cannot skip the gateway alert). Skipped during a power-off — the OS
  is not waiting politely there, which is `QuitGuard`'s own existing rule.

No alert and no copy: there is nothing here for a person to decide, and the wait is a moment.
Guards: `WorkboardVoiceScreenshotLaneTests.testTheStoppedRecordingIsDeclaredInFlightUntilThe
DeskHoldsIt` (a REAL measurement — the count read from inside the picture pipeline is 1 and from
inside the speech hop is 0) and
`MacMenuBarWorkShortcutDriftGuardTests.testTheQuitGuardWaitsForAWorkCaptureThatHasNotReachedThe
Desk`.

## P2-B — Esc during Ask transcription still sent (U-49) · **fixed**

The design deferred this to "an Ask-lane pass"; the verifier re-raised it and the fix is inside
this lane's files, so it is closed here. `cancelRecording()` was a no-op in `.processing`, so
Esc closed the popover and the finished transcript still reached `onTranscript` — which SENDS —
while Settings promises "Esc always cancels the request."

Fix: a `transcriptionGeneration` the run carries from `stopAndProcess`, moved by the new
`.processing` arm of `cancelRecording()`, and read by `stillCurrent(_:)` before every terminal
step of `processAudio` / `processTranscription`: the hand-off, the preservation (a cancelled
capture must not return as a Retry nobody parked), and each error surface. The provider hop is a
foreground `URLSession` nobody retains, so what is cancelled is its RESULT, not the request.
Scope: the STOP path only. `retryLast`'s own transcription is untouched — see Residuals.
Guard: `MenuBarEscCancellationContractTests` (4 cases, each with its pre-fix negative control),
which also pins the Settings sentence so copy and behaviour cannot drift apart.

## P2-C — the microphone guard test accepted a fall-through · **fixed (test)**

Deleting `return` from `return standDownForBusyMicrophone()` satisfied every assertion while
⌃⌘W carried on into the overlay. The busy branch is now asserted as ONE squeezed shape
(condition + refusal sentence + `return standDownForBusyMicrophone()`), with the no-return
variant as an explicit control.

## P2-D — the receipt guards accepted a swallowed drain · **fixed (test)**

`try? await` with `drained = true` beneath it satisfied the presence checks. The do/catch is now
asserted as one shape, `try? await WorkCaptureDrainer` is refused by name, and the swallowed
mutation is present as a control that fails both.

---

## Declined, with evidence

- **MAC-R1-P1-A (Siri/Shortcuts start a Work capture)** — not this lane's files
  (`Intents/**`, `Views/Workboard/**`). Adjudicated and refuted by the shortcuts lane in
  `fix-r3-shortcuts.md`: the stated boundary is *no implicit headless REROUTING to Work*
  (`design/watch-work-destination.md:39`), a phrase that names Work is a deliberate press, and
  `ConverseIntent` opens no microphone — its `audioFile` is audio the shortcut already holds.
- **MAC-R1-P2-A (a returned drain does not prove the card)** — the design's own decision 9 and
  its Open-risks entry, declined there on the record: the envelope is durable either way so
  nothing can be lost, and the exact version couples a receipt to the drainer's identity rules.
  The verifier's extension (the other drainer's write fails, releases the claim, and the
  foreground refresh stops retrying) leaves the envelope QUEUED — the next drain imports it —
  so the residual is still a receipt that is early, never one that is false about the note's
  survival. Founder call, recorded in `handoff.md`, not an implementation defect.

## Residuals

- `DictationService.retryLast` / `attemptRetry` run their own transcription and do NOT read the
  generation: Esc during a RETRY's STT still lands its words. Deliberate — that path owns claims
  and reservations, and gating it half-way is worse than not gating it. One scoped follow-up:
  take the token in `retryLast`, check it before `settleAfterFinishing`, and let the reservation
  go back so the capture stays queued.
- A ⌘⇧1 VOICE turn started during a `saveQuickDraftToWork` await can still attach the ⌘⇧2
  screenshot that commit is filing (the slot is consumed on the way back). Same class as P1-B,
  different door; not seen in the finding, not fixed here.

## Nobody undo

- **A live Ask microphone outranks the stored compose aim on the bail.** The router draws the
  recording HUD over every composition, so "what the person was looking at" is the Ask lane —
  reading `compose.target` alone erases a Work draft and its picture, which exist nowhere else.
- **`sendQuickTypedDraft` refuses on `isSavingQuickDraftToWork` as well as on the aim.** The
  aim reads `.chat` on the Chat surface's own "Add to Work", so the aim guard cannot see this
  door; the disabled button is a view, and Return does not read views.
- **The Work publication count is raised BEFORE `stopRecording()` returns and released at phase
  one — not at the end of the capture.** Raising it later leaves the compression window open;
  releasing it later makes every ⌘Q wait out a speech hop for a recording already on the desk.
  The `defer` is the backstop for the exits that never reach phase one, and it is at FUNCTION
  scope: inside the mint block it fires before the publication it is protecting.
- **`applicationShouldTerminate`'s deferred answer goes back through
  `quitGuardPermitsTermination()`.** A wait that ended in a bare `reply(true)` would quit
  through a live gateway reply the alert exists to protect.
- **The STT cancellation is a generation the run CARRIES, never a flag it reads.** A flag
  cleared by the next capture lets the old run pass its check and hand the previous words to the
  new surface.
- **`stillCurrent` gates the preservation too, not only the hand-off.** A cancelled capture that
  parked itself comes back as a Retry card for words the person threw away.
