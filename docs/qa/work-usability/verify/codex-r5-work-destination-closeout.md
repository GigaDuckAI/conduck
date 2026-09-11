## (1) Round-4 fixes

Static source and baseline-diff review only; no builds, tests, or file modifications.

| Finding | Verdict and evidence |
|---|---|
| **CP-R4-08** | Subscription exists in both mutually exclusive layouts, using view-scoped `onReceive`; no added observer-retention cycle or simultaneous duplicate subscription found. However, skipped changes are not reread on every exit: **R5-7**. `ContentView.swift:331`, `:337`, `:802`, `:1237`, `:1684`, `:2047`. |
| **CP-R4-02** | Normal ownership and release paths are corrected. Disconnect calls teardown, clears `anySessionActive`, and deactivates CarPlay’s session; a phone stop skipping deactivation therefore has an eventual owner release. No new deadlock or permanently stranded session found. The permission-await admission gap remains: **R5-6**. `InAppAudioRecorder.swift:927`; `AudioRecorder.swift:230`; `CarPlaySceneDelegate.swift:295`; `CarPlayRecordingService.swift:505`, `:2929`, `:2974`. |
| **CP-R4-03** | **Not closed.** Cached claims are revalidated, but the new final refusal invokes unconditional preservation and recreates completed retries: **R5-2**. `InAppAudioRecorder.swift:2061`, `:1781`, `:2004`, `:2209`. |
| **CP-R4-04** | **Closed for the reported partial-save case.** Audio/index commit and notification precede the partial outcome; the recorder records the armed ID and omitted-picture flag. Reservation and retirement remain available, while durability accounting correctly treats the picture separately. Quit wording now describes a capture rather than falsely identifying the recording alone. `PendingRetryStore.swift:759`, `:795`, `:801`; `InAppAudioRecorder.swift:2215`, `:2227`, `:2053`, `:2125`, `:2258`; `QuitGuard.swift:118`, `:133`. |
| **CP-R4-07 / MAC-R4-P2-F residual** | Both failure arms now preserve before acknowledging, but the newly parked terminal verdict disables phone recovery and can block older Chat retries: **R5-1**. `AppleSpeechRelayCoordinator.swift:559`, `:565`, `:603`, `:609`, `:855`. |
| **MAC-R4-P2-C** | Ordinary cancellation now exposes the stopped state, but ownership refusal recreates the phantom startup, and the new receipt can contradict confirmed card absence: **R5-3**, **R5-4**. `WorkboardVoiceCaptureView.swift:128`, `:302`, `:443`. |
| **MAC-R4-P2-M** | Production refusal arms currently return correctly. The new guard still does not enforce that requirement: **R5-5**. `AppleSpeechRelayCoordinator.swift:510`, `:521`; `WatchWorkRelayPhoneTests.swift:593`. |
| **Four CP-R4-10 out-of-lane rows** | The named mutations are closed by the return-verdict scan, complete release-block assertion, named Watch adapters/consumers, and complete publication-decrement assertion. `PendingRetryOwnershipHandoffTests.swift:346`; `PendingRetrySurfaceHandoffTests.swift:457`; `ErrorSurfaceDriftGuardTests.swift:2140`, `:2161`; `MacMenuBarWorkShortcutDriftGuardTests.swift:1549`. |

## (2) Shared-service regression sweep

The cumulative changes introduce the Chat recovery blockage in **R5-1**, completed-retry resurrection in **R5-2**, and desk-sheet regressions in **R5-3–4**.

No additional runtime regression was established in Mac Ask or the relay’s Chat branch. Primitive startup now rechecks its generation after permission; recovered Mac Chat handoffs retain their composition-free provenance. Work transcript cancellation reaches the queued mutation boundary. `AudioRecorder.swift:74`, `:159`, `:192`; `DictationService.swift:524`; `MenuBarCoordinator.swift:2983`, `:3249`; `WorkVoiceCaptureCoordinator.swift:645`.

`git diff a197ccd -- <file>` shows no production changes to the four named Shortcuts intents or `WorkCaptureDrainer`. Their callers still publish desk material, and the drain still checks material/payload durability before acknowledgement. `AddFilesToWorkIntent.swift:215`; `RecordWorkNoteIntent.swift:69`; `CaptureWorkboardIntent.swift:79`; `ConverseIntent.swift:659`; `WorkCaptureDrainer.swift:467`, `:514`, `:521`.

## (3) CarPlay chooser Work action

**Routing and claim lifecycle pass; no product finding.** The last row takes one synchronous claim before popping, releases it on missing-controller or failed/stale-pop refusal, and carries the same serial into presentation. The shared presentation half preserves the Mute clear, completion guard, refusal release/dismissal, and post-begin release. Disconnect clears outstanding claims. `CarPlaySceneDelegate.swift:1385`, `:1389`, `:1395`, `:1403`, `:1407`, `:692`, `:695`, `:700`, `:312`.

The literal “no `lastStartDestination` write” assertion is inaccurate: `claimStart(.work)` writes that hint bookkeeping and clears `oneShotStartFailureHint`. Those values do not choose the next destination. The Work row writes no gateway override or checkmark; New voice chat still unconditionally enters `startSession`, whose effective destination comes from the gateway override/default. `CarPlaySceneDelegate.swift:340`, `:341`, `:1370`, `:1129`, `:1304`.

Chooser reach remains unchanged: two call sites, with the navigation switcher still gated at two configured gateways. `CarPlaySceneDelegate.swift:608`, `:1112`, `:1036`.

## (4) Founder’s three intents

**No destination-crossover finding.**

- **Phone/desk:** Work recording explicitly selects `.work`; missing-card transcript fallback enters only the Work composer. Recovery rejects non-Work metadata. `WorkboardVoiceCaptureView.swift:27`; `WorkboardCaptureCanvas.swift:137`; `WorkVoiceCaptureCoordinator.swift:311`.
- **Mac menu bar:** The three shortcuts retain separate handlers. Work screenshots and failed-save holdings preserve their Work ownership; gateway attachments read only the Chat screenshot slot. `MenuBarController.swift:139`, `:145`, `:151`; `MenuBarCoordinator.swift:2055`, `:2530`, `:2687`, `:2983`.
- **Shortcuts/headless phone:** `ConverseIntent` defaults to Chat; explicit Work returns before the gateway hop. The three named Work actions use dedicated desk publication/recording routes. `ConverseIntent.swift:200`, `:659`, `:706`; `AddFilesToWorkIntent.swift:215`; `CaptureWorkboardIntent.swift:79`; `RecordWorkNoteIntent.swift:69`.
- **CarPlay:** Work and Chat starters explicitly set their destination. Work completes STT and attachment, then returns before the gateway hop. `CarPlayRecordingService.swift:581`, `:610`, `:1716`, `:1720`.
- **Watch:** Every Ask opens the chooser, whose rows always append Work—including with exactly one gateway. Work forces the phone relay; headless captures resolve the default-gateway target and stamp Chat. Notification taps open their existing conversation rather than initiating Work capture. Work acknowledgement settlement bypasses Chat completion. `WatchNoteView.swift:324`, `:659`, `:310`; `WatchRecordingService.swift:955`, `:745`, `:1677`; `AppleRelayPendingQueue.swift:677`.

## Findings

### R5-1 - P2 - Conduck/Conduck/Services/AppleSpeechRelayCoordinator.swift:855

**(a) Failure scenario:** Leave a Chat recording queued after a retryable network failure. Then record Work on Watch while the phone’s speech key is missing. The new helper inserts a newer Work entry carrying terminal error code 23. The store returns that newest code, and the phone uses its automatic-retry classification to hide Retry for the entire queue. Restoring the key and closing Settings rereads the same persisted code; neither the Work entry nor the older Chat recording is accessible through Retry. `PendingRetryStore.swift:513`, `:1178`; `ContentView.swift:1209`, `:1168`; `AppError.swift:1206`; `PendingRetryCard.swift:93`.

The terminal Work insertion is new relative to `a197ccd`; its suppression of an existing Chat retry is a fix-induced regression.

**(b) Smallest fix:** Separate explicit recovery eligibility from the historical error’s automatic-retry classification. Keep the diagnostic code, permit recovery after configuration changes, and prevent an ineligible newest entry from blocking older eligible captures.

### R5-2 - P2 - Conduck/Conduck/Services/InAppAudioRecorder.swift:1786

**(a) Failure scenario:** Start Work retry A. Its lease lapses during a stalled transcription; another surface finishes that capture and clears its queue entry. A subsequently receives successful STT, fails the new ownership check, drops its token, and calls `failPendingWorkCapture`. That helper unconditionally saves A’s capture ID and cached words again, recreating the completed retry. Its later hand-back has no claim to release. `InAppAudioRecorder.swift:1781`, `:2004`, `:2187`, `:2209`, `:2084`; `PendingRetryStore.swift:747`, `:795`.

The recreated entry can then replay A’s stale words. The **new regression is resurrection of the completed queue entry**; the baseline already permitted a stale direct attachment. `ContentView.swift:1706`; `WorkVoiceCaptureCoordinator.swift:353`.

**(b) Smallest fix:** Handle lost ownership without unconditional preservation. Mark the old claimant superseded and reconcile before permitting another retry; distinguish an absent superseded entry from one never queued. Preserve any independently unsaved picture separately.

### R5-3 - P2 - Conduck/Conduck/Views/Workboard/WorkboardVoiceCaptureView.swift:302

**(a) Failure scenario:** In the Mac desk sheet, retry a previously queued Work recording, then cancel transcription. While its stopped state remains open, use menu-bar Retry to claim that recording. Press Try Again in the sheet. The button immediately clears `transcriptionStopped`; reservation refusal leaves the recorder idle and returns a non-cancellation error, which `handle` ignores. The sheet again displays “Starting the microphone…” with no retry controls. `DictationService.swift:346`; `InAppAudioRecorder.swift:1033`; `WorkboardVoiceCaptureView.swift:133`, `:319`, `:443`.

**(b) Smallest fix:** Keep the stopped state until retry actually enters processing, or restore it when reservation refuses while the capture remains idle. Render the busy explanation in that state.

### R5-4 - P2 - Conduck/Conduck/Views/Workboard/WorkboardVoiceCaptureView.swift:128

**(a) Failure scenario:** Record and stop a phone Work note. While transcription runs, delete its newly published card from another synced device, then cancel transcription on the phone. Cancellation retains the pending capture; the final refresh can explicitly confirm the recording is gone. Nevertheless, `canRetryWorkCapture` remains true, so the new stopped state says the recording is on the desk and Try Again updates that same card. `WorkboardCaptureCanvas.swift:1296`; `InAppAudioRecorder.swift:1893`, `:1198`, `:1264`, `:283`; `WorkboardVoiceCaptureView.swift:443`.

**(b) Smallest fix:** Derive stopped-state receipt text from the recorder’s confirmed desk facts. A retained capture alone must not assert that its recording card exists.

### R5-5 - P3 - Conduck/ConduckTests/WatchWorkRelayPhoneTests.swift:593

**(a) Failure scenario:** The new guard still accepts removal of the production retryable arm’s final `return`. Its extraction chooses the next `case` anywhere later in the file before considering the nearer switch close, so unrelated catch-arm returns satisfy its assertion. Such a regression would let an attachment refusal fall through into the saved acknowledgement. The production return is currently present; this is a static coverage defect. `WatchWorkRelayPhoneTests.swift:594`, `:598`; `AppleSpeechRelayCoordinator.swift:521`, `:528`, `:572`, `:616`, `:680`.

**(b) Smallest fix:** Bound extraction to the actual switch and require each non-attached arm’s complete body to end with an unconditional return.

### R5-6 - P3 - Conduck/Conduck/Services/AudioRecorder.swift:79

**(a) Failure scenario:** A phone capture passes the new CarPlay gate, then waits for microphone permission. CarPlay starts before permission returns. The primitive skips session configuration but still constructs and starts the phone recorder, bypassing the intended busy refusal. Concurrent-start admission existed at `a197ccd`; this is an incomplete closure, not an established new P1/P2. `InAppAudioRecorder.swift:927`; `AudioRecorder.swift:63`, `:109`, `:116`; `CarPlayRecordingService.swift:620`.

**(b) Smallest fix:** Recheck CarPlay ownership after permission and before recorder construction, propagating a typed busy refusal.

### R5-7 - P3 - Conduck/Conduck/ContentView.swift:1238

**(a) Failure scenario:** Keep the phone’s retry-discard confirmation open while CarPlay queues another recording. The notification is ignored. Cancel the confirmation: `releasePendingRetryDiscard` releases its claim but never refreshes the queue. Likewise, several failed-retry exits only release their claim. The packet’s promised reread on every exit is absent, leaving the count and diagnosis stale until another refresh. This remains the baseline discovery limitation in those states. `ContentView.swift:2047`, `:1684`, `:1784`, `:1872`.

**(b) Smallest fix:** Remember a skipped queue change and consume it when retry/discard ownership ends. Revalidate ownership state before applying any asynchronously scheduled refresh.

Not clean: 0 P1, 4 P2