# fix-r2-menubar — Codex R2 findings on the macOS menu-bar Work lane (Slice D)

Round-2 verifier reports: `docs/qa/work-usability/verify/codex-r2-menubar.json` (R1, R2 — the
two round-1 items the verifier reopened as `still-open`) and `codex-r2-cross.json` R2 (the Mac
voice receipt). Round-1 S1, S4 and S7 were closed by the verifier and are untouched here.

Files touched, all inside this slice's ownership:

- `Conduck/Conduck/MenuBar/MenuBarCoordinator.swift`
- `Conduck/Conduck/MenuBar/MenuBarController.swift`
- `Conduck/Conduck/Localizable.xcstrings` (ONE new row, cross R2)
- `Conduck/ConduckTests/MenuBarWorkCaptureStateTests.swift`
- `Conduck/ConduckTests/MacMenuBarWorkShortcutDriftGuardTests.swift`

`DictationPopoverView.swift` and `MenuBarInputModeTests.swift` are unchanged.

**Catalog rows added: 1** — `workboard.menuBar.voice.saved`, inserted in the file's exact
existing shape and alphabetical position (immediately after
`workboard.menuBar.voice.cardMissing`). The catalog was re-parsed after the edit:
2296 keys (2295 + 1), no duplicate keys, `json.load` clean.

---

## R1 — Click-away during startup still leaves a recording behind a closed popover · **fixed** (minor)

**Verified.** The R1 token fix honours an EXPLICIT cancel and nothing else. `workRecordingIsLive`
recognises only `.recording`, so `updatePopoverBehavior` left the popover `.transient` for the
whole startup — which is seconds long when a permission prompt or the speech preflight is in the
way — and neither `MenuBarController.popoverDidClose` nor `MenuBarCoordinator.popoverDidCloseHook`
bumps `workVoiceStartToken`. An outside click during the start therefore closed the popover, the
token check at the end of `beginWorkVoiceCapture` accepted the start as current, and the
microphone came up behind a closed popover with no surface anywhere to stop it.

**The verifier offered two fixes; this slice took the SECOND — pin the popover for the whole
start — and did not touch either close hook.** Reasons, in order:

1. It preserves the person's actual request. They pressed ⌃⌘W to record; cancelling that from an
   implicit gesture would drop a capture they asked for, which is the same class of loss the
   whole two-slot compose design exists to prevent. The pin instead makes the start behave like
   the recording it becomes: the popover stays, the HUD appears, and the mic is visible.
2. It is CONTINUOUS with the rule already shipping. A live Work recording pins the popover; the
   start is the prelude to that recording, and the gap between them existed only because the
   recorder reads `.idle` across it.
3. **The S7 close-hook guard needed no allowlist extension and got none.** Its denylist
   (`discardWorkOnlyCompose`, `closeWorkOnlyCompose`, `discardActive`, `clearCommitted`,
   `returnToChat`, `quickWorkDraft`, `compose.workText`, `cancelActiveCapture`) is intact and
   both hook bodies are byte-for-byte what round 1 left. The alternative fix would have required
   deliberately widening that guard; this one does not, so the guard keeps its full strength.

**Fixed** — the pin now covers the claim and the start, not only the live recording.

- `MenuBarCoordinator.workVoiceStartIsInFlight` (new, public read) —
  `isSummoningWorkVoiceCapture || isStartingWorkVoiceCapture`, i.e. exactly the window
  `workVoiceRecorder.state` cannot describe because it reads `.idle` throughout.
- `MenuBarController.updatePopoverBehavior` — `if workRecordingIsLive || coordinator.workVoiceStartIsInFlight`
  resolves to `.applicationDefined`. The two are contiguous: `beginWorkVoiceCapture` sets
  `isStartingWorkVoiceCapture = true` in the same synchronous prefix that clears the summon flag,
  and drops it only after `startRecording()` returns, by which point `.recording` carries the pin.
- `MenuBarController.observeStateChanges` — `_ = coordinator.workVoiceStartIsInFlight` joins the
  tracked set. Without it nothing re-evaluates the behaviour when the start begins, and — the
  half that would bite harder — nothing RELEASES the pin when a refused start ends.
- `MenuBarController.handleWorkCapturePress` — `updatePopoverBehavior()` is called from the press
  itself, between the claim and the summon, so the pin does not wait on an observation tick.

Esc is unaffected: `handleEscape` routes through `cancelActiveCapture` (which bumps the token) and
then `performClose`, which closes an `.applicationDefined` popover just as it closes a transient
one. The explicit bail still works during the start; only the implicit one is refused.

**Pinned by** `MacMenuBarWorkShortcutDriftGuardTests.testTheWorkVoiceStartPinsThePopoverBeforeTheRecordingIsLive`
— the pin predicate, the `.applicationDefined` it resolves to, the observation entry, and the
press-time application, in order. Source shape for the same reason every guard in that file is:
`MenuBar/` is `#if os(macOS)` and an `NSPopover` behaviour is not mountable from an iOS test
bundle. **Measured red without the fix** (see Mutation check below).

## R2 — The initial Work voice summon still acknowledges an unread Chat reply · **fixed** (minor)

**Verified.** `handleWorkCapturePress` called `showPopover()` and only THEN hopped to
`beginWorkVoiceCapture`. During that summon `workCaptureIsActive` is still false, so
`showPopover`'s round-1 guard permitted `setPopoverVisibleConversation(displayedPopoverConversationID)`
— which synchronously runs `noteConversationSeen` and clears the delivered banner. The round-1
`setPopoverVisibleConversation(nil)` inside `beginWorkVoiceCapture` lands a hop later and can only
stop FUTURE acknowledgements; an unread mark that has already been consumed does not come back.

**Fixed** — ownership is established BEFORE the summon.

- `MenuBarCoordinator.isSummoningWorkVoiceCapture` (new, `private(set)`) — true from the press
  until the start it schedules picks the capture up.
- `MenuBarCoordinator.claimPopoverForWorkVoiceCapture()` (new) — sets that flag and calls
  `setPopoverVisibleConversation(nil)`. Both halves matter: the flag makes `showPopover` stand
  down, and the nil is what takes the currently-visible thread off screen.
- `MenuBarCoordinator.workCaptureIsActive` — now `if isSummoningWorkVoiceCapture || isStartingWorkVoiceCapture`.
  `showPopover`'s existing guard reads this property, so the claim is only worth making while it
  counts. This also means the HUD is the popover's first content arm from the press rather than
  from the hop, so the summon no longer draws one frame of the quick thread either.
- `MenuBarCoordinator.beginWorkVoiceCapture()` — `isSummoningWorkVoiceCapture = false` as its
  FIRST statement, ahead of `guard !workCaptureIsActive`. This is load-bearing in both
  directions: the start must take the claim over or its own re-entrancy guard would refuse the
  very capture the press claimed the popover for, and clearing it unconditionally means a claim
  can never outlive the hop it was made for.
- `MenuBarController.handleWorkCapturePress` — `coordinator.claimPopoverForWorkVoiceCapture()`
  precedes `showPopover()` in the VOICE arm.

The TEXT arm is deliberately untouched and still summons without a claim: in text mode the popover
renders the thread above the compose band, so the reply genuinely is on screen and marking it seen
is correct. That is the same scoping round 1 chose for `workCaptureIsActive`.

**Pinned by** `MenuBarWorkCaptureStateTests.testTheWorkVoiceSummonTakesThePopoverBeforeItShowsIt`
— the claim precedes the voice summon; the only `showPopover()` ahead of it is the text arm's,
which `return`s (asserted as a shape AND as a count, so a second summon cannot be smuggled in);
the claim body raises the flag and clears the visible thread; `workCaptureIsActive` counts the
flag; and the start takes the claim over before its re-entrancy guard reads it.
**Measured red without the fix.**

## Cross R2 — Mac voice completion still denies its cloud transcription transfer · **fixed** (minor)

**Verified.** `noteWorkCaptureFinished` is the SUCCESS receipt for a spoken capture, and it printed
`workboard.menuBar.saved` — "Added to Work. Nothing was sent." — immediately after
`stopAndUpload()` handed the audio to `STTClient.shared.transcribe`, whose provider roster is
mostly cloud vendors. That is the one claim a privacy surface may never make: a denial printed
over the upload that produced the very words on screen.

**Fixed** — the voice lane gets its OWN receipt; the typed lane keeps the one that is true.

- New key `workboard.menuBar.voice.saved` = **"Added to Work. The words came from your speech
  provider."** — it names the destination instead of denying it, and it stays true on the
  on-device provider too (Apple's engine is still "your speech provider"). It mirrors the honest
  shape of `workboard.voice.privacy` without repeating its length: the receipt is a one-line
  banner, not the sheet's explanation.
- `MenuBarCoordinator.noteWorkCaptureFinished` prints the new key.
- `MenuBarCoordinator.saveQuickDraftToWork` still prints `workboard.menuBar.saved` — "Added to
  Work. Nothing was sent." is TRUE for a typed note: the words were written on the desk's own
  surface, and no code path carries them anywhere. That row is unchanged.
- `workboard.menuBar.voice.cardMissing` (the no-card failure arm) is unchanged.

The new row passes `WorkboardCopyTruthGuardTests` unchanged and needed no exemption: it contains
none of the retired words (`send/sent/draft/brief/dispatch`), so it does not need
`chatLaneKeys`, and it makes no inertness promise, so it does not need `outboundHopKeys`. Rule
(4) is satisfied in both directions — the row is referenced in app-target source, and the source
key has a row.

**Pinned by** `MenuBarWorkCaptureStateTests.testTheVoiceReceiptNamesItsSpeechProviderAndTheTypedNoteKeepsItsInertness`
— selection AND wording, both directions: the voice completion names the voice key and NOT the
typed one, the typed commit names the typed key and NOT the voice one, the shipped `en` row for
the voice key contains "speech provider" and none of "nothing was sent" / "nothing is sent" /
"nothing leaves", and the typed row still carries its inertness promise. The catalog is read from
disk rather than through `String(localized:)`, because the shipped row wins over a source
`defaultValue:` at runtime. **Measured red without the fix.**

---

## Nobody-undo check

Every round-1 entry still stands; none of their premises was disproved.

- **d2 — "`clearActive(ifStillEqualTo:)` is conditional on purpose"** (now `clearCommitted(_:aimedAt:)`):
  untouched.
- **fix-r1-menubar S7 — the close hooks may not name the composition:** untouched, and NOT
  extended. R1 was fixed at the popover-behaviour seam instead, which is why no allowlist
  change was needed. Both hook bodies are byte-identical to round 1 and the guard's denylist is
  unchanged.
- **fix-r1-menubar S2 — "`isStartingWorkVoiceCapture` is deliberately NOT cleared by the cancel":**
  untouched. The new `isSummoningWorkVoiceCapture` follows the same discipline in the same
  direction — it is cleared by the START that takes it over, never by a cancel, so a withdrawn
  request still reaches the microphone through `workVoiceStartToken`.
- **fix-r1-menubar S3 — visibility is scoped to the voice HUD, not to a Work-aimed compose
  surface:** preserved. The claim is made only in the VOICE arm of `handleWorkCapturePress`.

## Invariants

Durable-before-hop, one desk write, no gateway hop from the desk, frozen wire strings (neither
`Wire` enum touched; no wire literal added), no `.xcdatamodeld` edit, no envelope-schema edit: all
untouched. Nothing here adds, removes or reorders a store write or a network call — the changes
are one flag, one synchronous claim, one widened popover-behaviour predicate, one observation
entry, and one receipt key. `sendQuickTypedDraft`'s `guard compose.target == .chat` is untouched.
New copy is a NEW key; no existing row's value was edited.

## Measured

`-derivedDataPath ~/Library/Caches/gigaduck-builds/fix2-menubar/dd`, no `-configuration` anywhere.

| Run | Result |
|---|---|
| macOS `build` (`platform=macOS`) — the only compile check for `MenuBar/` | exit 0, **0** `: error: `, `** BUILD SUCCEEDED **` |
| iOS `build-for-testing` (sim `04DEF4F5`) | exit 0, **0** `: error: ` |
| all six suites in one invocation | **73 tests, 0 failures** |
| `MenuBarWorkCaptureStateTests` | **28, 0 failures** (26 + 2 new) |
| `MacMenuBarWorkShortcutDriftGuardTests` | **13, 0 failures** (12 + 1 new) |
| `MenuBarInputModeTests` | **11, 0 failures** |
| `MacWorkbenchShellDriftGuardTests` | **4, 0 failures** |
| `ErrorSurfaceDriftGuardTests` | **7, 0 failures** |
| `WorkboardCopyTruthGuardTests` | **10, 0 failures** |

### Mutation check — the three new tests are RED without their fixes

Because all three read the shipped source and catalog from disk, redness is measurable without
recompiling. The three production edits were reverted in place, the three new tests run, and the
files restored immediately (backups taken first; `diff -q` clean after restore):

| Reverted | Result |
|---|---|
| the claim + press-time pin removed from `handleWorkCapturePress`, `updatePopoverBehavior` back to `if workRecordingIsLive {`, receipt back to `workboard.menuBar.saved` | **3 tests, 4 failures** — all three new tests failed |

Re-run after restore: 73/0 across the six suites (one environmental restart mid-run, below), then
`WorkboardCopyTruthGuardTests` alone 10/0.

**One environmental flake, recorded rather than hidden.** In the final six-suite run
`WorkboardCopyTruthGuardTests.testEveryWorkCatalogRowIsReferencedInSource` — the slow one, which
enumerates the whole source tree — died with `Restarting after unexpected exit, crash, or test
timeout`; the runner relaunched and the remaining 9 passed, with zero assertion failures anywhere.
Re-run 75 s later in isolation: **10 tests, 0 failures**. Same signature round 1 recorded: three
fixers sharing one simulator UDID, not a defect.

## Open items

None. Both reopened round-1 findings and the cross-cutting receipt are fixed; nothing was
deferred.
