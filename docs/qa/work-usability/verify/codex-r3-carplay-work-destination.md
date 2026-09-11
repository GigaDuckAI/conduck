**Not clean: 1 P1, 9 P2, and 1 P3.** Static review only; no builds, tests, or mutations were executed. Mutation results below are derived from the assertions.

1. **P1 — Work remains reachable without an attended foreground gesture.** [CaptureWorkboardIntent.swift:35](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Intents/CaptureWorkboardIntent.swift:35)  
   An automation supplying `thought` executes the background intent and writes directly through `upsertDeskMaterial` at line 79. `AddFilesToWorkIntent` likewise declares background execution and publishes/drains at lines 215/230. `ConverseIntent(destination: .work)` publishes without an attendance check. Separately, the registered Siri recording phrase invokes `RecordWorkNoteIntent`, whose route opens a sheet that automatically starts recording at `WorkboardVoiceCaptureView.swift:66`. Foreground presentation alone does not establish the required gesture.  
   **Smallest fix:** stage externally supplied inputs until an explicit foreground Add gesture; have the recording launch route open an idle recorder requiring Record. Forwarding implementation to the intents owner is legitimate; excluding this boundary from acceptance is not. CP-R1-01/CP-R2-01 remain live. I am not treating the absence of a physical-tap discriminator in CarPlay’s handler as independent proof of a headless CarPlay invocation.

2. **P2 — Cancellation marks can still be removed while their upload is pending.** [CarPlayConverseUploader.swift:577](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/CarPlay/CarPlayConverseUploader.swift:577)  
   A enters `uploadConverse` and suspends in `beginGatewayAttempt` after the recording service’s final lineage check. End marks A cancelled. If 32 newer retained cancellation marks accumulate before A resumes, `trimCancelClaims` removes A’s mark. A then passes the uploader’s cancellation check and dispatches. There is no enforced lifetime or outstanding-attempt bound establishing that the oldest mark is orphaned.  
   **Smallest fix:** retain cancellation state for every outstanding pre-dispatch attempt until that attempt exits; bound only marks proven orphaned. CP-R2-02’s two-turn reproducer is fixed, but its cancellation guarantee remains incomplete.

3. **P2 — Phone recording can still disrupt a live CarPlay capture.** [InAppAudioRecorder.swift:772](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/InAppAudioRecorder.swift:772)  
   With CarPlay recording, start a Work recording on the phone. Microphone arbitration remains macOS-only, and CarPlay registers no ownership with it. `AudioRecorder.swift:54` changes the shared session to `.record`; stopping or cancelling deactivates it at lines 141/167. CarPlay’s engine and spoken acknowledgement consequently lose their audio-session configuration.  
   **Smallest fix:** share an iOS microphone/session ownership gate between both recorders, including pending startups, and deactivate only for the owner. CP-R1-05/CP-R2-06 remain live.

4. **P2 — A missing Watch STT key still permanently removes the transcription recovery path.** [AppleSpeechRelayCoordinator.swift:538](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/AppleSpeechRelayCoordinator.swift:538)  
   Record to Work with the phone’s cloud STT key missing. Phase one publishes the audio; `.notConfigured` throws `.sttMissingAPIKey` at line 707. That non-retryable classification produces a cached wordless acknowledgement. The Watch consumes its queue entry at `AppleRelayPendingQueue.swift:667`, deleting the clip, while the phone has armed no retry entry. Restoring the key therefore provides no way to fulfil “Add the words on your iPhone.”  
   **Smallest fix:** establish a phone retry entry before acknowledging an unfinished transcription, or retain a recoverable Watch request for user-remediable configuration failures. Attachment throws/missing-card failures now retain the wrist clip; the missing-key half of CP-R1-07/CP-R2-07 remains live.

5. **P2 — The shared recorder still attaches words after losing its reservation.** [InAppAudioRecorder.swift:1840](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/InAppAudioRecorder.swift:1840)  
   A sheet retry holds a claim, renewal fails long enough for another surface to claim and finish it, then the original STT result returns. The cached claim is accepted without confirmation, renewal results are ignored, and attachment at line 1603 has no ownership check. The original result can overwrite the other surface’s words.  
   **Smallest fix:** confirm the reservation before resuming a cached claim and again immediately before attaching or handing on its transcript. CP-R2-09 remains live.

6. **P2 — An already-foreground phone still misses CarPlay retry arrivals.** [ContentView.swift:1193](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/ContentView.swift:1193)  
   Leave the phone foreground with no pending retry, then finish a CarPlay Work capture whose transcription fails. The store posts `queueDidChangeNotification` at line 768, but neither phone view branch observes it. The retry card stays absent until another lifecycle/settings refresh occurs.  
   **Smallest fix:** observe queue changes in both phone branches and refresh pending retry state. CP-R1-08/CP-R2-08 remain live.

7. **P2 — The new throwing screenshot write breaks callers’ “nothing preserved” assumption.** [PendingRetryStore.swift:751](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/PendingRetryStore.swift:751)  
   Saving a Work audio-plus-screenshot capture writes the sidecar and audio successfully, then the screenshot write fails. `save` throws, so `PendingRetryGuard.arm` returns `audioPreserved == false` with no reservation, and `InAppAudioRecorder` does not record an armed ID. However, reconciliation at lines 1279–1296 adopts that sidecar/audio pair. Another surface can claim it while the original caller continues under the assumption that no competing entry exists. Ownership checks on the original guard explicitly return true for this state.  
   **Smallest fix:** distinguish a partial, claimable save from a save that preserved nothing, and reserve the partial entry before continuing. Keep screenshot failure explicit. Propagating the error alone is insufficient.

8. **P2 — The Mac quit fix still equates “publication returned” with “recording is durable.”** [InAppAudioRecorder.swift:1162](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/InAppAudioRecorder.swift:1162)  
   Stop a Work recording, press ⌘Q during publication, and have both the desk write and retry preservation fail. `preserveForRetry` silently returns on its failed save; the unconditional defer decrements the publication count. The waiting AppDelegate now sees zero and permits termination, although `pendingWorkCapture` contains the only recording copy.  
   **Smallest fix:** keep an undurable stopped capture represented in the quit decision until preservation succeeds or the person explicitly discards it. CP-R2-10’s timeout-with-outstanding-publications defect is fixed at `AppDelegate.swift:363`; the failure exit still loses the recording.

9. **P2 — Cancellation protection is bypassed when retrying already-recognized words.** [InAppAudioRecorder.swift:1601](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/InAppAudioRecorder.swift:1601)  
   A capture has parked words from a failed attachment and still owes its screenshot. Retry it, then cancel while screenshot normalization is suspended. Screenshot publication observes cancellation, but its wrapper converts the throw into `nil` and the capture pipeline continues. Because `capture.transcript` already exists, it skips `settle`—the location of the new cancellation check—and attaches the words anyway. Returning a cancellation result later does not undo that write.  
   **Smallest fix:** check cancellation immediately before phase-two attachment on both fresh and parked-transcript paths.

10. **P2 — The strengthened source guards still admit the protections’ removal.** [CarPlayWorkNoteTests.swift:894](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/ConduckTests/CarPlayWorkNoteTests.swift:894)  
    For example, append `|| true` to `startIsLive`’s returned gate result, pass `claimHeld: false`, or remove `refreshPicker()` from `releaseStart` while retaining its `pickerRefreshPending` conditional. The relevant assertions still find their required text. These mutations respectively permit invalidated starts, defeat exclusive claiming, and strand retained refreshes. CP-R1-09/CP-R2-12 are not closed.  
    **Smallest fix:** exercise the production start/presentation coordinator with controllable preflight and presentation completions, asserting starts, dismissals, and refresh effects. Keep pure predicate tests, but do not use source presence as the race proof.

11. **P3 — The prescribed CarPlay handoff changes remain unapplied.** [handoff.md:286](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/docs/qa/work-usability/handoff.md:286)  
    Step 77 still instructs testing Mute/Unmute and says End saves nothing without distinguishing publication. Decision 14 at line 99 still names `carplay-communication`; the current entitlement is `com.apple.developer.carplay-voice-based-conversation`. The specified long-drive recovery and competing-start steps are absent.  
    **Smallest fix:** apply design §7’s CarPlay handoff edits, including the destination-specific failure hint and day-one order. CP-R1-10/CP-R2-13 remain live; the docs-owner forward is appropriate but unfinished.

The remaining prior findings re-derive as follows:

| Prior IDs | Current result |
|---|---|
| CP-R1-02 | Fixed for the reported pre-uploader suspensions: lineage checks now precede subsequent effects and dispatch. Finding 2 concerns the later uploader suspension. |
| CP-R1-03 | Fixed for the reported stale completion: refused-start cleanup requires no replacement claim and no live session. |
| CP-R1-04 | Fixed: End and modal disappearance cancel pending starts before the session-active guard. |
| CP-R1-06 | Fixed: conversation notifications retain refresh requests under a claim; release drains them. |
| CP-R2-03 | Fixed: compression and STT-readiness checks cover both destinations before refusals. |
| CP-R2-04 | Fixed for the reported stale startup commit/failure: startup identity is captured before suspension, checked on resumed terminal paths, and the arming slot is handed on. |
| CP-R2-05 | Fixed: presentation generation is checked before either completion arm mutates presentation state. |
| CP-R2-11 | Fixed: the reported abandonment exits and generic errors settle the appended user row by message ID. |

The recorder, relay, phone, and Mac forwards are legitimate assignments of repair ownership. They do not remove those defects from this review’s explicitly shared-service scope.

For the changed guards, the following production mutations survive the **named guard**, as determined by reading its assertions. This is not a claim that every mutation survives the entire repository suite.

`W` denotes `CarPlayWorkNoteTests.swift`; `T` denotes `CarPlayVoiceTimingContractTests.swift`; `C` denotes `CarPlayAttemptCancellationOutcomeTests.swift`.

| Changed guard | Surviving production mutation and resulting failure |
|---|---|
| W:292 — words parked/owned | Make the ownership condition `await stillOwnsCapture(...) || true`. All searched calls and ordering remain; an overtaken owner attaches. |
| W:422 — chat-hop suspensions | Make `isCurrentListen` check only `sessionActive`. The exact guard statements remain; an old chat resumes into a replacement session. |
| W:557 — no gateway/re-arm | Replace the re-arm restriction with `if sessionDestination == .chat { }`. The searched comparison remains; Work can re-arm. |
| W:667 — mic hint/day-one order | Pass a literal chat retry instruction instead of calculated `detail`; alternatively render `firstSectionItems.reversed()`. The destination expression, keys, array literal, and three variable mentions remain. |
| W:820 — pure start gate | Pass `claimHeld: false` from production `claimStart`. The pure gate remains correct while scene wiring violates the rule. |
| W:894 — start lifecycle wiring | Append `|| true` to `startIsLive`’s result, or remove the refresh call from `releaseStart`. Required text remains while the claimed protection disappears. |
| W:1197 — End without Mute | Call `installVoiceTemplateButtons(service:)` after the required unconditional clear. The guard passes; that helper reinstalls Mute. |
| W:1233 — no sticky Work mode | Add a separate sticky `workMode` flag and consult it in the New voice chat handler, leaving the typed override and chooser unchanged. The guard examines neither route. |
| W:1268 — shared STT preflight | Remove the generation comparison from `isCurrentListen`. Both required guard statements remain but accept replacement sessions. |
| W:1321 — superseded startup | The same helper mutation permits stale commits/failures while preserving every searched startup check. |
| W:1421 — presentation identity | Reset `presentationGeneration = 0` before each presentation’s flag write. Old and new presentations reuse generation 1; all asserted declarations, ordering, and guards remain. |
| T:290 — stale engine commit | Remove the generation comparison inside `isCurrentListen`; the guard and cleanup text remain. |
| T:360 — reconnect teardown | Put `recordingService?.teardown()` inside `if false`. Both shared-cleanup references remain; stale audio machinery survives reconnect. |
| T:384 — one-shot hint | Set the hint back to true immediately after the required false assignment in `claimStart`. Presence assertions still pass; the hint is not consumed. |
| C:123 — stale marks across drives | Remove the production `cancel` method’s call to `markCancelClaim`; helper-only assertions remain unaffected. Real pre-dispatch cancellation is lost. |
| C:177 — bounded claims | The same production-call removal passes this helper test while disabling actual cancellation. |
| C:200 — newer recheck preserves older claim | The same removal leaves its manually populated test set correct while real cancellations have no mark. |
| C:220 — newer cancellation preserves older claim | Same integration mutation; the test calls the helper directly. |
| C:240 — oldest-mark retention | Same integration mutation. Additionally, this test explicitly requires eviction without modeling whether the evicted attempt is still pending. |
| `PendingRetryQueueTests`: Chat expiry case | Change expiry from `>` to `>=`. Exact-boundary expiration changes; the 599/601-second samples still pass. |
| `PendingRetryQueueTests`: published Work expiry case | The same mutation changes the exact 86,400-second boundary; the surrounding samples still pass. |
| `WorkVoiceRecoveryTests:481` | Make `isExpired` ignore `retryTTL` and always use 600 seconds. Its new property assertion still passes; it never checks elapsed-time expiry. |
| `PendingRetrySurfaceHandoffTests:404` | Remove cancellation-generation enforcement inside `attemptRetry`, retaining its signature and caller expression. The source guard passes while Esc no longer suppresses delivery. |

The pure `mayClaim` truth table **does discriminate all Boolean combinations**. The cancellation helper tests discriminate the former two-token pruning error; the expiry tests discriminate 600 seconds versus a day versus unlimited retention. The current screenshot-lane tests also exercise actual store retention with Chat controls. Those are useful checks. The source guards do **not** establish their claimed lifecycle, cancellation, or ownership guarantees.

The CarPlay implementation otherwise follows the recorded design choices: one root Work action, no sticky destination, no Mute, corrected retry hint, Work first without gateways, transcript parking, and the 24-hour published retry budget. Keeping Work outside “Choose AI” is a recorded product decision, not an unexplained deviation. I found no current Work-to-gateway path in the reviewed desk, retry, intent, relay, or CarPlay forks. The CarPlay catalog/default values match, including the Watch’s two saved acknowledgements; both changed Mac catalog keys have matching consumers.

