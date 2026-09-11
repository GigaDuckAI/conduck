## Findings

### [P1] Siri and Shortcuts can start Work captures without a deliberate press

- **file:line** — `Conduck/Conduck/Intents/AppShortcuts.swift:74–81`; `Conduck/Conduck/Intents/RecordWorkNoteIntent.swift:65–74`; `Conduck/Conduck/Views/Workboard/WorkboardCaptureCanvas.swift:217–222`; `Conduck/Conduck/Views/Workboard/WorkboardVoiceCaptureView.swift:60–66`.
- **Failure scenario** — Invoke the registered “Record a note to Work” Siri phrase. The intent requests `WorkVoiceCaptureLaunchRoute`, its notification opens the capture sheet, and the sheet’s `.task` starts the microphone. Foreground presentation never requires a press. Separately, a Shortcut can supply audio to `ConverseIntent(destination: .work)`, which publishes through `WorkVoiceCaptureCoordinator` at `Conduck/Conduck/Intents/ConverseIntent.swift:346–354`. These pre-existing routes disprove the hard hands-free boundary.
- **Smallest fix** — Make intent-driven navigation stop at an unarmed capture surface requiring a recording-button press; reject `.work` in the headless `ConverseIntent` path. Add negative controls invoking these shipping entry points and asserting no recorder start or Work publication.

### [P1] Return can send a composition already committed to Work

- **file:line** — `Conduck/Conduck/MenuBar/DictationPopoverView.swift:617–626,744–748`; `Conduck/Conduck/MenuBar/MenuBarCoordinator.swift:1870–1905,2307–2347,2565–2594`.
- **Failure scenario** — In text mode’s Chat composer, write a private note and click **Add to Work**. While publication or draining is suspended, press Return in the field. The Ask button is disabled, but `.onSubmit` still calls `sendQuickTypedDraft()`, whose guards omit `isSavingQuickDraftToWork`. The draft remains in the Chat slot until the drain completes, so `handleQuickSend` sends the same words to the gateway; its screenshot can accompany them. This pre-existing path violates the Work boundary and can contradict the eventual “Nothing was sent” receipt.
- **Smallest fix** — Guard `sendQuickTypedDraft()` against `isSavingQuickDraftToWork` before consuming anything. Add a suspended-save test that presses the shipping send entry point and asserts zero gateway turns and attachments.

### [P1] Cancelling Ask still deletes a hidden Work draft

- **file:line** — `Conduck/Conduck/MenuBar/MenuBarCoordinator.swift:1064–1080,1795–1824,1950–1953`; `Conduck/Conduck/MenuBar/MenuBarController.swift:247–291`.
- **Failure scenario** — Use text-mode Ctrl-Cmd-W, write an unsaved Work draft, then change Settings to voice mode. The settings observer preserves the words and `.work` target. Start Ask with Cmd-Shift-1 and press its ✕ or Esc. P2-A now preserves the parked Work **recorder**, but `cancelActiveCapture()` still calls `discardWorkOnlyCompose()` because the stored compose target remains `.work`. Returning to text mode reveals that the unseen draft was erased. This pre-existing deletion remains outside the new cancellation guard.
- **Smallest fix** — Apply the captured `askMicrophoneIsLive` decision to composition teardown too: cancelling a live Ask must preserve parked composition text. Extend the cancellation test to assert that `quickWorkDraft` survives this mode-switch sequence.

### [P1] Quitting after Stop can permanently lose the Work recording

- **file:line** — `Conduck/Conduck/Services/AudioRecorder.swift:126–151`; `Conduck/Conduck/Services/InAppAudioRecorder.swift:1122–1202,1257–1272`; `Conduck/Conduck/AppDelegate.swift:339–347`.
- **Failure scenario** — Record with Ctrl-Cmd-W, stop, and quit while compression or screenshot normalization/publication is pending. `stopRecording()` has already deleted the audio file. The audio remains only in memory until the screenshot pipeline finishes and `publishRecording()` runs. The quit guard counts gateway turns only, so a Work-only capture permits immediate termination. Relaunch has neither a recording card nor a retry entry. This pre-existing durability gap remains.
- **Smallest fix** — Include unfinished Work capture publication in `applicationShouldTerminate`; delay termination until the stopped capture has a durable queue entry. Preserve stopped audio before the screenshot pipeline’s awaits.

### [P2] A returned drain still does not prove the typed card exists

- **file:line** — `Conduck/Conduck/MenuBar/MenuBarCoordinator.swift:2333–2373`; `Conduck/Conduck/Services/Workboard/WorkCaptureDrainer.swift:239–270,543–554`; `Conduck/Conduck/Services/WorkCaptureInbox.swift:486–558,667–675`.
- **Failure scenario** — Keep the main Work window mounted and save a typed note from the popover. Its notification-driven drainer claims the envelope first. The popover’s independent drainer finds nothing claimable and returns successfully, producing **Added to Work** and its “see the new card” button. If the first drainer’s store write then fails, it releases the envelope; no card exists. The foreground refresh deliberately stops retrying after such failure (`Conduck/Conduck/Views/Workboard/PersonalWorkbenchView.swift:743–752`). This is the design’s acknowledged P2-D residual, and it can persist beyond a momentary race.
- **Smallest fix** — Retain the published capture ID and issue `.saved` only after that capture’s completed import is confirmed. An empty drain while another consumer holds the capture must remain `.queued`.

### [P2] Esc during Ask transcription still sends despite the Settings promise

- **file:line** — `Conduck/Conduck/MenuBar/DictationService.swift:195–207,855–878`; `Conduck/Conduck/MenuBar/MenuBarController.swift:756–758`; `Conduck/Conduck/Views/Settings/MacGeneralCategory.swift:255–259`.
- **Failure scenario** — Stop Cmd-Shift-1 or Cmd-Shift-2 recording, then press Esc while STT is running. The popover closes, but `cancelRecording()` does nothing in `.processing`. Successful STT subsequently invokes `onTranscript`, which reaches the gateway. Settings still says “Esc always cancels the request.” The design records this pre-existing Ask defect, but it remains within the requested hotkeys review.
- **Smallest fix** — Give `DictationService`’s transcription task a cancellation generation, invalidate it on Esc, and check it before `onTranscript`. Assert that completing a suspended STT request after cancellation produces no send.

### [P2] The new microphone guard test does not require the branch to return

- **file:line** — `Conduck/ConduckTests/MacMenuBarWorkShortcutDriftGuardTests.swift:702–756`; `Conduck/Conduck/MenuBar/MenuBarController.swift:461–463`.
- **Failure scenario** — Remove `return` from `return standDownForBusyMicrophone()`. By inspection, `testTheWorkPressStandsDownBeforeTheOverlayWhileAMicrophoneIsHeld` still satisfies every assertion: the lease check precedes capture, the helper is present, and the refusal text remains. Ctrl-Cmd-W nevertheless continues into the overlay while another microphone is held. Its literal negative control never checks this mutation.
- **Smallest fix** — Assert that the helper call **inside the busy branch** returns from the handler. Add the otherwise-identical branch without `return` as a negative control; preferably exercise the shipping routing decision and assert zero overlay invocations.

### [P2] Both new receipt guards accept a swallowed drain error

- **file:line** — `Conduck/ConduckTests/MenuBarWorkCaptureStateTests.swift:379–466`.
- **Failure scenario** — Change the shipping drain call back to `try? await`, retaining `drained = true`, the unreachable catch assigning `false`, and the receipt ternary. By inspection, both `testTheDeskCommitDrainsBeforeItClaimsTheCardIsThere` and `testTheTypedReceiptSaysQueuedWhenTheDrainThrew` retain all their required strings and ordering. A failed import again reports **Added**. The negative control deletes the branching scaffolding, so it does not challenge this failure.
- **Smallest fix** — Inject a throwing drain into the shipping save path and assert `.queued`, with a successful-import control asserting `.saved`. At minimum, assert an unswallowed `try await` in the actual drain expression and test the `try?` mutation.

Not clean: 4 P1, 4 P2