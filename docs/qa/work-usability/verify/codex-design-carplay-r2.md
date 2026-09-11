Reviewed `a197ccd`, read-only. No simulator or rendered verification.

1. **P1 — The proposed claim has no owner identity; disconnect does not invalidate work.**  
   `startSession` retains `self` and `service` across awaits at [CarPlaySceneDelegate.swift:357](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/CarPlay/CarPlaySceneDelegate.swift:357). After disconnect/reconnect, that Task can present the **old service** through the **new controller**, while a new Work startup holds the claim. Old defers and presentation callbacks then unconditionally clear the new claim. The old service remains startable: `teardown()` does not permanently disable it. Moreover, [didConnect:102](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/CarPlay/CarPlaySceneDelegate.swift:102) tears down a stale service without calling `disconnectCleanup`, so skipped disconnect callbacks can leave `pendingStart` stuck.

   **Fix:** Give each start a unique token, bound to the connection and service. Validate it after suspensions, before side effects, and before `begin…`; release **only that token**. Invalidate through both disconnect and replacement-connect paths. The normal refusal defers and successful-completion releases are otherwise correctly placed.

2. **P1 — The claim does not establish that presentation completed.**  
   [ensureVoicePresented:503](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/CarPlay/CarPlaySceneDelegate.swift:503) conflates *presenting* with *presented*. A state-driven presentation through `applyState` owns no startup claim; a later startup taking this fast path immediately runs `begin…`. Also, `interfaceController?.presentTemplate` can invoke nothing: a stale row handler can claim a start after cleanup, hand off responsibility, and receive **no completion to release it**.

   Permission changes expose another failure: Chat preflight suspends; `.permissionBlocked` dismisses/refreshes; preflight resumes and presents anyway. `beginSession` refuses the blocked state, releases the claim, and leaves a Listening modal without a session ([service:580](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/CarPlay/CarPlayRecordingService.swift:580)).

   **Fix:** Distinguish presentation pending/completed, explicitly refuse a missing controller, and revalidate connection, eligibility and presentation before beginning. Invalidate pending starts on background/permission refusal; retire refused presentations.

3. **P2 — The chooser guard covers only one source of stale UI work.**  
   At [scene:1003](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/CarPlay/CarPlaySceneDelegate.swift:1003), `recordingService?.sessionActive != true` passes when disconnected; a queued handler can also overwrite the next connection’s override. Meanwhile, notification refreshes check only `sessionActive` ([1029](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/CarPlay/CarPlaySceneDelegate.swift:1029)), and already-running picker refreshes continue mutating templates during startup.

   **Fix:** Require the originating live connection and exclude pending starts at UI-mutation points. For §9, claim Work **before** popping, require pop success, and validate the same token in its completion; otherwise the transition remains unclaimed.

4. **P2 — Removing Mute is sound; “no service change needed” is too strong.**  
   Clearing trailing buttons follows the existing pre-presentation technique at [scene:450](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/CarPlay/CarPlaySceneDelegate.swift:450), **provided the shared template is actually dismissed**. Finding 2 invalidates that assumption on some paths. Rendering still needs Chat → Work → Chat QA.

   Normal Work does read `isMicMuted` in [startListening:865](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/CarPlay/CarPlayRecordingService.swift:865), but starts false and has no ordinary path setting it true. Its acknowledgements do not re-arm. However, an older Chat completion can already have launched `reArmAfterSettle()` without an expected listen ID: after End → Work, its post-sleep checks accept the new session ([2445](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/CarPlay/CarPlayRecordingService.swift:2445)). It can re-arm during Work processing. The sign-off completion also assigns `.idle` without session identity ([2816](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/CarPlay/CarPlayRecordingService.swift:2816)).

   **Fix:** Bind delayed re-arms and terminal speech callbacks to their originating session. No pause/append recorder is needed.

5. **P2 — Parking is semantically correct, but the proposed write ignores lost ownership.**  
   `recordPublicationState` returns `false` for an overtaken claim or failed persistence ([PendingRetryGuard.swift:255](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/PendingRetryGuard.swift:255)). Proposed sequence: ownership true → suspension → phone takes claim → parking returns false → CarPlay attaches anyway. `isCurrentListen` cannot detect queue takeover.

   **Fix:** Inspect the result and recheck capture ownership after parking, followed by session staleness. Preserve the `audioPreserved == false` path: inability to park must not automatically prohibit a valid desk attachment.

   **Reader audit:** No reader treats parked words as already attached. [ContentView:1672](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/ContentView.swift:1672) and [DictationService:314](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/MenuBar/DictationService.swift:314) skip recognition, then call recovery. [recover:315](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/Workboard/WorkVoiceCaptureCoordinator.swift:315) still attempts attachment; `.published` prevents republication, not attachment. Repeating identical words is idempotent. `InAppAudioRecorder` separately tracks `transcriptSettled`; merely possessing a transcript does not set it.

6. **P2 — Never-expiring Work entries fit the readers, but §6 misses two failing tests.**  
   Complete expiry chain: `isExemptFromExpiry` → `isExpired(at:)` → `partitioningExpired` → [liveQueueLocked:1346](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/PendingRetryStore.swift:1346). Its callers are `claimNext`, `claim(id:)`, `pendingCount`, `load`, `hasPending`, `pendingErrorCode`, `diagnosticSnapshot`, and `cleanupExpired` (launch paths in `ConduckApp` and `AppDelegate`). The convenience `isExpired` property has no external reader.

   None requires published Work to expire. Reservations remain independently stealable; confirmed discard still clears its claimed entry. `load`/claim operations can still retire **missing audio**, so “never expires” does not mean “only explicit discard can remove it.” Notifications are one-shot, not expiry-driven ([PendingRetryGuard:333](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/PendingRetryGuard.swift:333)). `holdsWorkImage` becomes redundant for correctly marked Work entries, without breaking image retirement.

   **Fix tests:** Update `WorkboardVoiceScreenshotLaneTests` at [573](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/ConduckTests/WorkboardVoiceScreenshotLaneTests.swift:573) and [1492](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/ConduckTests/WorkboardVoiceScreenshotLaneTests.swift:1492): both currently require published Work without a parked image to disappear. Retain a Chat expiry control. Include `PendingRetryLeaseTests`, `PendingRetryDurabilityTests`, `PendingRetryOwnershipHandoffTests`, and `PendingRetrySurfaceHandoffTests`; their retention/ownership/discard contracts remain relevant.

7. **P2 — §6 uses valid helper APIs, but does not prove its advertised guarantees.**  
   [RefusalLaneSource:272](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/ConduckTests/RemoteAgent/HeadlessRefusalLaneDriftGuardTests.swift:272) supports the proposed whole-source/function scoping. Remaining defects:

   - Baseline failure because the declaration is missing proves nothing about release ownership or races. Add deterministic suspended-preflight, pending-presentation, permission, disconnect/reconnect and late-callback cases; mutate each protection independently.
   - Banning `startWorkNote(` inside the chooser **rejects §9**. It still pins layout, contrary to the table’s claim.
   - `[makeWorkNoteItem(...), setupItem]` displays Work first even when `setupItem` was constructed earlier. Comparing against the setup string’s textual location rejects correct code.
   - Duplicating configured hint construction produces three title-key occurrences; [the existing assertion expects two:488](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/ConduckTests/CarPlayWorkNoteTests.swift:488).
   - Staleness counts and exact multiline-call substrings remain brittle. Extract the actual completion/guard blocks; assert the affected path, not a count elsewhere.

8. **P2 — Decision 13 still knowingly announces a missing recording as saved.**  
   [service:2008](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/CarPlay/CarPlayRecordingService.swift:2008) has just received `.recordingMissing`/`.notAudio`; earlier publication does not establish current availability. The “fourth key” objection is unnecessary: reuse `.notSaved` when recovery bytes exist, otherwise the existing “Couldn't save — try again.” This remains a correctness objection.

   Decision 1’s duplicate-control argument is reasonable, but still differs from the founder’s literal instruction; that is a product disagreement, not a technical safety blocker. I do not block on retaining the CAF or adding “later.” Revised spec arithmetic is correct: **16,892 words, −5**.

| Decision | Position | Assessment |
|---|---|---|
| 1 | **DISAGREE** | Literal founder mismatch; root-only is a defensible UX preference. |
| 2 | **AGREE** | No persistent Work override. |
| 3 | **AGREE** | Consistent with an AI-only chooser. |
| 4 | **AGREE** | Gateway types and repair remain AI-only. |
| 5 | **AGREE** | Working day-one action first. |
| 6 | **AGREE** | Labels are clear. |
| 7 | **AGREE** | Remove Mute; verify shared-template transitions. |
| 8 | **DISAGREE as specified** | Claim needs identity and lifecycle invalidation. |
| 9 | **AGREE** | Name the accepted startup destination. |
| 10 | **AGREE in principle** | Park first; handle ownership loss afterward. |
| 11 | **AGREE** | Retention policy is sound; expand tests. |
| 12 | **DISAGREE** | Presentation and delayed-callback handling must change. |
| 13 | **DISAGREE** | Reuse existing failure copy for known missing recordings. |

**Verdict: `change_required` — agree with the classification; the revised design is not yet implementation-ready.**

