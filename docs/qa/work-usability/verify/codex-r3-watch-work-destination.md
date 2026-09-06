## Prior findings re-check

- W-R1-1 — STILL OPEN.
- W-R1-2 — CLOSED at `docs/qa/work-usability/handoff.md:242`, `:258`; `docs/qa/work-usability/fixnotes/c3-watch-ui.md:135`; `README.md:55`; `docs/ai-context/project-structure.md:80`.
- W-R1-3 — STILL OPEN.
- W-R2-1 — STILL OPEN.
- W-R2-2 — STILL OPEN.
- W-R2-3 — CLOSED at `Conduck/Conduck/AppDelegate.swift:363` for the five-second timeout.
- W-R2-4 — CLOSED at `WatchRecordingService.swift:2593`; transition test at `WatchCaptureGuardTests.swift:971`.
- W-R2-5 — STILL OPEN.
- W-R2-6 — STILL OPEN.
- W-R2-7 — CLOSED at Watch `Localizable.xcstrings:3279`, `:3290` and app `Localizable.xcstrings:23735`, `:23790`; referenced localization keys exist, and retired keys have no Swift/catalog references.
- W-R2-8 — STILL OPEN.

### W-R3-1 — P1 — Conduck/ConduckWatch Watch App/Services/WatchRecordingService.swift:2796

**Claim:** W-R2-2 remains open for an unminted Chat capture because a nil live conversation is still treated as a matching reply.
**Failure scenario:** Relaunch with gateway A’s background turn outstanding. Start a new Ask addressed to B during the asynchronous restore fetch (`:2877`). While B is uploading, its conversation pins remain nil. A’s reply passes `:2796`; clearing A’s persisted marker calls `clearInFlight()`, which also deletes B’s Ask hint (`:3003`), and `:2804` releases the machine. B’s transcript subsequently resolves through the default gateway instead. A’s reply itself is correctly persisted before this callback at `WatchAudioUploader.swift:1337`.
**Smallest fix:** Require current capture ownership before changing live state, and separate old persisted-marker removal from clearing current pins/hints. Add a regression fixture with an old persisted marker and a new unminted Ask.

### W-R3-2 — P1 — Conduck/ConduckWatch Watch App/Services/WatchRecordingService.swift:2841

**Claim:** An older Chat failure can still release a live Work save.
**Failure scenario:** Start Work while an older background Chat task remains outstanding after relaunch. Stop the Work recording; while compression awaits, the old task fails through `WatchAudioUploader.swift:1629`. Work has no `pendingConversationID`, so this guard permits `state = .error`. Returning to Ask now admits another capture. Work’s continuing pipeline reaches `runRelay`, whose `recordingFileURL = nil` at `:1743` can erase the replacement recording’s handle.
**Smallest fix:** Apply destination and current-capture matching to the failure callback before any live cleanup or state assignment. Add the failure counterpart of `testAnOlderChatReplyDoesNotReleaseALiveWorkSave`.

### W-R3-3 — P1 — Conduck/ConduckWatch Watch App/Services/AppleRelayPendingQueue.swift:822

**Claim:** W-R2-1 remains open for queued Ask captures written before `backendRef` existed.
**Failure scenario:** On the older build, choose gateway A while B is default and let the phone relay defer. Upgrade before delivery. The entry decodes with neither conversation nor gateway binding; `completeEntry` passes both nil, and `WatchRecordingService.swift:2684`–`:2721` selects the current pointer/default B. The clip is claimed and deleted before that wrong-gateway hop. The legacy test at `WatchRelayQueueRetryabilityTests.swift:524` checks decoding only.
**Smallest fix:** Retain unbound legacy entries and require an explicit destination before dispatch; never infer their original selection from the current default. Pin this upgrade sequence.

### W-R3-4 — P1 — Conduck/Conduck/Services/InAppAudioRecorder.swift:1162

**Claim:** Mac quit protection releases its counter even when neither publication nor retry storage preserved the recording.
**Failure scenario:** Stop a Work recording, then encounter storage failures in both desk publication and `retryLane.save`. `AudioRecorder.swift:149` has deleted the source file; `preserveForRetry` swallows the save failure at `:1974`. Returning through this unconditional defer drops the publication counter to zero while `pendingWorkCapture` holds the only bytes. With no gateway turn outstanding, ⌘Q terminates and loses the recording.
**Smallest fix:** Return durable-save success from `preserveForRetry`; retain the quit-protection ownership while unpublished bytes remain only in memory, releasing it on durable publication, successful parking, or explicit discard.

### W-R3-5 — P2 — Conduck/ConduckWatch Watch App/Views/WatchNoteView.swift:721

**Claim:** W-R1-1 remains open because final uniqueness is checked within a shortened-name group, not across the roster.
**Failure scenario:** Configure three permitted names: `Frankfurt production alpha`, `Frankfurt production beta`, and `…alpha`. Their visible labels become `…alpha`, `…beta`, and `…alpha`. The third name bypasses disambiguation at `:715` and never enters the first group’s uniqueness pass. Both chooser and recording caption remain ambiguous. The requested three-long-name fixture exists at `ConduckWatchSmokeTests.swift:553`, and the shared shortener is unchanged, but neither closes this case.
**Smallest fix:** Resolve and verify final labels across the complete roster, including unchanged short labels, before applying bounded suffixes. Add this three-name fixture.

### W-R3-6 — P2 — Conduck/Conduck/Services/AppleSpeechRelayCoordinator.swift:538

**Claim:** W-R2-5’s settled-failure receipt still promises an iPhone recovery action without creating its recovery record.
**Failure scenario:** Select a cloud speech provider with its key missing, then capture Work on the wrist. The phone publishes the recording, receives `.sttMissingAPIKey`, and acknowledges without words. The wrist deletes its clip and displays “Add the words on your iPhone” (`WatchWorkCaptureView.swift:328`; deferred notification at `AppleRelayPendingQueue.swift:1180`). No phone retry entry was created, so restoring the key offers no recovery for that recording. Attachment-write failures now correctly return retryable at phone `:933`.
**Smallest fix:** Durably create a `.work` recovery entry before acknowledging, or replace both wrist receipt strings with wording that promises no recovery action.

### W-R3-7 — P2 — Conduck/ConduckWatchTests/WatchCaptureGuardTests.swift:786

**Claim:** W-R1-3’s original test still contains the pin assertion that starts and ends nil.
**Failure scenario:** Delete either Work-specific pin clear at `WatchRecordingService.swift:817` or `:819`. `testAWorkPickAfterAnAbandonedGatewayDraftInheritsNothing` still passes because it creates a fresh service and seeds only the Ask hint. The dedicated fixtures now correctly retain real pins through `.idle` at `:822` and `:863`, but the original assertion remains vacuous under the requested negative control.
**Smallest fix:** Seed a real pin in the original fixture, or remove its pin-clear assertion and explicitly limit that test to hint clearing and absence of minting; retain the corrected dedicated fixtures.

### W-R3-8 — P2 — Conduck/ConduckWatch Watch App/Views/WatchWorkCaptureView.swift:233

**Claim:** Done on a Work recorder error dismisses the screen without dismissing the error.
**Failure scenario:** Deny microphone permission, choose Ask → Add to Work, then tap Done on the resulting error. This clears only Work’s outcome identifiers. The service remains `.error`, so `WatchNoteView.swift:58` immediately presents the same error again on the launchpad, requiring a second dismissal.
**Smallest fix:** When this request owns the displayed recorder error, call `dismissError()` before clearing its outcome and dismissing the route.

### W-R3-9 — P3 — docs/qa/work-usability/handoff.md:250

**Claim:** W-R2-8 remains open because the QA fixtures still prescribe outcomes their setup cannot produce.
**Failure scenario:** Step 60’s dead custom endpoint produces a retryable failure, so Work remains queued and shows the deferred receipt; step 61 incorrectly expects those entries to disappear. Step 66f checks the empty-roster message with a maximum roster, where that message cannot render. Step 66a also expects a default-gateway capture with zero configured gateways, which correctly refuses.
**Smallest fix:** Separate retryable and settled STT fixtures; move the empty-roster layout assertion to 66c; make 66a expect the established headless refusal for zero gateways. Describe a list sheet as the remediation for failed layout acceptance.

### W-R3-10 — P3 — README.md:55

**Claim:** W-R2-6 remains open: the README names a nonexistent Mac command.
**Failure scenario:** Following “Record to Work…” in the README leads to a menu containing only “Capture to Work…” (`MenuBarController.swift:1162`).
**Smallest fix:** Replace “Record to Work…” with “Capture to Work…”.

