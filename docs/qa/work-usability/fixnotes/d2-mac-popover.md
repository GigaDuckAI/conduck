# d2-mac-popover — coordinator-owned Work recorder, popover Work HUD, Work-only compose

Slice D2. Two files edited (`MenuBar/MenuBarCoordinator.swift`,
`MenuBar/DictationPopoverView.swift`) plus one new test class. d1's scaffold
`MenuBar/MenuBarCoordinator+WorkContract.swift` is gone (moved out by the
orchestrator) — every member it declared is implemented for real on
`MenuBarCoordinator` itself.

## What changed

### `Conduck/Conduck/MenuBar/MenuBarCoordinator.swift`

- **`let workVoiceRecorder = InAppAudioRecorder(retryDestination: .work)`** — ONE
  instance for the app's lifetime, held on the coordinator rather than in the
  popover's view state, because the popover's hosted SwiftUI view is torn down
  while the mic is live and a view-owned recorder would be unstoppable.
- **`MenuBarComposeState`** replaces the single stored `quickDraft`. Two texts
  (`chatText`, `workText`) plus a `private(set) target`. `quickDraft` survives as
  a computed passthrough into `chatText`, so every existing call site and the
  macOS-gated `MenuBarCoordinatorQuickTypedTests` are untouched; `quickWorkDraft`
  is the new Work slot and `composeTarget` is the read-only aim.
- **`hasWorkComposeState`** — the Work surface's own commit gate. Deliberately
  NOT folded into `hasComposeState`, which also decides whether a gateway
  destination PICK survives a dismissal: a Work composition has no destination to
  pin and must not keep one alive.
- **Work-only compose:** `openComposeForWorkOnly()`, `closeWorkOnlyCompose()`
  (leave the surface, park the words — the ⌘⇧1 answer), `discardWorkOnlyCompose()`.
- **Work voice lane:** `workCaptureIsActive`, `isStartingWorkVoiceCapture`,
  `beginWorkVoiceCapture()`, `finishWorkVoiceCapture()`,
  `restartWorkVoiceCapture()`, `cancelWorkVoiceCapture()`, and the private
  `noteWorkCaptureFinished(_:)` / `presentWorkVoiceStartRefusal()`.
- **`workCaptureFeedbackIsShowing`** — `quickWorkCaptureFeedback != nil`.
- **`saveQuickDraftToWork()`** now commits `compose.activeText` (so the Chat
  surface's "Add to Work" button and the Work surface's Return are ONE path), and
  **drains inline** after `publishAppCapture` — `try? await
  WorkCaptureDrainer(sourceDevice: SourceDevice.current).drainAvailableCaptures()`,
  exactly as `WorkVoiceScreenshotCoordinator.publish` does. Without it the
  envelope sits unimported and "Added to Work" names a card that is not on the
  board.
- **`sendQuickTypedDraft()`** gains `guard compose.target == .chat else { return }`
  as its first line — the gateway refusal asserted where the gateway path begins,
  not only in the view that hides the button.
- **`cancelActiveCapture()`** now also cancels a live Work recording (invisible to
  `dictationService`, so an Esc that skipped it would close the popover over a
  running mic) and discards the composition ON SCREEN only — a parked Work draft
  is not thrown away by an Esc pressed over the Chat surface, and vice versa.
- **Below the file's closing `#endif`**, three cross-platform value types:
  `MenuBarComposeTarget`, `MenuBarComposeState`, `MenuBarWorkVoiceStatus`. They
  sit outside the platform gate on purpose — the lane that runs `ConduckTests` is
  an iOS simulator, and a rule sealed inside `#if os(macOS)` compiles to nothing
  there, so assertions about it would be assertions about an empty file. Nothing
  in them touches AppKit or knows what a popover is.

### `Conduck/Conduck/MenuBar/DictationPopoverView.swift`

- **`content` router gains a new FIRST arm**
  `if coordinator.workCaptureIsActive { workCaptureView }`, above even a live chat
  recording (the two lanes cannot both hold the mic, and this popover is the only
  surface a ⌃⌘W capture has). `showsHeader`, `hasFooterControls` and
  `showsComposeSurface` all stand down under it.
- **`workCaptureView`** — a compact HUD at `recordingStatusView`'s geometry:
  status line, then `RecordingStatusIndicator` (live) / install progress /
  the recorder's typed error, then the controls, then the desk sheet's privacy
  line. Stop and Save + Cancel-X while recording; Try Again + Record Again +
  Close on a retryable unfinished capture; Cancel Transcription while working.
  No destination picker, no Ask, no "send".
- **`MenuBarWorkVoiceStatus`** carries the state→key mapping. The desk sheet's own
  mapping is `private` inside `WorkboardVoiceCaptureView.statusCopy`, which I may
  not edit, so it is duplicated minimally here — see Requests.
- **`workFeedbackRow(_:)`** — one acknowledgement row used in both places it is
  drawn. The **saved** row is now a BUTTON reaching `openWorkboard()`
  (`NSApp.activate` + post `.showWorkboard`, then `dismiss()` — the same two lines
  `MenuBarController.openWorkFromMenu` uses). The failed row stays inert.
- **`workFeedbackBand`** — the standalone acknowledgement for the lanes with no
  compose surface under them (a ⌃⌘W voice capture). Rendered in `body` only when
  `!showsComposeSurface`, so it is never drawn twice.
- **`AccessibilityAnnouncer` moved to `body`.** The feedback announcer used to
  live on `composeSurface`, which a voice capture never mounts; a second hook
  announces the HUD's status line on the same terms the desk sheet does.
- **Compose surface has two aims.** Aimed at Work it titles itself "Add to Work",
  edits `quickWorkDraft`, routes `.onSubmit` and ⌘Return to `saveQuickDraftToWork()`,
  shows a Cancel, and the Ask affordance is **absent** (`if !isWorkOnly`), not
  disabled — a greyed Ask still says the words could be sent from here.
- **`startEmptyState`** gains a second hotkey line rendered from
  `KeyboardShortcuts.getShortcut(for: .captureToWork)`, i.e. the user's actual
  binding, exactly as the ⌘⇧1 line does.

### `Conduck/ConduckTests/MenuBarWorkCaptureStateTests.swift` (new)

19 tests. Cross-platform (the rules it asserts are outside the gate), so it
actually runs in the iOS lane.

## New API

On `MenuBarCoordinator` — the six the contract with d1 names, plus four the
popover needs:

```swift
let workVoiceRecorder: InAppAudioRecorder          // = InAppAudioRecorder(retryDestination: .work)
var workCaptureIsActive: Bool { get }
var workCaptureFeedbackIsShowing: Bool { get }
@discardableResult func beginWorkVoiceCapture() async -> Bool
func finishWorkVoiceCapture() async
func openComposeForWorkOnly()

private(set) var isStartingWorkVoiceCapture: Bool
func restartWorkVoiceCapture() async
func cancelWorkVoiceCapture()
func closeWorkOnlyCompose()                        // leave Work, park the words (see Requests)
func discardWorkOnlyCompose()                      // throw the Work composition away

private(set) var compose: MenuBarComposeState
var quickDraft: String { get set }                 // → compose.chatText (unchanged name + shape)
var quickWorkDraft: String { get set }             // → compose.workText
var composeTarget: MenuBarComposeTarget { get }
var hasWorkComposeState: Bool { get }
```

Cross-platform value types (file scope, below the `#endif`):

```swift
enum MenuBarComposeTarget: String, Equatable, Sendable, CaseIterable { case chat, work }

struct MenuBarComposeState: Equatable, Sendable {
    var chatText: String
    var workText: String
    private(set) var target: MenuBarComposeTarget
    var activeText: String { get set }
    var activeTextIsBlank: Bool { get }
    mutating func aimAtWork()
    mutating func returnToChat()
    @discardableResult mutating func clearActive(ifStillEqualTo committed: String) -> Bool
    mutating func discardActive()
}

enum MenuBarWorkVoiceStatus: String, Equatable, Sendable, CaseIterable {
    case starting = "workboard.voice.starting"
    case listening = "workboard.voice.listening"
    case transcribing = "workboard.voice.transcribing"
    case preparing = "workboard.voice.preparing"
    case stopped = "workboard.voice.error.title"
    static func resolve(_ state: InAppAudioRecorderState) -> MenuBarWorkVoiceStatus
}
```

**`workCaptureIsActive` diverges from the scaffold's stub comment, deliberately.**
The stub said `.error` is never active. Here `.error` IS active when
`workVoiceRecorder.canRetryWorkCapture` — a capture that published a card and then
could not get its words is UNFINISHED, its recording is on the desk, and the HUD
owning the Try Again that finishes it has to outrank everything else the popover
could show. A REFUSED start (busy mic, denied permission) owns nothing, is
cleared off the recorder immediately, and surfaces as a banner instead. Knock-on
for d1: `finishWorkVoiceCapture()` on a second ⌃⌘W press in that state runs
`retryWorkCapture()` rather than no-opping, which is the same thing the desk
sheet's Try Again does.

## New strings

Five rows. Every other string on these surfaces reuses an existing key.

```
workboard.menuBar.compose.work.title | Add to Work | Header on the macOS menu-bar compose surface while it is aimed at the Work desk (⌃⌘W), so it cannot be mistaken for the Chat compose surface. Same words as the button `workboard.menuBar.addToWork`, kept a separate row because one is a title and one is a control.
workboard.menuBar.compose.work.placeholder | Write a note for your desk | Placeholder in the macOS menu-bar compose field while it is aimed at Work. The Chat placeholder (`workboard.menuBar.compose.placeholder`) says "message", which is not what this field does.
workboard.menuBar.saved.open.help | Open Work and see the new card | Tooltip on the "Added to Work" acknowledgement in the macOS menu-bar popover, which is a button that opens the desk.
workboard.menuBar.voice.cardMissing | That recording is no longer on your desk. | Shown after a menu-bar voice capture whose card was deleted while speech recognition was in flight, where "Added to Work" would be false.
popover.start.workShortcut | Press %@ to keep a private note | macOS menu-bar popover start state: the second hotkey hint, beside the ⌘⇧1 talk line. %@ is the user's ACTUAL Capture-to-Work binding, not the ⌃⌘W default.
```

Note the last one is written at the call site as an interpolated
`defaultValue: "Press \(workShortcut.description) to keep a private note"`, so the
catalog row carries `%@`.

Reused, no new row: `workboard.voice.starting/.listening/.transcribing/.preparing/
.error.title/.stop/.tryAgain/.recordAgain/.cancelTranscription/.privacy` ·
`pendingRetry.card.busy` · `workboard.menuBar.saved` · `workboard.menuBar.addToWork`
(+`.help`) · `workboard.menuBar.ask` (+`.help`) · `workboard.menuBar.compose.placeholder`
· `common.cancel` · `common.close` · `recording.oneMinuteLeft` (via
`RecordingStatusIndicator`) · and the bare English literal
`"Microphone is in use by another recording."`, reused verbatim from
`DictationService.beginRecordingSession` for the same lease refusal.

## Tests

`MenuBarWorkCaptureStateTests` (new, 19 tests): the aim-with-the-words rules
(a click-away releases neither the words nor the aim; `returnToChat` parks rather
than loses; a commit consumes and releases; a composition that changed under the
commit keeps both; a discard touches only the composition on screen; whitespace
is nothing to commit), the recorder-state→catalog-key mapping including the
locked key list, and five source-shape claims the popover cannot be mounted to
prove (the Work HUD is the first content arm; Return branches on the aim and the
Work arm returns; the Ask affordance is gated out rather than disabled;
`sendQuickTypedDraft` refuses a Work-aimed composition; the saved acknowledgement
is a button that posts `.showWorkboard`; the desk commit drains before it
acknowledges; no popover path names a gateway hop).

Measured, `-derivedDataPath ~/Library/Caches/gigaduck-builds/work-d2/…`, no
`-configuration` flag anywhere:

| Run | Result |
|---|---|
| macOS `build` (`platform=macOS`) | exit 0, **0** `: error: `, `** BUILD SUCCEEDED **`, no new warnings in `MenuBar/` |
| iOS `build-for-testing` (sim `04DEF4F5`) | exit 0, **0** `: error: ` |
| `MenuBarWorkCaptureStateTests` | Executed **19** tests, 0 failures |
| `MenuBarInputModeTests` | Executed **11** tests, 0 failures |
| `MacMenuBarWorkShortcutDriftGuardTests` (d1's) | Executed **11** tests, 0 failures |
| `ErrorSurfaceDriftGuardTests` | Executed **7** tests, 0 failures |
| `WorkboardDeskSurfaceDriftGuardTests` | Executed **23** tests, 0 failures |
| `MacWorkbenchShellDriftGuardTests` | Executed **4** tests, 0 failures |
| `WorkboardCopyTruthGuardTests` | Executed **10** tests, **8 failures** — see below |

`scripts/add-spdx-headers.sh --check` exit 0; `git diff --check` clean.

**The 8 copy-guard failures are two known handoffs, neither of them a defect in
this slice.** Four are `testEveryWorkKeyInSourceHasACatalogRow` on my four new
`workboard.*` keys, which is exactly the state the plan puts implementers in
("only the serial copy agent opens a `.xcstrings` file") — they clear the moment
those rows land. The other four are
`testEveryWorkCatalogRowIsReferencedInSource` on `workboard.material.openFile`,
`workboard.material.file.ready`, `workboard.material.preview.unavailable.title`
and `…​.message`: those keys were referenced by
`Views/Workboard/PersonalWorkbenchView.swift` at HEAD (verified with
`git grep … HEAD`) and are unreferenced now that Slice A deleted
`WorkboardPreviewImage`. Neither file is mine.

## Requests

- **Copy agent** — the five rows above, plus the four ORPHANED rows Slice A left
  behind (`workboard.material.openFile`, `workboard.material.file.ready`,
  `workboard.material.preview.unavailable.title` / `.message`): the plan says
  those preview keys are "reused by the failure state or removed by the copy
  agent". Until both halves land, `WorkboardCopyTruthGuardTests` is red.
- **d1 / `MenuBarController.handleShortcutPress`** — in the TEXT-mode arm, call
  `coordinator.closeWorkOnlyCompose()` before `showPopover()` / `dismissPopover()`.
  ⌘⇧1 should bring back the Chat surface with the Work composition parked. It is
  a nicety, not a correctness dependency: without it a ⌘⇧1 press onto a live Work
  composition simply re-shows the Work surface, and the private words are still
  never offered to Chat's Return (the founder-QA line holds either way).
- **Whoever owns `Views/Workboard/WorkboardVoiceCaptureView.swift`** — its
  `statusCopy` / `accessibilityStatusMessage` state→key mapping is `private` and
  I may not edit that file, so `MenuBarWorkVoiceStatus` duplicates it minimally
  (five keys, one `switch`). If that file is opened again, route its mapping
  through `MenuBarWorkVoiceStatus.resolve` so one recorder state cannot grow two
  sentences. `MenuBarWorkCaptureStateTests.testTheStatusKeysAreTheOnesTheDeskSheetAlreadyRenders`
  is the tripwire in the meantime.
- **Docs pass** — spec §Work / §Where the surfaces differ: the Mac menu bar now
  has a Work HUD and a Work-only compose state on ⌃⌘W, and the popover's
  acknowledgement opens the desk.

## Nobody undo

- **The aim is stored WITH the words, and the two texts are separate slots.** Do
  not "simplify" `MenuBarComposeState` back to one draft plus a boolean the
  popover clears on close: an outside click is an IMPLICIT dismissal that keeps
  the composition, so a flag cleared there hands a private sentence to Chat's
  Return on the next ⌘⇧1. The plan calls this out by name.
- **`clearActive(ifStillEqualTo:)` is conditional on purpose.** A blanket clear
  would delete words typed during the publish `await` — words that were never
  published.
- **The Ask affordance is ABSENT on the Work surface, not disabled.** A greyed-out
  Ask still asserts the words could be sent from there.
- **`sendQuickTypedDraft`'s `guard compose.target == .chat`** is the refusal at the
  gateway path's entrance, not a duplicate of the view's `if !isWorkOnly`. Removing
  it because "the button is hidden anyway" re-opens the lane to any other caller.
- **The inline drain in `saveQuickDraftToWork` is what makes the banner true.**
  Its `try?` is deliberate: a drain that cannot reach the store is not a failed
  capture, the envelope stays queued, and the desk's own observer imports it.
- **`workCaptureIsActive` treats a retryable unfinished capture as active.** Do
  not narrow it to "recording or processing" to match the scaffold's comment —
  that hides the only Try Again a ⌃⌘W capture has.
- **`beginWorkVoiceCapture` never inspects `DictationService.state`.** The
  microphone lease is the authority; a second opinion derived from that state
  cannot see the main window's composer mic.
- **The three value types stay below the `#endif`.** Moving them inside
  `#if os(macOS)` silently empties `MenuBarWorkCaptureStateTests` on the iOS lane
  — it would still pass, having asserted nothing.

## Founder QA

Build and run the Mac app (menu-bar target). d1's steps first, then these.

**Voice mode (Settings → General → menu-bar input = Voice):**
1. Press **⌃⌘W**. The popover opens on a compact HUD: "Listening" + the red
   dot/timer + **Stop and Save** + an ✕. No gateway chrome, no destination
   picker, no Ask, nowhere the word "send" appears.
2. Speak, then press **⌃⌘W** again (or click Stop and Save). The HUD becomes
   "Turning speech into text…", then the popover falls back to its normal content
   with a green **"Added to Work. Nothing was sent."** row.
3. **Click that row.** The main window comes forward on the Work desk, with the
   new card on the board — *already there*, not appearing a moment later. (This
   is the inline drain; before it, the card only materialised when something else
   opened the desk.)
4. **Failure case — busy mic:** start a recording in the main window's composer,
   then press ⌃⌘W. Expect a red row reading **"Microphone is in use by another
   recording."** — the same sentence ⌘⇧1 gives — and no HUD, no recording.
5. **Failure case — no transcript:** with no STT API key configured (or airplane
   mode on a cloud provider), record a Work note and stop. Expect the HUD to stay
   with "Voice capture stopped" + the typed error + **Try Again** / **Record
   Again** / **Close**. Then open the desk: **the recording must already be a
   playable card there** — the words failed, the audio did not. Try Again should
   attach the words to that same card, not create a second one.
6. Press **Esc** during a recording: the popover closes and nothing is saved.

**Text mode (menu-bar input = Text):**
7. Press **⌃⌘W**. The compose surface opens titled **"Add to Work"**, placeholder
   "Write a note for your desk", with **Cancel** and **Add to Work** and *no Ask
   button at all*.
8. Type something, press **Return** (and separately, ⌘Return). Both save to Work
   and show the acknowledgement; nothing reaches a gateway.
9. **The retention case.** Press ⌃⌘W, type a few words, then **click outside** to
   dismiss. Press **⌃⌘W** again → the text is still there and still says "Add to
   Work".
10. **The crossover case.** With that Work text still parked, press **⌘⇧1**. The
    Work words must **not** appear as a Chat draft — you should see either the
    (empty) Chat compose surface or the Work surface still labelled "Add to Work",
    never your private sentence sitting in a field whose Return sends.
11. Press **⌘⇧1** and type normally: Return still sends to Chat, Ask is back, the
    "Add to Work" button beside it still works. **Nothing about ⌘⇧1 changed.**
12. On the Work surface press **Cancel**: the words are gone and the Chat surface
    (with its own untouched draft) comes back.
13. Empty popover, no reply yet: the start state should now show two hint lines —
    "Press ⌘⇧1 to talk" and "Press ⌃⌘W to keep a private note", both rendering
    *your* bindings if you remapped them in Settings → General.

## Open questions

- **The acknowledgement is sticky.** "Added to Work" stays until the next Work
  action clears it (a new capture, typing, another save) — it survives a popover
  close, matching the existing text-mode banner's behaviour and plan decision 8
  ("the popover holds the banner"). If the founder wants it to expire, the clean
  place is `popoverDidCloseHook`.
- **A parked Work composition has no visible home until ⌃⌘W is pressed again.**
  Nothing in the popover says "you have unsaved Work words". With d1's requested
  `closeWorkOnlyCompose()` call this becomes slightly more reachable-but-hidden;
  without it, ⌘⇧1 lands back on the Work surface, which is more discoverable but
  makes Chat compose momentarily harder to reach. Founder's call which reads
  better on the machine.
- **`workboard.voice.privacy` is long for a 340pt popover** (four lines at
  `.caption2`). It is the honest sentence and the copy guard pins its content, so
  I reused it verbatim rather than minting a short paraphrase that would have to
  make the same three promises in fewer words. Worth a look at QA.
