**P2-A/B/C are sound directions. P2-D still does not prove arrival, and the revised plan exposes two interactions its tests miss.**

1. **[P2][DISAGREE — P2-A is incomplete] The newly visible Ask ✕ also cancels the hidden Work capture.**  
   `recordingStatusView` calls `cancelActiveCapture`: [DictationPopoverView.swift:475](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/MenuBar/DictationPopoverView.swift:475). That method unconditionally calls `cancelWorkVoiceCapture`, which cancels Work transcription or discards its pending error capture: [MenuBarCoordinator.swift:1798](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/MenuBar/MenuBarCoordinator.swift:1798), [2156](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/MenuBar/MenuBarCoordinator.swift:2156). An unpublished, audio-less picture has no durable retry copy: [InAppAudioRecorder.swift:1865](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/InAppAudioRecorder.swift:1865).

   **Required addition:** cancel the visible Ask without cancelling Work; test both Work transcription and retained-error states.

   An ordinary Ask **stop** does not discard either capture. Returning to Work’s HUD restores its retry/cancel controls. Ask’s answering ✕ then becomes inaccessible **in the popover**, as your open risk acknowledges; that overlap limitation already exists. The precedence change itself does not introduce that loss.

2. **[P2][AGREE — P2-A’s lease assumption and P2-C’s placement] I find no normal path with both recorders live, or a Work self-refusal.**  
   Work advertises `isStarting` before its first suspension and includes startup in `isActivelyRecording`: [InAppAudioRecorder.swift:680](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/InAppAudioRecorder.swift:680), [1912](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/InAppAudioRecorder.swift:1912). Ask checks the other authorities, then sets `.recording` synchronously before its asynchronous microphone start: [DictationService.swift:675](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/MenuBar/DictationService.swift:675), [697](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/MenuBar/DictationService.swift:697).

   Yes, the registry includes Work itself. But `workCaptureIsActive` includes its startup, and the existing branch returns before the proposed query: [MenuBarCoordinator.swift:1959](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/MenuBar/MenuBarCoordinator.swift:1959), [MenuBarController.swift:435](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/MenuBar/MenuBarController.swift:435).

   Both controller and registry are `@MainActor`; this synchronous query introduces no actor-isolation problem: [MenuBarController.swift:57](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/MenuBar/MenuBarController.swift:57), [SpeechExclusivity.swift:93](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/TTS/SpeechExclusivity.swift:93).

3. **[P2][AGREE — P2-B’s hoist; DISAGREE — its change list is complete] Opening the menu is correct, but “Start Recording” is unsafe in the newly reachable busy states.**  
   I found no state requiring a secondary click to stop recording instead of opening the menu. The hoist preserves the existing click tests.

   However, choosing **Start Recording** during Ask recording or transcription calls `armQuickCapture()` before `toggleRecording()`: [MenuBarController.swift:1252](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/MenuBar/MenuBarController.swift:1252). During recording, that stops/sends; during transcription, the toggle does nothing—but the destination was already rearmed: [DictationService.swift:183](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/MenuBar/DictationService.swift:183). Rearming can replace the frozen automatic destination using a fresh TTL/default resolution: [MenuBarCoordinator.swift:1670](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/MenuBar/MenuBarCoordinator.swift:1670), [1511](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/MenuBar/MenuBarCoordinator.swift:1511).

   Keep the menu available. Make this command state-aware, and test that opening it or invoking its busy-state action never rearms an existing capture.

4. **[P2][DISAGREE — P2-D] A nonthrowing drain does not prove THIS capture imported. Reading the aggregate counts is also insufficient.**  
   [WorkCaptureDrainer.swift:52](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/Workboard/WorkCaptureDrainer.swift:52) returns:

   | Field | What it establishes |
   |---|---|
   | `importedCaptureCount` | Successfully completed captures without pre-existing expected materials. |
   | `replayedCaptureCount` | Successfully completed captures with at least one expected material already present—including partial prior imports. |
   | `invalidCaptureCount` | Malformed envelopes rejected during claiming, plus terminally refused captures retired from the queue. |
   | `importedMaterialCount` | Materials processed by completed publications, including replays; not simply newly inserted cards. |

   The increment paths are at [WorkCaptureDrainer.swift:239](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/Workboard/WorkCaptureDrainer.swift:239); replay classification is at [293](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/Workboard/WorkCaptureDrainer.swift:293).

   Consequently:
   - A nonthrowing report can contain only invalid captures.
   - Successful counts can describe other captures.
   - An empty report can occur while another drainer holds yours: [WorkCaptureInbox.swift:486](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/WorkCaptureInbox.swift:486).
   - A drain can import yours and then throw on a later capture.

   Retain the UUID returned by `publishAppCapture` and establish that capture’s outcome; the report contains no capture identities. Also remove the guarantee that opening Work means the card will be there: the foreground drain itself has a failure path at [PersonalWorkbenchView.swift:827](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Views/Workboard/PersonalWorkbenchView.swift:827). A queued button should not retain the tooltip **“Open Work and see the new card”** at [DictationPopoverView.swift:1195](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/MenuBar/DictationPopoverView.swift:1195).

5. **[P2][DISAGREE — test-list completeness] There are two concrete test-description errors and missing behavioral coverage.**  
   - **P2-A:** the existing router test examines only `prefix(120)` at [MenuBarWorkCaptureStateTests.swift:272](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/ConduckTests/MenuBarWorkCaptureStateTests.swift:272). Your proposed assertion is **143 characters** after that test’s whitespace normalization. Updating only the expected string will fail. Extract the router body or change the slice.
   - **P2-B:** line 396 belongs to `testALiveChatRecordingOutranksANonRecordingWorkState`, **not** `testAStatusItemClickStopsALiveWorkRecording`: [MacMenuBarWorkShortcutDriftGuardTests.swift:375](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/ConduckTests/MacMenuBarWorkShortcutDriftGuardTests.swift:375). It searches the whole function, so hoisting preserves it despite its stale failure-message wording.
   - Add tests for findings 1, 3 and 4. A `drained ?` source assertion would enshrine the incorrect boolean inference.
   - The P3 screenshot test’s name is correct: [WorkboardVoiceScreenshotLaneTests.swift:59](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/ConduckTests/WorkboardVoiceScreenshotLaneTests.swift:59).

   **The explicitly listed unchanged guards survive the specified edits by source inspection.** The queued sentence also passes the existing vocabulary rule because it strips “nothing was sent” before scanning: [WorkboardCopyTruthGuardTests.swift:216](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/ConduckTests/WorkboardCopyTruthGuardTests.swift:216). Its catalog row and source reference must land together.

6. **[P2][DISAGREE — U-49’s P3 classification; AGREE — separate Ask scope] The recorder-box explanation does not settle the cancellation contradiction.**  
   Even granting that interpretation of the Settings footer, the capture guide explicitly teaches **“Press Esc to cancel”** alongside the two Ask shortcuts: [MenuBarGuideView.swift:78](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Views/Settings/MenuBarGuideView.swift:78). The actual Esc handler performs cancellation and resets capture state, rather than merely dismissing: [MenuBarController.swift:736](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/MenuBar/MenuBarController.swift:736), [MenuBarCoordinator.swift:1789](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/MenuBar/MenuBarCoordinator.swift:1789).

   I accept separating U-49 and U-46 into an Ask follow-up. I would revise my original U-49 rating to **P2**, not describe it as a Work-to-AI routing violation. It remains a behavioral cancellation inconsistency, rather than P3 copy polish.

7. **[P3][AGREE — first-publication date fix; DISAGREE — complete “one capture, one date” guarantee] Durable recovery still substitutes another date.**  
   `preserveForRetry` writes `createdAt: Date()` rather than `capture.createdAt`: [InAppAudioRecorder.swift:1875](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/InAppAudioRecorder.swift:1875). Screenshot recovery later publishes using that metadata date: [DictationService.swift:523](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/MenuBar/DictationService.swift:523).

   Your change fixes the initial pair, but a picture recovered after relaunch can still differ from its recording. Either narrow the promise or carry the original capture date through recovery and test it.

**Verdict:** The third-option interpretation remains correct. Approve P2-A’s precedence, P2-B’s menu gesture, and P2-C’s query placement in principle. Revise cancellation ownership, busy menu actions, and P2-D’s capture-specific completion evidence before implementation. The test list is not yet complete.

Source review and in-memory guard probes only; no edits or Xcode test run.