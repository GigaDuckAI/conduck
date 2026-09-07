# U-40 — Capture to Work, and one look for every menu-bar capture

`⌃⌘W` opens with the same drag-select overlay `⌘⇧2` uses. The picture is
optional decoration on a private note — Return skips it, Esc abandons the whole
press — and it lands on the desk as a card of its own beside the recording. A
voice capture submits at its stop, publishing picture and recording
independently, so a cancel before the stop leaves nothing and one after it keeps
what is already durable. The recording names the picture it was captured with,
and the desk DRAWS that pair as one card — the mechanism, and the rules that
decide it, are `u71-companion-card.md`. The three capture surfaces (`⌘⇧1` voice,
`⌘⇧2` Screenshot & Ask, `⌃⌘W` Capture to Work) now draw one HUD, and the
status-item menu separates its three capture commands from its two Open rows.

## What changed

### Menu

`showContextMenu()` names the Work action **"Capture to Work…"** under a new key
(`menu.captureToWork`; `menu.recordToWork` retired), adds `.separator()`
immediately after it, and renames the desk door to **"Open Work"** without an
ellipsis under `menu.openWorkDesk` (`menu.openWork` retired). The selector stays
`captureToWorkFromMenu` and still routes to `handleWorkCapturePress()`, so the
menu and the hotkey cannot acquire different rules, and every capture item keeps
`keyEquivalent: ""` (a responder-chain equivalent can double-fire while the menu
is key-tracking).

The rename is a NEW key rather than an edited value in three places, because a
shipped translation of "Record to Work…" is a different sentence from the one the
English row now carries.

### Region capture: an outcome, and a purpose

`RegionCaptureController.captureRegion(purpose:requiresMicrophone:)` answers
`RegionCaptureOutcome` instead of `Data?`:

| Case | Means | Ask does | Work does |
|---|---|---|---|
| `.captured(Data)` | PNG bytes for the dragged region | sends the question | stages the picture |
| `.skipped` | the person chose to go without a picture | unreachable — the lane emits none | records anyway |
| `.cancelled` | Esc, a sub-4pt drag, Cancel in an alert, an outside dismiss | aborts | aborts |
| `.unavailable` | re-entrant call, denied permission, SCK failure, empty shot | aborts | aborts |

One `nil` cannot carry that split, and guessing either way is a real failure: a
wrong `.skipped` starts a microphone nobody asked for, a wrong `.cancelled` drops
the note somebody did ask for. A sub-4pt drag stays a CANCEL on both lanes — a
stray click must never read as "record without a picture" — and a failed
ScreenCaptureKit grab is `.unavailable`, never `.skipped`, so Work never silently
saves a note that was supposed to carry a picture.

`RegionCapturePurpose` (`.ask` / `.work`) is injected into the overlay view and
is immutable there, so the hint, the Return key and the accessibility action can
never disagree about which lane is running:

- **Hint** — `.ask` keeps `regionCapture.overlay.hint`; `.work` draws
  `regionCapture.overlay.hint.work` ("Drag to capture · Return to skip · Esc to
  cancel"). Two keys, not a runtime-assembled string: the sentences differ in
  more than one clause and a translator handed a half-string cannot punctuate a
  list they cannot see.
- **Return** — key codes 36 and 76 (keypad Enter too, or a keypad Enter that did
  nothing reads as a frozen overlay) call `onSkip` on `.work` only. On `.ask` a
  Return stays unhandled: the pixels ARE the question.
- **VoiceOver** — the borderless overlay carries no controls, so it declares
  itself an accessibility element with the hint as its label, and on `.work`
  only it offers a `regionCapture.overlay.skipAction` ("Skip screenshot") custom
  action. Offering it on Ask would name an outcome that lane has no code for.

**Alert matrix.** Ask's bodies promise that the screenshot and the words go to
the configured gateway — false on a lane whose desk reaches none, and a
permission prompt is the worst possible place for reused copy. Every Work SCREEN
RECORDING stop offers a third button, `regionCapture.permission.skipScreenshot`
("Continue Without Screenshot"), with Cancel LAST so Return never lands on the
choice that abandons the capture. The microphone alert offers none, and the
matrix below says why: a missing mic stops the recording, not the picture.

| Stop | Ask body / buttons | Work body / buttons |
|---|---|---|
| Microphone denied | `…mic.body` (names the gateway) · Open System Settings, Cancel | `…mic.work.body` · Open System Settings, Cancel — **no skip**: a missing mic stops the RECORDING, so "continue without a screenshot" would offer to continue with nothing |
| Screen Recording rationale (always precedes the system ask) | `…screen.body` · Continue, Cancel | `…screen.work.body` · Continue, **Continue Without Screenshot**, Cancel |
| Grant recorded, not adopted by this process | `…screen.relaunchBody` · Quit Conduck, Cancel | `…screen.work.relaunchBody` · Quit Conduck, **Continue Without Screenshot**, Cancel |
| Denied, or the system dialog just came up | deep-links `Privacy_ScreenCapture` and ends | `…screen.work.deniedBody` · Open System Settings, **Continue Without Screenshot**, Cancel — Work needs a surface on which to offer the third choice, so the deep link moves behind that alert's primary button |

`runPermissionAlert(…offersSkip:)` reads `.alertSecondButtonReturn` as a skip
only when a skip button was added; otherwise index 1 is Cancel, and reading it
as a skip would start a microphone the person just declined. Any other return
code defaults to `.cancel` — an unexpected code must never be read as consent.

### Press flow

`handleWorkCapturePress()` runs, in order:

```
second press while live → finishWorkVoiceCapture()            (unchanged)
guard !workCapturePressInFlight  → drop a press whose overlay still stands
workCapturePressInFlight = true; defer false
  cancellationAtPress = coordinator.workCaptureCancellationGeneration
  await regionCapture.captureRegion(purpose: .work, requiresMicrophone: !textMode)
    .cancelled / .unavailable → return   (no popover, no cue, no mic, nothing staged)
  guard generation unchanged, !workCaptureIsActive, !workRecordingIsLive,
        dictationService.state != .recording
  text mode → setPendingWorkCaptureImage(shot) → openComposeForWorkOnly() → showPopover()
  voice     → claimPopoverForWorkVoiceCapture() → updatePopoverBehavior()
              → showPopover() → cue → beginWorkVoiceCapture(screenshot:)
```

**The screenshot comes first, before any surface is raised** — the overlay covers
the screen the person wants a picture of, and a popover summoned ahead of it
would be in the shot.

`MenuBarCoordinator.workCaptureCancellationGeneration` is reserved at the press
and compared once the picture is in hand. `workVoiceStartToken` protects a start
that is already suspended; this protects the stretch BEFORE any start exists. For
the whole length of the overlay plus the ScreenCaptureKit acquisition the lane
owns nothing — no recorder state, no claim, no flag an Esc can change — so
without the generation a bail lands, does nothing observable, and is answered
seconds later by a microphone coming up behind the popover that same Esc had
just closed. `cancelWorkVoiceCapture()` bumps the generation FIRST and
unconditionally, because the press it has to reach may own nothing yet.

`workCapturePressInFlight` (on the controller) drops a second `⌃⌘W` while the
crosshair still stands. `coordinator.workCaptureIsActive` cannot cover that
stretch: nothing is claimed until the drag finishes, so a second press would read
the lane as free and race the first into it. The overlay stands for as long as
somebody takes to choose a region, which makes it by far the widest window in the
flow.

The post-await validation is three questions, in this order: has anything bailed
(the generation), has anything else claimed the lane (`workCaptureIsActive`,
`workRecordingIsLive`), is the chat recorder live. A cancellation outranks any
question about who else is busy; a stale press that staged its picture anyway
would hang the region on words it has nothing to do with.

`handleWorkCapturePress` still contains no `armQuickCapture`, no
`isQuickCaptureKnownUnavailable` and no `handleQuickSend` — the negative source
guard is unchanged and still green.

**Esc monitor scoping.** `installEscMonitor` is a LOCAL monitor, so it sees
key-downs dispatched to every window of this app — including the region overlay,
which takes key while a popover can still be open behind it. Both arms now
consume only when `event.window` is the popover's own window, so a person
pressing Esc over a crosshair cancels the crosshair. The alternative — close the
popover before raising the overlay — was rejected because a popover may be
holding a parked Work composition, and stranding those words is worse than the
bug being fixed.

### Click-to-stop

`statusBarButtonClicked` resolves the Work lane FIRST, above the
`dictationService.state` switch, because that state reads `.idle` through an
entire `⌃⌘W` capture — a click would otherwise be read as "open the popover onto
an idle app" while a microphone is live. With "Stop and Save" gone, the mouse is
the only stop affordance for somebody who cleared the binding.

| Click while `workCaptureIsActive` | Result |
|---|---|
| right / control | `showContextMenu()`, exactly as in the idle arm |
| left, recording live | `finishWorkVoiceCapture()` — a stop, never a discard |
| left, starting up or transcribing | `showPopover()` if it is closed, and start NOTHING |

A second capture during startup would fight the first for the microphone lease
and lose, and the refusal would land behind the HUD that hid it.
`isSecondaryClick()` is extracted so both arms disambiguate the same way.

### The Work-only image slot, and an aim-keyed publish

`MenuBarCoordinator.pendingWorkCaptureImage` is the desk's own slot and is
deliberately NOT `pendingCaptureImage`: that one rides the next chat turn as a
`PendingAttachment.image`, so a Work screenshot parked there would be handed to a
gateway by an Ask made minutes later — the same leak the two-composition design
exists to prevent, and worse, because a picture of somebody's screen carries far
more than they typed.

- `hasWorkComposeState` reads the Work slot, so a picture alone is a Work
  composition.
- A flip from text mode to voice clears both slots: in voice mode the Work slot
  is the HUD's thumbnail, so a leftover picture would caption the next capture,
  including one that deliberately skipped its screenshot.
- `discardWorkOnlyCompose()` drops it (half of the composition being thrown
  away); `closeWorkOnlyCompose()` parks it with the words.
- `cancelWorkVoiceCapture()` clears it only `if workCaptureIsActive` —
  `cancelActiveCapture` bails both lanes on one press, so an Esc typed over the
  Chat surface arrives here too and a parked Work composition's picture has to
  survive that exactly as its words do.
- `noteWorkCaptureFinished` clears it on success and KEEPS it on failure: an
  unfinished capture still owns a card and a Try Again, and the picture is what
  says which one.
- `restartWorkVoiceCapture()` passes no screenshot; a restart raises no overlay,
  so there is no new region and reusing the old one would caption fresh words
  with an old screen.

`saveQuickDraftToWork()` snapshots the picture from the slot the AIM owns
(`aimAtCommit == .work ? pendingWorkCaptureImage : pendingCaptureImage`) and
consumes from that same slot, only while it is still the one that was published.
One method serves both doors — the `⌃⌘W` surface and the Chat surface's "Add to
Work" button, which files what `⌘⇧2` staged for a turn the person decided not to
send — so reading one fixed slot would publish one composition's image under the
other's words, or silently drop the screenshot that is the entire reason the
button was pressed.

### Recorder: staging, ordering, debt

**Staging.** `stageWorkScreenshot(_:)` holds the bytes until Stop mints the
capture id; empty data normalizes to none. Nothing durable exists between the
drag and the stop, so one Esc still leaves the desk exactly as it was. A refused
`startRecording()` drops the stage (a `defer` below the re-entrancy guard, so a
press arriving while a capture is already live cannot take that capture's picture
away from it), and `cancelRecording()` drops it and resets the facts. At the mint
the bytes MOVE onto the `VoiceCapture` — which also gains a stable `createdAt`
and a `screenshotQueued` flag — so there is exactly one copy and one owner. A
Chat recorder has no card to put a picture on, so anything staged on one is
dropped at the mint rather than held for a publication that never comes.

**Stop ordering — picture, recording, words.** Phase 0 publishes the screenshot
through `WorkVoiceScreenshotCoordinator.publish(_:forCapture:createdAt:inbox:store:normalize:)`
BEFORE phase one, because the picture is the artifact that exists nowhere but
this process: publishing it first closes the window where the audio lands and an
in-memory image dies with a crash. The card is dated from the capture's own
`createdAt`, so a picture published here and again from the durable record is one
picture with one date. Phase 0 is deliberately NOT nested under phase one's
condition: the two artifacts are published independently and either may be owed
while the other is finished, which is what makes the screenshot's retry
independent of the audio's. A refusal here costs neither the recording nor the
words.

**Debt and retry.** The debt check sits ABOVE the pipeline, not inside it:
`finishAndUpload` is a two-statement wrapper that runs `runCaptureToCompletion`
and hands its answer to `settleOwedScreenshot`. A capture can end in a dozen
places — silence, a missing key, an unreadable one, a model that would not
install, a card deleted mid-recognition — and the picture is owed at every one of
them, so a check inside the pipeline is a check some exit walks past. Whatever
the speech hop did, a capture still owing its picture stays pending and answers
`.workScreenshotWriteFailed`, the retryable code whose copy names the artifact
that is actually missing; the facts carry what else went wrong, and the surface
renders both. It cannot loop — each call answers once and waits for the next tap.

Two exits keep their own answer. A refused DESK WRITE (`.workDeskWriteFailed`) is
already retryable, the same Try Again republishes the picture on its way through,
and "the recording is not saved" is the bigger news of the two. A CANCELLED hop
is a choice the person made, and turning their ✕ into an error banner answers a
question they did not ask — the picture is parked on the way out and the capture
stays retryable, but nothing is surfaced.

`canRetryWorkCapture` reads `pendingWorkCapture`, the HUD's Try Again reads that,
and the Mac has no pending-retry card of its own, so a capture reported
successful is a capture with no retry anywhere. Retaining the debt makes one Try
Again finish it in a single pass with no speech hop: the picture publishes, phase
one is skipped because a card exists, transcription is skipped because the words
are in hand, and phase two is skipped outright because `transcriptSettled` says
the words are already settled — the attachment is never reopened.

**A capture with no recording.** A microphone that gave no bytes, on a press
that dragged a region, mints a capture with EMPTY audio carrying only the
picture. It ends immediately after phase zero and reports `.audioMissingData`
once the picture is settled — the phases below would publish empty bytes as a
voice note and buy a transcription of silence. Such a capture is held in MEMORY
only: `preserveForRetry` refuses an audio-less capture, because every surface
that recovers a queued capture begins by transcribing it, so an entry holding no
audio is one none of them could finish and it would sit in the queue for ever
offering a retry that cannot work. The picture is retried from the surface
looking at it, and the cost is U-45 — a process death before that retry loses it.

**Phase two runs once.** `VoiceCapture.transcriptSettled` — not "attached":
`.recordingMissing` settles the words as finally as an attach does, since a card
that is gone can never take them — is set on BOTH attach outcomes, and phase two
is skipped when it is true. Before it, every resumed capture holding a material
id called `attachTranscript` again; unchanged words write nothing, but the call
still performs a throwing store fetch whose failure answered code 78 after the
screenshot debt had already settled.

**The tail retires by debt, not by step.** Fixing the double attachment exposed a
pre-existing bug: the capture's release was conditioned on phase two having
nil'd `pendingWorkCapture`, so a picture-only retry — which skips phase two
entirely — left the capture in hand for ever, still offering a Try Again with
nothing to do. The tail now retires any capture that owes nothing, whichever step
answered last, and holds any capture that still owes a picture for the debt check
to find.

**Cancellation answers with a cancellation.** The wrapper's cancel branch returns
`.failure(.unknown(CancellationError()))` with `state = .idle` rather than passing
the pipeline's outcome through. A picture-only retry reaches it having skipped the
speech hop, so nothing else examined the flag and its outcome is the success the
pipeline would have reported — returning that would tell somebody who pressed ✕
that their picture had been saved. The completion chime is gated on
`!Task.isCancelled` for the same reason, and
`WorkVoiceScreenshotCoordinator.publish` checks cancellation after normalization
and before the enqueue, so a cancelled retry queues nothing.

**The desk-fact refresh sits above the debt question.** `settleOwedScreenshot`
re-reads the desk on every FAILURE outcome, before it asks whether a picture is
owed. Integration pass 5 caught the refresh having sunk below the combined debt
guard, where a capture with no picture debt never re-read anything — so a desk
emptied mid-recognition was still reported present, which is finding 5 coming
back through a different door. The round-17 tests caught it.

**Durable-entry corrections.** Four writes, each stopping a record from
outliving its truth:

- A refused picture arms the entry with the only verdict true at the time —
  `.phaseOneFailed`, the desk holds no recording. The moment phase one lands, the
  entry is re-saved with the card's id, because a stale `.phaseOneFailed` is
  licence for a recovery hours later to republish a recording and resurrect a
  card the person deleted.
- `discardParkedWorkImage` → `PendingRetryStore.discardWorkImage(claim)` retires
  the parked image file the instant the durable inbox ACCEPTS the envelope —
  acceptance, not import: from that point the bytes exist outside this process
  and the parked copy is no longer the only one. Under the same lease every
  other write here takes. It is payload-only: the entry, its recording, its
  verdict and its words stay, because the words may still be owed. A later `save`
  carrying `workImageData: nil` writes no file and deletes none, so without this
  the stale file survives every subsequent failure of that capture.
- `preserveForRetry` writes `workImageData: capture.screenshotQueued ? nil :
  capture.screenshot` — the record carries the bytes only while the durable
  queue has not taken them.
- Both RETRY surfaces do the same retirement the recorder does:
  `DictationService`'s recovery and `ContentView.finishWorkRetry` call
  `discardWorkImage(claim)` immediately after a recovered picture publishes,
  under the reservation each already holds. A recovery that threw below that
  point otherwise left the parked file standing, and the sweep reads exactly
  that file.
- `PendingRetryStore.liveQueueLocked` filters expiry by `holdsWorkImage(id:)`,
  which asks the FILE, not the record: the publication verdict describes the
  recording, and the two artifacts publish separately, so an entry can hold a
  card on the desk and the only copy of a picture at the same time.

**Facts.** `InAppAudioRecorder.WorkCaptureFacts` stores six, reset at every mint,
on `cancelRecording()` and in `abandonPendingWorkCapture()`, and updated at each
publication step. A seventh, `screenshotImportPending`, is COMPUTED from three of
them — `screenshotQueued && !screenshotOnDesk && !screenshotEverOnDesk` — and is
the only thing that may be described as arriving:

| Fact | Set when | Means |
|---|---|---|
| `screenshotStaged` | at the mint, if bytes moved onto the capture | this capture carried a picture at all |
| `screenshotQueued` | the durable inbox accepts the envelope | historical: these bytes were accepted. Never cleared by a later import, and never by a deletion |
| `screenshotOnDesk` | a card is read back for the published id | a card carrying the picture is standing on the desk |
| `recordingOnDesk` | phase one published, refreshed at every error settle | a card owns the audio |
| `wordsOnDesk` | the transcript attaches | the words are written onto that card |
| `screenshotEverOnDesk` | any lookup finds the picture's card | a card once existed, so a later absence is a deletion and not a pending import |

Queued means ACCEPTED, not arriving. `WorkVoiceScreenshotCoordinator.publish`
hands back an id once the envelope is durable, and the drain that imports it runs
afterwards and is best-effort, so only a confirmed card read may be described as
saved — and acceptance alone never selects the arriving sentence, or a picture
whose card was imported and then deleted would be reported as still on its way.
That is what `screenshotEverOnDesk` is for. `owesScreenshot` is measured against `screenshotQueued`, not against the
card, because once the inbox has taken the envelope these bytes are no longer
this process's to republish — the foreground observer finishes the import.

Successful publication asserts presence; resumed captures preserve existing facts
until a lookup answers. On top of that,
`refreshDeskFacts` re-reads the desk at every error settle: `materialID` is
a memory of a write, not an observation, and a card deleted while recognition was
in flight is common enough that the attach step has a whole outcome for it, while
every exit that returns before that step never asks. Only a DEFINITE answer moves
a fact — a store that could not be read says nothing about what is on the desk —
and words cannot be on a card that is gone, so they fall with it. The durable
`.published` verdict is deliberately left alone by this refresh: it answers a
different question, whether a recovery would be republishing a recording or
resurrecting a deleted card.

### HUD

`captureHUD(screenshot:cancelLabel:cancel:indicator:)` is the one layout, kept as
one function rather than three near-identical stacks so the arms cannot drift:
thumbnail if any, one indicator, one compact ✕. No headline (the indicator says
what is happening), no stop button (stopping is a second hotkey press or a
status-item click), no privacy paragraph (a boundary is stated once, not on every
capture; `workboard.voice.privacy` still runs on the desk's own sheet).
`recordingStatusView` renders it for the chat lane from `pendingCaptureImage`;
`workCaptureView` renders it for Work from `pendingWorkCaptureImage`.

| `workRecorder.state` | Middle row | ✕ label |
|---|---|---|
| `.idle` (the start's own suspension) | `ProgressView` — a timer here would count seconds of a recording that does not exist | Cancel |
| `.recording(startedAt)` | `LiveRecordingStatusIndicator`, ticking from the instant the mic went live | Cancel |
| `.processing` / `.preparingVoice` | spinner, or a determinate bar when the Apple on-device model reports a fraction | **Cancel transcription** (`popover.cancelTranscription`) |
| `.error(error)` | `workCaptureErrorView` — thumbnail, outcome sentence, reason, Try Again + ✕ | Cancel |

The ✕ stays through processing because Work owns a real cancellable task, and it
says what it cancels: abandoning a transcription leaves the recording's card on
the desk, and a VoiceOver user who heard only "Cancel" could not know which of
the two they were about to lose. `cancelWorkCapture()` is narrower than
`cancelActiveCapture` on purpose — a chat turn in flight under the HUD is not the
thing being cancelled.

Try Again shows only when `error.isRetryable && workRecorder.canRetryWorkCapture`
("Record Again" and "Close" are gone), and `workCaptureFailureText` substitutes
`pendingRetry.card.busy` while another surface is already finishing the capture.

**Error sentence matrix.** `workCaptureOutcomeText` is composed from the facts,
never inferred from the error's identity — a sentence derived from the failure
lies in both directions, saying nothing arrived when the picture did, and saying
only the words are missing when the picture went with them.
A picture reads as arriving only while `screenshotImportPending` — queued, not on
the desk, and never confirmed there. Historical acceptance alone does not select
that sentence, or a picture whose card has since been deleted would be reported
as still on its way. Otherwise:
a picture is missing only when it is NOWHERE. Not taken is not missing (a note
started with Return carries none, and naming one invents an artifact nobody
took), and neither is a picture that is still `screenshotImportPending` — that
one is durable and its card is coming, so "on its way" is the honest word.
Acceptance ALONE is not that state: a picture whose card arrived and was deleted
is missing, not arriving.

| recordingOnDesk | wordsOnDesk | screenshot | Sentence |
|---|---|---|---|
| false | — | on desk | `workboard.voice.error.recordingMissing` — "Your screenshot is on your desk. The recording is not." |
| false | — | import pending | `workboard.voice.error.recordingMissingScreenshotQueued` — "Your screenshot is on its way to your desk. The recording is not." |
| false | — | missing or none | `workboard.voice.error.captureAbsent` — "Nothing from this capture is on your desk." |
| true | false | missing | `workboard.voice.error.wordsAndScreenshotMissing` — "Your recording is on your desk. The words and screenshot are missing." |
| true | false | on desk, import pending or none | `workboard.voice.error.recordingKept` — "Your recording is on your desk. Only the words are missing." |
| true | true | missing | `workboard.voice.error.screenshotMissing` — "Your recording and words are on your desk. The screenshot is not." |
| true | true | on desk, import pending or none | `nil` — nothing to add; unreachable today, and the right answer if it ever is |

With no card there is nothing for a transcript to attach to, which is why the
words are not mentioned on the first three rows at all. The reason line beneath
comes from the error, and a screenshot-only debt carries code 79's own sentence
("Work couldn't save the screenshot just now."), never 78's, which is about the
recording and would deny what the outcome sentence above it just said.

The receipt band renders the feedback VALUE and nothing else. A partial capture
never reaches it — a refused picture leaves a retryable error the HUD owns — and
reading any recorder flag there would outlive the capture it described, so a
typed note saved in between would inherit a warning about a recording it has
nothing to do with. The popover's start hint moves to
`popover.start.captureToWork` ("Press %@ to capture to Work"), retiring
`popover.start.workShortcut`; "Capture" is the one word for this action in the
menu, in Settings and here.

## Catalog

Nineteen rows added and three retired against `HEAD`; the iOS catalog is 2,323
rows and every `%@` placeholder survives.

**Added** — `menu.captureToWork`, `menu.openWorkDesk`,
`popover.cancelTranscription`, `popover.start.captureToWork`,
`regionCapture.overlay.hint.work`, `regionCapture.overlay.skipAction`,
`regionCapture.permission.mic.work.body`,
`regionCapture.permission.screen.work.body`,
`regionCapture.permission.screen.work.deniedBody`,
`regionCapture.permission.screen.work.relaunchBody`,
`regionCapture.permission.skipScreenshot`, `popover.retry.savedRecording.help`,
`workboard.voice.error.captureAbsent`, `workboard.voice.error.recordingKept`,
`workboard.voice.error.recordingMissing`,
`workboard.voice.error.recordingMissingScreenshotQueued`,
`workboard.voice.error.screenshotMissing`,
`workboard.voice.error.screenshotWrite`,
`workboard.voice.error.wordsAndScreenshotMissing`.

**Retired** — `menu.recordToWork`, `menu.openWork`,
`popover.start.workShortcut`.

`workboard.voice.error.captureAbsent` ("Nothing from this capture is on your
desk.") replaced an earlier `workboard.voice.error.nothingKept`, and then
`workboard.voice.error.deskEmpty`, inside this same change — so it counts as one
addition rather than a chain of retirements against `HEAD`.
`popover.retry.savedRecording.help` is the idle recovery control's tooltip ("Try
the saved recording again"); the control itself reuses the existing
`popover.retry` label, because it is the same action the error surface offers.

Ask's own strings (`regionCapture.overlay.hint`, `…permission.mic.body`,
`…screen.body`, `…screen.relaunchBody`) are untouched, and
`workboard.voice.privacy` stays for the desk sheet. Validated with
`plutil -convert xml1` plus `python3 -m json.tool` and a duplicate-key scan
(`plutil -lint` is broken on this machine — it rejects `HEAD`'s catalog and a
trivial `{"a":1}` alike).

## Files

Created:
- `Conduck/ConduckTests/RegionCaptureOutcomeGuardTests.swift`
- `Conduck/ConduckTests/WorkboardVoiceScreenshotLaneTests.swift`

Changed:
- `Conduck/Conduck/ScreenCapture/RegionCaptureController.swift`
- `Conduck/Conduck/Models/AppError.swift`
- `Conduck/Conduck/MenuBar/DictationService.swift`
- `Conduck/Conduck/ContentView.swift`
- `Conduck/Conduck/MenuBar/MenuBarController.swift`
- `Conduck/Conduck/MenuBar/MenuBarCoordinator.swift`
- `Conduck/Conduck/MenuBar/DictationPopoverView.swift`
- `Conduck/Conduck/Services/InAppAudioRecorder.swift`
- `Conduck/Conduck/Services/PendingRetryStore.swift`
- `Conduck/Conduck/Localizable.xcstrings`
- `Conduck/ConduckTests/MacMenuBarWorkShortcutDriftGuardTests.swift`
- `Conduck/ConduckTests/MenuBarCoordinatorQuickTypedTests.swift`
- `Conduck/ConduckTests/MenuBarWorkCaptureStateTests.swift`
- `Conduck/ConduckTests/AppErrorCodeContractTests.swift`
- `Conduck/ConduckTests/AppErrorTroubleshootableTests.swift`
- `Conduck/ConduckTests/STTKeyBlackoutLaneTests.swift`

## Tests

`RegionCaptureOutcomeGuardTests` (new, source-reading guards over the capture
controller):
`testTheOutcomeEnumCarriesExactlyTheFourResults`,
`testCaptureRegionAnswersWithTheOutcomeEnumOnBothLanes`,
`testEachLaneDrawsItsOwnOverlayHintKey`,
`testReturnSkipsTheScreenshotOnlyOnTheWorkLane`,
`testTheOverlayOffersSkipAsAnAccessibilityActionOnWorkOnly`,
`testOnlyTheWorkLaneIsOfferedAWayToContinueWithoutAScreenshot`,
`testASecondPressMidFlowResolvesUnavailable`,
`testTheSqueezeIgnoresFormattingAndCommentsCannotSatisfyAGuard`.

`WorkboardVoiceScreenshotLaneTests` (new, behavioural over the recorder, the
inbox seam and the retry store):
`testAStagedScreenshotBecomesItsOwnCardPublishedBeforeTheRecording`,
`testStagingNoScreenshotLeavesTheCaptureExactlyAsItWas`,
`testACancelledRecordingPublishesNothingAndDropsTheStagedScreenshot`,
`testARefusedMicrophoneDropsTheStagedPictureRatherThanArmingTheNextCapture`,
`testARefusedScreenshotHoldsTheCaptureRetryableWithTheWordsAlreadyOnTheCard`,
`testTryAgainOnAPictureOnlyDebtFinishesInOnePassWithNoSpeechHop`,
`testAPublishedRecordingCorrectsTheVerdictARefusedPictureArmed`,
`testAPictureThatLandsIsRetiredEvenWhenTheRetryGoesOnToFail`,
`testRetiringAPublishedPictureLetsItsEntryExpireOnTheOrdinaryBudget`,
`testTheClockDoesNotRetireAnEntryStillHoldingAnUnpublishedScreenshot`,
and from round 15 `testASilentCaptureStillOwingItsPictureStaysRetryable`,
`testADeletedCardIsNotReportedAsPresentWhenRecognitionFails`,
`testAQueuedPictureWhoseDrainFailsIsNotReportedAsOnTheDesk`,
`testBothRetrySurfacesRetireTheParkedPictureOnlyWhenPublicationTookIt`, and from
round 16 `testADeletedScreenshotCardIsNotReportedAsPresentWhenRecognitionFails`,
`testAPublicationCancelledBeforeTheQueueEnqueuesNothing`,
`testCancellingAPictureOnlyRetryReportsACancelAndKeepsTheDebt`,
`testAPictureOnlyRetryNeverReopensTheAttachmentItAlreadySettled`,
`testAMicrophoneThatGaveNothingStillCarriesTheStagedPicture`.
`testARefusedScreenshotHoldsTheCaptureRetryableWithTheWordsAlreadyOnTheCard` and
`testTryAgainOnAPictureOnlyDebtFinishesInOnePassWithNoSpeechHop` were reworked
onto code 79 and the queued/on-desk split.

`ErrorSurfaceDriftGuardTests`' registry entry for `DictationPopoverView` now
lists two tokens, `isRetryable` and `canRecoverPendingQueue`, with its reason
rewritten: the idle recovery control is gated on the QUEUE, not on an
`AppError`, so a guard that demanded only `isRetryable` of that file would be
satisfied by the wrong read. No other file's registry row changed.

`AppErrorCodeContractTests` carries a `workScreenshotWriteFailed` row at 79 and
its distinct-code arithmetic moves 78 → 79; `AppErrorTroubleshootableTests` adds
79 to the deny-list (Diagnostics reasons about connections and keys, not a local
write); `STTKeyBlackoutLaneTests`' lane row now reads
`delegatesTo: "runCaptureToCompletion"`, because the key verdict moved with the
pipeline when `finishAndUpload` became the wrapper around it.

`MacMenuBarWorkShortcutDriftGuardTests` — added
`testTheWorkPressTakesItsScreenshotBeforeItRaisesAnything`,
`testACancelledRegionEndsTheWorkPressWithNothingStaged`,
`testABailDuringTheScreenshotAwaitEndsTheWorkPress`,
`testASecondWorkPressDuringTheOverlayIsDropped`,
`testAStatusItemClickStopsALiveWorkRecording`,
`testTheEscMonitorLeavesAnotherWindowsEscAlone`; renamed
`testTheContextMenuOffersRecordToWorkRightAfterScreenshotAndAsk` →
`testTheContextMenuOffersCaptureToWorkRightAfterScreenshotAndAsk`, which now also
asserts the separator between the Work item and `conversations.openConversations`.

`MenuBarCoordinatorQuickTypedTests` — added
`testAChatTurnCarriesTheChatScreenshotAndNeverTheWorkOne`,
`testAChatTurnWithOnlyAWorkPictureParkedCarriesNoAttachment`,
`testAWorkScreenshotIsWorkComposeStateAndNotChatComposeState`,
`testLeavingTheWorkSurfaceParksItsPictureAndCarriesNothingToChat`,
`testDiscardingTheWorkCompositionThrowsAwayItsPicture`,
`testABailOverTheChatSurfaceLeavesAParkedWorkPictureAlone`,
`testCancellingARunningWorkCaptureDropsItsPicture`,
`testFlipToVoiceClearsAStagedWorkScreenshot`.

`MenuBarWorkCaptureStateTests` — added
`testTheChatSendPathCannotSeeTheWorkScreenshotSlot`,
`testTheDeskCommitTakesThePictureFromTheSlotItsAimOwns`,
`testTheWorkVoiceStartStagesItsPictureOnTheRecorderFirst`,
`testTheWorkPictureIsDroppedByACancelAndKeptByAFailure`; the receipt test at
`:596` and `ErrorSurfaceDriftGuardTests`' retry registry are unchanged and still
green.

## Codex rounds 14–16

Round 14 (`verify/codex-r14-menu-capture.md`) read the finished diff and raised
seven findings, each answered with a fix and a negative control:

1. **Esc during the screenshot await was followed by a microphone start.** The
   handler checked only current recording flags. Fixed by reserving
   `workCaptureCancellationGeneration` at the press and validating it after the
   `captureRegion` await.
2. **A screenshot failure left a `.phaseOneFailed` verdict standing** that a
   successful audio publication never corrected, so a later recovery could
   resurrect a deleted recording. Fixed by re-saving the armed entry with the
   card's id the moment phase one lands.
3. **A retried picture that published left its parked file behind**, and
   `holdsWorkImage` then exempted the entry from expiry indefinitely. Fixed with
   `discardWorkImage(claim)`, called under the capture's own reservation.
4. **A screenshot-only failure had no retry action on the Mac** — clearing
   `pendingWorkCapture` cleared `canRetryWorkCapture`, leaving a receipt with a
   caption. Fixed by retaining the debt and ending the capture retryable.
5. **The error copy was derived from the error, not the desk**, so it claimed
   nothing arrived when the picture had, and blamed only the words when the
   picture went with them. Fixed by composing the sentence from
   `workCaptureFacts`.
6. **A typed receipt inherited an earlier voice capture's screenshot warning**,
   because the feedback value outlived the recorder flag. Fixed by rendering only
   a whole success in the band.
7. **The Chat image-isolation test returned before attachments were assembled**,
   so it could not have caught a Work picture on the wire. Fixed by hoisting
   attachment assembly above the busy-target branch and intercepting it through
   `onQuickTurnAttachments`.

Round 14 recorded clean: overlay Esc/Return/accessibility skip, Screen Recording
skip and Cancel mappings, live/start/refused-mic cancellation, screenshot-before-
audio ordering and stable retry ids, click/hotkey stop serialization and
unpinning, Chat/Work image separation and aim-keyed saves, startup indicators,
catalog references and retirements, comment-resistant guards, diff whitespace.

Round 15 (`verify/codex-r15-menu-capture.md`) re-read the seven. It closed
findings 1, 2, 6 and 7, left 3, 4 and 5 open, and raised three code findings plus
one documentation finding.

**3 — the retry surfaces did not retire what the recorder does.** In-process
retirement was fixed, but `DictationService`'s recovery and
`ContentView.finishWorkRetry` published a recovered picture and left the parked
file standing, so a recovery that threw below that point had `holdsWorkImage`
exempting the entry from the clock for ever. Both now call
`discardWorkImage(claim)` immediately after the publish, under the reservation
each already holds.

**4 — a non-retryable speech exit walked past the debt check.** Silence named it:
`.noSpeechDetected` is terminal and not retryable, so a capture that ended there
offered no Try Again and the picture it was holding had nowhere to go. Every
other terminal exit has the same shape. The check moved ABOVE the pipeline —
`finishAndUpload` now wraps `runCaptureToCompletion` and passes every terminal
answer through `settleOwedScreenshot`, which keeps the capture pending and
answers `.workScreenshotWriteFailed` whenever a picture is owed.

**5 — the outcome sentence still made false claims about what the desk held.**
Round 15's own new findings are two instances of it, and it outlived them both:
it is still open after round 17.

**New 1 — the screenshot-only reason line named the recording.** A debt
printed 78's "Work couldn't save this recording just now." beneath "Your
recording and words are on your desk." Fixed with a code of its own: 79,
`workScreenshotWriteFailed`, "Work couldn't save the screenshot just now." —
retryable and preserved exactly like 78, because what refused is a local write,
the identical bytes written again normally land, and until they do the queue
entry holds the only copy of the picture. Not troubleshootable, for 78's reason.

**New 2 — a deleted recording was still reported present.** Publish the audio, delete
its card while recognition awaits, then let recognition fail: `materialID` stayed
non-nil and every exit before the attach step never asked the desk. Fixed with
`refreshDeskFacts`, called at every error settle; only a definite store
answer moves a fact, and the words fall with the card.

**New 3 — a queued image was reported as arrived.**
`WorkVoiceScreenshotCoordinator.publish` returns an id once the envelope is
durable, and the drain that imports it can still throw, so `screenshotOnDesk`
claimed a card that did not exist. Fixed by splitting the fact in two:
`screenshotQueued` recording the historical fact of acceptance — it stays true
after the import, because it answers "were these bytes taken?" and not "is there
a card?" — `screenshotOnDesk` only from a confirmed card read, and a sentence of
its own for the state where the first is true and the second is not.

Round 15 also raised a P3 against the docs — the handoff recorded a completed,
fully successful round 15 while three defects stood and the report did not yet
exist. That is what this correction pass answers.

Round 15 recorded clean: generation and start-token cancellation, the conditional
re-save without duplicate entries, the first-pass no-lease case, a successful
picture retry without a second speech hop, explicit retries terminating when
refused, ✕ preserving durable debt, busy-send attachment assembly, unread and
pinning behaviour, comment-stripped non-vacuous helper extraction, diff
whitespace.

Round 16 (`verify/codex-r16-menu-capture.md`) closed 3, 4 and all three of round
15's code findings, kept 5 open, and raised four of its own.

**5 stays open — presence was re-read for the recording only.** Delete BOTH cards
while recognition awaits, then fail recognition: the refresh asked the desk about
the recording only, and the screenshot's earlier `true` survived to select "Your
screenshot is on your desk." `refreshDeskFacts` now re-reads BOTH cards.

**New 1 — recovery deleted the parked image even when publication accepted
nothing.** Both recovery surfaces discarded the optional publication result and
retired the file unconditionally, but `publish` returns nil on a normalization
failure, BEFORE anything is enqueued — so a recovery that then failed left no
durable picture anywhere. The discard now requires a non-nil publication id.

**New 2 — cancelling a picture-only retry could still enqueue and chime.** Press
✕ while retry normalization awaits: publication did not check cancellation before
enqueueing, its drain swallows cancellation, and because the transcript already
existed the retry skipped the speech lane's own cancellation check, reattached,
chimed and returned success — which left the wrapper with no pending capture and
bypassed its cancellation exception. Cancellation is checked after normalization,
before the enqueue and before the success.

**New 3 — a picture-only retry repeated the transcript attachment.** Every
resumed capture holding a material id called `attachTranscript` again. Unchanged
words write nothing, but the call still performs a throwing store fetch, and its
failure answered code 78 after the screenshot debt had already settled.
`VoiceCapture.transcriptSettled` now skips a finished phase two, and fixing it
exposed the tail bug above.

**New 4 — a missing-microphone-data exit stranded a staged picture.** The
nil-or-empty-audio return happens BEFORE the screenshot moves onto a capture, so
the wrapper's `pendingWorkCapture` guard returned at once and the HUD offered no
retry for a picture that was still staged. Such a press now mints an audio-less
capture that carries the picture and settles its debt before it reports
`.audioMissingData`.

Round 17 (`verify/codex-r17-menu-capture.md`) closed new 1, new 3, new 4 and all
four documentation findings, kept 5 and new 2 open, and raised three of its own.

**New 1 — a cancelled picture retry left its capture unreachable.** The cancel
branch retains the capture and sets `.idle`, but `.idle` makes
`workCaptureIsActive` false and `finishWorkVoiceCapture` refuses to retry it: no
Try Again on reopening, and the next Work capture replaced it. An audio-less
capture had no durable recovery either.

**New 2 — a picture retry reversed a confirmed absence.** Let the picture fail,
delete the recording during successful recognition, then retry while the picture
still fails: the resumed capture reset presence from its historical material id,
phase two was skipped, and the pipeline returned success, so the wrapper never
refreshed the facts before converting the answer to code 79. The HUD reported a
recording the person had deleted.

**New 3 — a successful picture hid the audio-less capture's error.** Once the
picture is accepted, the capture is cleared and `.audioMissingData` is returned
into a HUD that is no longer drawn, so neither the missing recording nor the
picture's outcome was shown — on a first submission and after a Try Again alike.

### The rules that settle it

- **A capture that owes something stays in `.error(code)` with the capture
  retained.** The surface showing the failure is the surface that can finish it,
  so the state may not fall to `.idle` underneath a debt.
- **✕ on that error calls `workVoiceRecorder.discardPendingWorkCapture()`** —
  the in-memory capture is dropped and its facts reset, the durable entry is
  untouched, and the queue is the recovery from there.
  `restartWorkVoiceCapture` keeps `dismissError()`, because a restart replaces
  the capture rather than abandoning it. `MenuBarCoordinator.workCaptureErrorIsTerminal`
  is the name a dead error is tested by, and
  `PendingRetryStore.queueDidChangeNotification` with the `DictationService`
  observer keeps the popover's pending-retry count current.
- **✕ during an in-flight retry returns to the same error, silently.** Nothing
  changed, so nothing new is announced.
- **A cancel is silent, and it retires only a COMPLETED capture.** Acceptance
  ends the PICTURE's debt, not every debt: a cancelled transcription still
  retains its pending words, and that capture stays in hand. Retirement is
  scoped to a capture that owes nothing at all — picture debt and transcription
  debt are separate questions, and answering one does not close the other.
- **Facts are never reset from a historical id on a resumed capture.** A
  confirmed absence outranks a memory of a write, and `refreshDeskFacts` runs
  whenever the wrapper itself creates the error.
- **`screenshotImportPending` is the only state that reads "on its way"** —
  queued, not on the desk, and never confirmed there. Historical acceptance alone
  no longer selects that sentence, so a picture whose card has since been deleted
  reads as absent rather than as arriving.
- **A picture-only capture ends `.error(.audioMissingData)` with nothing to
  retry.** The HUD renders its facts and a Close; a retry would have nothing to
  do, and silence would hide both the missing recording and the picture.
- **The empty case says "Nothing from this capture is on your desk."**
  (`workboard.voice.error.captureAbsent`.) The branch reads this capture's
  artifacts only, so claiming the whole desk is empty overstates what it knows —
  unrelated cards can be sitting right there.

Round 18 (`verify/codex-r18-menu-capture.md`) closed every round-17 item and
raised five, all fixed.

**New 1 — a standing Work error blocked the mouse-stop of an Ask recording.**
⌘⇧1 is gated on the live Work MICROPHONE rather than on the HUD, so an Ask can be
recording underneath a terminal Work error; the click then entered the Work arm
and returned without reaching Chat's stop. A live Chat recording now consumes the
left-click first — the two lanes are mutually exclusive at the microphone, not at
the surface, and whichever one actually holds it is the one a click has to stop.

**New 2 — a dismissed Work debt had no menu-bar recovery.** ✕ discards the
in-memory capture, the idle popover drew no queue-retry control, and `retryLast()`
itself demanded `.error`, so the parked capture was reachable only through an
unrelated Chat failure. The idle popover now shows the existing queue-retry
control while `DictationService.canRecoverPendingQueue`, and `retryLast()` runs
from idle.

**New 3 — retirement did not notify the count.** Saves posted
`queueDidChangeNotification`; retirement did not, so a successful Work retry left
a positive pending-retry badge and a standing retryable Chat error offered a Retry
against an empty queue, ending on "No saved recording to retry." The notification
now fires after a successful retirement too, outside the lock.

**New 4 — absence learned by the refresh was reset on resume.** Only the attach
step latched `recordingConfirmedGone`, so a recording deleted during a FAILED
recognition set presence false without latching it; the retry then re-derived
presence from `materialID`, and if the next desk read threw, the false "recording
is on your desk" survived. Presence is preserved on resume and set true only by a
real publication or a real lookup.

**New 5 — "Nothing is on your desk." overclaimed.** The branch inspects this
capture's artifacts and nothing else, so it cannot speak for the desk; unrelated
cards can be sitting right there. The sentence is now "Nothing from this capture
is on your desk." under `workboard.voice.error.captureAbsent`.

Round 18 also raised three documentation corrections, answered here: cancellation
rules that equated picture acceptance with retirement, a facts list that still
said five and called a queued picture arriving, and a manual QA step still
quoting a retired sentence.

Round 19 (`verify/codex-r19-menu-capture.md`) closed all five round-18 code
items and raised two, plus three surviving documentation contradictions answered
here.

**New 1 — Chat queue recovery sends another composition's screenshot.**
PRE-EXISTING at `HEAD`, recorded and NOT fixed. Park a failed Chat recording,
switch to text, drag a picture for a new question without submitting it, then
Retry: text capture stages the new picture without changing dictation state,
recovery hands the parked words to `onTranscript`, and the send reads the LIVE
image slot — so the old words go out with the new picture, which is then
cleared. `HEAD` already does this from the `.error` route; round 18's idle
recovery route inherits it. The fix is to pass capture-owned attachments into
recovery and preserve any separate staged composition. See U-46.

**New 2 — an unexpected recorder failure bypassed screenshot recovery.** The
audio delegate's `onRecordingFailed` — a HAL-aborted capture with no user stop —
only set `.error(.audioMissingData)`, so the picture stayed staged with no
pending capture behind it: Stop refused because recording had ended, Try Again
had no capture to finish, and the empty-audio handling was never reached. That
failure is now routed through the picture-only finalization, which mints the
audio-less capture, publishes its picture, and ends on the audio error with its
facts.

Round 20 (`verify/codex-r20-menu-capture.md`) confirmed the round-19 items closed
and found no further ordinary-use P1 or P2 across drag, skip, cancel, recording,
stop, one Try Again, click-to-stop, the menu actions, the Settings bindings, and
Ask with and without a standing Work state. It raised one PRE-EXISTING routing
gap, fixed while here: in text mode, `⌘⇧2` and the "Type a Message…" menu item
staged the Ask picture without selecting the Chat aim, so Return went on saving
to Work — and this change additionally hid the picture, because the Work
thumbnail reads its own slot. Both commands now select the Chat aim before they
stage, so Return sends to Chat and the thumbnail shows; a standing Work
composition stays parked, exactly as it does across any other aim switch. Plain
`⌘⇧1` always selected Chat and is untouched. Round 20's second item was this
note's own round-19 numbering, corrected above.

Round 20 raised the routing gap fixed above; a scoped round 21 read that fix alone and confirmed it closed. Round 21 closed the wave; its report is `verify/codex-r21-menu-capture.md`.

Round 16 recorded clean: the code-79 wiring, context-owned local reads and facts
left unmoved on a read failure, a success-to-79 conversion that preserves the
material id and the transcript, an ordinary retry that avoids another speech hop
and acknowledges success once, a cancelled speech hop creating neither desk card
nor inbox envelope, the updated catalog counts and test names, the contracts
retained behind the doc cuts, and diff whitespace.

## Nobody undo

- **The outcome is an enum, and `.skipped` belongs to Work alone.** Do not
  collapse it back to `Data?`: `nil` would mean chose-no-picture, denied
  permission and failed grab at once, and either reading is a real failure.
- **A sub-4pt drag is a cancel on both lanes.** It must never become a skip; a
  stray click would then start a microphone.
- **The screenshot is published at Stop, never at the drag.** That is what lets
  one Esc leave the desk untouched, and it is why the picture goes out FIRST once
  a capture id exists.
- **Phase 0 is not nested under phase one's condition.** Nesting it makes the
  picture's retry depend on the audio's, and either artifact may be owed while
  the other is finished.
- **A capture that owes a picture ends retryable, not successful.** A success
  clears `pendingWorkCapture`, and with it the only Try Again the Mac lane has.
- **`settleOwedScreenshot` stays ABOVE `runCaptureToCompletion`.** Moving the
  debt check back inside the pipeline puts it behind whichever exit is added
  next; silence is the one that proved it.
- **Code 79 is not 78 with different wording.** They name different artifacts,
  and either can fail while the other is safely on the desk.
- **`screenshotQueued` and `screenshotOnDesk` stay two facts.** Publication is
  durable before the drain imports it, so only the confirmed card read may be
  described to a person as saved.
- **`refreshDeskFacts` moves a fact only on a definite answer**, re-reads BOTH
  cards, and never touches the durable `.published` verdict — that one answers
  whether a recovery would republish or resurrect.
- **`transcriptSettled` is set on BOTH attach outcomes.** `.recordingMissing` is
  as final as an attach: a card that is gone can never take the words, and
  treating it as unsettled reopens a throwing store fetch on every retry.
- **The tail retires by debt, never by which step ran.** Conditioning the release
  on phase two is what left a picture-only retry holding a dead Try Again.
- **A cancelled capture answers with a cancellation, and chimes nothing.**
  Passing the pipeline's outcome through tells somebody who pressed ✕ that their
  picture was saved.
- **The idle recovery control is gated on `canRecoverPendingQueue`, never on
  `AppError.isRetryable`.** No error reaches that surface — the queue is what
  says whether there is anything to recover — and `retryLast()` asks
  `DictationService.isRetryPermitted` rather than demanding `.error`, which is
  what made a dismissed Work debt unreachable.
- **`PendingRetryStore.clear` posts `queueDidChangeNotification` only when a
  clear actually happened.** Posting unconditionally turns every no-op read into
  a refresh storm; posting never is what left a stale positive count.
- **The desk-fact refresh sits above the debt question and runs on every
  failure.** Below the debt guard it stops running for captures that owe
  nothing, which is exactly the case that reports a deleted card as present.
- **A debt keeps the recorder in `.error(code)`.** Dropping to `.idle` under a
  retained capture makes `workCaptureIsActive` false and the capture unreachable;
  the next Work capture then replaces it.
- **Acceptance ends the PICTURE's debt, not every debt.** A cancel is silent,
  and it retires only a capture that owes nothing at all: a cancelled
  transcription still retains its pending words.
- **A resumed capture never re-derives a fact from its historical ids**, and the
  wrapper refreshes the facts whenever it is the thing creating the error.
- **`screenshotImportPending`, not historical acceptance, selects "on its way".**
- **`preserveForRetry` refuses an audio-less capture.** Parking one queues a
  retry no recovery surface can finish, because they all begin by transcribing.
- **`workCaptureFacts` is the source of the error sentence.** Do not re-derive it
  from `AppError`: three artifacts publish on three independent terms, and a
  sentence keyed to the failure will misreport at least one of them.
- **The receipt band reads the feedback value only.** Reading a recorder flag
  there hands one capture's warning to the next lane's save.
- **`pendingWorkCaptureImage` and `pendingCaptureImage` stay two slots**, and
  `saveQuickDraftToWork` keys on the AIM. Merging them puts a private screenshot
  on a turn whose Return reaches a gateway.
- **The Esc monitor stays scoped to the popover's own window.** Closing the
  popover before the overlay instead would strand a parked Work composition.
- **`workCapturePressInFlight` is on the controller, not derived from
  `workCaptureIsActive`.** Nothing is claimed until the drag finishes, so the
  coordinator's flag reads the lane as free for the widest window in the flow.
- **The Work lane is resolved before `dictationService.state` in
  `statusBarButtonClicked`.** That state reads `.idle` through an entire Work
  capture.
- **`discardWorkImage` is separate from `clear`.** The image file is the evidence
  the expiry sweep reads; a `save(workImageData: nil)` deletes nothing.
- **`holdsWorkImage` asks the file system, not the record.** The publication
  verdict describes the recording only.
- **The HUD keeps its ✕ during processing and labels it "Cancel transcription".**
  Work owns a real cancellable task there, and the label is the only place the
  distinction can be said out loud.
- **The Work permission alerts never name a gateway**, and every Work stop except
  the microphone one offers "Continue Without Screenshot" with Cancel last.

## Known limits

- **U-41** — Esc typed into the MAIN window no longer closes an open popover; the
  monitor consumes only inside the popover's own window. The popover's ✕ and
  click-away are untouched, and the compose keys already used this scoping.
- **U-42** — on the denied path, Conduck's Work alert can stack over macOS's own
  Screen Recording consent dialog, because the system dialog is raised by the
  request that precedes it. Accepted: Ask has no third choice and can end at the
  deep link, while Work needs a surface to offer one on.
- **U-43** — `onQuickTurnAttachments` is a production-code observation seam, nil
  in production. It exists because the send writes through
  `ConversationStore.shared`, which the unsigned test host cannot touch, and the
  rule it guards is a negative one that is only worth asserting where the
  forbidden value was available to be taken.
- **U-46** — Chat queue recovery attaches the currently staged Chat screenshot
  rather than the capture's own. Pre-existing at `HEAD` from the `.error` route;
  the idle recovery route inherits it. Recorded, not fixed: the repair is to pass
  capture-owned attachments into recovery and preserve any separate staged
  composition.
- **U-45** — an audio-less Work capture (no microphone bytes, a dragged picture
  only) is not durable across a relaunch. It stays in memory so its picture is
  retryable from the surface looking at it, but nothing parks it, so a process
  death before that retry loses the picture. The alternative — parking an entry
  with no audio — is worse: every recovery surface begins by transcribing, so
  that entry would sit in the queue for ever offering a retry that cannot work.
- **U-44** — a transient click-away during the screenshot hop is not a cancel.
  The popover is not pinned until the press claims it, so only an explicit bail
  moves the cancellation generation; a click that merely dismisses a popover
  leaves the press to finish.
