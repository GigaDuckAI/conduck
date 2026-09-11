Not clean. The ordinary three-shortcut flow matches the intended destinations, but the human-press boundary is unenforced, a new screenshot-ownership path can expose Work content to Chat, and cancellation and shared-service regressions remain.

This is a source-only assessment. No builds or tests were run. Mutation conclusions come from reading the assertions. Paths below are relative to the supplied worktree.

## MAC-R4-P1-A — Automated entry points still start microphones and publish to Work

**Severity:** P1  
**Files:** `Conduck/Conduck/Intents/RecordWorkNoteIntent.swift:69`; `Views/Workboard/WorkboardCaptureCanvas.swift:217`; `Views/Workboard/WorkboardVoiceCaptureView.swift:60`.

**Failure sequence:**

1. Invoke the registered Siri recording phrase.
2. `RecordWorkNoteIntent` requests `WorkVoiceCaptureLaunchRoute`.
3. Notification, appearance or destination activation consumes that route and presents the sheet.
4. The sheet’s `.task` calls `recorder.startRecording()` without a recording-button press.

Independent publication paths also remain: `CaptureWorkboardIntent.swift:79` directly writes text; `ConverseIntent.swift:346` publishes supplied Work audio; `AddFilesToWorkIntent.swift:215` publishes an envelope and drains it. The envelope carries no authorization proving a human press.

The prior declines are **not defensible against this packet**. File ownership assigns the fix; it does not resolve the violation. A phrase naming Work does not satisfy the expressly required press.

**Smallest fix:** Automated triggers may navigate or stage an unarmed preview. Require a human action before microphone acquisition or initial Work publication, and carry that authorization through subsequent asynchronous work.

## MAC-R4-P1-B — The new failed-save holding slot can lose Work screenshots or transfer them into Chat

**Severity:** P1  
**File:** `Conduck/Conduck/MenuBar/MenuBarCoordinator.swift:2443`, `:2454`, `:2566`.

**Failure sequence:**

1. Start saving Work screenshot A.
2. During publication, stage screenshot B in the Work slot.
3. A’s publication fails; A moves to `stalledWorkSaveImage`.
4. Save again while B remains staged.
5. `stagedAtCommit ?? stalledWorkSaveImage` selects B, then unconditionally clears the holding slot. A disappears without publication or explicit discard.

The slot also has no composition owner:

1. Establish held Work screenshot A as above.
2. Switch to Chat, whose screenshot slot is empty, and press **Add to Work** for unrelated text.
3. That commit silently takes A from the shared holding slot.
4. If publication fails, the `.chat` failure arm restores A into `pendingCaptureImage`.
5. Press Return. A screenshot staged exclusively for Work now reaches `handleQuickSend` and the gateway.

**Smallest fix:** Retain a failed-save snapshot with its original aim, text and identity. Retry or discard that snapshot explicitly; never substitute it into another composition or discard it because a newer screenshot exists. Blocking replacement staging during publication is a smaller alternative.

## MAC-R4-P1-C — A cancelled send still clears a newer capture’s screenshot and destination

**Severity:** P1  
**File:** `Conduck/Conduck/MenuBar/MenuBarCoordinator.swift:2637`, `:2770`, `:2835`.

**Failure sequence:**

1. Start an Ask send and suspend it during conversation creation.
2. Press Esc, invalidating `quickSendGeneration`.
3. In text mode, use ⌘⇧2 to stage screenshot B for another question.
4. Resume the old send.
5. Its final generation check correctly refuses dispatch.
6. Its unconditional `defer` nevertheless clears B and resets the current destination.

The cancellation check also comes after the error branches that call `presentHandoffError` and populate `pendingFailedTurn`. A cancelled mint that fails can therefore resurrect its withdrawn transcript as Retry.

**Smallest fix:** Associate attachments, destination cleanup and `turnStarting` with the originating send. Check cancellation before post-await error/stash writes, and make stale completion cleanup incapable of consuming a newer capture.

## MAC-R4-P1-D — Ask startup cancellation does not establish recorder-session ownership

**Severity:** P1  
**Files:** `Conduck/Conduck/MenuBar/DictationService.swift:857`, `:864`, `:873`, `:907`; `Services/AudioRecorder.swift:43`, `:46`, `:81`.

**Failure sequence:**

1. Start Ask. The service declares `.recording` before primitive startup completes.
2. While startup awaits microphone permission, press the hotkey again to stop.
3. `stopAndProcess()` finds no audio and sets `.error`, without invalidating `recordingStartToken`.
4. Startup resumes and opens the microphone.
5. The token still matches, leaving a live microphone behind an error surface. Esc in `.error` merely clears the error.

The new teardown also mishandles overlapping starts:

1. Start A, cancel it during permission acquisition, then start B.
2. Both primitive calls have passed their initial `!isRecording` check.
3. B resumes first and starts recording.
4. A resumes later and replaces `audioRecorder`; the primitive performs no ownership check after its await.
5. A’s stale completion sees `.recording` and deliberately leaves the replacement running. Stopping B can return A’s recording and lose B’s earlier speech.

**Smallest fix:** Give primitive startup a session reservation checked after permission and before recorder creation. Stop must invalidate pending startup. Aggregate service state cannot identify which recorder a completion owns.

## MAC-R4-P2-A — A recovered Chat retry loses attachment ownership when it becomes a handoff retry

**Severity:** P2  
**File:** `Conduck/Conduck/MenuBar/MenuBarCoordinator.swift:2824`, `:2863`, `:3037`.

**Failure sequence:**

1. Leave recording A in the Chat retry queue.
2. Stage screenshot B for a different question.
3. Retry A. The new recovered hook correctly passes `carriesComposition: false`.
4. Its destination is busy, so the coordinator stores `.voice(transcript:)` in `pendingFailedTurn`.
5. Retry that handoff after the destination becomes available.
6. `.voice` routes through `handleTranscript`, restoring the default `carriesComposition: true`; B is attached and cleared.

**Smallest fix:** Preserve attachment ownership through `PendingFailedTurn`. A recovered recording must remain composition-free through every subsequent retry.

## MAC-R4-P2-B — Work cancellation still misses the queued transcript write

**Severity:** P2  
**File:** `Conduck/Conduck/Services/Workboard/WorkVoiceCaptureCoordinator.swift:548`, `:550`, `:583`.

**Failure sequence:**

1. Recognition succeeds and attachment passes `Task.checkCancellation()`.
2. Attachment suspends in `context.perform`.
3. Press **Cancel transcription** before the queued operation executes.
4. The closure mutates and saves the transcript without cancellation authorization.
5. The caller reports cancellation after the words have landed.

This affects the Mac and phone recorder.

**Smallest fix:** Carry a thread-safe cancellation authorization into the write operation and check it at the mutation/commit boundary. The difficulty of reading task cancellation inside a dispatched closure does not remove the requirement.

## MAC-R4-P2-C — Cancel Transcription leaves the phone desk sheet showing a nonexistent startup

**Severity:** P2  
**Files:** `Conduck/Conduck/Services/InAppAudioRecorder.swift:1691`, `:1762`; `Views/Workboard/WorkboardVoiceCaptureView.swift:263`, `:270`, `:375`.

**Failure sequence:**

1. Stop a phone Work recording.
2. Press the sheet’s **Cancel Transcription** button.
3. The new cancelled-success handling returns cancellation and sets `.idle`.
4. The sheet ignores the failure result.
5. `.idle` displays “Starting the microphone…” and no main action, although no startup exists.

The model retains `canRetryWorkCapture`, but the view exposes Try Again only in `.error`.

**Smallest fix:** Dismiss on this cancellation result or render an explicit stopped state with the retained retry action. Test the shipping host’s response, not only the recorder Boolean.

## MAC-R4-P2-D — Dismissing the Mac desk sheet leaves a permanent unsaved-capture registration

**Severity:** P2  
**Files:** `Conduck/Conduck/Services/InAppAudioRecorder.swift:2107`; `Views/Workboard/WorkboardVoiceCaptureView.swift:68`, `:383`.

**Failure sequence:**

1. Record using the Mac main-window Work sheet.
2. Both recording publication and retry preservation fail, incrementing `unsavedWorkCaptureCount`.
3. Cancel or dismiss the error sheet.
4. Both cancellation and disappearance do nothing for `.error`; neither releases the capture’s registration.
5. Subsequent ⌘Q prompts describe an unsaved recording and promise Try Again, although its surface is gone.

The recorder has no lifetime cleanup balancing this registration.

**Smallest fix:** Release or transfer the capture and its durability registration on explicit sheet disposal, including processing that completes after dismissal.

## MAC-R4-P2-E — A partial retry save can bypass another surface’s ownership

**Severity:** P2  
**Files:** `Conduck/Conduck/Services/PendingRetryStore.swift:727`, `:751`, `:1276`; `Services/InAppAudioRecorder.swift:1916`, `:2055`.

**Failure sequence:**

1. Screenshot publication fails.
2. Retry storage successfully writes the sidecar and audio, then fails writing the screenshot.
3. The newly propagated error leaves `armedDurableRetryID` unset.
4. Queue reconciliation nevertheless adopts the sidecar/audio, and another surface claims that entry.
5. Press the original recorder’s Try Again.
6. `reserveDurableRetry` returns true immediately because its local armed ID is absent.
7. Both surfaces can transcribe and attach different results to the same card.

**Smallest fix:** Distinguish absent, partially preserved and already-claimed entries. Reserve an existing capture ID regardless of whether its previous save returned success.

## MAC-R4-P2-F — Watch recovery copy still promises an unavailable phone action

**Severity:** P2  
**Files:** `Conduck/Conduck/Services/AppleSpeechRelayCoordinator.swift:538`, `:762`; `Conduck/ConduckWatch Watch App/Services/AppleRelayPendingQueue.swift:664`, `:1178`.

**Failure sequence:**

1. The phone publishes a Watch Work recording.
2. STT fails terminally, for example because the speech key is missing.
3. The relay acknowledges `workSaved: true` with empty text.
4. Watch consumes its entry and says **Saved to Work. Add the words on your iPhone.**
5. No phone retry entry was created, and the audio card has no transcription action.

**Smallest fix:** Persist a published Work retry entry before acknowledging, or change wrist and notification copy to promise only the saved recording. Declining on lane ownership does not refute this shared-service defect.

## MAC-R4-P2-G — The new Watch attachment retry resurrects a deleted recording

**Severity:** P2  
**File:** `Conduck/Conduck/Services/AppleSpeechRelayCoordinator.swift:414`, `:502`, `:924`.

**Failure sequence:**

1. Watch records to Work; phone phase one publishes the audio card.
2. Delete that card on the phone while STT runs.
3. STT succeeds, but attachment returns `.recordingMissing`.
4. The changed relay maps that result to `.retryable`, retaining the wrist entry.
5. A subsequent queue drain replays the request.
6. Phase one republishes the recording the person deleted.

The shared recovery contract explicitly distinguishes failed publication from a previously published card that must stay deleted.

**Smallest fix:** Preserve publication/deletion provenance across relay retries. Retrying attachment must not automatically authorize republication after confirmed deletion.

## MAC-R4-P2-H — The typed receipt can still confirm a collision occupant instead of the capture

**Severity:** P2  
**Files:** `Conduck/Conduck/MenuBar/MenuBarCoordinator.swift:2518`, `:2604`; `Services/Workboard/WorkCaptureDrainer.swift:397`, `:523`.

**Failure sequence — collision recovery case:**

1. Publish a capture whose primary material ID and deterministic escape ID are occupied by incompatible cards.
2. The drainer refuses both identities, retires the capture and returns a successful report containing a refusal.
3. `deskHoldsWorkMaterial(published)` finds the unrelated primary-ID occupant.
4. The receipt says **Added to Work** although this capture was refused.

The ordinary empty-drain/no-card sequence is fixed. The new helper still proves only ID presence, not this capture’s completed import or payload.

**Smallest fix:** Consume an import confirmation identifying this capture’s actual material IDs and required payloads. Keep unconfirmed/refused outcomes out of `.saved`.

## MAC-R4-P2-I — A bail before the send task starts is invisible to its cancellation token

**Severity:** P2  
**File:** `Conduck/Conduck/MenuBar/MenuBarCoordinator.swift:1062`, `:2031`, `:2628`.

**Failure sequence:**

1. A transcript callback or typed send sets `turnStarting` and schedules its task.
2. `cancelActiveCapture()` runs before that task starts and advances `quickSendGeneration`.
3. The task begins and reads the already-advanced generation as its own identity.
4. Its final check passes and dispatches the cancelled request.

**Smallest fix:** Capture the send identity synchronously when the callback or press commits, before task creation, and pass it through the send.

## MAC-R4-P2-J — Cancellation guards still accept moving checks across the waits they protect

**Severity:** P2  
**Files:** `Conduck/ConduckTests/MenuBarEscCancellationContractTests.swift:159`, `:382`, `:507`; `WorkboardAudioCaptureTests.swift:668`.

These mutations survive the relevant assertions:

| Guard | Smallest surviving mutation | Concrete failure |
|---|---|---|
| Ask startup | Move the complete stale-start block before `await recorder.startRecording()`. | Start → cancel during permission wait → microphone starts afterward. |
| Stop token origin | Move `let generation = transcriptionGeneration` inside the stop task. | Stop → cancel before task execution → task accepts the new token and sends withdrawn audio. |
| Retry settlement | Move the second token check above `await pendingErrorCode()`. | Retry → cancel and start another Ask during that read → old backlog error overwrites the new recording state. |
| Work attachment | Move `Task.checkCancellation()` above `ensureLoaded()`. | Cancel during store loading → transcript still writes. The fixtures cancel before entering attachment, so they cannot distinguish the mutation. |

**Smallest fix:** Assert each check’s position after its particular suspension, and token acquisition before task creation. Add suspended cases at those actual boundaries.

## MAC-R4-P2-K — The new unsaved-capture guard never verifies its counter’s effect

**Severity:** P2  
**File:** `Conduck/ConduckTests/MacMenuBarWorkShortcutDriftGuardTests.swift:1377`.

**Smallest surviving mutation:** Change `InAppAudioRecorder.swift:2110` from `unsavedWorkCaptureCount += 1` to `+= 0`.

**Failure sequence:**

1. Apply that mutation.
2. Fail desk publication and retry preservation.
3. The helper is called, but the counter remains zero.
4. ⌘Q silently terminates with memory-only capture bytes.

All asserted predicates, helper names and verdict shapes remain present. Passing `unsavedCount: 0` in `AppDelegate` also survives.

**Smallest fix:** Verify the actual count and termination verdict after failed preservation, durable recovery and discard, including two recorder instances.

## MAC-R4-P2-L — Receipt guards call the confirmation helper without testing what it confirms

**Severity:** P2  
**File:** `Conduck/ConduckTests/MenuBarWorkCaptureStateTests.swift:519`.

**Smallest surviving mutation:** Change `$0.id == materialID` to `$0.id != materialID` in `MenuBarCoordinator.swift:2604`.

**Failure sequence:**

1. An unrelated card already exists.
2. Another drainer claims the new typed capture; the inline drain returns empty.
3. The mutated helper accepts the unrelated card.
4. The claimant fails, but the receipt still says **Added to Work**.

The tests require the helper call, never its behavior.

**Smallest fix:** Exercise an unrelated existing card plus an unimported capture and require `.queued`; confirm the intended capture and payload for `.saved`.

## MAC-R4-P2-M — Watch phase-two tests do not pin the shipping acknowledgement

**Severity:** P2  
**File:** `Conduck/ConduckTests/WatchWorkRelayPhoneTests.swift:274`; production `Services/AppleSpeechRelayCoordinator.swift:502`.

**Smallest surviving mutation:** Replace the caller’s `.retryable` case body with `break`.

**Failure sequence:**

1. Attachment fails and the helper correctly returns `.retryable`.
2. The mutated caller falls through to its success reply.
3. Watch receives the saved stamp and consumes its clip despite refusal.

The new tests exercise the helper’s verdict; the existing source guard checks catch arms, not this switch.

**Smallest fix:** Test the shipping reply decision and require an error with no saved stamp for retryable attachment failure.

## MAC-R4-P3-A — README still advertises a nonexistent menu item

**Severity:** P3  
**File:** `README.md:55`.

**Failure sequence:** Read **Record to Work…** in the README, then look for it in the menu; the actual action is **Capture to Work…**.

**Smallest fix:** Replace that phrase. The docs handoff has not closed the finding.

## MAC-R4-P3-B — The unsaved quit prompt misidentifies screenshot-only loss

**Severity:** P3  
**Files:** `Conduck/Conduck/Services/InAppAudioRecorder.swift:2092`; `MenuBar/QuitGuard.swift:115`.

**Failure sequence:**

1. Screenshot publication and preservation fail.
2. Audio publication succeeds.
3. The unsaved counter correctly remains positive for the screenshot.
4. ⌘Q says **A recording hasn’t reached your desk** and offers **Keep the Recording**, although the recording is already playable and safe.

**Smallest fix:** Use capture-neutral wording or describe the actual unsaved artifact.

## Implementation, boundaries and verified guard closures

The normal registrations are correct: ⌘⇧1 calls Ask, ⌘⇧2 calls Screenshot & Ask, and ⌃⌘W calls Work capture. Optional Work screenshots, separate picture/recording cards, shared capture dates, microphone precedence, secondary-click menus, menu delegation and the plural Settings header are implemented.

The final implementation also supersedes several design decisions: text mode now bypasses the post-overlay Ask-microphone restriction; typed receipts use desk read-back; Ask cancellation and queued recovery received changes previously deferred; and unsaved-capture quitting now introduces a prompt. Those changes are not inherently deviations from founder intent, but their remaining defects are listed above.

The direct shared-service graph remains desk-scoped: `WorkVoiceScreenshotCoordinator` publishes through the inbox/drainer; the drainer writes Work materials; `WorkVoiceCaptureCoordinator.recover` rejects non-Work metadata; Mac Work retry returns through `finishWorkRetry`; Watch Work settlement bypasses `completeChat`. I found no new CarPlay gateway-routing defect from these shared changes. Chat retains its ten-minute retry budget, published Work receives a day, and unpublished artifacts retain expiry protection.

Those structural boundaries **do not establish either required impossibility**: P1-A breaks human-press authorization, and P1-B provides a staged-Work-screenshot path into a gateway turn.

The exact earlier guard mutations are now rejected:

| Prior guard | Mutation now rejected |
|---|---|
| R1-P2-C | Removing the busy-branch `return`. |
| R1-P2-D | Swallowing the drain with `try?`. |
| R2-P2-D | Inverting closed-popover visibility. |
| R2-P2-E | Giving queued feedback `.saved` kind. |
| R3-P2-G | Swapping shortcut callbacks or classifying left-click as secondary-click. |
| R3-P2-H | Moving ordinary STT’s success check before its provider call. |
| R3-P2-I | Declaring protection after compression or swallowing the image write. |
| R3-P2-J | Moving ownership transfer inside the task or adding queued `onTapGesture`. |

The action/commit naming distinction is otherwise coherent: **Capture to Work** initiates capture; **Add to Work** commits. Remaining receipt, recovery and cancellation promises are covered by the findings above.

## Prior-finding dispositions

“Closed” below means the reported failure sequence is closed in source, not that tests were executed.

| Prior finding ID | Round-4 disposition |
|---|---|
| MAC-R1-P1-A | Open — P1-A; decline not defensible. |
| MAC-R1-P1-B | Closed for Return during Work save; new failed-save ownership defect is P1-B. |
| MAC-R1-P1-C | Closed for hidden Work-draft cancellation. |
| MAC-R1-P1-D | Original stop-to-publication quit window closed; lifecycle and guard gaps remain in P2-D/K. |
| MAC-R1-P2-A | Ordinary empty-drain case closed; confirmation remains incomplete under P2-H/L. |
| MAC-R1-P2-B | Ordinary STT cancellation closed; broader handoff/startup defects remain in P1-C/D and P2-I. |
| MAC-R1-P2-C | Closed — missing-return mutation rejected. |
| MAC-R1-P2-D | Closed — swallowed-drain mutation rejected. |
| MAC-R2-P1-A | Open — P1-A; decline not defensible. |
| MAC-R2-P1-B | Original committed-screenshot leak closed; new ownership bridge is P1-B. |
| MAC-R2-P1-C | Closed for both reported visible-owner cancellation cases. |
| MAC-R2-P1-D | Reported preservation and retry-settlement races closed in production; new guard gap is P2-J. |
| MAC-R2-P1-E | Timeout and failed-preservation quit decisions implemented; shared lifecycle/partial-save defects are P2-D/E, guard gap P2-K. |
| MAC-R2-P2-A | Ordinary empty-drain case closed; P2-H/L remain. |
| MAC-R2-P2-B | Provider-return race closed; actual queued-write race remains P2-B, host regression P2-C. |
| MAC-R2-P2-C | Open — P2-F; ownership decline does not refute it. |
| MAC-R2-P2-D | Closed — inverted visibility mutation rejected. |
| MAC-R2-P2-E | Closed for wrong queued kind and the previously reported tap interaction. |
| MAC-R3-P1-A | Open — P1-A. |
| MAC-R3-P1-B | Reported settlement surface/handoff race closed; its guard still admits P2-J. |
| MAC-R3-P1-C | Failed preservation now produces a quit decision; remaining lifecycle and coverage defects are P2-D/K. |
| MAC-R3-P1-D | Incomplete — P1-B merely delays the loss and introduces cross-aim leakage. |
| MAC-R3-P1-E | Closed for a Work save resetting a newer Ask arm; a cancelled Ask send has the separate P1-C cleanup defect. |
| MAC-R3-P1-F | Partial — ordinary Esc/preflight cancellation fixed; Stop and overlapping startup ownership remain P1-D. |
| MAC-R3-P2-A | Ordinary empty-drain/no-card sequence closed; incomplete confirmation remains P2-H/L. |
| MAC-R3-P2-B | Partial — cancellation after loading is checked, but queued-write cancellation remains P2-B. |
| MAC-R3-P2-C | Open — P2-F. |
| MAC-R3-P2-D | Partial — final dispatch check added; task-origin and stale-cleanup holes remain P2-I/P1-C. |
| MAC-R3-P2-E | Partial — first recovered send is isolated; handoff retry loses that provenance, P2-A. |
| MAC-R3-P2-F | Closed — text mode survives the post-overlay microphone check. |
| MAC-R3-P2-G | Closed for both reported routing mutations. |
| MAC-R3-P2-H | Closed for the reported provider-order mutation; additional cancellation guards have P2-J gaps. |
| MAC-R3-P2-I | Closed for both reported mutations; new unsaved accounting remains unpinned, P2-K. |
| MAC-R3-P2-J | Closed for both reported mutations; failed-save ownership itself remains P1-B. |
| MAC-R3-P3-A | Open — P3-A; README remains unchanged at the offending phrase. |

