**DISAGREE with `matches_intent_no_change`.** The draft correctly recognizes the STT-only Work lane, but rejects the founder’s chooser shape by assuming it must introduce a sticky Work mode. That assumption is unnecessary.

Reviewed against `a197ccd`. This is a source review; I did not run the app or simulator suites.

1. **Major — The draft rejects a construction of its own, not the founder’s request.**

   **Evidence:** The existing chooser assigns an AI override at [CarPlaySceneDelegate.swift:1006](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/CarPlay/CarPlaySceneDelegate.swift:1006). The independent Work starter already needs no gateway or override at [CarPlaySceneDelegate.swift:482](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/CarPlay/CarPlaySceneDelegate.swift:482). Nothing requires a chooser’s Work row to assign anything: it can start that one recording directly.

   The smallest literal solution is to **retain the one-tap root action and also offer Work as an immediate action inside the chooser**, displaying the chooser with one configured gateway. Work leaves the selected AI untouched. Sequence the chooser’s pop completion before presenting the voice modal; preserve `beginWorkNote` inside the presentation completion.

   | Route | Taps from root | Persistent Work selection |
   |---|---:|---|
   | Existing root action, retained | 1 | No |
   | Chooser → immediate Work action | 2 | No |
   | Draft’s selected-mode construction | 3 initially | Yes |

   This honors “inside the gateway selector” without worsening the existing one-tap path. If **one location** is essential, promote the actual gateway-and-Work action list into the root: each destination starts recording on its own tap. That is literally one tap, though a large gateway roster would require checking scrolling and the Recent budget.

   **Fix:** Evaluate these options before rejecting the requested shape. Rename a mixed chooser “Choose destination.” Keep `RemoteAgentRef?`, `effectiveCarPlayRef`, and `newChatPlan` AI-only. The watch sibling already demonstrates per-press selection followed by an action, with a second busy check at [WatchNoteView.swift:301](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/ConduckWatch%20Watch%20App/Views/WatchNoteView.swift:301).

2. **Major — There is an unreviewed startup race between Chat and Work.**

   **Evidence:** `startSession` checks idle once, then suspends for gateway resolution at [CarPlaySceneDelegate.swift:351](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/CarPlay/CarPlaySceneDelegate.swift:351). Work can start during that suspension. Meanwhile, `ensureVoicePresented` sets `isVoicePresented` **before presentation completes**, and subsequent callers immediately run their completion at [CarPlaySceneDelegate.swift:503](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/CarPlay/CarPlaySceneDelegate.swift:503).

   A rapid New voice chat → Work sequence can therefore let the older Chat startup resume during Work presentation and call `beginSession` first. That threatens both the destination boundary and the audio presentation ordering. This is a source-derived race, not a reproduced device result.

   The chooser’s own handler also lacks a busy check at [CarPlaySceneDelegate.swift:1000](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/CarPlay/CarPlaySceneDelegate.swift:1000).

   **Fix:** Reserve startup synchronously across both entry points, reject competing starts, and invalidate suspended startups on disconnect. Recheck that reservation before presentation and in its completion. Add a deterministic test that suspends Chat preflight, attempts Work, then resumes Chat. Merely checking `sessionActive` again is insufficient while presentation is pending.

3. **Major — The incorrect microphone hint is a destination error, not P3 polish.**

   **Evidence:** After Work fails to start, the configured picker says “Tap New voice chat to try again” at [CarPlaySceneDelegate.swift:804](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/CarPlay/CarPlaySceneDelegate.swift:804). Following that instruction routes the repeated thought to an AI. It also directly fails the existing acceptance criterion in [handoff.md:266](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/docs/qa/work-usability/handoff.md:266).

   **Fix:** Correct it before acceptance. Tracking the last **accepted** startup destination is reasonable once startup is serialized. A shorter destination-neutral retry instruction is another option with less state. Preserve the explicit silent-failure → `applyState` transition; [fix-r2-carplay.md:85](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/docs/qa/work-usability/fixnotes/fix-r2-carplay.md:85) explains why setting a flag alone strands the modal.

4. **Major — “Mute parks/resumes” conceals lost speech; “End saves nothing” is phase-dependent.**

   **Evidence:** Mute stops capture, deletes the partial recording, and clears its URL at [CarPlayRecordingService.swift:655](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/CarPlay/CarPlayRecordingService.swift:655). Unmute starts another listen at [CarPlayRecordingService.swift:685](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/CarPlay/CarPlayRecordingService.swift:685). Words spoken before Mute are lost.

   End deletes the current scratch recording at [CarPlayRecordingService.swift:2800](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/CarPlay/CarPlayRecordingService.swift:2800), but does not remove an already published card or queued capture. End during publication can still leave a durable result.

   **Fix:** Rewrite QA step 77 around actual boundaries:

   | State | Actual outcome |
   |---|---|
   | Initial silence, no speech | Sign-off; no note |
   | End while recording | Partial recording discarded |
   | End before preservation finishes | Outcome depends on which durable operation completes |
   | End after publication | Existing recording remains; late speech must not affect another session |
   | Mute while recording | Pre-mute speech discarded; Unmute starts fresh |
   | Empty STT result after publication | Recording retained; no automatic follow-up listen |

   For Work, I would remove Mute from the recording experience unless it can preserve what was already said. Keep Chat’s existing behavior separate. Test an unmistakable phrase **before** Mute and another after it; “it still saves” misses the loss entirely.

5. **Major — The entitlement argument uses the wrong category and overlooks a relevant audio rule.**

   **Evidence:** The official target declares `com.apple.developer.carplay-voice-based-conversation` at [Conduck-Official.entitlements:7](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Conduck-Official.entitlements:7). Handoff decision 14 instead analyzes `carplay-communication` at [handoff.md:99](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/docs/qa/work-usability/handoff.md:99).

   Apple’s current guide distinguishes these entitlements. Its voice-based category allows responding to requests and performing actions; it does **not** establish a requirement for another human recipient. It also requires active voice use while holding an audio session and discourages text or imagery in response to queries. Indefinitely holding the route while muted deserves scrutiny under that rule. See the [CarPlay Developer Guide, printed pages 7, 13–14](https://developer.apple.com/download/files/CarPlay-Developer-Guide.pdf).

   **Fix:** Correct the category analysis. Keep App Review disclosure, but do not present “no other recipient” as an established prohibition. List and voice-control templates are supported; HIG does not establish “Work must never appear in a chooser.” Its relevant guidance favors minimal interaction, clear actionable content, and deferring phone intervention until stopped. [Apple CarPlay HIG](https://developer.apple.com/design/human-interface-guidelines/carplay/)

   Accordingly, “Open Conduck to retry” should explicitly mean **later**, not invite phone interaction while driving.

6. **Major — The durability narrative mistakes calling `arm` for successful preservation.**

   **Evidence:** `PendingRetryGuard.arm` catches save failure and returns `audioPreserved == false` at [PendingRetryGuard.swift:139](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/PendingRetryGuard.swift:139). CarPlay nevertheless deletes the CAF after it returns at [CarPlayRecordingService.swift:1878](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/CarPlay/CarPlayRecordingService.swift:1878).

   Consequently, a nonnil `WorkNoteCapture` proves publication succeeded, **not** that both a card and retry entry exist. The phase-one catch correctly distinguishes preserved versus unpreserved audio at line 1911; the draft’s table does not.

   **Fix:** State the actual guarantees and test failed queue preservation independently from failed desk publication. Retain the original until either preservation or publication is confirmed; do not refuse an otherwise successful desk write merely because the retry safety net failed. Preserve the existing token ownership checks—[fix-r1-carplay.md:23](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/docs/qa/work-usability/fixnotes/fix-r1-carplay.md:23) correctly disproves unconditional attachment idempotence.

7. **Minor — “Finish it on the phone” hides three shared-service limitations.**

   **Evidence:**

   - Published Work retry entries become eligible for expiry after **600 seconds**, once unreserved: [PendingRetryStore.swift:219](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/PendingRetryStore.swift:219). A retry card is not guaranteed to remain until the driver parks.
   - CarPlay does not park the successful transcript when attachment throws at [CarPlayRecordingService.swift:1987](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/CarPlay/CarPlayRecordingService.swift:1987). The phone may purchase recognition again. Its existing retry lane can skip STT when words were retained: [ContentView.swift:1672](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/ContentView.swift:1672).
   - `InAppAudioRecorder` has its own Work retry reservation and handback lifecycle at [InAppAudioRecorder.swift:845](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/InAppAudioRecorder.swift:845). A chooser change does not simplify or replace that machinery.

   **Fix:** Reuse the existing metadata’s transcript field under the held claim; preserve `.work` through every recovery. Explicitly document the retry-window limitation and test recovery after a realistic drive. Do not introduce another queue or recorder.

   Also distinguish unsupported custom STT endpoints from transient outages: CarPlay deliberately refuses those every time at [CarPlayRecordingService.swift:1517](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/CarPlay/CarPlayRecordingService.swift:1517). “STT-only” does not mean every configured STT provider currently works in the car.

8. **Minor — “Saved to Work” is knowingly stale when the recording is missing.**

   **Evidence:** `.recordingMissing` and `.notAudio` still produce the saved acknowledgement at [CarPlayRecordingService.swift:2008](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/CarPlay/CarPlayRecordingService.swift:2008). Yet the coordinator has just established that the target is absent or unsuitable. The in-app sibling explicitly clears its “recording on desk” fact in that situation at [InAppAudioRecorder.swift:1541](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/InAppAudioRecorder.swift:1541).

   **Fix:** Keep the queued recovery and never resurrect a deleted recording merely to make the acknowledgement true. Change the spoken outcome for this case to a recovery statement conditional on preserved bytes. “Published earlier” and “on Work now” are different facts.

9. **Minor — The proposed guard freezes the disputed layout and overstates existing test coverage.**

   **Evidence:** The proposed test at [carplay-work-destination.md:85](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/docs/qa/work-usability/design/carplay-work-destination.md:85) bans Work from the chooser rather than proving safe routing.

   For `RefusalLaneSource`, use `source(at:)` to strip comments, then `body(ofFunction:in:path:)`; the variable declaration must be checked against the whole stripped source, not the function body. Those APIs are defined at [HeadlessRefusalLaneDriftGuardTests.swift:271](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/ConduckTests/RemoteAgent/HeadlessRefusalLaneDriftGuardTests.swift:271).

   Even correctly scoped, banning the substrings `work`/`Work` is brittle, and negative assertions alone allow an emptied chooser to pass. Require positive evidence that configured gateway rows and their handlers exist.

   The draft’s breakage list is also inaccurate:

   - A chooser Work action retaining both root offers leaves all four listed guards intact.
   - Even §9’s construction need not change `beginWorkNote`, `startWorkNote`, or the recording service’s destination resets.
   - Its actual necessary break is the configured-root offer count at [CarPlayWorkNoteTests.swift:458](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/ConduckTests/CarPlayWorkNoteTests.swift:458).

   **Fix:** Test one-gateway visibility, Work action routing, unchanged AI override, bound Recent routing, startup contention, and reconnect behavior. Add mutation controls/non-vacuity. The existing “every suspension” test merely requires at least two checks, and the presentation test checks textual order—not closure containment—at [CarPlayWorkNoteTests.swift:364](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/ConduckTests/CarPlayWorkNoteTests.swift:364).

   The recovery suites, `STTKeyBlackoutLaneTests`, and `HeadlessRefusalLaneDriftGuardTests` also belong in the impact assessment.

10. **Minor — Day-one ordering and naming are defended with weak evidence.**

    **Evidence:** The only working day-one action appears after “Set up your AI on iPhone first” at [CarPlaySceneDelegate.swift:724](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/CarPlay/CarPlaySceneDelegate.swift:724). That reads like a prerequisite for Work.

    “Add to Work” is a reasonable action label, but it is not the universal Shortcut title: [RecordWorkNoteIntent.swift:43](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Intents/RecordWorkNoteIntent.swift:43) says “Record a Note to Work”; Watch says “Save to Work.” Only the **two saved acknowledgements** match the cited watch keys, not all three CarPlay outcomes.

    **Fix:** Put Work first on day one and scope setup wording to chatting. Name the destination **Work**, its action **Add to Work**, and its success **Saved to Work**. Different verbs are not different product names; consistency should clarify the action, not be decided by counting existing strings.

    Preserve bound Recents and their existing row budget. Retaining the root shortcut keeps the current one-row Recent cost; adding a chooser row requires checking that chooser’s own maximum-item budget.

11. **Minor — The spec arithmetic is wrong, although the proposal passes the cap.**

    I ran `scripts/check-spec-size.sh`: **16,897 / 16,900 words**, with 39 decisions.

    Using the script’s whitespace word counting:

    | Edit | Actual count |
    |---|---:|
    | Addition | **31**, not 30 |
    | Cut 1 | 29 → 13: saves 16 |
    | Cut 2 | 31 → 26: saves 5 |
    | Cut 3 | 28 → 22: saves 6 |
    | Cut 4 | 17 → 14: saves 3 |
    | Result | **16,898 words; +1; two words spare** |

    **Fix:** Do not add the categorical prohibition: it records an unjustified rejection as architecture. Cuts 1, 2, and 4 preserve their intended facts, though the Apple attribution needs correcting. Cut 3’s “reaching nobody” loses the precise distinction that the memo reaches its owner but no other person—and retains the wrong entitlement premise. Rewrite that sentence accurately rather than optimizing its count.

    Do not add the proposed QA failure criterion that declares the founder’s requested chooser a failure.

12. **Nit — Drop the flicker P3 as currently specified.**

    **Evidence:** Removing the final Saving activation at [CarPlayRecordingService.swift:1984](/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/CarPlay/CarPlayRecordingService.swift:1984) leaves the original Thinking → Saving → Thinking flicker intact.

    **Fix:** Defer this until rendered QA shows a problem. The driver needs a stable indication that the note is being handled, not a display of storage and STT phases. Do not add another state machine for cosmetic sequencing. The microphone hint, by contrast, must be fixed.

My decisions:

| Decision | Position | Change |
|---|---|---|
| **1** | **DISAGREE** | Keep one-tap access; allow an immediate Work action in the chooser. |
| **2** | **AGREE** | No sticky Work mode. This supports the alternative above. |
| **3** | **DISAGREE** | One gateway plus Work is a real choice; expose the chooser. |
| **4** | **DISAGREE** | Keep AI resolution AI-only, but do not confuse that with banning a Work action from the UI. |
| **5** | **DISAGREE as written** | Preserve gateway-free capture; improve ordering and setup wording. |
| **6** | **AGREE on the labels** | Correct the cross-platform evidence and scope saved claims to verified outcomes. |
| **7** | **DISAGREE with “unchanged”** | Preserve ownership, recovery, and no-follow-up rules; fix the identified durability/copy gaps. |
| **8** | **AGREE on the lifecycle contract** | Preserve modal ordering and silent-failure handling; add startup exclusion and safe chooser transition sequencing. |

**Verdict: DISAGREE with `matches_intent_no_change`.** The STT-only foundation matches the intent. The destination affordance needs revision, and the draft should not turn its preferred layout into a guard against the founder’s request.

