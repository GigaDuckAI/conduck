## Prior findings re-check

- W-R1-1 — CLOSED at `WatchNoteView.swift:741`, `:766`, `:540` and `WatchConversationThreadView.swift:1533`: roster-wide custom-label disambiguation and full accessibility names.
- W-R1-2 — CLOSED at `docs/qa/work-usability/handoff.md:242`, `:258`; `fixnotes/c3-watch-ui.md:135`; `README.md:55`; `project-structure.md:80`.
- W-R1-3 — CLOSED at `WatchCaptureGuardTests.swift:771`, `:822`, `:863`: the original nil-pin assertion is removed; dedicated fixtures retain non-nil pins, so deleting the corresponding Work clears at `WatchRecordingService.swift:817` or `:819` would fail them.
- W-R2-1 — STILL OPEN: legacy queued selections remain unbound; W-R4-1.
- W-R2-2 — CLOSED at `WatchRecordingService.swift:2809`, `:3068`: an older reply cannot release an already-live Work capture.
- W-R2-3 — CLOSED at `AppDelegate.swift:363`: exceeding the wait refuses termination.
- W-R2-4 — CLOSED at `WatchRecordingService.swift:2593`: deferred Chat explicitly restores its destination.
- W-R2-5 — STILL OPEN: attachment failures are retryable at `AppleSpeechRelayCoordinator.swift:502`, `:933`, but settled failures still promise nonexistent recovery; W-R4-4.
- W-R2-6 — STILL OPEN; W-R4-8.
- W-R2-7 — CLOSED at Watch `Localizable.xcstrings:3279`, `:3290`: shared error keys exist; the five stale entries and three retired chooser keys are absent.
- W-R2-8 — STILL OPEN; W-R4-7.
- W-R3-1 — CLOSED at `WatchRecordingService.swift:2809`, `:3068`, `:3091`: a new unminted Ask retains its ownership and hint.
- W-R3-2 — CLOSED at `WatchRecordingService.swift:2867`, `:2871`: an older failure cannot release an already-live Work capture.
- W-R3-3 — STILL OPEN; W-R4-1.
- W-R3-4 — CLOSED at `InAppAudioRecorder.swift:2022`, `:2091`, `:2098` and `AppDelegate.swift:382`, `:390`: failed durable preservation retains an unsaved-capture declaration and quitting asks before losing it.
- W-R3-5 — CLOSED at `WatchNoteView.swift:766`: unchanged short names participate in the final uniqueness pass.
- W-R3-6 — STILL OPEN; W-R4-4.
- W-R3-7 — CLOSED at `WatchCaptureGuardTests.swift:771`: the tautological pin assertion is gone; the remaining assertion fails if Work’s hint clear is deleted.
- W-R3-8 — STILL OPEN for retryable recorder errors; microphone-denial dismissal is fixed at `WatchWorkCaptureView.swift:246`; W-R4-5.
- W-R3-9 — STILL OPEN; W-R4-7.
- W-R3-10 — STILL OPEN; W-R4-8.

**Design assessment:** The requested chooser is implemented: every enabled, non-busy Ask opens it, gateways precede Add to Work, both destinations recheck the switch, recording names its destination, and Work forces the phone’s publication/STT path. Decisions 2 and 7’s device acceptance remains explicitly **Unrun** at `handoff.md:258`. Decision 10’s capture-ownership guarantee remains incomplete as detailed below. Decision 11’s “no new persisted state” differs from implementation: `AppleRelayPendingQueue.swift:103` adds `backendRef` for deferred routing.

**Invariant assessment:** No implicit Watch Action Button, widget, complication, notification, or recording-coordinator path to Work was found; these lead through Chat capture or read-only thread navigation (`WatchNoteView.swift:249`, `:272`, `:313`). CarPlay starts Work from its explicit picker handler (`CarPlaySceneDelegate.swift:868`). The literal *all-surface* “only Add to Work phrase intent” restriction has additional intentional exceptions: `RecordWorkNoteIntent.swift:69` and explicitly configured GigaAction Work captures (`ConverseIntent.swift:200`, `:580`). Those implement the founder’s other requested doors. Invariant **(b) fails under the expressly requested mis-stamped-destination case**, W-R4-3.

**Shared services and copy:** No additional route from correctly stamped Work recovery or its screenshot inbox to a gateway was found. Work recovery rejects Chat metadata (`WorkVoiceCaptureCoordinator.swift:276`), and phone retry returns through Work recovery before gateway sending (`ContentView.swift:1783`). The current Mac durability fixes cover the previously reported quit windows. Added catalog keys have production references and matching English defaults; retired keys have no remaining production references. `spec.md` is unchanged, the map uses present-tense end-state prose, and no `CLAUDE.md` exists in this worktree. Copy defects remain below.

**Verification limit:** This was source/history/document inspection only. Negative-control conclusions below are static predictions; no builds, tests, or mutations were run.

### W-R4-1 - P1 - Conduck/ConduckWatch Watch App/Services/AppleRelayPendingQueue.swift:822

**Claim:** Legacy deferred Ask recordings still reach the current default gateway instead of the gateway originally selected.
**Failure scenario:** On the older build, select gateway A while B is default and let the relay defer; upgrade before delivery. The entry has neither `conversationID` nor `backendRef`. Settlement claims and deletes its audio at `:661`, then passes both missing bindings through `:822`. `WatchRecordingService.swift:2726` chooses B and creates a conversation there. Avoiding the active-thread continuation does not recover A. `WatchCaptureGuardTests.swift:1072` pins creation of another conversation—it would fail if the pointer branch were restored, but explicitly permits the wrong-default routing.
**Smallest fix:** Park unbound legacy entries before transcription/claiming, retain their audio, and require an explicit gateway choice before dispatch.

### W-R4-2 - P1 - Conduck/ConduckWatch Watch App/Services/WatchRecordingService.swift:3093

**Claim:** An older Chat completion can release a deferred Chat hop during its unminted interval, allowing that hop to overwrite a newly started Work recorder.
**Failure scenario:** With older Chat A outstanding, drain an unbound-but-addressed Chat B entry. `startDeferredConverseHop` sets `.waiting` but clears `captureRequestID` at `:2581`; B then suspends creating its conversation at `:2679`. With both pins nil, A’s reply passes `liveTurnOwns` and assigns `.idle` at `:2817`. Start and speak into Work before B resumes. B subsequently stamps its mint onto the current request and assigns `.waiting` at `:2474`. Work loses its recording controls, and `stopRecording()` refuses to save because state is no longer `.recording` (`:1364`). Its audio never reaches the Work relay.
**Smallest fix:** Give deferred dispatch independent ownership before its first suspension; distinguish it from restored waiting state, and require matching ownership before resumed hops or callbacks mutate capture state.

### W-R4-3 - P1 - Conduck/ConduckWatch Watch App/Services/AppleRelayPendingQueue.swift:616

**Claim:** A reply explicitly confirming that a capture is on Work can still dispatch its transcript to a gateway when the local destination is mis-stamped Chat.
**Failure scenario:** Under the requested mis-stamp fault case, the phone has published a private recording and returns `workSaved: true`, but its queued destination is missing or unrecognised and resolves to Chat at `:133`. Settlement ignores the contradictory Work receipt, claims the clip, and calls `completeChat` at `:662`. `WatchRelayQueueRetryabilityTests.swift:269` deliberately asserts this behaviour using `.chat` plus `workSaved: true`; changing settlement to refuse that combination would fail the test. This counterexample requires the destination fault—it is not evidence that normal Work entry currently generates that stamp.
**Smallest fix:** Reject and retain contradictory Chat/Work receipts before claiming or dispatching; require destination reconciliation rather than sending or silently changing destinations. Preserve ordinary Chat coverage with `workSaved: false`.

### W-R4-4 - P2 - Conduck/Conduck/Services/AppleSpeechRelayCoordinator.swift:538

**Claim:** A settled transcription failure still promises an iPhone recovery action without creating its recovery record.
**Failure scenario:** Select cloud STT with its key missing and record Work on the wrist. The phone publishes the recording, receives `.sttMissingAPIKey`, and acknowledges without words. The wrist deletes its queued clip and displays “Saved to Work. Add the words on your iPhone.” (`WatchWorkCaptureView.swift:364`; notification at `AppleRelayPendingQueue.swift:1180`). Restoring the key exposes no retry for that capture because the relay created no phone retry entry.
**Smallest fix:** Durably create a `.work` recovery entry before acknowledging, or replace both wrist receipts with wording that promises no recovery action.

### W-R4-5 - P2 - Conduck/ConduckWatch Watch App/Views/WatchWorkCaptureView.swift:328

**Claim:** Done still presents the same recorder failure twice whenever the original audio remains retryable.
**Failure scenario:** Record Work successfully, then fail the compressed-file write before relaying (`WatchRecordingService.swift:1652`), leaving the original recording handle intact. The Work screen shows the preparation error and Done. Because `canRetry` is true, Done skips `dismissError()`, clears only Work’s outcome, and returns to the launchpad; `WatchNoteView.swift:58` immediately presents the identical error again, now with Try Again. The denial-only case is fixed, but this half is deliberately retained.
**Smallest fix:** Render the existing Try Again/Dismiss choice on the Work recorder’s error surface, preserving its audio, so recovery does not require dismissing into a duplicate error screen.

### W-R4-6 - P2 - Conduck/ConduckWatchTests/ConduckWatchSmokeTests.swift:401

**Claim:** Several new tests validate helper results while leaving the repaired production calls unpinned.
**Failure scenario:** Static negative controls expose four gaps: deleting `WatchWorkCaptureView.swift:246` leaves the Done truth-table test passing; deleting `addressedTo: entry.backendRef` at `AppleRelayPendingQueue.swift:829` leaves `WatchCaptureGuardTests.swift:914` passing because it supplies the argument directly, and leaves the enqueue test at `WatchRelayQueueRetryabilityTests.swift:478` passing; deleting the retryable-attachment branch’s `return` at phone `AppleSpeechRelayCoordinator.swift:512` leaves the helper-verdict test at `WatchWorkRelayPhoneTests.swift:284` passing while production falls through to caching success; deleting the Work failure guard at `WatchRecordingService.swift:2867` leaves `WatchCaptureGuardTests.swift:1023` passing because the separate request-ownership guard masks its removal. These assertions are vacuous for the stated call-site guarantees, although their helper checks have narrower value.
**Smallest fix:** Exercise the Done action’s state change, queue-to-deferred binding handoff, and phone attachment-failure reply orchestration; add a Work failure fixture with nil `conversationID` to isolate the destination guard.

### W-R4-7 - P3 - docs/qa/work-usability/handoff.md:250

**Claim:** The handoff still prescribes outcomes its fixtures cannot produce.
**Failure scenario:** Step 60’s dead endpoint yields a retryable deferral, so step 61 incorrectly expects those entries to disappear; step 66a expects successful default-gateway capture even with zero gateways; step 66f checks the empty-roster message under a maximum roster and labels the proposed list-sheet remedy as the failure itself.
**Smallest fix:** Separate transient and settled STT cases, expect the zero-gateway headless refusal, move empty-roster layout acceptance to 66c, and identify a list sheet as remediation if layout acceptance fails.

### W-R4-8 - P3 - README.md:55

**Claim:** The README still names a Mac command that does not exist.
**Failure scenario:** Following “Record to Work…” leads to a menu whose command is “Capture to Work…” (`Conduck/Conduck/MenuBar/MenuBarController.swift:1171`).
**Smallest fix:** Replace “Record to Work…” with “Capture to Work…”.

