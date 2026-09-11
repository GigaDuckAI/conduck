# Codex round 1 — Watch Work destination

The core intent is implemented: Ask always opens the chooser for 0/1/N gateways, with Add to Work last. The mechanisms specified by decisions 1–14, numbered source changes, and catalog changes are present; the requested documentation changes are missing. Headless starts remain chat and notification taps remain browse-only in `WatchNoteView.swift:249`, `:272`, and `:313`; the sole Work start is the explicit chooser path at `:387`. Accepted Work starts clear conversation routing state at `WatchRecordingService.swift:810`, force the relay at `:1640`, and settle without converse at `AppleRelayPendingQueue.swift:649`; gateway starts explicitly stamp `.chat` at `WatchRecordingService.swift:708`. I found no shared-contract regression: relay literals and mirror triplets match, and retry exemptions, screenshot protection, and notification ordering remain intact. Three P2 findings remain. Physical layout, largest-text accessibility, and presentation timing remain unverified.

## [P2] Similar gateway names become indistinguishable

- **File:** Conduck/ConduckWatch Watch App/Views/WatchNoteView.swift:525; Conduck/ConduckWatch Watch App/Views/WatchConversationThreadView.swift:239; Conduck/Conduck/Services/RemoteAgent/RemoteAgentRefMetadata.swift:105
- **Claim:** The chooser and new destination caption discard distinguishing name suffixes, defeating the long, similar-name acceptance condition.
- **Failure scenario:** Configure “Personal Hermes East” and “Personal Hermes West”. Both become “Personal Hermes…”. The chooser supplies no separate accessibility label, so VoiceOver receives the same shortened names; picking either gateway also produces the same recording caption. A mistaken destination cannot be identified before stopping. The truncation predates this change, but the new destination cue inherits the defect.
- **Smallest fix:** Preserve full gateway names for accessibility and disambiguate colliding visible labels locally in the Watch chooser and recording cue, without changing the shared shortening policy for other surfaces.

## [P2] The required QA handoff still tests the removed interface

- **File:** docs/qa/work-usability/handoff.md:242; docs/qa/work-usability/fixnotes/c3-watch-ui.md:135; README.md:55; docs/ai-context/project-structure.md:80
- **Claim:** The entire documentation change list is unimplemented, leaving the deliberately manual verification of the new chooser without its required checks.
- **Failure scenario:** QA follows steps 52–54 expecting a separate Save to Work button and unchanged Ask behavior. Meanwhile, the row-builder tests at `ConduckWatchSmokeTests.swift:453` would still pass if the one-gateway chooser bypass returned, because they never invoke Ask. Missing negative controls include chooser cancellation without a hint or capture, headless takeover never selecting Work, switch-off and busy refusals after opening the sheet, notification dismissal, and maximum-roster/41 mm recorder clearance. The old “Nobody undo” instruction also still advocates two buttons.
- **Smallest fix:** Apply the design’s specified README, map, handoff, and supersession edits. Add the prescribed QA cases explicitly, including arming/recording/“1 min left” with Stop and cancel reachable; leave their execution status honestly pending.

## [P2] The inheritance test never creates a conversation pin

- **File:** Conduck/ConduckWatchTests/WatchCaptureGuardTests.swift:763
- **Claim:** `testAWorkPickAfterAnAbandonedGatewayDraftInheritsNothing` meaningfully checks stale-hint clearing, but its conversation-pin assertion starts and ends with no pin.
- **Failure scenario:** Remove either `pendingConversationID = nil` or `mintedConversationID = nil` from `startWorkCapture` at `WatchRecordingService.swift:817`. This test still passes: it constructs a fresh service, seeds only the Ask hint, and denies microphone permission. It therefore cannot detect the advertised failure of inheriting a conversation from an abandoned gateway capture. The reverse Work-to-chat test does establish its prior lane correctly.
- **Smallest fix:** Add separate fixtures establishing a non-nil existing-conversation pin and a minted-conversation pin through the public service seams. Assert each precondition, preserve that state while arranging `.idle`, then start Work and assert clearing. The negative controls must fail when the corresponding production clear is removed.

