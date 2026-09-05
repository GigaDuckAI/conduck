# fix-r1-menubar — Codex R1 findings on the macOS menu-bar Work lane (Slice D)

Round-1 verifier report: `docs/qa/work-usability/verify/codex-r1-menubar.json` (S1–S4) plus
the cross-cutting S7 handed over mid-run. Files touched, all inside this slice's ownership:

- `Conduck/Conduck/MenuBar/MenuBarCoordinator.swift`
- `Conduck/Conduck/MenuBar/MenuBarController.swift`
- `Conduck/ConduckTests/MenuBarWorkCaptureStateTests.swift`
- `Conduck/ConduckTests/MacMenuBarWorkShortcutDriftGuardTests.swift`

`DictationPopoverView.swift` is unchanged: every finding that pointed at it (S4) turned out to
be fixable at the coordinator seam it reads, which is also the seam a second caller could reach.

**No catalog rows added or changed.** None of these fixes prints a new sentence — each one
changes which composition is consumed, which microphone survives, which thread counts as
looked-at, and which display override is standing. `Localizable.xcstrings` is untouched by
this fixnote's work.

---

## S1 — Save completion consumes the currently selected composition · **fixed** (major)

**Verified.** `saveQuickDraftToWork` snapshotted only the TEXT
(`let draftAtCommit = compose.activeText`) and, two `await`s later, called
`clearActive(ifStillEqualTo:)`, whose guard read `activeText` — i.e. whichever slot the
surface happened to be aimed at on return. A ⌃⌘W (or ⌘⇧1) pressed during the publish+drain
therefore compared the published words against the OTHER slot, matched nothing, and left the
already-saved private sentence sitting in the Chat draft, where the next ⌘⇧1 offers it to a
Return that sends. The mirror case is worse in a quieter way: a Work commit that fails to
consume can be saved a second time.

**Fixed** — the snapshot now names the SLOT as well as the words, and the consume names it back.

- `MenuBarComposeState.text(for:)` / `setText(_:for:)` — slot access by aim, not by "active".
- `MenuBarComposeState.clearCommitted(_:aimedAt:)` replaces `clearActive(ifStillEqualTo:)`:
  it compares and clears the slot the commit was TAKEN from, keeps the conditional-consume
  rule intact (a slot that changed under the `await` keeps its words and its aim), and hands
  the surface back to Chat **only if the surface is still showing the consumed slot** — a
  composition the person navigated to mid-save is never re-aimed under them.
- `MenuBarCoordinator.saveQuickDraftToWork` — `let aimAtCommit = compose.target` beside the
  text snapshot, `compose.clearCommitted(draftAtCommit, aimedAt: aimAtCommit)` at completion.

**Pinned by** (`MenuBarWorkCaptureStateTests`):
`testACommitConsumesTheSlotItTookTheWordsFromEvenAfterTheSurfaceIsReAimed` (the verifier's exact
scenario: Chat words committed, ⌃⌘W under the save → Chat slot emptied, Work composition
untouched, aim left on Work), `testACommitOnAParkedSlotLeavesTheSurfaceWhereTheUserPutIt` (the
mirror: Work commit with ⌘⇧1 under it), and `testTheDeskCommitSnapshotsTheSlotItIsConsuming`
(source shape: the commit still snapshots the aim and still names it in the consume — the value
rule is only worth having if the production commit uses it). The two pre-existing rules
(`…IsConsumedAndReleasedBackToChat`, `…ChangedUnderTheCommitKeepsItsWordsAndItsAim`) carry over
onto the new signature unchanged.

**Nobody-undo check:** d2's "`clearActive(ifStillEqualTo:)` is conditional on purpose" stands —
the conditionality is untouched; only the *identity of the slot being compared* changed, which
is the half that entry did not cover. The rename is deliberate: `clearActive` now names
something the method no longer does.

## S2 — Cancellation during startup can leave an unseen recording · **fixed** (minor)

**Verified.** `InAppAudioRecorder.startRecording()` leaves `state == .idle` for its entire
duration (the speech preflight, the mic lease, the HAL start), and `.idle` is the one arm of
`cancelWorkVoiceCapture` that does nothing. An Esc during the start therefore closed the
popover, and the microphone came up a moment later behind it with no surface anywhere to stop
it — `MenuBarController.handleStateChange` only re-opens for CHAT recorder states, and the
chat recorder is idle throughout a Work capture.

**Fixed** — the start carries a token, and a cancellation invalidates it.

- `MenuBarCoordinator.workVoiceStartToken` (private) — bumped on every start and on every cancel.
- `beginWorkVoiceCapture()` — takes `startToken` BEFORE the suspension; after it,
  `guard startToken == workVoiceStartToken else { cancelWorkVoiceCapture(); return false }`,
  which tears down a microphone that came up into a withdrawn request (`.recording` →
  `cancelRecording()`, a refusal → `dismissError()`) and prints no banner, because the person
  already withdrew the request.
- `cancelWorkVoiceCapture()` — `workVoiceStartToken &+= 1` ahead of its state switch.

`isStartingWorkVoiceCapture` is deliberately NOT cleared by the cancel: it is the recorder's
own re-entrancy guard's twin (`workCaptureIsActive` gates `beginWorkVoiceCapture`), and
clearing it early would let a second ⌃⌘W land inside the first start's suspension, where
`InAppAudioRecorder.isStarting` refuses it silently and the refusal banner would name a
microphone conflict that does not exist. The HUD therefore lingers for the tail of the start
and then disappears — invisible on the Esc path, which closes the popover anyway.

**Pinned by** `MenuBarWorkCaptureStateTests.testAStartCancelledUnderItsOwnSuspensionTearsTheMicrophoneDown`
(source shape, ordered: token taken before the `await`, checked after it, teardown behind the
check; and the cancel invalidates). Source shape rather than value, because the whole rule lives
inside a `#if os(macOS)` `async` method over a real `AVAudioRecorder` — there is nothing pure to
exercise, and the neighbouring guards in this file are shaped the same way.

## S3 — The Work HUD leaves a hidden conversation marked visible · **fixed** (minor)

**Verified.** A thread reported through `setPopoverVisibleConversation` is acknowledged as read
(`settleIfWatchedInPopover` → `noteConversationSeen`) and loses its arrival banner
(`postReplyBannerIfUnattended`). `showPopover` assigned it whenever the CHAT service was idle —
which it is throughout a Work capture — and the new `handleStateChange` guard only skipped
*re-assignment*, never cleared what was already assigned. A reply landing behind the Work HUD
was therefore marked read and silenced although its content was never on screen.

**Fixed** at both ends of the window:

- `MenuBarCoordinator.beginWorkVoiceCapture()` — `setPopoverVisibleConversation(nil)` as the
  capture takes the surface (before the start's suspension, so the window is never open).
- `MenuBarController.showPopover()` — `if dictationService.state == .idle, !coordinator.workCaptureIsActive`,
  so a summon onto a running capture (the status-item click, `showWorkCaptureInstead`) cannot
  re-assign one.
- Restoration needs no new code: `handleStateChange`'s `.idle` arm re-reports the thread the
  moment `workCaptureIsActive` goes false with the popover still open.

Scoped to `workCaptureIsActive` (the voice HUD), NOT to a Work-aimed compose surface: in text
mode the popover still renders `content` above the compose band, so the reply genuinely is on
screen and marking it seen is correct.

**Pinned by** `MenuBarWorkCaptureStateTests.testStartingAWorkCaptureTakesTheVisibleThreadOffScreen`
and `MacMenuBarWorkShortcutDriftGuardTests.testNoThreadIsReportedVisibleWhileTheWorkHUDOwnsThePopover`
(both ends: the summon stands down, and the settled-state callback — which is also the restore
path — keeps its guard).

## S4 — A read-only reply override blocks Work composition · **fixed** (minor)

**Verified.** `showsComposeSurface` returns false for a non-nil `popoverOverrideViewModel`
before it ever reaches the Work-target branch, and `openComposeForWorkOnly()` cleared only the
feedback banner. ⌃⌘W pressed over a dot-clicked read-only reply therefore aimed the composition
at Work and showed nothing — no field, no Add to Work, and no sight of words already parked there.

**Fixed** — `MenuBarCoordinator.openComposeForWorkOnly()` now calls `clearPopoverOverride()`
before `compose.aimAtWork()`. That call is display-only (`popoverOverrideViewModel = nil` +
`sweepRegistry()`): it arms no capture, latches no destination, and is explicitly not
`armQuickCapture()`, which this lane may never run.

**Pinned by** `MenuBarWorkCaptureStateTests.testWorkComposeClearsTheReadOnlyOverrideWithoutArmingAChatCapture`
— both halves, the clear AND the continued absence of `armQuickCapture`.

## S7 — The click-away test never exercises the production dismissal path · **fixed** (minor)

**Verified.** `testAClickAwayDismissalReleasesNeitherTheWordsNorTheAim` asserts over a copied
value, and a dismissal is the ABSENCE of a mutation — so the test passes identically whether or
not `MenuBarController.popoverDidClose` / `MenuBarCoordinator.popoverDidCloseHook` grows a
discard. The real seam is unmountable from this suite (`#if os(macOS)`, an `NSPopover` delegate
callback), so the guard is a source-shape one in the idiom of this file's other wiring checks.

**Fixed** — `MenuBarWorkCaptureStateTests.testNoPopoverCloseHookTouchesTheWorkComposition`
(new, plus a `controllerPath` constant) reads BOTH close hooks comment-stripped and asserts that
neither names `discardWorkOnlyCompose`, `closeWorkOnlyCompose`, `discardActive`,
`clearCommitted`, `returnToChat`, `quickWorkDraft`, `compose.workText`, or `cancelActiveCapture`.
The last one matters as much as the first: routing the close hook into the Esc teardown would
turn every implicit click-away into a discard without ever naming the Work composition. No
production code changed — the current hooks already satisfy it.

---

## Invariants

Durable-before-hop, one desk write, no gateway hop from the desk, frozen wire strings, no
`.xcdatamodeld` edit, no envelope-schema edit: all untouched. Nothing here adds, removes or
reorders a store write or a network call; the four code changes are a slot-identity fix, a
cancellation token, one visibility clear, and one display-override clear.
`sendQuickTypedDraft`'s `guard compose.target == .chat` is untouched and still refuses a
Work-aimed composition at the gateway path's entrance.

## Measured

`-derivedDataPath ~/Library/Caches/gigaduck-builds/fix-menubar/…`, no `-configuration` anywhere.

| Run | Result |
|---|---|
| macOS `build` (`platform=macOS`) — the only compile check for `MenuBar/` | exit 0, **0** `: error: `, `** BUILD SUCCEEDED **` |
| iOS `build-for-testing` (sim `04DEF4F5`) | exit 0, **0** `: error: ` |
| all five suites in one invocation | **60 tests, 0 failures**, 5 suite-start lines (no vacuous filter) |
| `MenuBarWorkCaptureStateTests` | **26 tests, 0 failures** (19 + 7 new) |
| `MacMenuBarWorkShortcutDriftGuardTests` | **12 tests, 0 failures** (11 + 1 new) |
| `MenuBarInputModeTests` | **11 tests, 0 failures** |
| `MacWorkbenchShellDriftGuardTests` | **4 tests, 0 failures** |
| `ErrorSurfaceDriftGuardTests` | **7 tests, 0 failures** |

**One environmental flake, recorded rather than hidden.** After the green 60/60 run,
later invocations of `ErrorSurfaceDriftGuardTests` died with
`Test crashed with signal kill before establishing connection` / `Early unexpected exit`,
on a DIFFERENT test each time and with zero assertion failures; mid-run this slice's build
cache directory was also deleted out from under it by another agent. Both are the signature
of parallel fixers sharing one simulator UDID and one cache root, not of a defect: the suite
is green in this slice's own full run, it reads shipping sources this slice does not own, and
the only edits made after its green run were two control `XCTAssertTrue` lines inside
`MenuBarWorkCaptureStateTests` (re-verified green, 26/26). The four other suites were re-run
green after that edit.

## Open items

None. Every finding is fixed; nothing was deferred as a design change.
