Reviewed the repository’s **draft 2**; no revised stdin was attached. That file lists **four service tests, not five**.

1. **NIT — HELD: Work-last is defensible now.** I no longer object to the stated AI-first priority. Correct two remaining claims: `configuredBackendRefs()` puts built-ins in enum order, so the first row is not necessarily the person’s first-added or default gateway; and watchOS Cancel is normally upper-left, not a final row. **Fix:** Say “gateways in roster order, Work last among destinations; system dismissal.” Remove “always one tap” from `beginInAppAsk`’s proposed comment where scrolling may intervene. [Apple’s guidance](https://developer.apple.com/design/human-interface-guidelines/action-sheets?changes=_1).

2. **MINOR — HELD: keeping `confirmationDialog` is reasonable, but the acceptance criterion remains weak.** Reuse and maintenance cost justify trying the existing presentation. My strongest remaining objection: **“every row is reachable” does not establish that people can reliably distinguish and select the intended destination.** Apple’s recommendation remains three choices plus Cancel; three gateways already exceed it.

   **Fix:** Keep the dialog provisionally, but test the maximum supported roster—not merely the founder’s current roster—with long similar names, largest text and VoiceOver. Require readable labels and reliable selection without accidental activation while navigating. Change presentation only if that fails. [Apple’s watchOS action-sheet guidance](https://developer.apple.com/design/human-interface-guidelines/action-sheets?changes=_1).

3. **MINOR — The new destination cue has narrower coverage than decision 7 claims.** The `.new` fallback is correct. However, `.existing(id)` starts with a nonnil `conversationID`; its name still depends on `viewModel.conversations`, which may be empty during cold loading. `loadThread(for:)` loads messages, not that roster. A custom missing from both badge rosters intentionally remains unnamed. AOD intentionally shows no destination.

   **Fix:** In [WatchConversationThreadView.swift](</Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/ConduckWatch Watch App/Views/WatchConversationThreadView.swift:229>), resolve the persisted conversation’s ref first; use `autoCaptureTarget.new` **only when `conversationID == nil`**; then apply the existing missing-custom guard before `shortDisplayName`. Never substitute the default for `.existing`. Narrow the guarantee to “while the wrist is raised and destination metadata is available”; remove the unconditional headless claim.

4. **MINOR — Adding the overlay caption needs its own small-face check.** `WatchThreadCaptureOverlay` has a centered, non-scrolling `VStack`, an 80-point ring, timer, optional duration warning and Stop, with a separate 44-point Cancel overlay. Another line can crowd Stop or overlap Cancel at large text.

   **Fix:** Place the caption before the `if isLive` branch so it appears during arming too. Explicitly reserve clearance from Cancel and verify arming, recording and the near-limit warning on 41 mm. Keep Cancel and Stop fully reachable; do not sacrifice their hit areas or silently clip the destination. Leave AOD unchanged.

5. **MINOR — Chooser dismissal still misses other navigation replacements.** Dismissing in the successful headless `.directStart` and `.pushAndStart` arms is correct. But `drainDeepLinkIfNeeded()` also replaces navigation. The earlier headless-resolution refusal branch can replace the launchpad with an error before reaching either successful arm.

   **Fix:** In [WatchNoteView.swift](</Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/ConduckWatch Watch App/Views/WatchNoteView.swift:271>), dismiss the chooser after an accepted deep-link guard, before replacing `path`; also retire it when an accepted external refusal replaces the root with an error. Preserve the busy-refusal ordering. Add QA for chooser → notification and chooser → unavailable headless gateway → Dismiss.

6. **MAJOR — The explicit-pick test names a transport seam that does not exist.** `stageGateways(..., chosen: false)` exists, but a configured Hermes followed by `startConverseHop` can reach `WatchAudioUploader.shared.uploadConverse`. Neither `sttUpload` nor `relayTranscribe` intercepts that call. Existing mint tests deliberately use unavailable refs to stop before transport. [WatchRecordingService.swift](</Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/ConduckWatch Watch App/Services/WatchRecordingService.swift:2455>).

   **Fix:** Split the assertions: prove an accepted explicit start writes the Hermes hint despite no chosen default; then prove hint-driven minting bypasses the default gate using an unavailable captured ref, as `WatchDraftMintTests` does. Alternatively, remove Hermes after selection while retaining another configured gateway and `chosen: false`, then assert one Hermes-bound conversation and the subsequent configuration refusal. Neither version claims successful network dispatch.

7. **MAJOR — Both transition tests need stronger preconditions, and two assertions cannot compile.** `pendingConversationID` and `mintedConversationID` are `private`; `@testable` cannot read them. Moreover, `cancelRecording()` already clears the hint and resets the lane to `.chat`. The reverse test therefore passes even if `startCapture` stops stamping `.chat`.

   **Fix:** Use `inFlightConversationID == nil`, unchanged `captureMintCount`, and the injected store’s conversation count. For Chat → Work, explicitly seed a stale hint immediately before the Work start and verify it is cleared. For Work → Chat, use `recordPermissionRequest = { false }`: a denied Work capture leaves `.work` with `.error`; the next gateway start must stamp `.chat`.

   The actual arming seams are `recordPermissionRequest`, `recordSessionActivator` and `sessionCoordinator`. `ActivationGate` and `makeService` in `WatchArmActivationTests` are private helpers, not directly reusable from `WatchCaptureGuardTests`. Cancel pending starts and release any suspended gates during cleanup.

8. **MINOR — The queue test is writable, but there is no ready-made full-queue fixture.** `WatchRelayQueueRetryabilityTests.entry()` creates values for pure tests; it does not populate the singleton. Its live tests use temporary audio, `runRelay` and `relayTranscribe`. Also, unchanged `entryCount` does not prove every recording survived.

   **Fix:** Populate `AppleRelayPendingQueue.shared` through `enqueue(requestID:audioFileURL:…destination: .work)` using unique test IDs. Assert the initial depth, every retained ID and its bytes, plus zero permission/activation calls, `.idle`, the request-scoped refusal and unchanged lane. Clean up only test-owned entries through `claimEntry`. `StorageTestSupport` substitutes defaults and secrets; it does **not** isolate the queue’s audio directory or automatically reset its cached `entryCount`.

9. **MINOR — The new view guards need explicit QA cases.** The row-builder and service tests cannot prove the private view methods actually enforce the switch or dismiss presentations.

   **Fix:** Add chooser-open → switch-off → attempted selection; chooser-open → accepted headless capture; and chooser-open → machine becomes busy → row selection. Require no forbidden start, no changed live capture ownership, and no lingering chooser. Append gateway-fixture tests inside the existing `WatchCaptureGuardTests` class if they need its private `stageGateways` helper.

**What I agree with**

- **Copy:** “Where to?”, “Add to Work” for row and screen, and reuse of “Saving to Work…” are consistent and concise. “No personal AI available.” is honest under I3: it describes current availability without diagnosing missing setup. Allow wrapping; do not promise a single line.
- **Observation:** `WatchSettingsReader` is `@Observable`; `watchEnabledCache` is tracked and `isWatchEnabled()` reads it. The proposed `onChange` is observable. Test writes must update the cache through `updateFromContext` or `refreshWatchEnabledCache`, not just modify defaults.
- **Ordering:** busy guard → master-switch guard → synchronous push/start is correct. No `await` or deferred start should be inserted between them.
- **Scope:** separate Work route, capacity-refusal rendering, existing pending-hint lifecycle and gateway-only implicit headless routing remain appropriate.