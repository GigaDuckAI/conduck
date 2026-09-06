**Not clean.** The main chooser change implements the founder’s requested shape, and Work remains STT-only. W-R1-2 is fixed; W-R1-1 and W-R1-3 remain open. The wider inspection also found capture ownership, deferred routing, and recovery defects. Several are inherited from `a197ccd`; I distinguish those from defects in the new changes below. No builds, tests, guards, or mutations were run.

| Finding | Severity | Location | Concrete failure → smallest fix |
|---|---|---|---|
| W-R2-1 | P1 | `WatchRecordingService.swift:2551` | Deferred Ask loses its explicitly selected gateway and sends to the default → persist the selected ref with the queued capture. |
| W-R2-2 | P1 | `WatchRecordingService.swift:2709` | An old Chat reply makes an active Work save idle, admitting another capture → match the lane and current turn before changing live state. |
| W-R2-3 | P1 | `AppDelegate.swift:352` | Mac quits after five seconds while Work audio remains memory-only → refuse termination if publication remains outstanding. |
| W-R1-1 | P2 | `WatchNoteView.swift:721` | Three supported custom names still produce duplicate chooser/capture labels → check uniqueness of the final labels across the roster. |
| W-R1-3 | P2 | `WatchCaptureGuardTests.swift:823` | Both new pin fixtures clear through `dismissError()` first → arrange `.idle` while retaining each established pin. |
| W-R2-4 | P2 | `WatchRecordingService.swift:2531` | Deferred Chat inherits `.work` after denied Work capture → explicitly stamp `.chat` at deferred Chat entry. |
| W-R2-5 | P2 | `AppleSpeechRelayCoordinator.swift:892` | Failed transcript attachment is acknowledged and cannot be retried through the offered flow → preserve/propagate the unfinished transcript before acknowledging completion. |
| W-R2-6 | P3 | `README.md:55` | Reader searches for nonexistent “Record to Work…” command → use “Capture to Work…”. |
| W-R2-7 | P3 | Watch `Localizable.xcstrings:21` | Five unused keys remain; two shared error keys are absent → retire unused entries and catalogue applicable shared keys. |
| W-R2-8 | P3 | `handoff.md:250` | Dead-endpoint QA expects a settled acknowledgement from a retryable failure → separate transient and settled failure cases. |

Locations below use the repository’s actual files.

**W-R2-1 — Deferred Ask can reach the wrong gateway**

**Inherited defect, still reachable through the new chooser.**

Configure gateways A and B, with B the default. Pick A in Ask, use phone-relayed STT, and let delivery defer. The new draft has no conversation pin: its chosen ref exists only in the global Ask hint.

[`runRelay`](</Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/ConduckWatch Watch App/Services/WatchRecordingService.swift:1749>) queues `pendingConversationID`, which is nil for that draft. The queue’s entry contains no selected gateway ref. [`completeEntry`](</Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/ConduckWatch Watch App/Services/AppleRelayPendingQueue.swift:807>) subsequently calls `startDeferredConverseHop(boundTo: nil)`, which disables Ask-hint consumption at `WatchRecordingService.swift:2551`. The resolver then uses the active/default gateway at `:2616`–`:2653`.

**Outcome:** words deliberately addressed to A can be sent to B, potentially appended to an existing B conversation. Choosing Work between deferral and delivery also clears the global hint, but the defect exists without that intervening choice.

**Smallest fix:** persist an optional captured gateway ref alongside `conversationID`; use it to mint the deferred draft. Never recover an explicit selection from the current default or another capture’s hint.

**W-R2-2 — An old Chat reply releases a live Work save**

**Inherited defect.**

Start Chat A, cancel its waiting state through the composer, then record Work. The composer calls `cancelRecording()` at [`WatchMessageComposerBar.swift:129`](</Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/ConduckWatch Watch App/Views/WatchMessageComposerBar.swift:129>); cancellation deliberately leaves the background converse hop alive.

If A’s reply arrives while Work is `.uploading`, [`handleBackgroundReply`](</Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/ConduckWatch Watch App/Services/WatchRecordingService.swift:2693>) accepts that state and unconditionally assigns `.idle` at `:2709`. Conversation matching guards the marker clear, **not** that state assignment.

**Outcome:** Ask/Action Button can accept another capture while Work still owns its asynchronous pipeline. If the replacement microphone starts before Work reaches `runRelay`, Work’s `recordingFileURL = nil` at `:1743` removes the replacement capture’s handle; its subsequent Stop reaches “Recording file not found” at `:1511`.

**Smallest fix:** require the completion to match the current Chat turn before mutating the live machine. Persisting A’s reply in A’s thread can proceed independently.

**W-R2-3 — The new Mac quit protection still permits audio loss**

[`AudioRecorder.stopRecording()`](</Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/AudioRecorder.swift:149>) deletes the recording file. Compression, screenshot publication and recording publication then run before the desk owns the audio.

With no gateway turn running, press ⌘Q while that publication takes longer than five seconds. [`waitForWorkPublications`](</Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/InAppAudioRecorder.swift:551>) returns on timeout even with a positive counter. [`AppDelegate.swift:352`](</Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/AppDelegate.swift:352>) then consults only the gateway quit guard and permits termination.

**Outcome:** the stopped recording disappears without a card or retry record. This is an incomplete fix of the previous loss window, rather than evidence that the new counter itself introduces a regression.

**Smallest fix:** return whether publication completed; answer the pending termination request with `false` if it did not. A bounded wait need not end by permitting data loss.

The counter test never invokes quitting, and the source guard explicitly accepts this unsafe completion shape.

**W-R1-1 — STILL OPEN: disambiguation can recreate collisions**

Full VoiceOver labels are now wired at [`WatchNoteView.swift:540`](</Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/ConduckWatch Watch App/Views/WatchNoteView.swift:540>) and `WatchConversationThreadView.swift:1533`. That half is fixed.

The visible-label algorithm remains defective. These **three** custom gateways fit the shipping custom-roster limit:

| Full name | Result of current algorithm |
|---|---|
| Frankfurt production alpha one | `…one` |
| Frankfurt production alpha two | `…two` |
| Frankfurt production one | `…one` |

[`WatchGatewayLabel.visible`](</Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/ConduckWatch Watch App/Views/WatchNoteView.swift:721>) chooses a different divergence offset for each name. Distinct original names therefore become identical final labels. Both the chooser and recording caption use that result.

**Smallest fix:** resolve the roster’s labels together and verify final uniqueness, adding a bounded disambiguator for residual collisions. Add this three-name fixture; the existing three-name test uses “beta” as its third name and misses the failure.

**W-R1-3 — STILL OPEN: the Work-start pin clears remain unpinned**

The original test at [`WatchCaptureGuardTests.swift:769`](</Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/ConduckWatchTests/WatchCaptureGuardTests.swift:769>) genuinely tests stale-hint clearing. Its pin assertion still starts nil.

The two added fixtures now establish real pins, which is useful. However, both call Work while `.error`:

- Bound pin: `WatchCaptureGuardTests.swift:823`.
- Minted pin: `WatchCaptureGuardTests.swift:858`.

`startWorkCapture` calls `dismissError()` at `WatchRecordingService.swift:787`; that clears both pins at `:2948` and `:2949` before the Work-specific clears run.

**Outcome:** deleting either Work-specific clear at `:817` or `:819` still leaves all three tests passing by inspection. The explanatory comment acknowledges this gap; it does not close it.

**Smallest fix:** after establishing each pin, assign `service.state = .idle`, assert that the pin remains non-nil, then start Work. `state` is writable at `WatchRecordingService.swift:270`, and its observer does not clear pins. This needs no private-pin access or new production seam.

**W-R2-4 — Deferred Chat retains Work’s destination stamp**

Deny microphone permission for Work, leaving `.error` and `.work`. Dismiss the error while an older Chat relay is queued.

[`dismissError()`](</Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/ConduckWatch Watch App/Services/WatchRecordingService.swift:2942>) retains `captureDestination` and schedules a drain. [`startDeferredConverseHop`](</Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/ConduckWatch Watch App/Services/WatchRecordingService.swift:2531>) occupies the machine but never stamps `.chat`.

**Outcome:** a real gateway turn runs while the launchpad displays the newly added **“Saving to Work…”** caption. The queued Chat text remains Chat, but the cross-lane stamp and privacy cue are wrong.

**Smallest fix:** stamp `.chat` and clear stale Work presentation state when a deferred Chat turn is accepted. Add the denied-Work → dismiss → deferred-Chat transition test.

**W-R2-5 — The watch relay acknowledges unfinished transcript work without recovery**

**Inherited defect.**

Let the phone publish the Work recording and transcribe it successfully, then make the transcript’s store write fail. [`attachRelayedWorkTranscript`](</Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/Conduck/Services/AppleSpeechRelayCoordinator.swift:873>) catches the error and only logs it. Its caller caches and returns successful text plus `workSaved` at `:494`.

**Outcome:** the watch claims/deletes its queued clip and displays “Saved to Work.” The phone has an untranscribed recording and no pending retry holding the recognized words.

The settled-STT-error branch has the related recovery gap: it returns “Saved to Work. Add the words on your iPhone,” but creates no phone retry entry. The existing audio card offers playback, not transcription; extending `PendingRetryStore`’s TTL cannot help a record never placed there.

**Smallest fix:** propagate attachment failure as a retryable Work-write verdict, or durably park the transcript under that capture before acknowledging it. For settled STT failures, either create an actionable phone recovery record or use receipt copy that does not promise that action.

**W-R2-6 — README names the wrong Mac command**

[`README.md:55`](</Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/README.md:55>) still says **“Record to Work…”**. The actual command is **“Capture to Work…”** at `MenuBarController.swift:1162`.

**Smallest fix:** replace that README phrase. The watch wording in the same paragraph is correct.

**W-R2-7 — Catalog hygiene remains incomplete**

The four requested keys are present with the correct defaults:

| Key | Watch catalog line |
|---|---:|
| `watch.ask.destination.noAI` | 2938 |
| `watch.ask.destination.title` | 2949 |
| `watch.ask.destination.work` | 2960 |
| `watch.work.capture.navigationTitle` | 3158 |

All three requested retired keys are absent from both catalog and watch code. None of the four additions is orphaned.

The following older entries have no production Swift reference:

- `A queued recording couldn't reach your iPhone and has expired.` — line 21.
- `Ask your personal AI to start one.` — line 63.
- `Couldn't reach your personal AI. Try again.` — line 242.
- `Couldn't read the reply from your personal AI.` — line 253.
- `Reply from your personal AI` — line 466.

Two localization keys in the shared, watch-compiled `AppError.swift` are absent: `workboard.voice.error.deskWrite` at `:761` and `workboard.voice.error.screenshotWrite` at `:767`. Their English defaults prevent raw-key output.

`Add ${thought} to Work` is **not** orphaned: it corresponds to the intent’s parameter summary at `WorkboardCaptureIntent.swift:208`. The widget’s “Capture a voice transcription with Conduck” is also absent from this catalog, but belongs to the separate widget binary; adding it only to the app catalog would not establish widget localization.

**Smallest fix:** remove the five stale entries and reconcile applicable localization resources by target.

**W-R2-8 — Handoff’s failure fixture expects the wrong result**

[`handoff.md:250`](</Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/docs/qa/work-usability/handoff.md:250>) instructs QA to use a dead custom STT endpoint and expect the wordless success acknowledgement. An unreachable endpoint yields a retryable failure; the phone does not acknowledge it as settled, and the watch retains the entry and reports deferral at `WatchRecordingService.swift:1847`.

**Smallest fix:** test unreachable/transient failure separately from a settled failure, with the correct receipt and queue expectations for each.

Also split step 66f’s empty-roster message check from its maximum-roster check: “No personal AI available.” cannot appear with a maximum configured roster.

**Design implementation checklist**

“Implemented” below means present in source, not device-verified.

| Change | Status | Evidence |
|---|---|---|
| 1. Root header describes chooser versus headless | Implemented | `WatchNoteView.swift:6` |
| 2. State renamed; gateway snapshot retained | Implemented | `WatchNoteView.swift:28` |
| 3. Ask always opens chooser | Implemented | `WatchNoteView.swift:324` |
| 4. Gateway push rechecks busy, then master switch | Implemented | `WatchNoteView.swift:337` |
| 5. Work push rechecks both; renders capacity refusal | Implemented | `WatchNoteView.swift:375` |
| 6. Separate button removed; Work busy caption added | Implemented | `WatchNoteView.swift:457`, `:478` |
| 7. Dialog, zero-roster message, switch dismissal and takeover dismissals | Implemented | `WatchNoteView.swift:522`; dismissals `:177`, `:190`, `:220`, `:230`, `:253`, `:308`, `:562` |
| 8. Pure row builder | Implemented | `WatchNoteView.swift:653` |
| 9. Work route comment updated | Implemented | `WatchNoteView.swift:631` |
| 10. Persisted-first title; `.new`-only fallback | Implemented, with local label extension | `WatchConversationThreadView.swift:268`; residual label defect above |
| 11. Caption during arming and recording; AOD unchanged | Implemented; visual acceptance pending | `WatchConversationThreadView.swift:1513`, `:1528` |
| 12. Work title and entry comments | Implemented | `WatchWorkCaptureView.swift:6`, `:290` |
| 13. Settings-reader comment | Implemented | `WatchSettingsReader.swift:299` |
| Catalog change list | Implemented | Four additions and three retirements confirmed above |
| Tests section | Partially implemented | All prescribed cases exist; pin-clearing negative controls remain incomplete |
| Docs section | Implemented | README `:55`; project structure `:80`; handoff `:67`, `:83`, `:126`, `:242`; fixnote `:135` |
| `spec.md` no-edit requirement | Implemented | No diff against `a197ccd` |

For every **enabled, non-busy** Ask press, zero, one or several gateways all take the chooser. Work is last, and the separate launchpad button is gone. Busy/disabled refusals remain intentional exceptions. Work forces the phone relay at `WatchRecordingService.swift:1640`; its settlement cannot call the Chat closure.

**Boundary and shared-service assessment**

- **Implicit watch entry:** Action Button, ControlWidget and both `RecordNoteIntent` variants call `requestStart()`, then resolve default-gateway Chat targets. None calls `beginWorkCapture` or `startWorkCapture`. Notification navigation uses `.thread`, not capture. The explicitly named Siri Work intent writes an inert note.
- **Work → gateway:** no such path found in live relay, deferred settlement, old-phone words-only fallback, or retry routing. `AppleRelayPendingQueue.swift:645`–`:662` structurally separates Chat completion from Work settlement.
- **Cross-lane state:** not clean—W-R2-2 and W-R2-4 expose ownership/stamp leakage, even though Work content itself stays out of converse.
- **Shared recorder:** the new capture date is passed correctly; the publication counter has W-R2-3’s termination hole.
- **Pending retry store:** published Work gets 86,400 seconds; Chat retains 600. Unpublished/unknown Work remains exempt, and a retained screenshot separately blocks expiry (`PendingRetryStore.swift:1383`). No destination rerouting was found in this change.
- **Work coordinators/inbox:** publication and recovery remain desk-only. `WorkVoiceCaptureCoordinator.swift:276` rejects Chat recovery; screenshot publication uses the inert inbox at `WorkVoiceScreenshotCoordinator.swift:99`; `Services/WorkCaptureInbox.swift:1135` constructs an envelope without gateway routing fields. W-R2-5 is in the phone relay’s handling of coordinator failures.
- **AOD, controls and layout:** source retains the intended branches. Actual readability, reachability and accidental activation require founder QA.

**What each new watch test pins**

These are **static mutation predictions**, not executed mutations. Surviving deletion of unrelated wiring is not automatically a test defect; it identifies the test’s boundary.

| New test | What it pins | Single production line whose deletion still survives |
|---|---|---|
| `testWorkIsAlwaysOfferedAndAlwaysLast` | Work membership/count in returned rows | `WatchNoteView.swift:329` — opens chooser |
| `testGatewaysKeepRosterOrderAheadOfWork` | Exact returned order | Same `:329` |
| `testTheNoAILineShowsOnlyForAnEmptyRoster` | Empty-roster predicate | Same `:329` |
| `testCollidingCustomNamesGetLabelsThatCanBeToldApart` | Its two-name helper fixture | `WatchNoteView.swift:540` — VoiceOver modifier |
| `testEveryRowOfALongerCollidingGroupIsDistinct` | Its three-name fixture and length budget | Same `:540`; misses W-R1-1’s fixture |
| `testANameThatCollidesWithNothingKeepsTheSharedShortForm` | Noncolliding/built-in helper output | Same `:540` |
| `testAnUnnamedCustomIsLeftOnItsFallbackLabel` | Visible fallback output | Same `:540` |
| `testTheSpokenLabelIsNeverCut` | Full-name helper output | Same `:540`; does not prove attachment to a row |
| `testAnExplicitGatewayPickWritesItsHintWithNoChosenDefault` | Explicit hint bypasses default gate | `WatchRecordingService.swift:708` — initial destination already Chat |
| `testAHintDrivenMintBypassesTheDefaultGate` | One stored conversation bound to captured ref | `WatchRecordingService.swift:2613` — `recordMint(record.id)` |
| `testAWorkPickAfterAnAbandonedGatewayDraftInheritsNothing` | Stale hint cleared; no mint | `WatchRecordingService.swift:817` — pin already nil |
| `testAWorkPickAfterADeniedBoundCaptureInheritsNoConversationPin` | Error-entry reset clears bound pin | Same `:817` — `dismissError()` cleared it first |
| `testAWorkPickAfterAMintedDraftInheritsNoConversationPin` | Error-entry reset clears minted pin | `WatchRecordingService.swift:819` — same masking reset |
| `testAGatewayPickAfterADeniedWorkCaptureIsChat` | Genuine Work → Chat restamp | `WatchRecordingService.swift:728` — gateway hint write is not asserted |
| `testAFullQueueRefusesTheWorkPickBeforeArmingAndKeepsEveryQueuedRecording` | Refusal identity/state and seeded bytes survive | `WatchRecordingService.swift:826` — accepted-start arming lies outside this case |

The capacity fixture meaningfully checks individual queued IDs and bytes, not merely queue size. Both changed watch test files already belong to the test target.

For the shared changes:

- The two TTL tests contain genuine controls against both ten-minute Work expiry and unlimited retention. They do not exercise file/screenshot exemptions; deleting `PendingRetryStore.swift:1383` would leave those metadata tests passing.
- The changed screenshot-expiry integration cases do exercise those file exemptions and distinguish hour-old Chat from Work.
- The changed shared-date test’s normalization delay makes removing `createdAt: capture.createdAt` fail its intended assertion.
- `testTheStoppedRecordingIsDeclaredInFlightUntilTheDeskHoldsIt` checks counter lifetime, but survives deletion of `AppDelegate.swift:351`; it never quits and is macOS-only.
- `testTheQuitGuardWaitsForAWorkCaptureThatHasNotReachedTheDesk` checks source shape, but survives deletion of the counter increment at `InAppAudioRecorder.swift:1171`. It does not test timeout safety.

**Founder QA and copy closure**

The handoff now explicitly lists chooser cancellation, one/zero gateways, destination captions, similar names, maximum roster, VoiceOver, 41 mm clearance through “1 min left,” switch-off, headless takeover/refusal, notification dismissal, busy refusal and back-out saving copy at steps **66a–66m**. Those steps are honestly marked **Unrun**.

Still missing are the concrete regression cases above: deferred nondefault-gateway delivery, old Chat completion during Work saving, denied Work followed by deferred Chat, transcript-attachment recovery, and Mac publication exceeding the quit timeout. Step 66a’s following Action-Button check also cannot independently prove that Cancel wrote no hint, because headless entry clears hints itself.

Naming aligns on **Add to Work** for the watch row/title, CarPlay row, Siri text intent and Mac compose header. Shortcuts retain the specific actions **Add Files to Work** and **Record a Note to Work**. Watch/CarPlay recording receipts use **Saved to Work**; typed receipts use **Added to Work. Nothing was sent.** The remaining misleading recovery receipt is W-R2-5.

Changed permanent documentation is present-tense end-state prose. `spec.md` is unchanged. There is no `CLAUDE.md` in this worktree.

| Prior finding | Round-2 verdict |
|---|---|
| **W-R1-1** | **STILL OPEN** — full VoiceOver labels fixed; supported three-name visible collision remains. |
| **W-R1-2** | **FIXED** — prescribed docs, supersession and pending founder-QA cases are present. Separate residual QA/copy defects are listed above. |
| **W-R1-3** | **STILL OPEN** — stale-hint half is genuine; Work-specific pin clears still survive deletion. |

