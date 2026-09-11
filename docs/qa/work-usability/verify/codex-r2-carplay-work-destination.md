## Re-check of round-1 findings

- **CP-R1-01 — RE-CHECKED: STILL OPEN.** `Conduck/Conduck/Intents/CaptureWorkboardIntent.swift:35` permits background execution and writes at `:79`. The refutation does not address an automation running without a present gesture; it substitutes a narrower boundary for the packet’s explicit requirement.
- **CP-R1-02 — RE-CHECKED: CLOSED-BUT-NEW-HOLE.** The pre-token suspension checks and catch guard are present in `Conduck/Conduck/CarPlay/CarPlayRecordingService.swift:2139` and `:2358`. After token allocation, older cancellations can still be forgotten by `Conduck/Conduck/CarPlay/CarPlayConverseUploader.swift:540` and `:551`. Earlier STT refusals also remain unsafe at `CarPlayRecordingService.swift:1551`.
- **CP-R1-03 — RE-CHECKED: CLOSED-BUT-NEW-HOLE.** Refused-start dismissal now checks ownership at `Conduck/Conduck/CarPlay/CarPlaySceneDelegate.swift:654`, and dismissal completion checks the current presentation/session at `:773`. However, an older failed presentation still clears a newer presentation’s flag at `:726`.
- **CP-R1-04 — RE-CHECKED: CLOSED.** `Conduck/Conduck/CarPlay/CarPlaySceneDelegate.swift:1323` cancels the claim before End; `:392` cancels it before the disappearance handler’s session guard. Both reach serial-scoped release at `:363`.
- **CP-R1-05 — RE-CHECKED: STILL OPEN.** Microphone arbitration remains macOS-only at `Conduck/Conduck/Services/InAppAudioRecorder.swift:772`. The iOS recorder still changes the shared session at `Conduck/Conduck/Services/AudioRecorder.swift:54` and deactivates it at `:141`.
- **CP-R1-06 — RE-CHECKED: CLOSED.** `Conduck/Conduck/CarPlay/CarPlaySceneDelegate.swift:1296` retains the notification under a claim; `:345` drains it on release. Mid-session notifications still return at `:1290`.
- **CP-R1-07 — RE-CHECKED: STILL OPEN.** `Conduck/Conduck/Services/AppleSpeechRelayCoordinator.swift:513` acknowledges the recording without creating a transcription retry. The Watch consumes that acknowledgement at `Conduck/ConduckWatch Watch App/Services/AppleRelayPendingQueue.swift:649`.
- **CP-R1-08 — RE-CHECKED: STILL OPEN.** `Conduck/Conduck/Services/PendingRetryStore.swift:761` posts the notification, but the phone has no corresponding subscription invoking `Conduck/Conduck/ContentView.swift:1193`.
- **CP-R1-09 — RE-CHECKED: STILL OPEN.** Several named mutations are now rejected, but deleting the successful-ownership staleness check still passes `Conduck/ConduckTests/CarPlayWorkNoteTests.swift:316`; replacing the re-arm guard with an unused comparison still passes `:524`. Actual scene interleavings remain untested.
- **CP-R1-10 — RE-CHECKED: STILL OPEN.** `docs/qa/work-usability/handoff.md:286` still prescribes Mute and unconditional “nothing is saved” after End. The incorrect entitlement remains at `:99`; the requested competing-start and long-drive steps are absent.

## Findings

The code implements the design’s **one-tap “Add to Work” root row**, including Work-first ordering without a gateway and End without Mute. It does **not** literally add Work to the gateway chooser: `CarPlaySceneDelegate.swift:1246` still maps configured gateways only. That departure is deliberate in `docs/qa/work-usability/design/carplay-work-destination.md:52`.

The current CarPlay Work branch publishes audio, performs STT, attaches words and returns before `startConverseHop` (`CarPlayRecordingService.swift:1665`). I found no Work-to-gateway dispatch edge in the inspected desk, inbox, retry, Shortcut or Watch routing. Watch Work settlement explicitly avoids `completeChat` (`AppleRelayPendingQueue.swift:644`). This supports the desk-to-gateway boundary; it does not establish the separate attended-capture boundary.

Catalog inspection found no duplicate keys in either catalog, missing/orphan lane-owned keys, or CarPlay default-value mismatches. Work/Add to Work/Saved to Work consistently name destination/action/outcome. The two supplied catalog changes concern Mac UI and have consumers at `MacGeneralCategory.swift:254` and `MenuBarCoordinator.swift:2390`. The queued Mac receipt is used by the typed capture path; the voice path correctly uses separate speech-provider wording at `MenuBarCoordinator.swift:2247`.

### CP-R2-01 — P1 — Conduck/Conduck/Intents/CaptureWorkboardIntent.swift:35

**Claim:** Work capture remains reachable without an attended foreground gesture. The implementer’s CP-R1-01 refutation is unsound against this packet’s explicit boundary.

**Failure scenario:** A scheduled Shortcut supplies `thought` while the phone is unattended. `perform()` reaches `upsertDeskMaterial` at `:79` without presenting capture UI. Supplied files similarly reach publication and draining through `AddFilesToWorkIntent.swift:215`. Separately, the registered Siri recording phrase invokes `RecordWorkNoteIntent.swift:69`, and the foreground sheet starts recording from `WorkboardVoiceCaptureView.swift:60` without another gesture.

Foreground presentation alone does not prove attendance. CarPlay’s row handler at `CarPlaySceneDelegate.swift:828` also does not distinguish a physical interaction from an OS voice-control invocation; static reading cannot certify that exclusion.

**Smallest fix:** Require an explicit foreground capture action before creating new Work material or starting its microphone. Intents may open that surface; subsequent draining may finish captures already authorized there.

### CP-R2-02 — P2 — Conduck/Conduck/CarPlay/CarPlayConverseUploader.swift:540

**Claim:** A cancelled older chat can still dispatch after a newer turn removes its cancellation mark.

**Failure scenario:** Chat A mints token 1 and suspends in `mintOutboxKey` (`CarPlayRecordingService.swift:2316`). End marks token 1 cancelled. After sign-off, chat B starts and reaches dispatch with token 2. `consumeCancelClaim` removes all lower marks at `CarPlayConverseUploader.swift:551`, including token 1. A resumes, reaches `uploadConverse`, finds no cancellation mark and sends its abandoned transcript.

The new staleness checks stop before these suspensions. The premise that older turns cannot return is false across End and a replacement session.

**Smallest fix:** Retain cancellation state until that exact dispatch attempt finishes or acknowledges cancellation. Recheck listen ownership after post-token suspensions too; do not use token ordering as proof that an older task has terminated.

### CP-R2-03 — P2 — Conduck/Conduck/CarPlay/CarPlayRecordingService.swift:1551

**Claim:** An earlier chat’s STT preflight can still terminate a replacement Work session.

**Failure scenario:** Chat A suspends in `STTKeyReadiness.resolve` at `:1542`. The driver ends A and starts Work B. A resumes with `.notConfigured`. Its `workCapture` is nil, so the staleness check at `:1551` does nothing. `endRefusalBelowFork` at `:1562` follows the chat refusal arm and ends the currently active session, deleting B’s partial recording.

The downstream `startConverseHop` fix cannot protect a refusal that occurs before that function is called.

**Smallest fix:** Apply listen ownership checks to both destinations after compression and STT preflight, before any refusal or shared-state mutation.

### CP-R2-04 — P2 — Conduck/Conduck/CarPlay/CarPlayRecordingService.swift:849

**Claim:** Microphone startup validates session activity without validating which session owns the startup.

**Failure scenario:** A suspends in `detector.start()` at `:810`. End invalidates A, then Work B begins. B’s startup returns because A still holds `isArmingListen` (`:715`). A resumes and passes `guard sessionActive` because B is active. It can install a detector whose callbacks carry A’s invalidated attempt ID (`:797`, `:804`), so B’s speech never satisfies the detector. Alternatively, A’s delayed startup error calls `endSilentlyAfterCaptureStartFailure` at `:813` and ends B.

**Smallest fix:** Capture the startup generation before its first suspension and check it on every resumed success/error path. Serialize disposal of the old startup with admission of its replacement.

### CP-R2-05 — P2 — Conduck/Conduck/CarPlay/CarPlaySceneDelegate.swift:726

**Claim:** Presentation failure handling still confuses connection identity with presentation identity.

**Failure scenario:** Presentation A is pending; backgrounding cancels its start. On the same controller, the driver returns and starts Work B. A’s delayed failure callback passes the controller-identity check at `:709` and unconditionally clears `isVoicePresented` at `:726`. The caller’s serial check occurs afterward.

B now has a modal with a false presentation flag. A subsequent state update can attempt another presentation, or End can skip dismissal because `ensureVoiceDismissed` returns on that flag at `:757`.

**Smallest fix:** Give each presentation its own generation and reject obsolete callbacks before changing presentation state or activating template states.

### CP-R2-06 — P2 — Conduck/Conduck/Services/InAppAudioRecorder.swift:772

**Claim:** Phone and CarPlay recording still lack shared microphone ownership.

**Failure scenario:** CarPlay is recording a Work note. A passenger opens the phone’s Work recorder and starts capture. The phone bypasses the macOS-only lease and calls `AudioRecorder.startRecording`, which sets the shared iOS session to `.record` (`AudioRecorder.swift:54`). Stopping that recorder calls `setActive(false)` at `:141`, interfering with CarPlay’s capture or acknowledgement.

Mac arbitration does not protect two surfaces using the same iPhone audio session.

**Smallest fix:** Apply one ownership gate to phone and CarPlay microphone starts, refusing the second capture. Only the current owner should release the session.

### CP-R2-07 — P2 — Conduck/Conduck/Services/AppleSpeechRelayCoordinator.swift:513

**Claim:** Watch Work acknowledgements can retire the recovery path while transcription remains unfinished.

**Failure scenario:** The phone publishes the Watch recording, then discovers its STT key is missing. This branch sends a successful recording-only acknowledgement. The Watch’s `.workRecordingOnly` settlement claims the entry at `AppleRelayPendingQueue.swift:652`, retiring its clip. No phone retry entry is armed, so restoring the key leaves a playable but untranscribed card without the promised recovery action.

The related attachment-failure path at `AppleSpeechRelayCoordinator.swift:488` also proceeds to a success stamp without establishing a phone retry.

**Smallest fix:** Persist the outstanding transcription—and any already recognized words—in the phone retry queue before sending an acknowledgement that retires the Watch entry.

### CP-R2-08 — P2 — Conduck/Conduck/ContentView.swift:1193

**Claim:** A foreground phone still fails to discover retries created by CarPlay.

**Failure scenario:** The phone already displays Chats with no retry card. CarPlay saves a Work recording and encounters a network failure. The queue commits and posts its change notification (`PendingRetryStore.swift:761`), but the phone does not refresh its retry state. “Add the words on your iPhone” leads to no visible action until another lifecycle/settings refresh occurs.

**Smallest fix:** Observe queue changes in the phone retry surface and coalesce calls to `refreshPendingRetryState`.

### CP-R2-09 — P2 — Conduck/Conduck/Services/InAppAudioRecorder.swift:1603

**Claim:** The shared recorder can write a transcript after losing its retry reservation.

**Failure scenario:** A desk sheet retries recording X and suspends in STT. Lease renewal fails long enough for another retry surface to claim X and attach its result. The original sheet resumes and calls `attachTranscript` without confirming ownership. Attachment permits different words to replace existing words, so the stale result overwrites the new owner’s transcript.

`reserveDurableRetry` also trusts a cached claim at `:1833`; repeated renewal attempts at `:1871` do not establish continued ownership.

**Smallest fix:** Confirm the held reservation before transcript attachment and retry-metadata updates. A proven takeover must end the stale attempt without writing or clearing the other owner’s entry.

### CP-R2-10 — P2 — Conduck/Conduck/AppDelegate.swift:352

**Claim:** The new quit wait postpones the recording-loss window but does not close it.

**Failure scenario:** A Mac Work capture stops; `AudioRecorder.swift:149` deletes its file. Compression or publication remains suspended for more than five seconds. The user quits. `waitForWorkPublications` reaches its deadline while the count is still positive, but this line asks only the gateway quit guard and permits termination. No gateway turn exists, and the recording’s only remaining copy is process memory.

**Smallest fix:** Keep the stopped recording durable until publication succeeds. At minimum, refuse delayed termination when the timeout ends with publications still outstanding.

### CP-R2-11 — P2 — Conduck/Conduck/CarPlay/CarPlayRecordingService.swift:2255

**Claim:** The new cancellation exits leave an already-written user turn in `sending`.

**Failure scenario:** End lands while `appendMessage(status: "sending")` is suspended. The append completes, then the new guard returns. No uploader was created, so no delegate will mark this exact message failed. The same happens after the following file-lane/history suspensions.

The phone is left with an unresolved send and no immediate Retry state. A later launch sweep can repair old rows (`ConversationStore.swift:4989`), but that is not cancellation settlement.

**Smallest fix:** Once `userRecord.id` exists, cancellation before dispatch must terminalize that exact message. This cleanup need not touch any replacement session’s fields.

### CP-R2-12 — P2 — Conduck/ConduckTests/CarPlayWorkNoteTests.swift:316

**Claim:** The revised source guards still admit deletion or bypass of the protections they claim to enforce.

**Failure scenario:** Delete production `CarPlayRecordingService.swift:1997`, the staleness guard after successful ownership confirmation. The test still finds the check inside the ownership-refusal branch at `:1991`. Its ordering assertions pass while the successful path can write after End.

Other concrete survivors include replacing the re-arm guard with an unused comparison, reversing rows inline at the paint call, and supplying constant gate arguments from production. The table below identifies the remaining assertion-level gaps.

**Smallest fix:** Exercise suspended production operations and injected presentation completions. Where source guards remain, assert the relevant executable branch and exit rather than token presence.

### CP-R2-13 — P3 — docs/qa/work-usability/handoff.md:286

**Claim:** The QA instructions still contradict the implemented Work controls and cancellation semantics.

**Failure scenario:** A verifier follows step 77 and reports the intentionally absent Mute button as broken, or expects End after publication to remove a durable card. The handoff also omits the competing-start and long-drive recovery checks. Decision 14 names `carplay-communication`, while the actual entitlement is `com.apple.developer.carplay-voice-based-conversation` (`Conduck/Conduck/Conduck-Official.entitlements:7`).

**Smallest fix:** Describe End separately before and after publication, require End-only controls, add the missing race/recovery scenarios, and use the entitlement actually present in the project.

## Negative controls

These are **static deductions, not executed mutations or test results**. Test filenames below are under `Conduck/ConduckTests/`. Grouped rows cover each listed assertion and each loop instance; a mutation surviving one group may be rejected elsewhere.

| Assertions | Production mutation still admitted |
|---|---|
| `CarPlayWorkNoteTests.swift:297,303,307,311,316,323,329` — parking, ownership and ordering | Delete the successful-ownership staleness guard at production `:1997`. The refusal-path check satisfies the search. Changing the parked publication verdict also survives these assertions. |
| `CarPlayWorkNoteTests.swift:418,435,443,454,458,463,471,475,479,488` — token boundary, nine suspension checks, two hoisted refusals, catch and caller | Change `isCurrentListen` to return only `sessionActive`, dropping attempt identity. Every searched guard remains, but a replaced session passes it. |
| `CarPlayWorkNoteTests.swift:524` — chat-only re-arm | Replace `guard sessionDestination == .chat else { return }` with `_ = sessionDestination == .chat`. |
| `CarPlayWorkNoteTests.swift:624,633,639,643` — configured hint branch and destination wording | Keep the selected `detail` expression but pass `detailText: nil` to the hint item. Selection and key-count assertions still pass; the driver gets no retry instruction. |
| `CarPlayWorkNoteTests.swift:649,655` — Work-first order and exactly three array mentions | Paint `CPListSection(items: Array(firstSectionItems.reversed()))`. The checked literal and mention count remain unchanged. |
| `CarPlayWorkNoteTests.swift:773,780,818` — exhaustive `mayClaim` truth table and positive/negative `isLive` cases | In production `claimStart`, pass `claimHeld: false`. The pure predicates remain correct while competing starts are admitted. These tests discriminate predicate regressions, not caller wiring. |
| `CarPlayWorkNoteTests.swift:843` — both starters claim first | Make `claimStart` ignore the actual pending claim. Both starter prefixes remain identical. |
| `CarPlayWorkNoteTests.swift:859,862,866` — checks immediately after each preflight suspension | Make `startIsLive` return its current predicate result `|| true`. Placement remains correct; enforcement disappears. |
| `CarPlayWorkNoteTests.swift:871` — early-return defer | Make `releaseStart` leave `pendingStart` set. The defer still calls it. |
| `CarPlayWorkNoteTests.swift:888,892,904,908,912,916,920,924` — both presentation completions | Make `startIsLive` always admit the stored claim. The exact refusal guard, release, dismissal, exit and begin ordering remain present, but stale starts take the success arm. |
| `CarPlayWorkNoteTests.swift:948` — both false-completion branches | Put each `completion?(false)` inside `if false { … }`. Both brace-matched branches retain the required text but stop notifying their callers. |
| `CarPlayWorkNoteTests.swift:950,957` — present/dismiss controller identity | Keep the identity comparison inside a condition made unconditional with `|| true`. |
| `CarPlayWorkNoteTests.swift:963,968,972` — stale dismiss cannot deactivate | Replace the presentation/session guard with unused evaluations of `!self.isVoicePresented` and `self.recordingService?.sessionActive != true`, followed by deactivation. |
| `CarPlayWorkNoteTests.swift:984` — stored claim supplied to gate | Keep `claimSerial: pendingStart?.serial` but pass `sceneActive: true`. Backgrounded starts are admitted while the asserted argument remains correct. |
| `CarPlayWorkNoteTests.swift:991,995` — serial-scoped release and clearing | Keep the exact serial guard but wrap `pendingStart = nil` in `if false`. The release clears nothing. |
| `CarPlayWorkNoteTests.swift:1005,1015` — three refused-modal ownership predicates | Evaluate all three comparisons without making them conditions for dismissal. All required tokens still precede the dismiss call. |
| `CarPlayWorkNoteTests.swift:1022,1026,1033,1037,1041` — End/disappearance cancellation ordering | Make `cancelPendingStart` ineffective. The callers still invoke it before their session operations. |
| `CarPlayWorkNoteTests.swift:1048,1052` — cancellation helper release and identity | Retain the service guard but place `releaseStart(claim.serial)` in an unreachable branch. |
| `CarPlayWorkNoteTests.swift:1062,1070` — lifecycle clearing and reconnect cleanup | Put the required clearing/cleanup calls inside unreachable branches. Presence remains; lifecycle invalidation disappears. |
| `CarPlayWorkNoteTests.swift:1079,1081` — chooser identity and pending-start gate | Retain the comparisons as unused expressions while allowing the override assignment to proceed. |
| `CarPlayWorkNoteTests.swift:1088,1089,1093,1098` — read-before-paint ordering and retained refusal | Delete `pendingStart == nil` from the actual paint guard. Await ordering and the single retained-refresh assignment remain unchanged. |
| `CarPlayWorkNoteTests.swift:1102` — release drains retained refresh | Remove `refreshPicker()` from `releaseStart` but retain its `pickerRefreshPending` condition. |
| `CarPlayWorkNoteTests.swift:1113,1117,1121,1125` — notification retention and later refresh | Put `pickerRefreshPending = true` inside an unreachable branch within the pending-claim refusal. The expected tokens remain ordered, but the refresh is dropped. |
| `CarPlayWorkNoteTests.swift:1146,1152,1159` — Work clears Mute; Chat installs it | Reinstall Mute inside `ensureVoicePresented`. Both starter bodies retain exactly the checked shape. |
| `CarPlayWorkNoteTests.swift:1175,1182,1184,1186,1190` — gateway-typed override and chooser shape | Make the chooser’s `sessionDefaultRefOverride = ref` assignment unreachable. The selector stops changing gateways while all shape assertions pass. |
| `CarPlayVoiceTimingContractTests.swift:357,361,362,364,369` — reconnect teardown | Keep `disconnectCleanup()` before fresh-service construction but make that call unreachable. Its ordering and the separately inspected cleanup body remain compliant. |
| `CarPlayVoiceTimingContractTests.swift:380,386,392` — one-shot hint reset and starter wiring | Make the hint reset inside `claimStart` unreachable. Both starters still call the helper and the picker still references the flag. |
| `PendingRetryQueueTests.swift:139–143` — Chat expiry/exemption/constants | Change expiry comparison from `>` to `>=`. These checks never exercise exactly 600 seconds. They do correctly reject a longer Chat budget. |
| `PendingRetryQueueTests.swift:162,170,171` — published Work exemption and TTL properties | Make `isExpired` ignore `retryTTL` and use 600 seconds. These property assertions still pass. |
| `PendingRetryQueueTests.swift:175,182` — Work survives 601 and 86,399 seconds | Make published Work never expire. These assertions pass; the separate 86,401-second assertion rejects that mutation. |
| `PendingRetryQueueTests.swift:185` — Work expires after one day | Restore the 600-second expiry rule. This assertion passes; the 601/86,399-second assertions reject that mutation. |
| Entire changed Work-expiry test, `PendingRetryQueueTests.swift:155` | Changing `>` to `>=` survives the complete test because exactly 86,400 seconds is untested. The test nevertheless genuinely distinguishes ten minutes, one day and no expiry. |
| `WorkVoiceRecoveryTests.swift:519` — recovered entry’s TTL | Make `isExpired` ignore `retryTTL`. The recovery assertion checks the property, not actual expiry behavior. |

The earlier direct mutations replacing the stored claim with `serial`, removing `presented`, removing the presentation-refusal `return`, deleting the two specific false callbacks, reversing the hint comparison, and conditionally hiding the initial Mute clear are now rejected. That is meaningful progress; it does not close the remaining integration holes.

**No discriminating execution test in the scoped files covers** competing actual scene starts; End during presentation; stale same-controller callbacks; startup resuming into a replacement session; an earlier chat refusal ending Work; cancellation-mark pruning across overlapping suspended turns; phone/CarPlay microphone ownership; foreground retry discovery; a lost shared-recorder lease during STT; the Mac quit deadline with undurable bytes; or unattended Work entry. The source guards also do not execute a Work capture through attachment failure and recovery via the actual phone retry surface.

Not clean — 1 P1, 11 P2