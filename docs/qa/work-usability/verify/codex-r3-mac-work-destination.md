Not clean. The three shortcut registrations and the ordinary Work flow match the design: ⌘⇧1 Ask, ⌘⇧2 Screenshot & Ask, and ⌃⌘W screenshot plus voice to Work. Optional screenshots, separate picture/audio cards, microphone precedence, secondary-click handling and the plural Settings header are implemented.

The hard human-press boundary is not enforced. Cancellation, durability and cross-capture ownership defects also remain. This is a source-only assessment; no builds or tests were run. Mutation-survival statements below are conclusions from reading the assertions.

Paths are relative to the supplied worktree.

## MAC-R3-P1-A — Automated entry points still start microphones and publish to Work

**Severity:** P1  
**Files:** `Conduck/Conduck/Intents/RecordWorkNoteIntent.swift:69`; `Views/Workboard/WorkboardCaptureCanvas.swift:217`; `Views/Workboard/WorkboardVoiceCaptureView.swift:60`; `Intents/ConverseIntent.swift:346`; `Intents/CaptureWorkboardIntent.swift:79`.

**Failure sequence:**

1. Invoke the registered Siri phrase “Record a note to Work.”
2. `RecordWorkNoteIntent.perform()` requests `WorkVoiceCaptureLaunchRoute`.
3. Notification, destination activation or view appearance consumes that route and presents the sheet.
4. The sheet’s `.task` calls `recorder.startRecording()` without a recording-button press.

Independent publication paths also violate the requirement: background `CaptureWorkboardIntent` directly writes supplied text, and `ConverseIntent(destination: .work)` publishes supplied audio. `AddFilesToWorkIntent` similarly feeds the envelope/drain path without establishing press provenance.

The declines of **MAC-R1-P1-A / MAC-R2-P1-A are not defensible against this packet**. “The phrase is the press” substitutes a weaker boundary; file ownership does not resolve the violation.

**Smallest fix:** Automated entry points may stage content or navigate to an unarmed surface. Require an explicit human action before microphone acquisition or initial Work publication, and preserve that authorization through asynchronous completion.

## MAC-R3-P1-B — Retry cancellation still loses the race against settlement

**Severity:** P1  
**Files:** `Conduck/Conduck/MenuBar/DictationService.swift:488`, `:566`, `:665`.

**Failure sequence:**

1. Retry a queued Chat recording.
2. STT succeeds and passes `stillCurrent(generation)` at line 462.
3. `settleAfterFinishing(claim)` suspends while clearing the queue entry or refreshing its count.
4. Press Esc, then start a new Ask recording.
5. Settlement resumes and writes `.idle` or `.error` over the new recording.
6. `attemptRetry` calls `onTranscript(trimmed)` without another generation check, sending the cancelled retry.

Work recovery has the same stale-state problem: `finishWorkRetry` receives no generation and writes state after ownership, screenshot and recovery awaits. Accepting a completed desk write does not justify overwriting a newer microphone’s state.

**MAC-R2-P1-D is incomplete.** The preservation checks and provider-return check are real fixes, but “every suspension” is not guarded.

**Smallest fix:** Carry the token through both settlement helpers, check after their awaits before surface mutations and before handoff, and preserve recoverability if cancellation arrives after queue retirement. Add suspended-settlement cases for Chat and Work followed by a fresh recording.

## MAC-R3-P1-C — Failed preservation still permits quitting with the only capture copy in memory

**Severity:** P1  
**Files:** `Conduck/Conduck/Services/InAppAudioRecorder.swift:1162`, `:1335`, `:1974`; `Conduck/Conduck/AppDelegate.swift:349`.

**Failure sequence:**

1. Stop a Work recording; `AudioRecorder.stopRecording()` reads and deletes its file.
2. Recording publication fails.
3. `retryLane.save` also fails; `preserveForRetry` silently returns.
4. The function-scope defer releases `workPublicationsInFlight`.
5. Press ⌘Q. With no gateway turn and count zero, termination proceeds.
6. Relaunch has neither the recording card nor its retry entry.

There is another unprotected artifact: screenshot publication and preservation can fail, then audio publication succeeds and releases the count while the screenshot remains memory-only.

The timeout refusal and propagated image-write error are fixed. **MAC-R1-P1-D / MAC-R2-P1-E are nevertheless only partly fixed**, as the second fixnote itself acknowledges.

**Smallest fix:** Track unresolved durability per capture, including its screenshot. Release protection only after durable preservation or explicit discard. A failed preservation needs an explicit unsaved-capture quit decision; silently allowing loss is not a defensible substitute.

## MAC-R3-P1-D — A failed typed save can permanently lose its transferred screenshot

**Severity:** P1  
**File:** `Conduck/Conduck/MenuBar/MenuBarCoordinator.swift:2386`, `:2453`.

**Failure sequence:**

1. Stage screenshot A and press **Add to Work**.
2. The new synchronous transfer clears its composition slot.
3. While publication is suspended, stage screenshot B in that slot.
4. Publication of A throws.
5. The failure arm refuses to restore A because the slot contains B.
6. The task releases its snapshot. A has no card, envelope, retry entry or remaining composition reference.

Keeping B is correct, but discarding A is a new data-loss consequence of the R2 fix.

**Smallest fix:** Retain a failed-save snapshot independently of the active composition until retry or explicit discard. Alternatively, prevent replacement staging until publication has settled.

## MAC-R3-P1-E — Completion of a Work save can retarget a newer Ask capture

**Severity:** P1  
**File:** `Conduck/Conduck/MenuBar/MenuBarCoordinator.swift:2429`, `:1701`, `:2525`.

**Failure sequence:**

1. Begin a typed Work save and leave its publication/drain suspended.
2. Switch to voice mode, select a non-default Chat destination and start ⌘⇧1.
3. Ask freezes that selection.
4. The older Work save completes. With the Chat draft and screenshot slot empty, it calls `resetQuickDestinationAfterTurn()`.
5. That clears the newer Ask’s explicit destination and schedules automatic resolution.
6. Stop Ask. `handleQuickSend` consumes the replacement destination.

The menu-entry rearming fix does not close this second route to changing an in-flight capture’s destination.

**Smallest fix:** Associate destination cleanup with the composition/capture generation that owns it. A Work completion must not reset an Ask arm created after its commit.

## MAC-R3-P1-F — Cancelling an Ask start can still be followed by a hidden live microphone

**Severity:** P1  
**Files:** `Conduck/Conduck/MenuBar/DictationService.swift:720`, `:772`; `Conduck/Conduck/Services/AudioRecorder.swift:46`.

**Failure sequence:**

1. Press ⌘⇧1 with permissions already granted.
2. Suspend the asynchronous speech preflight before `beginRecordingSession()`.
3. Press Esc in the popover. The service is still idle, so cancellation invalidates no startup.
4. Resume preflight.
5. `beginRecordingSession()` starts recording after the popover has closed.

The later `recorder.startRecording()` await has the same missing startup identity: cancelling while it is suspended does not prevent its eventual microphone start.

**Smallest fix:** Give Ask startup a cancellation identity covering both awaits, invalidate it on bail, and tear down a microphone that completes a cancelled start. The Work startup token already demonstrates the required pattern.

## MAC-R3-P2-A — A successful empty drain still produces a false “Added to Work” receipt

**Severity:** P2  
**Files:** `Conduck/Conduck/MenuBar/MenuBarCoordinator.swift:2393`, `:2416`; `Services/Workboard/WorkCaptureDrainer.swift:248`; `Views/Workboard/PersonalWorkbenchView.swift:745`.

**Failure sequence:**

1. Save a typed capture while the main desk is mounted.
2. Its observer claims the envelope first.
3. The popover’s separate drainer finds nothing claimable and returns successfully.
4. The popover announces **Added to Work** and offers **Open Work and see the new card**.
5. The claimant’s persistence fails, releases the envelope and stops its retry loop.
6. No card exists until another drain trigger succeeds.

This can persist beyond a brief race. Envelope survival proves survival, not arrival. **MAC-R1-P2-A / MAC-R2-P2-A remain valid; the decline does not refute them.**

**Smallest fix:** Retain the returned capture ID and keep `.queued` until that capture’s completed import is confirmed, including escape identities and required payloads. A conservative always-queued receipt is also honest until confirmation exists.

## MAC-R3-P2-B — Work cancellation still does not guard the transcript write itself

**Severity:** P2  
**Files:** `Conduck/Conduck/Services/InAppAudioRecorder.swift:1603`; `Services/Workboard/WorkVoiceCaptureCoordinator.swift:536`.

**Failure sequence:**

1. A successful transcript passes the new cancellation check in `settle`.
2. Attachment suspends in `ensureLoaded()` or while its Core Data operation is queued.
3. Press **Cancel transcription** before the write executes.
4. `applyWorkVoiceTranscript` writes the transcript and saves without checking cancellation.
5. The later recorder check returns cancellation after the words have landed.

This affects the Mac popover and phone desk sheet. The exact provider-return race from **MAC-R2-P2-B is closed**, but cancellation during attachment remains.

**Smallest fix:** Carry cancellation authorization to the actual write boundary and check it before mutation. Extend the test with cancellation after recognition but before transcript persistence.

## MAC-R3-P2-C — Watch recovery copy still promises an unavailable phone action

**Severity:** P2  
**Files:** `Conduck/Conduck/Services/AppleSpeechRelayCoordinator.swift:538`, `:763`; `Conduck/ConduckWatch Watch App/Services/AppleRelayPendingQueue.swift:664`, `:1178`.

**Failure sequence:**

1. The phone publishes a Watch Work recording.
2. Transcription fails terminally, for example because the speech key is missing.
3. The relay acknowledges `workSaved: true` with empty text.
4. The Watch consumes its entry and displays **Saved to Work. Add the words on your iPhone.**
5. No phone retry entry was created, and the audio card exposes no transcription action.

The longer retry TTL cannot help an entry that does not exist. **MAC-R2-P2-C remains open.** Ownership is a reasonable implementation assignment, not a reason to exclude the defect from this shared-service verification.

**Smallest fix:** Persist a recoverable published Work entry before acknowledgement, or change both notification and wrist copy to promise only the saved recording.

## MAC-R3-P2-D — Esc still cannot cancel the Ask handoff before dispatch

**Severity:** P2  
**File:** `Conduck/Conduck/MenuBar/MenuBarCoordinator.swift:1029`, `:2507`, `:2680`.

**Failure sequence:**

1. Ask finishes STT. Its callback sets `turnStarting` and launches the asynchronous send.
2. Suspend `handleQuickSend` during destination/settings resolution, before a gateway request exists.
3. Press Esc.
4. `cancelActiveCapture()` finds neither processing dictation nor an awaiting-reply task to cancel.
5. The send resumes and calls `sendUserTurn`.

The Settings promise **“Esc always cancels the request”** therefore remains broader than the implementation, despite the ordinary STT fix.

**Smallest fix:** Retain cancellation ownership through the handoff and recheck it before committing a turn. Include cancellation during a suspended pre-dispatch hop.

## MAC-R3-P2-E — Chat Retry still borrows another composition’s screenshot

**Severity:** P2  
**Files:** `Conduck/Conduck/MenuBar/DictationService.swift:495`; `MenuBarCoordinator.swift:2654`; `DictationPopoverView.swift:1657`.

**Failure sequence:**

1. Leave Chat recording A in the retry queue.
2. Stage screenshot B with text-mode ⌘⇧2 for a different question.
3. Press the footer’s saved-recording **Retry**.
4. A’s transcript reaches `handleQuickSend`.
5. It attaches B from the current `pendingCaptureImage` slot and subsequently clears that slot.

The R2 Work-commit transfer closes leakage of a successfully committed Work screenshot. It does not close **U-46**, the underlying Chat attachment-ownership defect.

**Smallest fix:** Retry must carry its own attachment snapshot and leave the active composition untouched.

## MAC-R3-P2-F — Text-mode Work capture still silently drops a completed drag

**Severity:** P2  
**File:** `Conduck/Conduck/MenuBar/MenuBarController.swift:518`.

**Failure sequence:**

1. Use text input mode while the shared Ask service is recording.
2. Press ⌃⌘W. The pre-overlay microphone check correctly exempts text mode.
3. Drag a screenshot.
4. The unconditional post-await `dictationService.state != .recording` guard returns.
5. No Work composition opens and no refusal explains the discarded drag.

This is the recorded **U-48** limitation, still present. It is a real narrow defect even though decision 7 deliberately retains it.

**Smallest fix:** Apply the post-await microphone restriction only to voice capture, or refuse text capture before the overlay with an explicit explanation.

## MAC-R3-P2-G — Shortcut and secondary-click guards do not pin their actual routing

**Severity:** P2  
**Files:** `Conduck/ConduckTests/MacMenuBarWorkShortcutDriftGuardTests.swift:76`, `:647`; production `MenuBar/MenuBarController.swift:139`, `:217`.

Two small mutations survive the relevant guards:

| Guard | Surviving mutation | Wrong result |
|---|---|---|
| Work shortcut registration | Swap the Ask and Work callback bodies in `setup`. Both searched strings remain somewhere in the function. | ⌃⌘W starts Ask and can send to a gateway. |
| Secondary click opens the menu | Change `isSecondaryClick`’s `.rightMouseUp` comparison to `.leftMouseUp`. The hoisted caller remains exact. | An ordinary right-click during Ask recording falls through to stop-and-send. |

**Smallest fix:** Bind each shortcut assertion to its own registration closure, and test event classification as well as the handler’s ordering. The current production mappings are correct; their protection is incomplete.

## MAC-R3-P2-H — The new STT cancellation guard accepts checking before the provider await

**Severity:** P2  
**File:** `Conduck/ConduckTests/MenuBarEscCancellationContractTests.swift:98`; production `MenuBar/DictationService.swift:958`.

**Mutation and failure sequence:**

1. Move the success-path `guard stillCurrent(generation)` from after `STTClient.transcribe` to immediately before it.
2. The test still finds a check before `onTranscript`, enough checks overall, and the unchanged preservation checks.
3. Start Ask, stop, then cancel while the provider is suspended.
4. The provider returns and the cancelled transcript is sent.

The helper-body test correctly rejects `token == token`; it does not establish that the call occurs after the suspension being guarded.

**Smallest fix:** Pin the successful guard between provider completion and handoff, preferably with a suspended-provider test through the shipping path.

## MAC-R3-P2-I — Durability tests miss both compression coverage and image-write failure propagation

**Severity:** P2  
**Files:** `Conduck/ConduckTests/WorkboardVoiceScreenshotLaneTests.swift:189`; `MacMenuBarWorkShortcutDriftGuardTests.swift:1148`; production `Services/PendingRetryStore.swift:751`.

Two plausible regressions remain unpinned:

| Guard | Smallest surviving mutation | Failure sequence |
|---|---|---|
| Work publication protection | Move the counter declaration below compression, keeping it before screenshot publication. | Stop → quit during compression → only audio copy disappears. The measurements still see 1 during picture processing and 0 during STT. |
| Screenshot retry durability | Restore `try? workImageData.write`. | Image write fails → save reports success → caller trusts nonexistent preservation → quit loses the screenshot. Successful-write fixtures remain unchanged. |

The counter measurement is also macOS-only, so the prescribed iOS suite cannot execute it.

**Smallest fix:** Measure protection across a suspended compression step and inject a failure specifically at the image write. Assert that failed preservation cannot authorize termination.

## MAC-R3-P2-J — Typed-save guards do not prove synchronous ownership or inert queued feedback

**Severity:** P2  
**File:** `Conduck/ConduckTests/MenuBarWorkCaptureStateTests.swift:403`, `:1007`.

| Guard | Smallest surviving mutation | Wrong result |
|---|---|---|
| Synchronous save transfer | Move the `Task` opening above the flag raise and slot consumption. Counts and ordering before `publishAppCapture` remain satisfied. | A send invoked before the task runs sees the old composition and false saving flag. |
| Queued receipt is inert | Add `.onTapGesture { openWorkboard() }` to the queued `Label`. | A queued receipt becomes actionable despite there being no confirmed card. The label and single-button assertions still pass. |

**Smallest fix:** Assert that ownership changes precede task creation, and verify queued interaction behavior rather than treating `Label` syntax as proof of inertness.

## MAC-R3-P3-A — README names a Mac menu item that does not exist

**Severity:** P3  
**File:** `README.md:55`.

**Failure sequence:** Read the Work introduction, then look for its advertised **Record to Work…** menu item. The shipped menu and Settings action are **Capture to Work**.

**Smallest fix:** Use **Capture to Work…** in that sentence. The action/commit distinction—**Capture to Work** versus **Add to Work**—is otherwise coherent.

The remaining boundary tracing found no direct desk-to-gateway path: `WorkCaptureInbox` feeds `WorkCaptureDrainer`’s desk writes; `WorkVoiceScreenshotCoordinator` only publishes/drains; `WorkVoiceCaptureCoordinator.recover` refuses non-Work records; Mac `.work` retries return through `finishWorkRetry`; and Watch `.work` settlement bypasses `completeChat`. The shared TTL change preserves Chat’s ten-minute budget, gives published Work recordings a day, and retains separate protection for unpublished material. Those observations do not establish the missing human-press boundary.

Every prior outcome rechecks as follows:

| Prior finding(s) | Round-3 disposition |
|---|---|
| R1-P1-A, R2-P1-A | Open: MAC-R3-P1-A. |
| R1-P1-B, R2-P1-B | Original Return and committed-screenshot leaks closed. New save failures are P1-D/E; remaining test gaps are P2-J. |
| R1-P1-C, R2-P1-C | Closed for the reported visible-owner cancellation cases. Owner resolution and teardown now agree. |
| R1-P1-D, R2-P1-E | Partial: timeout refusal and image-error propagation fixed; P1-C remains. Durability coverage has P2-I gaps. |
| R1-P2-A, R2-P2-A | Open: P2-A. |
| R1-P2-B | Ordinary stop/STT cancellation fixed, including stale preservation cleanup. Broader cancellation holes remain in P1-B/F and P2-D. |
| R1-P2-C | Missing-return mutation is rejected. |
| R1-P2-D | Swallowed-drain mutation is rejected. |
| R2-P1-D | Partial: settlement still permits stale state and handoff, P1-B. |
| R2-P2-B | Original provider-return cancellation race fixed; attachment-await race remains, P2-B. |
| R2-P2-C | Open: P2-C. |
| R2-P2-D | Inverted stand-down visibility mutation is rejected. |
| R2-P2-E | Wrong queued-kind mutation is rejected; inert interaction remains unpinned, P2-J. |

