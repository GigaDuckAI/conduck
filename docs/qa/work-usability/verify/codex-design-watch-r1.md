The founder’s direction is sound. **The draft overstates its safety and underspecifies the small-screen behavior.** Reviewed read-only at `a197ccd`; six repository source checks passed. I did not run simulator tests or verify rendered UI.

1. **MAJOR — The selected gateway is not visible while recording.** The draft’s “wrong pick is visible before the microphone opens” argument is false. `pushNewCapture` starts the service immediately. In [WatchConversationThreadView.swift](</Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/ConduckWatch Watch App/Views/WatchConversationThreadView.swift:229>), `threadBackendName` is empty until the draft has a conversation; the toolbar is also hidden during capture, and `WatchThreadCaptureOverlay` shows no destination. A mistaken gateway pick can therefore lead to recording and automatic dispatch without another visible destination cue.

   **Fix:** Show the selected gateway’s short name in the arming/recording overlay, derived from the captured `WatchCaptureTarget`. Keep the synchronous service start and existing Cancel; add no confirmation step. Describe the guarantee accurately: no inherited destination, but an explicit mis-tap remains possible.

2. **MAJOR — The master switch is checked only when drawing the launchpad.** Open the chooser, turn Watch access off on the phone, then pick a row. Both `pushNewCapture` and `beginWorkCapture` check busy only; neither `startCapture` nor `startWorkCapture` checks `isWatchEnabled()`. The dialog is attached outside the enabled branch, so hiding Ask does not itself enforce the gate. This existing multi-gateway gap would now affect every Ask.

   **Fix:** In [WatchNoteView.swift](</Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/ConduckWatch Watch App/Views/WatchNoteView.swift:320>), recheck the switch at both push sites, **after busy refusal and before any route/hint/start mutation**. Dismiss an open chooser when the switch turns off. Preserve the rule that disabling does not interrupt a live capture.

3. **MAJOR — “0, 1 or N” needs a presentation that accommodates N.** Three gateways already produce five buttons including Work and Cancel. Apple recommends at most four buttons total on watchOS. “It scrolls” is insufficient justification for a frequently used choice between a private desk and an AI. Apple also places watchOS Cancel at the upper left; it is not necessarily the final row. [Apple action-sheet guidance](https://developer.apple.com/design/human-interface-guidelines/action-sheets?changes=_1).

   **Fix:** For unrestricted roster sizes, use one simple native list-based destination sheet across all counts, retaining the same handlers. If retaining `confirmationDialog`, make maximum-roster testing on 41 mm a design acceptance condition. Remove the unverified claims about one-line messages, guaranteed visibility, and hidden titles necessarily producing an unnamed VoiceOver sheet. A visible **“Where to?”** is reasonable; “Choose a destination” adds little.

4. **MINOR — Work-last has a weak rationale and increasing access cost.** CarPlay places `makeWorkNoteItem` after **New voice chat**, but **before Recent conversations**, not after every chat row. Its gateway picker is separate. Mac has a fixed capture-command group. Neither establishes “after an arbitrary gateway roster.” Last is a stable relationship, not a stable screen position; Work moves farther away as gateways arrive.

   **Fix:** Put Work first, then gateways in their existing roster order. That gives the newly hidden recording destination a consistent location without changing gateway ordering. If retaining Work-last, describe it honestly as prioritizing AI access, with scrolling potentially required—not “always one tap away.”

5. **MINOR — The zero-gateway message changes meaning in this context.** “Set up your personal AI on iPhone **first**” above the only working Work action reads as a prerequisite for recording. `configuredBackendRefs()` means usable **on this watch now**; emptiness also covers hydration and unreadable credentials. Reusing an existing refusal does not make it appropriate explanatory copy.

   **Fix:** Keep Work available and use a short, scoped message such as **“For AI, check Conduck on iPhone.”** Give it a new watch catalog key. Leave `headlessGatewayRefusal` unchanged: `WatchCaptureGuardTests.testHeadlessCaptureKeepsTheOriginalSentenceWhenNothingIsConfigured` and `testAnUnchosenDefaultOnAnEmptyRosterKeepsTheAmbiguousSentence` explicitly pin its existing sentence. Zero gateways should not promise immediate success: phone unavailable means deferred; queue full means refusal.

6. **MINOR — “Nothing is persisted” is materially inaccurate.** Merely opening or cancelling this chooser creates no gateway hint. But an accepted gateway capture calls `setPendingInAppNewConversationBackend`, which persists its ref in the Watch App Group for background recovery. `askGatewayRefs` also survives dismissal as view state. The actual protection is deliberate replacement and clearing: `startCapture` stamps `.chat`; an accepted `startWorkCapture` stamps `.work` and clears the hint and conversation pins. [WatchRecordingService.swift](</Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/ConduckWatch Watch App/Services/WatchRecordingService.swift:703>).

   **Fix:** Say **“No last-destination preference; each accepted capture binds its destination explicitly.”** Preserve the existing pending hint. Do not clear it merely because the chooser closes: selecting a gateway closes the chooser too. Also dismiss an outstanding chooser when an accepted external trigger replaces navigation, so it cannot linger over another capture.

7. **MAJOR — The proposed tests miss the behavior that motivates the change.** A correct `WatchAskDestinationRows` can coexist with the old single-gateway bypass; its tests would all pass. Banning `UserDefaults` in the view cannot detect persistence through `settingsReader`. Counting `beginWorkCapture()` text can count its declaration or comments.

   **Fix:** Pin the actual entry wiring: zero/one/multiple gateways all present a choice without starting capture; cancellation starts nothing; explicit gateway selection works even with `hasChosenDefaultBackend == false`; both push sites refuse a newly busy machine before mutation. Extend `WatchRecordingLifecycleTests`/`WatchDraftMintTests` with stale-hint → Work and Work → Chat transitions, including cancellation/error boundaries. Use existing test doubles and clean shared settings between cases.

   I found no existing assertion requiring the old threshold, button or title. That supports “no obvious conflicting assertion,” not the unconditional “no existing test breaks.” Preserve `ErrorSurfaceDriftGuardTests`’ existing `canRetry` contract and the relay ownership guards.

8. **MINOR — Spell out the capacity-refusal contract for the implementer.** `startWorkCapture` returns `.refusedBusy` for queue capacity too, while publishing a request-scoped `workCaptureOutcome`. The Work route must remain visible to show that explanation. Crucially, capacity refusal happens **before** `captureDestination = .work`. [WatchRecordingService.swift](</Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/Conduck/ConduckWatch Watch App/Services/WatchRecordingService.swift:786>).

   **Fix:** Explicitly prohibit auto-dismissing Work on `.refusedBusy`, adding a `.work` render prerequisite, or copying the chat view’s redundant auto-start. Preserve push → synchronous start → outcome rendering. Add a test that full capacity arms no microphone, stamps the new request’s refusal, preserves queued recordings, and leaves the explanation available. The existing capacity test covers the predicate, not this complete handoff.

9. **MINOR — The unchanged busy caption can describe Work as an AI conversation.** Back navigation is available while Work is uploading. Returning to the launchpad then shows **“Still answering your last question.”** Keeping that caption unchanged contradicts the lane’s purpose.

   **Fix:** In `WatchNoteView.launchpadView`, use the existing **“Saving to Work…”** resource when `captureDestination == .work` and the service is busy after recording. Keep the current chat caption for Chat. No new state or copy is needed.

10. **MINOR — Prefer “Add to Work,” but do not turn naming into a broad rename.** Bare **Work** matches `GigaActionDestination`, but can collide with an ordinary gateway name. **Save to Work** reduces that collision and is understandable; it does not eliminate ambiguity. **Add to Work** already names this recording action in CarPlay and the watch’s own `CaptureWorkboardIntent`.

    **Fix:** My preference is **Add to Work** for the watch row and capture title, with fresh localized keys and translator context identifying Work as the named private desk. Keep **Saved to Work** for the receipt and **Capture to Work…** for Mac’s broader screenshot/voice/text command. Different action verbs do not themselves violate one-name-per-thing; the destination remains **Work**.

11. **NIT — Correct the implementation map and stale comments.** New Watch **app** files do not require a project-file edit: that target uses a filesystem-synchronized group. New `ConduckWatchTests` files do require explicit membership. [project-structure.md](</Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard/docs/ai-context/project-structure.md:96>) states this distinction. The change list also misses the obsolete threshold comment on `WatchSettingsReader.configuredBackendRefs()` and the “both in-app Ask paths” comment on `pushNewCapture`.

    **Fix:** Keep the helper beside its view for cohesion, not a nonexistent build restriction. Update those comments and the complete root header, which currently says both triggers always push chat threads. Mark the separate-button instruction in `c3-watch-ui.md` as superseded so it cannot prompt a later reversal. Neither architecture document needs a navigation walkthrough.

**What I agree with**

The founder clearly asks for Work inside Ask, including with one gateway. Removing the separate button is a reasonable reading of his preference for fewer controls; the extra tap follows from that choice. Zero-gateway handling and row order are design judgments, not verbatim founder instructions.

The existing separate Work route, nonce, service entry and relay should remain. Keep the dialog attached to an enabled ancestor, retain both busy checks, and keep microphone startup synchronous with the push.

The Action Button, ControlWidget and `RecordNoteIntent` should remain gateway-only. There is already an explicitly named, background-capable **Add to Work** text intent; therefore the accurate boundary is **no implicit headless rerouting to Work**, not “no hands-free trigger can reach Work.” Nothing here calls for a desk AI layer, dispatch feature or further founder decision.

