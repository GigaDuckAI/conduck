1. **P1 — The “no unattended Work capture” boundary is already violated.** [CaptureWorkboardIntent.swift:35](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Intents/CaptureWorkboardIntent.swift:35)

   **Scenario:** A Shortcuts automation supplies `thought` and runs Add to Work. The intent runs in the background and calls `upsertDeskMaterial` without opening a capture surface or requiring a gesture. `AddFilesToWorkIntent` similarly publishes and drains files in the background. GigaAction also accepts a Work destination. Separately, the registered Siri record phrase reaches `RecordWorkNoteIntent` → `WorkVoiceCaptureLaunchRoute` → [WorkboardVoiceCaptureView.swift:60](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Views/Workboard/WorkboardVoiceCaptureView.swift:60), whose task starts recording automatically.

   This disproves boundary (3a), independently of CarPlay. These paths predate this diff.

   **Smallest fix:** Require an explicit foreground Record/Add action before these Work intents start recording or publish. Merely marking an intent foreground does not supply that action.

2. **P1 — End/backgrounding can still be followed by a gateway request. Existing CarPlay timing defect.** [CarPlayRecordingService.swift:2262](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/CarPlay/CarPlayRecordingService.swift:2262)

   **Scenario:** Chat transcription finishes and enters `startConverseHop`. While gateway resolution, conversation creation or history assembly is suspended, the driver presses End or switches to Maps. `endSession` sees `currentTurnToken == 0`, so it cancels no upload. The suspended hop subsequently resumes, allocates a fresh token and calls `uploadConverse`. The uploader’s cancellation check cannot find a cancellation for that newly allocated token.

   The old chat transcript therefore leaves after cancellation. If Work has started meanwhile, the old task can also overwrite session fields or terminate the Work session through its error handler. The new scene-start guards do not cover this downstream task.

   **Smallest fix:** Allocate the cancellation token before the first suspension, carry the originating listen/session identity through the hop, and revalidate before subsequent session mutations and dispatch.

3. **P2 — A stale presentation completion can dismiss a newer Work capture on the same connection.** [CarPlaySceneDelegate.swift:616](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/CarPlay/CarPlaySceneDelegate.swift:616)

   **Scenario:** Start A is presenting; backgrounding clears its claim. Return to Conduck and start B on the same controller/service. A’s delayed completion now fails `startIsLive`, but its failure arm still calls `ensureVoiceDismissed` because the service identity matches. B’s modal is dismissed, and `templateDidDisappear` ends B, deleting its partial recording.

   The analogous dismiss completion at line 736 can deactivate B’s audio because it checks only controller identity. Connection identity does not identify a presentation or session. This is an unresolved lifecycle defect in the prescribed design.

   **Smallest fix:** Bind presentation, dismissal and their failure cleanup to a presentation/session generation. Check that generation before changing `isVoicePresented`, dismissing or deactivating audio.

4. **P2 — End and modal disappearance do not cancel a pending start.** [CarPlaySceneDelegate.swift:1271](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/CarPlay/CarPlaySceneDelegate.swift:1271)

   **Scenario:** The voice template becomes interactive before its asynchronous present completion has begun the service. The driver presses End. Its handler calls only `endFromButton`; `endSession` immediately returns because `sessionActive` is still false. The claim survives, so the present completion starts recording anyway.

   A modal disappearance during this window also leaves the claim alive: [CarPlaySceneDelegate.swift:374](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/CarPlay/CarPlaySceneDelegate.swift:374) returns before invalidating it.

   **Smallest fix:** Invalidate the matching pending start in the scene’s End and voice-disappearance handlers before ending the service. Refuse completion-time startup when that presentation has disappeared.

5. **P2 — The phone recorder can reconfigure a live CarPlay audio session. Existing shared ownership defect.** [InAppAudioRecorder.swift:737](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/InAppAudioRecorder.swift:737)

   **Scenario:** CarPlay is recording a Work note or conducting a chat. A passenger opens the phone’s Work recorder. Microphone ownership is checked only under `#if os(macOS)`, and CarPlay is not registered with that arbitration mechanism. The phone recorder calls `setCategory(.record, mode: .default)` on the same audio session; stopping it calls `setActive(false)`. CarPlay still retains its own `audioActivated` state and expects its HFP/play-and-record configuration.

   The second surface can interrupt or truncate the first surface’s capture and break its spoken acknowledgement. The shared timestamp edit neither introduces nor fixes this.

   **Smallest fix:** Enforce one microphone owner across the iOS recorders and CarPlay, including their pending starts. Refuse the second start before it changes the audio session; release ownership only from its holder.

6. **P2 — The new conversation-notification gate drops refreshes instead of retaining them. New regression.** [CarPlaySceneDelegate.swift:1252](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/CarPlay/CarPlaySceneDelegate.swift:1252)

   **Scenario:** No picker refresh is running. A start claims the scene, then another device changes the conversation list. The notification handler returns because `pendingStart != nil`, without setting `pickerRefreshPending`. The presentation subsequently fails, or preflight refuses the start. `releaseStart` finds no retained refresh, and the Recent list remains stale until another refresh trigger.

   This defeats the design’s retained-refresh promise and affects ordinary chat navigation.

   **Smallest fix:** When a notification arrives under a pending start, set `pickerRefreshPending = true` before returning. Preserve the existing active-session behavior.

7. **P2 — The Watch promises phone recovery without creating a phone retry entry. Existing cross-lane defect.** [AppleSpeechRelayCoordinator.swift:513](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/AppleSpeechRelayCoordinator.swift:513)

   **Scenario:** Record to Work on Watch with the phone’s STT key missing. The phone publishes the recording, classifies the STT failure as settled, and acknowledges a wordless save. The wrist retires its queued recording and says “Add the words on your iPhone.” The relay never arms `PendingRetryStore`; the phone therefore has no retry entry, and the desk audio card offers no transcription action.

   Recognition followed by an attachment failure has the same missing recovery mechanism: the helper swallows the attachment failure, then the relay sends a success stamp with words. The 24-hour policy cannot protect an entry that never exists.

   **Smallest fix:** Arm a `.work` retry entry for the relayed recording, stamp publication, park recognized words before attachment, and clear it only after attachment succeeds.

8. **P2 — A foreground phone does not discover CarPlay’s newly queued retry. Existing refresh defect.** [ContentView.swift:1193](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/ContentView.swift:1193)

   **Scenario:** The phone already displays Chats with no pending retries. CarPlay publishes a Work recording whose transcription fails. `PendingRetryStore.save` posts `queueDidChangeNotification`, but `ContentView` does not observe it. Its retry card stays absent until foregrounding, settings dismissal or another explicit refresh path.

   The Mac `DictationService` observes this notification; the phone does not.

   **Smallest fix:** Observe queue changes in the phone retry surface and coalesce calls to `refreshPendingRetryState`.

9. **P2 — The new source guards admit mutations that remove the protections they claim to prove.** [CarPlayWorkNoteTests.swift:730](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/ConduckTests/CarPlayWorkNoteTests.swift:730)

   **Concrete failure:** Change production `startIsLive` to pass `claimSerial: serial`, bypassing the stored claim identity. A start invalidated by backgrounding can then resume underneath a later Work start. The pure gate tests still receive their original synthetic arguments, and every new wiring assertion still sees its expected markers.

   These negative controls follow from static inspection; I did not execute tests or mutations.

   | Assertions | Mutation or reversion that they still admit |
   |---|---|
   | Start-gate assertions at **669, 676, 714** | Bypass the gate or supply constant arguments in production. These test the pure predicate, not its callers. |
   | Starter prefix, post-await placement and defer assertions at **739, 762, 767** | Make `startIsLive` always return true, or make `releaseStart` ineffective. All markers remain. |
   | Present-completion range checks at **784, 788, 792, 796, 800** | Remove `presented` from the guard, remove the refusal’s `return`, or remove its service-identity protection. The required tokens remain in order. |
   | False-completion count at **811** | Remove both the nil-controller and failed-present callbacks. The missing-self and stale-controller branches still supply two `completion?(false)` occurrences. |
   | Identity/lifecycle/chooser presence assertions at **815, 822, 832, 840, 849, 851** | Keep the expressions inside ineffective conditions, or bypass them with `|| true`. Presence does not establish enforcement. |
   | Refresh assertions at **863, 868, 875** | Remove the pending-start condition from the paint gate, or remove `refreshPicker()` from `releaseStart` while retaining the flag reference. |
   | Parking checks at **303, 307, 311, 316, 323, 329** | Delete the successful-ownership-path staleness guard at production line 1997. The check inside the ownership-refusal branch satisfies the search. Assertion 323 is guaranteed by the search range used to obtain `firstStaleness`. Changing the parked publication verdict or returning when parking fails also escapes these checks. |
   | Re-arm assertion at **428** | Replace the guard with `_ = sessionDestination == .chat`. |
   | Hint assertions at **516, 537, 541, 545, 556, 558, 562, 568** | Reverse the destination comparison. Both keys and all expected markers remain. |
   | Day-one order assertion at **551** | Reverse `firstSectionItems` after the checked array literal. |
   | No-Mute assertions at **892, 896, 903** | Put the clearing assignment inside an unreachable branch. |
   | Override assertions at **919, 926, 928, 930, 934** | All survive the baseline implementation. They pin an existing shape; they do not prove start-race or reconnect behavior. |
   | `CarPlayVoiceTimingContractTests` assertions at **362, 364, 369, 380, 386, 392** | Leave teardown/hint-reset calls present but unreachable or ineffective. |

   The behavioral controls are stronger, but their limits matter:

   - Reverting `isExpired` to 600 seconds still passes the Chat assertions, published-Work exemption/constant assertions, and the 86,401-second expiry assertion. The **601- and 86,399-second assertions fail**, so that test does distinguish the new policy.
   - [WorkVoiceRecoveryTests.swift:519](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/ConduckTests/WorkVoiceRecoveryTests.swift:519) checks only `retryTTL`; it survives an `isExpired` implementation that ignores that property.
   - Every assertion in `testRetiringAPublishedPictureLetsItsEntryExpireOnTheDayBudget` survives restoring the ten-minute rule: its fixtures are older than both budgets. The separate within-day survivor assertion at **1585** supplies the missing distinction.
   - The timestamp control `recording.createdAt >= beforeTheStop` survives reverting the recorder timestamp edit. The measured spread assertion at **148** distinguishes it.

   **No execution tests cover:** competing actual CarPlay starts; End during presentation; stale same-connection presentation/dismissal callbacks; backgrounding before chat-token allocation; CarPlay/phone microphone ownership; notification arrival followed by a refused start; or CarPlay parking/attachment failure followed by recovery through the actual phone retry surface. The no-unattended-entry boundary is not enforced by tests either.

   **Smallest fix:** Exercise the production claim/presentation coordinator through injected completions and suspended operations. For remaining source guards, assert the relevant branch and its exit, and add explicit negative fixtures for each claimed protection.

10. **P3 — The prescribed QA handoff updates were omitted.** [handoff.md:270](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/docs/qa/work-usability/handoff.md:270)

   **Scenario:** A verifier follows step 77 and looks for Mute on a Work note, or treats End after publication as guaranteeing no card. Both expectations contradict the accepted implementation. The long-drive retry and competing-start steps are missing. Decision 14 still names `carplay-communication`.

   **Smallest fix:** Apply the handoff corrections specified in design §7, including End-only behavior, publication timing, day-one order, steps 77a/78a and the actual entitlement key.

   The catalog inspection found no missing CarPlay keys, duplicate JSON keys, mismatched CarPlay English defaults, or orphaned newly changed keys. There is no copy defect to add beyond the stale handoff.

