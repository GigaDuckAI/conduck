# d1-mac-controller — macOS hotkey, controller wiring, menu item, settings row, guard

Slice D1 of the Work usability wave: the ⌃⌘W lane's *plumbing*. The popover HUD and the
Work-only compose state are d2's; this note covers the shortcut, the controller, the menu
door, the Settings row and the drift guard.

## What changed

**`Conduck/Conduck/MenuBar/GlobalShortcut.swift`**

- `KeyboardShortcuts.Name.captureToWork`, default ⌃⌘W. Chosen over the ⌘⇧n series the other
  two shortcuts use because ⌘⇧3…5 are system screenshot shortcuts (no free neighbour) and
  ⌘⇧W sits one modifier away from close-window, which reads as a typo of it.

**`Conduck/Conduck/MenuBar/MenuBarController.swift`**

- `setup()` registers `.captureToWork` in the same weak-self `Task { @MainActor }` shape as
  the other two, routed to `handleWorkCapturePress()`.
- `handleWorkCapturePress()` — new. Press semantics of `handleRegionCapturePress` (second
  press stops and saves) minus `isQuickCaptureKnownUnavailable` and minus
  `armQuickCapture()`: the desk is local, so a gateway-readiness refusal would deny the one
  capture lane that still works when every gateway is down, and arming would bind a private
  note to the quick CHAT lane's destination snapshot. Order: active → `finishWorkVoiceCapture()`;
  text mode → `openComposeForWorkOnly()` then `showPopover()`; voice → `showPopover()`,
  the existing `CompletionFeedbackPlayer.play(mode: "sound")` start cue, then
  `beginWorkVoiceCapture()` (return value dropped — the coordinator owns the refusal banner).
- `showWorkCaptureInstead()` — new, plus a one-line gate at the top of `handleShortcutPress`,
  `handleRegionCapturePress` and `startRecordingFromMenu`. **Beyond the brief; see Requests.**
  While the Work microphone is LIVE, an Ask press cannot start anything (the
  `SpeechExclusivity` lease refuses it) — it can only push `DictationService` into `.error`,
  where the Work HUD hides it, and that stale "Microphone is in use" error then surfaces the
  instant the Work capture ends, attached to a press made a minute earlier (⌘⇧2 would also
  spend a region drag first). The gate shows the capture that IS running instead. Scoped to
  a live recording, not to `workCaptureIsActive`: the mic is released at the stop, so a
  capture still owing its transcript blocks nothing.
- `workRecordingIsLive` / `workCaptureIsBusy` — new private computed properties over
  `coordinator.workVoiceRecorder.state`. Two of them on purpose: only a LIVE mic may pin the
  popover, while the status item narrates the whole busy window (recording + the
  transcription after it).
- `observe()` (inside `observeStateChanges()`) tracks `coordinator.workVoiceRecorder.state`.
  Without it `dictationService.state` reads `.idle` throughout a Work capture, so nothing
  re-evaluates the popover behaviour or the icon while the mic is live.
- `updatePopoverBehavior()` pins `.applicationDefined` for a live Work recording, ahead of
  the `dictationService` switch — same rule as a chat recording, same reason (a click-away
  must not orphan an audio session).
- `updateIcon()` resolves a busy Work recorder first, to the SAME two glyphs the chat lane
  uses (`record.circle.fill` / `ellipsis.circle.fill`), and suppresses both status dots while
  busy (they narrate settled chat replies).
- `handleStateChange()`'s `.idle` branch no longer reports the quick thread as visible while
  `coordinator.workCaptureIsActive` — the surface on screen is the Work HUD, so marking that
  thread read would clear an unread mark for a reply nobody saw.
- `showContextMenu()` gains "Record to Work…" immediately after `screenshotAskItem` (no key
  equivalent — ⌃⌘W is owned by KeyboardShortcuts), targeting `captureToWorkFromMenu()`, which
  is a one-line call into `handleWorkCapturePress()` so the two doors cannot acquire
  different rules. "Open Work…" is untouched.

**`Conduck/Conduck/Views/Settings/MacGeneralCategory.swift`**

- `shortcutSection` gains a third row, identical in shape to the other two:
  `KeyboardShortcuts.Recorder(for: .captureToWork)`, icon `tray.and.arrow.down`.

**`Conduck/ConduckTests/MacMenuBarWorkShortcutDriftGuardTests.swift`** — new (below).

The scaffold `MenuBar/MenuBarCoordinator+WorkContract.swift` this slice wrote while d2 was
in flight is **gone** — the orchestrator moved it out once d2 landed, and both the macOS
build and the iOS build are green against d2's real implementation. Nothing references it.

## New API

```swift
// GlobalShortcut.swift (macOS)
extension KeyboardShortcuts.Name {
    static let captureToWork = Self("captureToWork", default: .init(.w, modifiers: [.control, .command]))
}

// MenuBarController.swift — all private
private func handleWorkCapturePress()
private func showWorkCaptureInstead()
private var workRecordingIsLive: Bool
private var workCaptureIsBusy: Bool
@objc private func captureToWorkFromMenu()
```

Consumed from d2 exactly as contracted, no deviation: `coordinator.workVoiceRecorder`,
`workCaptureIsActive`, `beginWorkVoiceCapture() async -> Bool`,
`finishWorkVoiceCapture() async`, `openComposeForWorkOnly()`.
`workCaptureFeedbackIsShowing` is not read by the controller — the popover owns that banner
and nothing in the status item or the popover behaviour depends on it.

## New strings

App catalog (iOS/macOS), both NEW keys:

```
menu.recordToWork | Record to Work… | macOS status-item context-menu item that starts a Work capture — the menu counterpart of the ⌃⌘W shortcut.
settings.mac.general.shortcut.captureToWork.label | Capture to Work | Label of the Settings → General row whose recorder remaps the Capture to Work shortcut.
```

Neither is a `workboard.*` key, so `WorkboardCopyTruthGuardTests`' bidirectional catalog
check does not cover them — they still need catalog rows from the copy agent or they render
from `defaultValue:` and can never be translated. No watch-catalog strings. No App Intent
title or description touched.

## Tests

New: `MacMenuBarWorkShortcutDriftGuardTests` (`Conduck/ConduckTests/`, auto-joins the
synchronized target). Reads the three `#if os(macOS)` files this suite never compiles
through `RefusalLaneSource`, comment-stripped and whitespace-squeezed, each assertion scoped
to ONE function body so a forbidden-call check means "not in THIS handler". 11 tests:
the ⌃⌘W declaration and its default; `setup()`'s registration; the handler's absence of
`armQuickCapture` / `isQuickCaptureKnownUnavailable` / `handleQuickSend`; its stop-and-save,
input-mode branch and both coordinator entry points; the recorder in the observed set; the
popover pin; the icon; the three Ask doors' stand-down; the menu item's position between
Screenshot & Ask and Open Conversations plus its shared handler; the Settings recorder and
its label key; and a control test proving the squeeze ignores formatting AND that a comment
can neither satisfy nor fail a guard.

Measured, `-derivedDataPath ~/Library/Caches/gigaduck-builds/work-d1/…`, no `-configuration`:

| Run | Result |
|---|---|
| `MacMenuBarWorkShortcutDriftGuardTests` | **11 tests, 0 failures** |
| `MacWorkbenchShellDriftGuardTests` | **4 tests, 0 failures** |
| `MenuBarInputModeTests` | **11 tests, 0 failures** |
| all three in one invocation | **26 tests, 0 failures**, 3 `Test Suite … started` lines (no vacuous filter) |
| `ErrorSurfaceDriftGuardTests` | **7 tests, 0 failures** (this slice draws no Retry control; no registry row needed) |
| iOS `build-for-testing` (sim `04DEF4F5`) | exit 0, **0** `: error: ` |
| macOS `build` (`platform=macOS`) | exit 0, **0** `: error: ` — the only compile check for every file in this slice |

`WorkboardCopyTruthGuardTests` currently fails 8 assertions, all of them `workboard.*` keys
belonging to OTHER slices awaiting the serial copy agent (`workboard.menuBar.compose.work.*`,
`workboard.menuBar.saved.open.help`, `workboard.menuBar.voice.cardMissing`,
`workboard.material.file.ready`, `workboard.material.openFile`, …). None is mine and none is
in a file I own.

## Requests

1. **Copy agent** — the two rows under New strings.
2. **d2 / `DictationPopoverView.startEmptyState`** — name the shortcut. The empty state is
   the only place a first-time user meets the menu bar's capabilities, and Work is now the
   one lane that works with no gateway configured, which is exactly the state that empty
   state describes. A line in the ⌘⇧1/⌘⇧2 idiom ("⌃⌘W saves to Work") is enough; the
   context-menu item and the Settings row are the only other doors.
3. **d2 / `DictationPopoverView`** — a Work capture sitting in its retryable-error state
   keeps `workCaptureIsActive == true`, so the Work HUD outranks the popover's other
   content indefinitely. My stand-down gate is deliberately narrower (a LIVE mic only), so a
   ⌘⇧1 press in that window DOES start a chat recording — whose own HUD the Work branch then
   hides. Either the Work HUD should yield to a live chat capture, or the desk's Try Again
   should be reachable from something smaller than a full-height HUD. Not mine to decide.
4. **Docs pass** — README's per-surface Work row and the spec's §Where the surfaces differ
   want ⌃⌘W, the "Record to Work…" menu item and the Settings row; `project-structure.md`
   needs no new entry (no new folder, and `MenuBar/` already has a row).

## Nobody undo

- **`handleWorkCapturePress` must never grow `armQuickCapture()` or an
  `isQuickCaptureKnownUnavailable` guard**, however much it comes to look like its two
  neighbours. The first binds a private capture to the chat lane's destination snapshot; the
  second refuses a purely local capture because a REMOTE gateway is unreachable — which
  breaks Work precisely in the situation Work is most useful. `handleQuickSend` must never
  appear on this lane at all. The drift guard asserts all three by name.
- **The Work recorder stays in the observation set** and the popover pin stays keyed to
  `workRecordingIsLive`. `dictationService.state` is `.idle` for the whole Work capture, so
  dropping either one silently returns the popover to `.transient` while the mic is live —
  one outside click then orphans the audio session, and nothing about the code looks wrong.
- **`workRecordingIsLive` and `workCaptureIsBusy` are two properties, not one.** Pinning the
  popover on the wider one would lock it open through the transcription; narrowing the icon
  to the live mic would drop the busy glyph the moment the user stops speaking.
- **The menu item calls `handleWorkCapturePress()` and nothing else.** Inlining its logic is
  how the menu door loses the stop-on-second-press or the text-mode branch a release later.
- **The Ask stand-down gate is `workRecordingIsLive`, never `workCaptureIsActive`** — the
  wider flag would block Ask for as long as an unfinished Work capture waits for its
  transcript, which can be hours.

## Founder QA

Signed Mac, Conduck running in the menu bar. **First, before anything else: confirm ⌃⌘W is
free on your Mac** (System Settings → Keyboard → Keyboard Shortcuts, and any launcher you
run — Raycast/Alfred). If it is taken, the hotkey silently does nothing and step 1 fails for
a reason that has nothing to do with this code; remap it in step 6 and continue.

1. **Voice mode, happy path.** Settings → General → "Ask with" = Voice. Press ⌃⌘W from any
   other app. The popover opens with the Work HUD, you hear the start cue, the menu-bar icon
   becomes the red record dot. Speak a sentence. Press ⌃⌘W again → the HUD resolves to
   "Added to Work". Click that → the desk opens with a new voice card carrying your words.
2. **Click-away is refused.** Start a capture with ⌃⌘W and click on another app's window
   while the red dot is showing. The popover must STAY OPEN. (If it closes, the recording is
   orphaned — that is the failure this pins.)
3. **Text mode.** Settings → General → "Ask with" = Text. Press ⌃⌘W. The compose surface
   opens already saying **Add to Work** (never "Ask"), with no Ask affordance. Type a line,
   press Return → it saves to the desk. Then press ⌘⇧1: the compose surface must come back
   in its ordinary **Chat** state, and Return there must send to Chat — the two must never
   share a retained composition. Failure case: your Work words reappearing in the Chat
   composer, or a Chat header over a Work draft.
4. **Menu door.** Right-click (or control-click) the menu-bar duck. "Record to Work…" sits
   directly under "Screenshot & Ask…", above "Open Conversations". It behaves exactly like
   ⌃⌘W in whichever input mode you are in. "Open Work…" is still further down and unchanged.
5. **Ask is refused while Work records.** Start a Work recording (⌃⌘W), then press ⌘⇧1 and
   ⌘⇧2 while the red dot is showing. Neither may start anything: the popover just shows the
   running Work capture. **Failure case to watch for:** finish the Work capture and wait —
   a red "Microphone is in use by another recording." error appearing AFTER the capture is
   saved means the stand-down gate regressed.
6. **Remap.** Settings → General → Keyboard Shortcut. Three rows now: Ask, Screenshot & Ask,
   **Capture to Work** (tray icon), the last showing ⌃⌘W. Click it, press a different combo
   (e.g. ⌃⌥W). The new combo starts a Work capture; the old ⌃⌘W does nothing.
7. **No gateway, still works.** This is the point of the lane: with no gateway configured (or
   the Keychain locked), ⌘⇧1 refuses with the popover's "nothing to send to" empty state,
   while ⌃⌘W still records and still saves. If ⌃⌘W refuses for a gateway reason, that is a
   regression of the whole slice.

## Open questions

- The context-menu item reads "Record to Work…" in BOTH input modes, though in text mode it
  opens a compose surface rather than a microphone (the brief specifies one item, one
  handler). A mode-conditional title the way `recordItem` does it would read better —
  "Add to Work…" in text mode — at the cost of one more key. Founder call.
- With a Work capture busy, the status item shows the Work glyph even if a chat reply is in
  flight, so the 6th "sparkles" state and both status dots are suppressed for that window.
  Deliberate (a capture in hand outranks an ambient marker), and it resolves the moment the
  capture finishes — but it is a visible precedence choice.
- ⌃⌘W is unbound on a stock macOS install as far as this slice can verify headlessly; only
  the founder's own machine can confirm it against installed launchers.
