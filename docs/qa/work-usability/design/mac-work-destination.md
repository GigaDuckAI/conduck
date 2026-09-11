# Design — Mac menu bar: Work as the third capture

**Lane:** Mac menu-bar hotkeys (`⌘⇧1` Ask · `⌘⇧2` Screenshot & Ask · `⌃⌘W` Capture to Work).
**Verdict:** the shipped implementation at `a197ccd` matches the founder's intent for the third option — screenshot + voice to the desk, STT only, no gateway. No structural change to the Work lane. Codex agrees on the reading in all three rounds. The polish list below is what those rounds and a code read found around it: two P2 defects in how the two lanes share the popover and the status item (a live Ask microphone hidden behind a Work HUD, and a bail that reaches the lane it cannot see; a right-click that sends, and a menu door that re-arms a busy Ask), two P2 honesty/UX gaps on the Work door itself (a press that raises a crosshair it then drops silently; a typed receipt that claims a card the drain may not have imported), and P3 polish.

## The founder's intent, and what the Mac does

> "so far we had 2 options: voice only, voice + screenshot. now we are adding a third option — that the user can send the screenshot + voice to the workboard."

| Option | Hotkey | Picture | Speech hop | Where it lands |
|---|---|---|---|---|
| Voice only | `⌘⇧1` | none | STT | the quick chat lane → a gateway turn |
| Voice + screenshot | `⌘⇧2` | required (Esc cancels) | STT | the quick chat lane → one multimodal gateway turn |
| **Screenshot + voice to Work** | **`⌃⌘W`** | optional (Return skips, Esc cancels the whole press) | **STT only** | the Work desk: a picture card and a playable recording card carrying the words. **No gateway. No LLM.** |

Text input mode: `⌘⇧1`/`⌘⇧2` open the Chat compose surface; `⌃⌘W` opens the same surface in its Work-only state (header "Add to Work", no Ask button, Return and ⌘Return save to the desk), with the dragged region staged in the Work-only image slot.

## What the lane does today (verified in code at `a197ccd`)

**Entry points — one handler, three doors.** `KeyboardShortcuts.Name.captureToWork` (`MenuBar/GlobalShortcut.swift`, default ⌃⌘W) → `MenuBarController.handleWorkCapturePress()`; the status-item menu row "Capture to Work…" (`captureToWorkFromMenu`) calls the same handler; Settings → General → Keyboard Shortcut has a third `KeyboardShortcuts.Recorder(for: .captureToWork)` row labelled "Capture to Work" with the `tray.and.arrow.down` glyph (`Views/Settings/MacGeneralCategory.swift:242`). The menu is **Start Recording** (voice mode) / **Type a Message…** (text mode) · Screenshot & Ask… · Capture to Work… · separator · Open Conversations · Open Work · separator · Launch at Login · Show in Dock · separator · Settings… · separator · Quit Conduck — pinned by `testTheContextMenuOffersCaptureToWorkRightAfterScreenshotAndAsk`. (The Settings row for `⌘⇧1` is labelled "Ask"; the menu's first item names the input, not the destination. Pre-existing, not changed here.)

**Press flow** (`handleWorkCapturePress`, `MenuBarController.swift:422`): terminal Work error → dismiss and treat as a fresh press · Work capture in hand → `finishWorkVoiceCapture()` (stop-and-save, or the retry that finishes it) · `workCapturePressInFlight` drops a second press while the crosshair stands · reserve `workCaptureCancellationGeneration` · `regionCapture.captureRegion(purpose: .work, requiresMicrophone: !textMode)` → `.captured(Data)` / `.skipped` (Return) / `.cancelled`, `.unavailable` (return, nothing staged) · post-await guard: generation unchanged, `!workCaptureIsActive`, `!workRecordingIsLive`, `dictationService.state != .recording` · text mode → `setPendingWorkCaptureImage` + `openComposeForWorkOnly()` + `showPopover()` · voice → `claimPopoverForWorkVoiceCapture()` → `updatePopoverBehavior()` → `showPopover()` → start cue → `beginWorkVoiceCapture(screenshot:)`.

**Overlay** (`ScreenCapture/RegionCaptureController.swift`): `RegionCapturePurpose.work` draws `regionCapture.overlay.hint.work` ("Drag to capture · Return to skip · Esc to cancel"), maps Return/keypad Enter to `onSkip` on Work only (`:954`), offers the "Skip screenshot" accessibility action on Work only, and every Work Screen-Recording permission stop offers "Continue Without Screenshot" with Cancel last; the microphone stop offers no skip. A sub-4pt drag is a cancel on both lanes.

**What reaches the desk, and how.** Voice: `InAppAudioRecorder(retryDestination: .work)` stages the picture (`stageWorkScreenshot`) until Stop; `runCaptureToCompletion` (`InAppAudioRecorder.swift:1115`) mints the capture, publishes the picture first (`WorkVoiceScreenshotCoordinator.publish` → App-Group inbox → `WorkCaptureDrainer`), publishes the recording (`WorkVoiceCaptureCoordinator.publishRecording`, `:1259`), transcribes (`AppleSpeechRunner.transcribe` or `STTClient.shared.transcribe`, `:1453`/`:1459` — the same speech hop every lane uses), then `attachTranscript` writes the words onto the recording's card. Text: `saveQuickDraftToWork()` (`MenuBarCoordinator.swift:2248`) → `WorkCaptureInbox.shared.publishAppCapture(note:screenshotPNG:)` → inline drain. Nothing on either path assembles a turn, arms a destination, or calls `handleQuickSend`; pinned by `testTheWorkHandlerCarriesNoQuickCaptureGatewayMachinery`, `testNoPopoverPathReachesAGatewayHop`, `testTheChatSendPathCannotSeeTheWorkScreenshotSlot`, `testAChatTurnCarriesTheChatScreenshotAndNeverTheWorkOne`.

**HUD.** `DictationPopoverView.captureHUD(screenshot:cancelLabel:cancel:indicator:)` (`:446`) is the one layout for the three captures' recording phase — thumbnail if any, one indicator, one compact ✕. The Ask lane renders it from `pendingCaptureImage` (`recordingStatusView`), the Work lane from `pendingWorkCaptureImage` (`workCaptureView`, `:884`). After the stop the lanes differ on purpose: Ask's `workingView` (`:1227`) hides its ✕ through STT because the stop committed the turn; Work keeps its ✕ as "Cancel transcription" because it owns a cancellable task and the recording's card is already durable. The Work error arm renders a one-sentence outcome composed from `workCaptureFacts`, the reason, Try Again and ✕.

**Cancel / stop / error.** Esc or ✕ before the stop → nothing on the desk (picture staged, never published). Second ⌃⌘W or a left-click on the status item → stop and save. ✕ during transcription → "Cancel transcription": the recording's card stays. A refused picture, recording or transcript holds the capture retryable in `.error(code)`; one Try Again finishes it with no second recording and no second card.

**Where the two lanes meet.** `handleShortcutPress`, `handleRegionCapturePress` and `startRecordingFromMenu` all begin `guard !workRecordingIsLive else { return showWorkCaptureInstead() }` (`:249`, `:307`, `:1232`): while the Work microphone is live an Ask press shows the running capture and starts nothing. `statusBarButtonClicked` (`:160`) resolves a live Chat recording first, then the Work lane, then the Ask state switch. `workCaptureIsActive` (`MenuBarCoordinator.swift:1959`) stays true through the Work transcription AND a standing Work error, and the popover's content router (`DictationPopoverView.swift:352`) and the status icon (`MenuBarController.swift:865`) put the Work HUD/glyph first whenever it is — which is where P2-A below comes from.

## Judgement

Matches the intent: three options, the third lands on the desk and never on a gateway, with STT as its only hop. Nothing headless routes a private thought to an AI (the Work handler has no `armQuickCapture`, no readiness guard, no send) or an AI-bound thought to the desk (Chat's three doors all `closeWorkOnlyCompose()` before they show, so Return follows the surface being looked at). The screenshot being *optional* on the Work lane is a deliberate superset of "screenshot + voice": a missing Screen Recording grant can never deny a voice note, and Return is one key. Codex round 1 concurs on the reading and on the extension.

## Decisions

| # | Decision | Why |
|---|---|---|
| 1 | **No structural change to the Work lane.** Overlay first, then record, publish picture → recording → words, no gateway. | It is the founder's third option verbatim, seven Codex rounds have read it, and every mechanism is pinned by a guard test with a negative control. Re-cutting a verified lane to reach the same behaviour is pure risk. |
| 2 | **The picture stays optional on `⌃⌘W`** (Return skips). | A denied Screen Recording grant would otherwise deny the voice note too; Return costs one key; the Ask overlay stays strict because on that lane the pixels ARE the question. |
| 3 | **Two cards on the desk — the picture and the recording — not one composite card.** They are adjacent because both publish at one stop and the desk orders by sequence rank; a picture retried later lands where the retry puts it. | One kind per card and one desk write; a composite kind is a new model, gallery page, Quick Look case and CloudKit field for one lane. Founder may overrule at QA (see Notes). Codex round 1 corrected the draft's claim that a shared `createdAt` guarantees adjacency — it does not (ordering is by sequence, and the recording is dated at publication, not from the capture); P3-C below dates the recording from the capture so the two cards at least carry one date. |
| 4 | **P2-A — whichever lane holds the microphone owns the popover and the status glyph.** The content router's first arm becomes `if coordinator.workCaptureIsActive, service.state != .recording { workCaptureView }`, followed by the existing `else if service.state == .recording { recordingStatusView }`; `updateIcon` resolves the Work glyph only when `workCaptureIsBusy && dictationService.state != .recording`. | Today a Work capture parked in transcription or in a retryable error keeps `workCaptureIsActive` true, so a `⌘⇧1` pressed then starts an Ask recording whose HUD, timer and ✕ are hidden behind the Work HUD and whose glyph reads "Transcribing" — and the status-item click (already "live Chat recording first" since round 18) then stops and SENDS a recording nobody could see. A live microphone with no visible surface is the failure the startup pin exists to prevent. This is handoff decision 13 resolved on the "Work HUD yields while the Ask microphone is live" side: the click rule already says so, and the surface must agree with the click. The Work capture is not narrowed — its HUD, its Try Again and its debt return the moment the Ask microphone releases (`.processing` → Work HUD again; the Ask reply then arrives as an unread dot, which is the lane's ordinary late-reply path). Founder may reverse at QA. **(ii) A bail takes what is on screen.** `cancelActiveCapture` (`MenuBarCoordinator.swift:1789`) calls `cancelWorkVoiceCapture()` only when the Ask microphone is NOT live, so the Ask HUD's ✕ and Esc — both route there — cancel the Ask they show and leave a parked Work transcription or error alone. Codex round 2 found that without this the newly visible Ask ✕ would discard a Work capture underneath it, and an audio-less picture has no durable copy to fall back on. This is the same rule the method already applies to compositions ("an explicit bail throws away what the person was looking at, never a second composition they cannot see"), extended to captures. **The press generation is still bumped unconditionally:** Codex round 3 showed that cancelling the Ask sets its state `.idle` synchronously, so a `⌃⌘W` press suspended in ScreenCaptureKit acquisition would then pass the post-await guard and record after the Esc — the generation bump is extracted from `cancelWorkVoiceCapture()` into `bailWorkCapturePress()` and `cancelActiveCapture` always calls that, gating only the recorder teardown. |
| 5 | **P2-B — a secondary click is the menu in every state.** `isSecondaryClick()` is hoisted to the top of `statusBarButtonClicked`; the Work arm's inner check goes. | Today a right-click or control-click during an Ask recording falls into `case .recording: dictationService.toggleRecording()` — stop-and-send. A person reaching for the menu (including for "Capture to Work…") sends a turn. HIG: secondary click is the context-menu gesture. The Work arm already handles it; one rule, one place. **(ii) "Start Recording" is the same door as `⌘⇧1`.** `startRecordingFromMenu` keeps its text-mode re-check and otherwise delegates to `handleShortcutPress()`. Codex round 2 found that with the menu reachable during an Ask recording or transcription, the item's own `armQuickCapture()` + `toggleRecording()` re-arms the destination of a turn already in flight (a fresh TTL/default resolution can retarget it) — `handleShortcutPress` arms only from `.idle`/`.error`. Delegation also gives the menu door the `discardPendingFailedTurn()` the hotkey already has, and matches how `screenshotAndAskFromMenu` and `captureToWorkFromMenu` are already wired. |
| 6 | **P2-C — `⌃⌘W` stands down BEFORE the overlay while any microphone is held**, in voice mode. `SpeechExclusivity.shared.isRecordingActive` (existing, `Services/TTS/SpeechExclusivity.swift:116`) is the question; the answer is the popover: the Ask HUD if the popover's own lane is recording (P2-A makes it visible), otherwise the idle view with the existing busy sentence ("Microphone is in use by another recording.") set through a new one-line coordinator method. Never a stop. | Today the press raises the crosshair, lets the person drag a region, and only then the post-await guard drops it silently (menu-bar Ask recording) or the lease refuses it with the busy sentence (main-window composer recording — QA step 27). Both wasted a drag. Codex round 1 pointed out the lease query already exists, so the draft's "needs a new query" deferral was wrong. Text mode skips this check: a typed note needs no microphone. |
| 7 | **The post-await guard keeps every clause.** | It answers a recording that STARTS during the overlay; the pre-overlay check answers one already live. Both windows are real. Its `dictationService.state != .recording` clause still refuses a text-mode note while the popover's lane records — pre-existing, recorded as U-48, not widened. |
| 8 | **One lane-neutral helper for standing down:** `showWorkCaptureInstead()` → `standDownForBusyMicrophone()`, same body (`if !popover.isShown { showPopover() }`), three direct callers once the menu door delegates (`handleShortcutPress`, `handleRegionCapturePress`, `handleWorkCapturePress`). | The helper's name was lane-specific; called from the Work door it would claim the opposite of what is running. |
| 9 | **P2-D — the typed receipt says "Added" only when the drain came back, and "On its way" when it threw.** `saveQuickDraftToWork` binds the inline drain's THROW (not its report, and not a desk read-back): returned → "Added to Work. Nothing was sent." (unchanged key, `.saved` button); threw → a new `.queued` feedback kind, an inert row (no button, no tooltip) under a new key, "On its way to Work. Nothing was sent." | The envelope is durable either way, so the note is never lost — but "Added" claims a card, and the acknowledgement button promises the card is *already there* (handoff step 23). A drain that throws has put the claim back first (`WorkCaptureDrainer.swift:220–223`), so "queued" is exactly true then. A drain that returns has imported this capture, or is racing the desk's own observer that is importing it (the report comes back empty while the other drainer holds the claim — the receipt is then a beat ahead of the card, and the observer finishes before the desk can be opened), or has refused it — which for a fresh, well-formed app envelope needs both its id and its escape id to already name cards of another kind, and is negligible. **Surviving disagreement with Codex (rounds 2–3):** it wants proof of THIS capture — per-capture identities and payload completeness in the drainer's report, because a desk read-back by `captureID` is wrong under an escape-id republish and a row does not prove its payload. This design declines: nothing is lost on this lane (the envelope is the durable boundary), the false-claim window is a race measured in milliseconds, and the exact version couples a receipt to the drainer's identity rules. If the founder wants exactness, the upgrade is `Report.importedCaptureIDs` / `refusedCaptureIDs` on `WorkCaptureDrainer` and a third sentence for refusal — a separate, scoped change. |
| 10 | **P3-C — the recording card is dated from the capture** (`publishRecording(createdAt: capture.createdAt)` at the Mac recorder's phase-one call). Scope: first publication only. | The picture already is; both cards published at one stop then carry one date. A picture recovered after a relaunch is dated from the retry record (`preserveForRetry` writes `createdAt: Date()`, `:1875`), and that field is the queue's expiry clock (`PendingRetryStore.swift:238`), so it is deliberately not repointed. |
| 11 | **P3-E — the Settings card header reads "Keyboard Shortcuts"** under a new key; the singular key retires. | Three recorder rows sit under a singular header. New wording = new key. Optional. |
| 12 | **Copy: no other change.** "Capture to Work…" (menu, ellipsis because the overlay asks first) / "Capture to Work" (Settings; hint "Press ⌃⌘W to capture to Work") name the ACTION; "Add to Work" (compose header, commit button, the Chat surface's button) names the COMMIT; "Added to Work. …" is the receipt. | The hotkey does three different things (picture, recording, typed note) and "Capture" is the only word true of all three; "Add to Work" is the one commit the popover has and matches CarPlay's row. Codex agrees the split is HIG-conformant. |
| 13 | **Out of this lane, recorded not fixed — for an Ask-lane pass:** **U-49 (P2)** Esc during Ask STT does not abort the send that follows (`DictationService.cancelRecording` is a no-op in `.processing`, `:195`), while the capture guide teaches "Press Esc to cancel" beside the two Ask shortcuts (`MenuBarGuideView.swift:78`) and the Esc handler is a cancel, not a close (`MenuBarController.swift:736`); **U-46 (P2)** Chat queue recovery sends the currently staged Chat screenshot. | Both predate the Work destination and neither routes a Work thought to a gateway. A fix needs a cancellation token through `DictationService`'s STT task and capture-owned attachments respectively — Ask-lane work with its own guards, not a rider on this design. Settled with Codex in round 2: U-49 is P2 (a cancellation inconsistency the app's own guide contradicts), not the P1 "routing violation" of round 1, and not P3. |

## Changes by file

### P2-A — the live microphone owns the surface and the glyph

**`Conduck/Conduck/MenuBar/DictationPopoverView.swift`** — `content` router (`:352`): first arm `if coordinator.workCaptureIsActive, service.state != .recording { workCaptureView } else if service.state == .recording { recordingStatusView } else if isWorking { … }` (the remaining arms unchanged). Rewrite the arm's comment: the two lanes are exclusive at the MICROPHONE, not at the surface — a Work capture stays active through its transcription and a standing error, so an Ask recording can be live underneath; whichever lane holds the microphone is the one the person must be able to see and stop, and the Work HUD returns the instant it is released.

**`Conduck/Conduck/MenuBar/MenuBarController.swift`** — `updateIcon()` (`:865`): `if workCaptureIsBusy, dictationService.state != .recording { … }`; same comment correction.

**`Conduck/Conduck/MenuBar/MenuBarCoordinator.swift`**
1. Extract the first statement of `cancelWorkVoiceCapture()` (`:2139`, `workCaptureCancellationGeneration &+= 1`) into `func bailWorkCapturePress()` with the existing comment (the press this bail has to reach may own nothing yet); `cancelWorkVoiceCapture()` calls it first, unchanged in every other line.
2. `cancelActiveCapture()` (`:1789`): read `let askMicrophoneIsLive = dictationService.state == .recording` as the FIRST statement (before `dictationService.cancelRecording()` sets the state `.idle`); call `bailWorkCapturePress()` unconditionally where `cancelWorkVoiceCapture()` is called today; then `if !askMicrophoneIsLive { cancelWorkVoiceCapture() }`. Comment: the two lanes are exclusive at the microphone, so a live Ask means the Work capture is parked (transcribing, or holding a debt), and a bail takes what is on screen — the Ask HUD — never the capture it hides; the Work HUD returns at the Ask's stop with its Try Again intact. The generation is still moved because the Ask's cancel frees the microphone synchronously, and a `⌃⌘W` press still suspended in its screenshot await would otherwise pass the post-await guard and record after the Esc (Codex round 3).

**Tests**
- `MenuBarWorkCaptureStateTests.testTheWorkHUDIsTheFirstArmOfTheContentRouter` → rename `testTheWorkHUDIsTheFirstArmUnlessTheAskMicrophoneIsLive`; the existing test reads only `prefix(120)` of the squeezed router (`:272`) and the new head is ~143 characters, so widen the slice to `prefix(260)`; assert it contains the squeezed `if coordinator.workCaptureIsActive, service.state != .recording { workCaptureView } else if service.state == .recording { recordingStatusView }`, with the message: a Work HUD that outranks a live Ask microphone hides the only surface that can stop it.
- `MacMenuBarWorkShortcutDriftGuardTests.testALiveChatRecordingOutranksANonRecordingWorkState` (`:375`) gains a second assertion over `updateIcon`: the Work glyph branch carries `dictationService.state != .recording`.
- `MacMenuBarWorkShortcutDriftGuardTests.testABusyWorkRecorderDrivesTheStatusItem` stays green (it checks `workCaptureIsBusy` is read; the clause is additive).
- **Add** `MenuBarCoordinatorQuickTypedTests.testABailWhileTheAskMicrophoneIsLiveLeavesAParkedWorkCaptureAlone`: drive the Work recorder into a retained error (the seam `WorkboardVoiceScreenshotLaneTests` uses for a refused picture) and `DictationService` into `.recording` through its `CONDUCK_TESTING` seam if one exists; call `cancelActiveCapture()`; assert `workVoiceRecorder.pendingWorkCapture` and `workCaptureIsActive` are unchanged and the Ask recording was cancelled. If the service state cannot be driven in the unsigned host, a source guard in `MacMenuBarWorkShortcutDriftGuardTests` asserts `let askMicrophoneIsLive = dictationService.state == .recording` precedes `dictationService.cancelRecording()`, `bailWorkCapturePress()` is called unconditionally, and `cancelWorkVoiceCapture()` sits inside `if !askMicrophoneIsLive`. Negative control: the un-gated form must fail it. `testABailDuringTheScreenshotAwaitEndsTheWorkPress` (`:212`) reads `cancelWorkVoiceCapture` for the bump — re-point it at `bailWorkCapturePress` and assert `cancelWorkVoiceCapture()` calls it first.

### P2-B — a secondary click is the menu in every state

**`Conduck/Conduck/MenuBar/MenuBarController.swift`** — `statusBarButtonClicked` (`:160`): first line `if isSecondaryClick() { return showContextMenu() }`; delete the `isSecondaryClick()` branches inside the Work arm and the `.idle, .error` arm (the `.idle, .error` arm becomes `presentPopoverForClick()` alone). The Work arm's live-Chat-first condition and its stop/show logic are untouched.

**`Conduck/Conduck/MenuBar/MenuBarController.swift`** — `startRecordingFromMenu()` (`:1232`): keep the defensive `guard coordinator.menuBarInputMode == .voice else { openPopoverForTyping(); return }`, then `handleShortcutPress()`. Delete its own `workRecordingIsLive` guard, readiness guard, `armQuickCapture()`, `showPopover()` and `toggleRecording()` — the hotkey handler carries all of them, arms only from `.idle`/`.error`, and stops (never re-arms) from `.recording`.

**Tests**
- `MacMenuBarWorkShortcutDriftGuardTests.testALiveChatRecordingOutranksANonRecordingWorkState` (`:375`; it is THIS test, not `testAStatusItemClickStopsALiveWorkRecording`, whose assertion at `:396` reads `isSecondaryClick()` anywhere in the body) stays green after the hoist. **Add** `testASecondaryClickIsTheMenuOnBothLanes`: the squeezed `if isSecondaryClick() { return showContextMenu() }` precedes both `if coordinator.workCaptureIsActive` and `switch dictationService.state` in `statusBarButtonClicked`, and no other `isSecondaryClick()` remains below it; negative control: an `isSecondaryClick()` inside a `case .recording:` arm does not satisfy it.
- `testEveryAskEntryPointStandsDownWhileTheWorkMicrophoneIsLive` (`:477`): the `startRecordingFromMenu` door now satisfies the rule by delegation — assert its body contains `handleShortcutPress()` and none of `armQuickCapture`, `toggleRecording`, `isQuickCaptureKnownUnavailable`; the other two doors keep the `workRecordingIsLive` assertion. **Add** `testTheMenuRecordingDoorIsTheHotkeyHandler` with exactly that, plus the text-mode re-check ordering (`openPopoverForTyping()` precedes `handleShortcutPress()`).

### P2-C — `⌃⌘W` stands down before the overlay while a microphone is held

**`Conduck/Conduck/MenuBar/MenuBarController.swift`**
1. Rename `showWorkCaptureInstead()` → `standDownForBusyMicrophone()`; lane-neutral doc comment ("What a capture hotkey does while a microphone is already held: show the popover, which shows whatever is running, and start nothing"); same body. Update the two hotkey call sites (`startRecordingFromMenu`'s goes with P2-B(ii)).
2. In `handleWorkCapturePress()`, after the `else if coordinator.workCaptureIsActive { … return }` branch and before `guard !workCapturePressInFlight`:
   ```swift
   // A microphone is already held — the popover's own Ask recording, or the
   // main window's composer. Raising the crosshair now would let the person
   // drag a region and then drop the press at the post-await guard, or refuse
   // it at the lease, either way after the drag. Text mode needs no microphone
   // and is not asked. Never a stop: this key must never be the thing that
   // sends an Ask turn to a gateway.
   if coordinator.menuBarInputMode == .voice, SpeechExclusivity.shared.isRecordingActive {
       if dictationService.state != .recording { coordinator.noteWorkCaptureRefusedMicrophoneBusy() }
       return standDownForBusyMicrophone()
   }
   ```
   `let textMode` inside the Task stays as is. The post-await guard is unchanged.

**`Conduck/Conduck/MenuBar/MenuBarCoordinator.swift`**
3. Extract the busy sentence used in `presentWorkVoiceStartRefusal()` (`:2222`) into `private static var microphoneBusyMessage: String { String(localized: "Microphone is in use by another recording.") }` and add
   ```swift
   /// A ⌃⌘W refused BEFORE its overlay because another recorder — the main
   /// window's composer — holds the microphone. Same sentence the lease
   /// refusal prints after a start, so one conflict reads one way.
   func noteWorkCaptureRefusedMicrophoneBusy() {
       quickWorkCaptureFeedback = MenuBarWorkCaptureFeedback(kind: .failed, message: Self.microphoneBusyMessage)
   }
   ```
   `presentWorkVoiceStartRefusal` reads the same property. No new catalog key: the sentence is the existing shipped row.

**Tests**
- `MacMenuBarWorkShortcutDriftGuardTests`: add `testTheWorkPressStandsDownBeforeTheOverlayWhileAMicrophoneIsHeld` — in `handleWorkCapturePress`, the squeezed `SpeechExclusivity.shared.isRecordingActive` check precedes `regionCapture.captureRegion(purpose: .work`, is gated on `.voice`, calls `standDownForBusyMicrophone()` and `noteWorkCaptureRefusedMicrophoneBusy()`, and the helper's body (`controllerFunction("standDownForBusyMicrophone")`) contains `showPopover()` and none of `toggleRecording`, `finishWorkVoiceCapture`, `captureRegion`.
- `testTheWorkPressTakesItsScreenshotBeforeItRaisesAnything` (`:144`) stays green: its ordered list names `showPopover()` literally and the stand-down calls the helper. Codex round 1 called this a textual loophole rather than a safety property; accepted in part — the new test above pins the stand-down's own shape, and the ordering test keeps its job of catching a surface raised into the shot. Do not inline `showPopover()` at the stand-down.
- `testEveryAskEntryPointStandsDownWhileTheWorkMicrophoneIsLive` is updated under P2-B(ii) (the menu door satisfies it by delegation); the other two doors keep the `workRecordingIsLive` assertion, so the helper's rename does not touch them.

### P2-D — the typed receipt says what the drain proved

**`Conduck/Conduck/MenuBar/MenuBarCoordinator.swift`**
1. `MenuBarWorkCaptureFeedback.Kind` (`:86`) gains `case queued`.
2. `saveQuickDraftToWork()` (`:2284`): replace `_ = try? await WorkCaptureDrainer(…).drainAvailableCaptures()` with
   ```swift
   // The drain is what makes "Added" true; a drain that throws has put the
   // claim back first, so the note is queued, not lost, and the desk's own
   // observer imports it. The report is deliberately not read: it carries no
   // identities, so it can say nothing about THIS capture that the throw does
   // not already say.
   let drained: Bool
   do { _ = try await WorkCaptureDrainer(sourceDevice: SourceDevice.current).drainAvailableCaptures(); drained = true }
   catch { drained = false }
   ```
   and the feedback assignment becomes
   ```swift
   quickWorkCaptureFeedback = drained
       ? MenuBarWorkCaptureFeedback(kind: .saved, message: String(localized: LocalizedStringResource("workboard.menuBar.saved", defaultValue: "Added to Work. Nothing was sent.")))
       : MenuBarWorkCaptureFeedback(kind: .queued, message: String(localized: LocalizedStringResource("workboard.menuBar.savedQueued", defaultValue: "On its way to Work. Nothing was sent.")))
   ```
   The consume-the-committed-values block is unchanged and stays BEFORE the feedback, as today.

**`Conduck/Conduck/MenuBar/DictationPopoverView.swift`** — `workFeedbackRow` (`:1177`): a `.queued` arm renders `Label(feedback.message, systemImage: "clock")` in `.caption` / `AppColors.textSecondary`, inert — no button, no `.help`, because there is no card to promise. The `.saved` arm and its "Open Work and see the new card" tooltip are untouched.

**Tests** — `MenuBarWorkCaptureStateTests.testTheDeskCommitDrainsBeforeItClaimsTheCardIsThere` (`:356`) gains: the drain sits in a `do`/`catch` that sets `drained`, the `.saved` sentence is under `drained ?`, and `.queued` names `workboard.menuBar.savedQueued`. **Add** `testTheTypedReceiptSaysQueuedWhenTheDrainThrew` in the same file — a source guard that the exact key `"workboard.menuBar.saved"` appears only in the `drained` branch, with a negative control (a `try?` drain whose result is discarded fails it). `WorkboardCopyTruthGuardTests`: the new sentence passes the existing vocabulary rule (it strips "nothing was sent" before scanning, `:216`); the catalog row and the source reference land in one change.

### P3-C — one date for both cards

**`Conduck/Conduck/Services/InAppAudioRecorder.swift`** (`:1259`): `publishRecording(captureID:audio:fileExtension:mimeType:createdAt: capture.createdAt, store:)`. `WorkboardVoiceScreenshotLaneTests.testAStagedScreenshotBecomesItsOwnCardPublishedBeforeTheRecording` (`:59`) gains an assertion that both cards' `createdAt` equal the capture's. The recovery path (`preserveForRetry` `:1875`, `DictationService.swift:523`) is NOT touched — that date is the retry queue's expiry clock.

### P3-E — Settings header plural (optional)

**`Conduck/Conduck/Views/Settings/MacGeneralCategory.swift`** (`:251`): `LocalizedStringResource("settings.mac.general.shortcuts.header", defaultValue: "Keyboard Shortcuts")`. Catalog owner: add the new key, retire `settings.mac.general.shortcut.header`. `MenuBarGuideView`'s literal "Keyboard Shortcut" names the concept, not this list; leave it.

## Catalog keys (iOS catalog; owner: the catalog agent — this lane edits none)

| Action | Key | Default | For |
|---|---|---|---|
| add | `workboard.menuBar.savedQueued` | On its way to Work. Nothing was sent. | P2-D |
| add | `settings.mac.general.shortcuts.header` | Keyboard Shortcuts | P3-E |
| retire | `settings.mac.general.shortcut.header` | Keyboard Shortcut | P3-E |

Watch catalog: none. P2-A/B/C add no key (the busy sentence is the existing shipped row).

## Tests (summary)

- **Update:** `MenuBarWorkCaptureStateTests.testTheWorkHUDIsTheFirstArmOfTheContentRouter` (→ `…UnlessTheAskMicrophoneIsLive`, slice widened); `MacMenuBarWorkShortcutDriftGuardTests.testALiveChatRecordingOutranksANonRecordingWorkState` (+ icon clause); `testEveryAskEntryPointStandsDownWhileTheWorkMicrophoneIsLive` (menu door by delegation); `MenuBarWorkCaptureStateTests.testTheDeskCommitDrainsBeforeItClaimsTheCardIsThere` (+ desk read-back); `WorkboardVoiceScreenshotLaneTests.testAStagedScreenshotBecomesItsOwnCardPublishedBeforeTheRecording` (+ dates, P3).
- **Add:** `MacMenuBarWorkShortcutDriftGuardTests.testASecondaryClickIsTheMenuOnBothLanes`, `testTheMenuRecordingDoorIsTheHotkeyHandler`, `testTheWorkPressStandsDownBeforeTheOverlayWhileAMicrophoneIsHeld`; `MenuBarCoordinatorQuickTypedTests.testABailWhileTheAskMicrophoneIsLiveLeavesAParkedWorkCaptureAlone` (or its source-guard fallback); `MenuBarWorkCaptureStateTests.testTheTypedReceiptNeverClaimsACardTheDeskDoesNotHold`.
- **Update (P2-A(ii)):** `MacMenuBarWorkShortcutDriftGuardTests.testABailDuringTheScreenshotAwaitEndsTheWorkPress` (re-pointed at `bailWorkCapturePress`).
- **Unchanged and must stay green:** `testTheWorkPressTakesItsScreenshotBeforeItRaisesAnything`, `testACancelledRegionEndsTheWorkPressWithNothingStaged`, `testTheWorkHandlerCarriesNoQuickCaptureGatewayMachinery`, `testNoPopoverPathReachesAGatewayHop`, `testTheVoiceReceiptNamesItsSpeechProviderAndTheTypedNoteKeepsItsInertness`, `testALiveChatRecordingOutranksANonRecordingWorkState`'s existing `isSecondaryClick()` assertion, all of `RegionCaptureOutcomeGuardTests`.

## Docs

- `spec.md`: **no edit** (three words of headroom). "All three menu-bar captures share one panel … and stop on a second hotkey press or a status-item click" stays true; the microphone-precedence rule is an interaction detail below the spec's altitude.
- `project-structure.md`: no edit.
- `handoff.md`: decision 13 → resolved by P2-A (Work HUD yields while the Ask microphone is live; founder may reverse). QA step 27 → the busy sentence now appears with NO crosshair. Step 33 gains the reverse direction (⌃⌘W while an Ask records: no crosshair, the Ask HUD shows, nothing stops). Step 38 → the Ask HUD is visible above a parked Work error while the Ask mic is live, and the Work HUD returns at the stop. Step 89 → the first item is "Start Recording" / "Type a Message…", not "Ask". Add U-47 (secondary click on the Ask `.processing` arm still opens the popover rather than the menu — resolved by P2-B's hoist, delete if implemented), U-48 (text-mode note refused by the post-await guard while the popover's lane records), U-49 (Esc during Ask STT does not abort the send).
- - `fixnotes/u40-capture-to-work.md`: the paragraph at `:107` ("`cancelWorkVoiceCapture()` bumps the generation FIRST and unconditionally") now names `bailWorkCapturePress()`, called by `cancelActiveCapture` even when the bail leaves the Work recorder alone; press-flow list gains the pre-overlay stand-down; HUD section gains the microphone-precedence rule; "Nobody undo" gains: *the live microphone outranks a parked Work state on the router, the icon, the click and the bail alike — all four must agree, or a click stops what the surface hides and a ✕ discards what it cannot show*; *`⌃⌘W` asks `SpeechExclusivity` before it raises an overlay, through `standDownForBusyMicrophone()`, never `showPopover()` inline and never a stop*; *"Start Recording" is `handleShortcutPress()` — a menu door with an arm of its own re-arms a turn in flight*; *the typed receipt binds the drain's throw, never its counts — a returned drain says "Added", a thrown one "On its way", and the report identifies nobody*.

## Founder-visible notes (decisions, not defects — override at QA)

- **Two cards, not one.** A `⌃⌘W` with a picture leaves a screenshot card AND a recording card (words on the recording). One card carrying both is a new card kind (model, gallery, Quick Look, CloudKit field) and its own design session.
- **Decision 13 is resolved here as "the Work HUD yields while the Ask microphone is live"** (P2-A). Reverse it if you would rather the Work error stay on top and accept a hidden live microphone.
- **Names across surfaces.** Mac: "Capture to Work" (action) / "Add to Work" (commit); CarPlay "Add to Work"; Watch "Save to Work". The Mac is internally consistent; the Watch wording is the Watch lane's and the integrator's call.
- **Receipt length.** "Added to Work. The words came from your speech provider." is kept: "Nothing was sent" over an STT upload would be false, and `testTheVoiceReceiptNamesItsSpeechProviderAndTheTypedNoteKeepsItsInertness` pins the distinction. Shortening it is a copy decision with one test to change.

## Open risks

- **U-48** (decision 7): text mode's post-await guard refuses a typed note the microphone conflict does not block; rare, one clause to narrow.
- **U-49 (P2, Ask lane)**: Esc during Ask STT closes the popover and the send still goes out, while the guide teaches "Press Esc to cancel" — pre-existing; needs a cancellation token through `DictationService`'s STT task. Recommended as the first item of an Ask-lane pass.
- **U-46 (P2, Ask lane)**: Chat queue recovery attaches the currently staged Chat screenshot — pre-existing.
- **P2-D residual**: when the desk's own observer is the drainer that imports the typed note, the inline drain returns empty and the receipt says "Added" a beat before the card exists; the observer finishes before the desk can be opened. Codex's exact alternative (per-capture identities in the drain report) is recorded in decision 9.
- **⌃⌘W availability** (handoff decision 15) is unverifiable except on the founder's Mac; the Settings recorder is the remedy.
- P2-A hides Ask's `workingView` ✕ (abort an in-flight reply) behind a returning Work HUD while both are pending; the reply lands as unread. Accepted: the Work HUD's Try Again is the surface with a debt.

## Codex rounds

`verify/codex-design-mac-r1.md` — ten findings: P2-A (its #2, rated P1 there), P2-B (#6), P2-C's lease query (#4), P2-D (#8) and the adjacency correction (#5) accepted; its #3 agreed with the stand-down; #1 (Esc during Ask STT) and #7 (U-46) recorded as Ask-lane open items, severity disputed on #1; #9 accepted in part (the helper stays, the new test pins its shape); #10's copy corrections folded in.

`verify/codex-design-mac-r2.md` — seven findings, all accepted: the Ask ✕ under P2-A would have discarded the hidden Work capture (→ P2-A(ii)); no both-recorders-live state and no self-refusal from the lease query, main-actor safe (P2-C confirmed); "Start Recording" re-armed a busy Ask once the menu became reachable (→ P2-B(ii)); the drain report identifies no capture (→ P2-D reads the desk by id, `.queued` kind); two test-description errors corrected (router slice width; which test owns `:396`); U-49 settled at P2 for an Ask-lane pass; the recovery date left alone (P3-C narrowed).

`verify/codex-design-mac-r3.md` — five findings. Accepted: the suspended-press hole under P2-A(ii) (Esc frees the Ask microphone synchronously, so the generation must still move → `bailWorkCapturePress()`); P2-B(ii) confirmed complete with no lost behaviour and the delegation test update required; the test-summary inconsistency and the helper's caller count. **Disputed and left open:** its P2-D position — that only per-capture identities and payload completeness from the drainer prove arrival, and that a desk read-back by `captureID` is wrong under an escape-id republish. The read-back is withdrawn on that evidence; the design binds the drain's throw instead and records why that is honest enough on a lane where nothing can be lost (decision 9).
