# U-47 — Work as a destination: the wrist, the car, the Mac's third
capture, and the share sheet's last row

## Current design — the share sheet (supersedes every share-sheet passage in this file, its title included)

The share sheet's destination list holds **gateways and recent chats only**, and
**Add to Work is an ACTION on the floor beside Send, never a row in the list**.
The list opens with a destination already ringed, and the Send button names it.
Decision 21 in `../handoff.md` is the binding statement of that shape, its founder
call and its accepted cost. The wrist, the car and the Mac are unaffected: on
those three, Work is still a row the person names.

**Everything below is historical** — the opening summary, the rounds, the
reasoning and the "Nobody undo" list record how each lane got here, including the
share sheet's Work-last, nothing-pre-selected layout and the guards written for
it. Where they disagree with decision 21, decision 21 is the design.

Work is reached by NAMING it, on every surface that can reach it. The wrist's
Ask opens a destination chooser on every press — every configured gateway, then
**Add to Work** last — and the launchpad's separate button is gone. The car has
two doors under one name: the one-tap root row, offered whatever the gateway
roster holds and listed first where the roster is empty, and the last row of the
nav-bar "Choose AI" list wherever that list exists. Both are ACTIONS — the
chooser row stores no override, because an override that could name the desk is a
drive-long mode whose failure is a private thought reaching an AI. The Mac is the
founder's third
option — screenshot + voice to the desk, speech-to-text and no gateway — so its
lane carries the polish three design rounds and four implementation rounds found
around it rather than a re-cut. The share sheet is the fourth: one destination
list — every configured gateway, the recent chats, then **Add to Work** as its
last row — and nothing pre-selected, so no share is routed for the person who
does not read the button. On all four, a Work pick reaches the desk and nothing
else: one speech hop where there is speech at all, and no LLM step.

Each lane was designed before it was cut (`design/watch-work-destination.md`,
`design/carplay-work-destination.md`, `design/mac-work-destination.md`,
`design/share-work-destination.md`), each design was read three times by Codex,
each of the first three implementations four times more and the share sheet's
once, and the finished wave once more end to end.

## What changed

### Watch — Ask asks where

`beginInAppAsk()` is now two statements: refuse if busy, snapshot
`configuredBackendRefs()`, show the chooser. The `count >= 2` branch and the
straight-to-record call for a single gateway are gone, so the sheet opens for 0,
1 and N gateways alike — verbatim founder intent ("even if only 1 gateway is
configured"), at the cost of one extra tap per Ask on a single-gateway watch.

The rows are a pure value, `WatchAskDestinationRows`, kept beside the view that
draws them: `rows(configured:)` = every gateway in roster order, then `.work`,
always present and always last; `showsNoAILine(configured:)` is true only for an
empty roster. Ask is the AI button, so the AI rows lead; Work last is a stable
RELATIONSHIP to them rather than a fixed position. With no gateway at all the
dialog's message reads "No personal AI available." — not the existing "Set up
your personal AI on iPhone first.", which above the only row that works reads as
its prerequisite, and whose meaning is pinned for the headless lane.

The chooser is still a `confirmationDialog` attached to the launchpad `VStack`,
not to the (disabled) Ask button. A row picked seconds after the sheet opened is
re-checked at its push site, and every path that takes over the root also
dismisses the sheet: the headless proceed arms, all three arms that write a root
error, and an accepted notification deep link. The master switch is re-read at
both push sites — it is otherwise read only when the launchpad is drawn, so a
row picked after the phone turned the wrist off would still have started.

The launchpad is one capture button again: duck · **Ask** · **Conversations**.
Its busy caption reads "Saving to Work…" while a Work capture owns the machine
after recording, because describing a private save as "Still answering your last
question." is the one sentence this lane must never show.

### Watch — the destination is legible before you speak

A `.new` draft thread names its gateway from the first frame: `threadBackendName`
keeps the persisted-conversation lookup first and falls back to the
`autoCaptureTarget`'s own ref when there is no conversation yet, so the name is
there while the mic arms rather than after the mint. `WatchThreadCaptureOverlay`
draws it as one secondary caption above the ring, before the `isLive` branch so
it shows through arming and recording alike. The Work screen carries its own
title, "Add to Work".

`WatchGatewayLabel` is what stops two gateways reading alike. The shared
`RemoteAgentRefMetadata.shortDisplayName` is a head cut, which is right for a
sentence read aloud and wrong for a CHOICE: "Frankfurt production alpha" and
"Frankfurt production beta" render one identical label. The shared policy is left
exactly as it is — every other surface keeps it — and the wrist resolves its own
labels: the WHOLE roster at once, never one colliding group, in two passes.
Divergence first (a cut name opens at the earliest character that tells it from
any name it collides with, behind a leading ellipsis, so "…alpha one" and
"…alpha two" survive beside "…one"), then uniqueness across the complete roster
including the labels the shortener never touched, with a bounded ordinal by
roster position for residual ties. VoiceOver is handed
`RemoteAgentRefMetadata.displayName` — the full name — at both call sites, so the
spoken label is never the ambiguous one.

### Watch — the two lanes cannot bleed into each other

`startWorkCapture` stamps `.work` and clears the Ask hint and every conversation
pin; `startCapture` stamps `.chat` and writes the hint. Around that, four rules
the rounds forced:

- **A deferred Ask reaches the gateway it was addressed to.** The queue entry
  carries `backendRef` beside `conversationID`, and `completeEntry` hands it to
  `startDeferredConverseHop(addressedTo:)` through a substitutable seam whose
  whole purpose is that the defect at this call site is a DROPPED ARGUMENT. The
  ref is never recovered from the current default or from another capture's live
  hint.
- **A completion must own the current capture before it touches live state.**
  An older chat reply, and equally an older chat FAILURE, used to assign `.idle`
  or `.error` over a live Work save whose pins are legitimately nil, freeing the
  machine for a second microphone while Work still owned its pipeline. Both
  callbacks now match destination and request identity; persisting the old
  reply into its own thread proceeds independently.
- **A deferred dispatch owns the machine before its first suspension**, and is
  distinguishable from restored waiting state, so it cannot resume on top of a
  Work recorder started while it was minting.
- **A contradictory receipt is refused, not reconciled.** A reply confirming the
  desk holds the capture while the local entry says Chat is retained rather than
  claimed and dispatched.

Done on a Work recorder error dismisses the error it is showing, so the same
failure is not presented twice, and a retryable one keeps Try Again on the
screen that owns the audio.

### CarPlay — one start at a time

`startSession` guarded `.idle && !sessionActive` and then suspended on the
gateway pre-flight; `startWorkNote` could pass the same guard during that
suspension, present its modal, and be overtaken by the resumed chat start —
leaving the driver who tapped **Add to Work** inside a chat session. The claim is
now a serial: `claimStart(_:service:)` takes it synchronously at the row tap,
`startIsLive(_:service:)` re-asks after every suspension group and inside both
present completions, `releaseStart(_:)` is honoured only for the holder's serial,
and `CarPlayStartGate` holds the two predicates as pure functions so the decision
is unit-tested without a `CPInterfaceController`.

Connection identity is not presentation identity, and the difference is a bug
either way round: a present or dismiss completion left over from a previous
connection may not flip the new connection's flag, free the new service's audio,
or run the new caller's completion, and a refused start dismisses the Listening
modal only when that modal belongs to NOBODY — no claim held, no session behind
it — because dismissing on service identity alone tears down a NEWER capture and
deletes its partial recording. `sceneWillResignActive` drops a pending claim,
`didConnect`'s stale-service path runs the full `disconnectCleanup()`, and a
refresh refused under a held claim is RETAINED (`pickerRefreshPending`) and
drained by `releaseStart`, so a start that never began still repaints the picker.

Cancellation is symmetrical: a cancel mark is retained until its own dispatch
attempt exits, an End landing after the user turn was written terminalizes that
exact message, and both destinations re-check listen ownership after compression
and after the STT preflight, so an earlier chat's refusal cannot end a
replacement Work session.

### CarPlay — the row, the hint, the day-one order, and no Mute

- **The root row is permanent, and the chooser repeats it.** `presentGatewayChooser`
  builds its gateway rows, then appends **Add to Work** LAST, under the same key
  and the same `tray.and.arrow.down.fill` the root row uses: one action, one name.
  The chooser row claims the start synchronously BEFORE it pops — the row
  underneath the chooser is "New voice chat" — then re-validates the serial after
  the pop and hands it to the shared `presentWorkNote`. `sessionDefaultRefOverride`,
  `newChatPlan` and `effectiveCarPlayRef` stay `RemoteAgentRef`-typed and the
  chooser row writes none of them, which is what keeps Work out of the gateway
  pre-flight and out of the drive's stored state. The chooser itself still needs
  two or more gateways, so a single-gateway phone has one door.
- **Day one first.** With no gateway configured the first section is hint →
  **Add to Work** → "Set up your AI on iPhone first.", because the setup line
  above the only row that works reads as its prerequisite.
- **The hint names the row that failed.** "Tap New voice chat to try again."
  after a failed WORK start routed the repeated private thought to an AI; the
  detail line now reads `lastStartDestination`. No new key — `.detail.work`
  already existed for the no-gateway picker.
- **A Work note has no Mute.** `mute()` tears capture down and deletes the
  partial recording; on a multi-turn chat that is call-style mute and the spec
  keeps it, on a one-shot note it silently throws away everything already said
  and holds the route with no timer. `startWorkNote` clears the trailing button
  before the template is presented; `reArmAfterSettle` additionally refuses to
  re-arm unless `sessionDestination == .chat`.

### Shared — the words are parked, and they live long enough to be claimed

`attachWorkNoteTranscript` parks the transcript on the queue entry BEFORE it
attaches (`recordPublicationState(_:transcript:publicationState: .published)`),
then asks ownership, then writes. Parking in the catch would not survive a kill
during the attach; the result of the parking is deliberately ignored, because it
is false both for an overtaken claim and for an arm that preserved nothing, and
those need opposite answers.

`PendingRetryStore.publishedWorkRetryTTL` (86,400 s) is the budget for an entry
that is `.work` AND `.published`. Ten minutes is a budget for somebody holding
the device that failed, and the car is the surface where that is never true: a
drive is hours, the phone may stay locked until the driver is home, and "Add the
words on your iPhone" is false the moment the entry is swept. `isExemptFromExpiry`
is unchanged and means something else — bytes that exist nowhere else — so an
UNPUBLISHED Work entry is still on no clock at all. Shared-service change: the
Mac and phone lanes inherit the longer budget.

The relay closes the other half. A settled transcription failure after a
successful publication now parks a `.published` retry entry under the desk card's
own id before it acknowledges, so the wrist can delete its clip against a promise
the phone can actually keep, and a recovery attaches the words to that card
rather than resurrecting a second recording beside it. A retryable attachment
failure travels back as an error, so the wrist keeps its clip.

### Mac — the live microphone owns the surface

A Work capture stays `workCaptureIsActive` through its transcription and through
a standing retryable error, so a `⌘⇧1` pressed in that window started an Ask
recording whose HUD, timer and ✕ were hidden behind the Work HUD — and the
status-item click, which already resolved a live chat recording first, then
stopped and SENT a recording nobody could see. Four rules now agree:

| Surface | Rule |
|---|---|
| Popover router | `workCaptureIsActive, service.state != .recording` → Work HUD, else the Ask HUD |
| Status glyph | the Work glyph only when `workCaptureIsBusy && dictationService.state != .recording` |
| Status-item click | a live chat recording is resolved first (already true) |
| ✕ / Esc bail | `cancelActiveCapture` reads `askMicrophoneIsLive` FIRST, and only tears down the Work recorder when the Ask microphone is not live |

The press generation is a separate concern and moves UNCONDITIONALLY:
`bailWorkCapturePress()` was extracted out of `cancelWorkVoiceCapture()` for
exactly that, because cancelling the Ask frees the microphone synchronously and a
`⌃⌘W` still suspended in its screenshot await would otherwise pass the post-await
guard and start recording after the Esc.

### Mac — three doors, one set of rules

- **A secondary click is the context menu in every state.** `isSecondaryClick()`
  is hoisted to the first line of `statusBarButtonClicked`; it used to fall
  through to `case .recording: toggleRecording()`, so reaching for the menu
  during an Ask recording SENT the turn.
- **"Start Recording" in the menu is `handleShortcutPress()`.** Its own
  `armQuickCapture()` + `toggleRecording()` re-armed the destination of a turn
  already in flight once the menu became reachable mid-recording; the hotkey
  handler arms only from `.idle`/`.error` and carries the discard the menu door
  lacked.
- **`⌃⌘W` stands down BEFORE the overlay** while any microphone is held, in
  voice mode only: `SpeechExclusivity.shared.isRecordingActive` is the question,
  `standDownForBusyMicrophone()` (renamed from the lane-specific
  `showWorkCaptureInstead()`) is the answer, and the existing busy sentence is
  the explanation. It used to raise the crosshair, let the person drag a region,
  and then drop the press silently at the post-await guard. Never a stop — this
  key must never be the thing that sends an Ask turn.

### Mac — receipts and durability

The typed receipt binds the inline drain AND a desk read-back for this capture:
a returned drain plus a card that reads back says "Added to Work. Nothing was
sent." over a button that opens the desk; a drain that threw says "On its way to
Work. Nothing was sent." as an inert row, because the envelope is durable and the
claim was put back, so nothing is lost and nothing has arrived.

Quitting cannot lose a stopped capture. `AudioRecorder.stopRecording()` has
already deleted the file by the time compression, the screenshot lane and
publication run, so the bytes live only in memory until something durable owns
them: publication is counted in flight, the terminate reply refuses while that
count stands rather than permitting on a timeout, and a capture whose desk write
AND retry preservation both failed registers as an unsaved capture that the quit
alert names — in capture-neutral wording, because the unsaved artifact may be the
screenshot while the recording is already a card. That registration is balanced
on explicit discard and on sheet disposal, so a dismissed failure cannot warn
about a capture whose Try Again is gone.

Cancellation, on both hosts: Esc during Ask STT now carries a generation through
the provider call, the preservation that follows it and the retry settlement
after it, so a completion resuming into a NEWER recording writes nothing; and
Work's "Cancel transcription" is checked at the attachment boundary rather than
only before it.

### Share sheet — one list, and nothing picked for you

The segmented `ShareDisposition` (Work · Send now), the Work explanation panel
and the sheet's Work default are gone. `workSection` draws the desk as the LAST
row of the one destination list — its own `Section` header ("Work"), an amber
badge carrying the desk glyph `tray.and.arrow.down.fill`, title **Add to Work**,
subtitle **Nothing is sent to AI** — and it renders OUTSIDE the
`if showsLegacyRow / else if showsNoAILine / else if isEmptySearch / else` chain,
so no search, no empty roster and no missing snapshot can take the destination
away. Its own section because the list pins section headers: a header-less
trailing row scrolls under RECENT CHATS and reads as a chat.

The pick is `ShareDestination { case work; case send(ShareTarget) }`, a two-case
value BESIDE `ShareTarget` rather than a third case inside it. The send manifest
writer `writeEnvelope(uuid:caption:target: ShareTarget,…)` is closed over gateway
targets by TYPE, so the desk cannot reach the manifest however either view is
edited — a `.work` case would instead give that writer's `switch` an arm that
must never fire. `@State private var destination: ShareDestination?` carries no
initializer and no lifecycle hook assigns it; the only five assignment sites per
copy are row `action:` closures. `commit()` reads the pick once and dispatches to
`addToWorkboard()` or `send(_ target:)`, each bound to one inbox and neither
reading `destination` again. The primary button is disabled until a row is
tapped, reads "Choose a destination" until then, and ⌘-Return fires only an
enabled button.

Two pure rules move into `ShareTargetFilter`, byte-identical below the header in
both copies as its drift guard requires.
`showsLegacyNewConversationRow(snapshotDecoded:)`: the legacy "New conversation"
row is offered only when NO snapshot decoded, because undecoded is *unknown*, not
empty — the app may hold a gateway the appex cannot see — and it is tappable now
that nothing is pre-selected. `showsNoAILine(snapshotDecoded:gatewayCount:recentCount:)`:
a DECODED empty roster is told "No personal AI available." — the wrist's own
sentence — rather than offered a send the drainer would refuse.

iOS titles the sheet **Where to?**, the wrist's string, because "Send to" is
false the moment Work is a row. The Mac pair changes in lockstep and loses the
filler panel the mode left it, keeping its ✕ header, its attachment-limit banner
(which still disables the button and still guards `commit()` and both helpers),
its 30 pt badges (34 pt on iOS) and plain-Return-inserts-newline. Both
`ShareViewController` copies and `ShareTargetsSnapshotWriter` take comment-only
edits: no payload decoding is added on either side (spec line ~467),
`recentWorkItems` is still published EMPTY, and every wire type, publisher and
mirror triplet is untouched.

## Decisions

| # | Decision | Why |
|---|---|---|
| 1 | Watch: Work is the last row of the Ask chooser; the launchpad button is deleted | The founder's shape. One fewer button on a 41 mm face; a per-press pick has no last destination to leave switched on, which is what the "never a mode on Ask" rule was actually protecting |
| 2 | The chooser opens for 0, 1 and N gateways | Verbatim intent. Costs one extra tap on a single-gateway watch; a `count >= 1` bypass would drop Work off exactly the case the founder named |
| 3 | Gateways in roster order, then Add to Work | Ask is the AI button, so AI rows lead. Work last is a relationship, not a position |
| 4 | "Add to Work" for the row and the Work screen's title; "Saved to Work." stays the receipt | One name per thing: CarPlay's row, the wrist's own Siri intent, the Mac compose header and Shortcuts all say Add to Work. A bare "Work" collides with a gateway somebody named Work |
| 5 | Chooser title "Where to?" | "Ask which gateway?" is false the moment Work is a row, and the shortest honest question contains no word for sending |
| 6 | Empty roster: "No personal AI available." above the one row that works | "Set up … first" reads as a prerequisite for recording, and its meaning is pinned for the headless lane. "Available" is also honest under a locked keychain |
| 7 | Headless and implicit wrist triggers never pick Work | A trigger with no screen in front of the person routing a thought is the silent reroute the desk's whole boundary exists to forbid. The only hands-free door to the desk is the one that names Work in its own phrase |
| 8 | CarPlay: Work has TWO doors under one name — a permanent root row, and the last row of the "Choose AI" list wherever that list exists | The founder's literal shape (design §9), taken as an override of the design's own decision 1. The root row is day one's only working row and the fewest taps everywhere else; the chooser row is where a driver who opened the destination list looks for the destination. The danger the design guarded against was the *sticky* form, and that is what the ACTION shape removes: no checkmark, no `sessionDefaultRefOverride`, no destination stored, so the next "New voice chat" resolves exactly the gateway it would have resolved untapped. The switcher still needs two or more gateways, so a single-gateway phone grows no second door |
| 9 | CarPlay: a Work note has End and no Mute | Mute deletes what was already said and holds the route with no timer. One control fewer, and it sits better under the entitlement's active-voice expectation |
| 10 | A published Work retry entry keeps its words for 24 h | The car is the surface where nobody can act inside ten minutes. The clock still governs, because those bytes are a second copy of a recording already on the desk |
| 11 | Mac: no structural change to the Work lane | It is the founder's third option verbatim, and re-cutting a lane that seven earlier rounds already read is pure risk |
| 12 | Mac: whichever lane holds the microphone owns the popover, the glyph, the click and the bail | A running microphone with no visible surface is worse than a Work error that waits. Resolves handoff decision 13 |
| 13 | Mac: "Capture to Work" names the action, "Add to Work" names the commit | The hotkey does three different things and "Capture" is the only word true of all three |
| 14 | Share sheet: Work is the last row of ONE destination list, in its own "Work" section, after every gateway and every recent chat | The founder's shape, and the mode was a second control for one decision. Its hidden-list behaviour is what made Work feel like a different sheet; the panel's one load-bearing sentence survives as the row's subtitle |
| 15 | Nothing is pre-selected; the button is disabled and reads "Choose a destination" until a row is tapped | Both directions of the boundary are silent-reroute directions. A Work default costs a redone share; a first-gateway default costs a private document sent to an AI. A pre-selected destination under a big amber button is a choice made for the person who does not read the button. The cost is two taps on the share-and-go path, the founder's own trade on the wrist |
| 16 | The pick is a `ShareDestination`, never a third `ShareTarget` case | The manifest writer takes only a `ShareTarget`, so the desk cannot reach it by type. The same "cannot dispatch" property the two host closures already give, now on the value that carries the pick |
| 17 | An undecoded snapshot keeps the legacy "New conversation" row and makes it tappable; a DECODED empty roster is told "No personal AI available." instead | Unknown is not empty: the app may hold a gateway the appex cannot see, and with nothing pre-selected a non-selectable row is a dead end. A decoded empty roster is a route the app itself says cannot succeed, and the wrist and the car both tell the person rather than offer it |

## Catalog

Watch (`ConduckWatch Watch App/Localizable.xcstrings`): add
`watch.ask.destination.title` ("Where to?"), `watch.ask.destination.work`
("Add to Work"), `watch.ask.destination.noAI` ("No personal AI available."),
`watch.work.capture.navigationTitle` ("Add to Work"); retire
`watch.work.launchpad.save`, `watch.work.capture.title` and the bare-literal
"Ask which gateway?". Wording changes take NEW keys — a shipped translation of
"Save to Work" is a different sentence from the one the row now carries.
`watch.work.capture.saving` is reused verbatim in a second role (the launchpad's
busy caption): same sentence, same state, same device. The same pass reconciled
the two `AppError` keys the wrist compiles but never carried
(`workboard.voice.error.deskWrite`, `.screenshotWrite`) and retired five older
rows with no production reference.

iOS (`Conduck/Localizable.xcstrings`): add `workboard.menuBar.savedQueued`
("On its way to Work. Nothing was sent."), `settings.mac.general.shortcuts.header`
("Keyboard Shortcuts", retiring the singular key — three recorder rows sat under
a singular header), the four `quitGuard.unsaved.*.v2` rows whose wording is
capture-neutral, and `workboard.voice.stopped.body.noCard` ("That recording
isn’t on your desk any more. Try Again brings its words back.") for the
stopped state whose card the desk no longer holds — a different sentence takes a
different key, so `workboard.voice.stopped.body` keeps the card-is-standing arm.
The close-out adds nothing else: `AudioRecorderError.microphoneBusy` is worded
from `audio.error.micBusy` through `AppError`, the STT testers reuse
`settings.voice.{apple,cloud}.test.error.micBusy`, and the sheet's busy line
reuses `pendingRetry.card.busy`. CarPlay adds none: `carplay.picker.addToWork.title`,
`carplay.hint.captureStartFailed.detail{,.work}` and the two saved lines all
already existed.

Share extensions (`ConduckShareExtension/Localizable.xcstrings`,
`ConduckShareExtensionMac/Localizable.xcstrings`): add `share.section.work`
("Work"), `share.destination.choose` ("Choose a destination") and
`share.destination.noAI` ("No personal AI available.") to BOTH, and
`share.destination.title` ("Where to?") to iOS alone — the macOS share host
renders no toolbar, so there is no title to fill. Retire `share.mode.work`,
`share.mode.send`, `share.mode.accessibility`, `share.work.desk.detail`,
`share.send` (the accessibility label of the deleted `sendCircle`), and on iOS
`share.title` and `share.work.title`. `share.addToWork` and `share.work.inert`
are reused in a second role — the row's title and the row's subtitle — because
the sentence, the state and the surface are the same. Both catalogs end at 40
rows; the only single-sided keys are `share.destination.title` (iOS) and
`share.error.tooManyItems` (Mac), and `WorkCaptureInboxTests` pins both facts,
each retired key absent from source AND catalog with it.

Every edited catalog: `plutil -convert xml1`, `python3 -m json.tool`, and a
duplicate-key load with `object_pairs_hook` — clean, and round-trip fidelity was checked against
the untouched files byte-for-byte before any row was written.

## Files

**Watch:** `Views/WatchNoteView.swift` (chooser, `WatchAskDestinationRows`,
`WatchGatewayLabel`, launchpad, dismissal sites) · `Views/WatchConversationThreadView.swift`
(draft-thread name, overlay caption) · `Views/WatchWorkCaptureView.swift` (title,
Done semantics) · `Services/WatchRecordingService.swift` (lane stamps, ownership
of replies and failures, deferred dispatch) · `Services/AppleRelayPendingQueue.swift`
(`backendRef` on the entry, the dispatch seam, contradictory-receipt refusal) ·
`Services/WatchSettingsReader.swift` (comment) · `QA/WatchScreenshotSeed.swift`.

**CarPlay:** `CarPlay/CarPlaySceneDelegate.swift` (claim, `CarPlayStartGate`,
presentation identity, hint, day-one order, no Mute, retained refresh) ·
`CarPlay/CarPlayRecordingService.swift` (listen ownership after every suspension,
parking before the attach, no re-arm on Work) · `CarPlay/CarPlayConverseUploader.swift`
(cancel-mark lifetime).

**Mac:** `MenuBar/MenuBarController.swift` (secondary click, menu delegation,
pre-overlay stand-down) · `MenuBar/MenuBarCoordinator.swift` (bail, receipt,
desk read-back, send identity) · `MenuBar/DictationPopoverView.swift` (router,
queued row) · `MenuBar/DictationService.swift` (cancellation generation) ·
`MenuBar/QuitGuard.swift` · `AppDelegate.swift` · `Views/Settings/MacGeneralCategory.swift`.

**Share extensions:** `ConduckShareExtension/ShareView.swift` and
`ConduckShareExtensionMac/ShareView.swift` (the destination list, `workSection`,
`ShareDestination`, `commit()` and its two bound helpers, the disabled button,
and the deleted mode picker, Work panel, `sendCircle` and `SendButtonStyle`) ·
both `ShareTargetFilter.swift` copies (the two visibility rules, byte-identical
below the header) · both `ShareViewController.swift` copies (comments) ·
`Services/ShareTargetsSnapshotWriter.swift` (comment).

**Shared:** `Services/PendingRetryStore.swift` (`publishedWorkRetryTTL`) ·
`Services/InAppAudioRecorder.swift` (durability accounting, cancellation at the
write) · `Services/AppleSpeechRelayCoordinator.swift` (parked words before a
wordless acknowledgement) · `Services/Workboard/WorkVoiceCaptureCoordinator.swift`
· `Services/AudioRecorder.swift`.

## Tests

The iOS suite goes 5,433 → 5,485 and the watch suite 269 → 302; both green, one
known environment skip. The close-out fixes add seven more iOS cases with no new
file (`PendingRetrySurfaceHandoffTests`, `WorkVoiceRecoveryTests`,
`MenuBarWorkCaptureStateTests` +2 each, `AudioExclusivityCrossSurfaceTests` +1),
tighten `WatchWorkRelayPhoneTests`' phase-two guard in place, re-pin
`PendingRetryOwnershipHandoffTests`' queue-change needle to the remembering
shape, and give `RecordingRetryLane` a `finishFromAnotherSurface(id:)` — the
other surface FINISHING a capture, which `reserveForAnotherSurface` cannot
model. Two new files, `ConduckTests/MenuBarEscCancellationContractTests.swift`
and `ConduckTests/WatchWorkRelayRecoveryTests.swift` (the watch target's own
files needed no `pbxproj` edit because everything was appended to existing
classes — `ConduckWatchTests` has no synchronized group).

The share sheet takes the iOS suite 5,505 → 5,508 with no new file:
`ShareTargetFilterTests` gains the two visibility truth tables (a decoded empty
roster, and the four cases that must NOT show the no-AI line), and
`WorkCaptureInboxTests` gains `testTheShareSheetPicksNoDestinationAndRemembersNone`
— one pure predicate over whitespace-collapsed source (no initializer; exactly
five assignment sites, each a row `action:`; no lifecycle body touching the pick;
no mode control and no store of any kind; no `case work` in `ShareTarget`; one
read of the pick and two bound helpers; a Work-only retry; the two `.disabled`
rules) with five negative controls that each mutate the REAL source and must be
reported, the line-broken `.task` assignment among them.
`testShareSurfacesUseDistinctWorkVocabularyAndAdaptivePrimaryActions` is re-pinned
to the new key set, with the seven retired keys asserted absent in source AND
catalog. What a source predicate proves is stated where it lives: these are
targeted regression checks on the source's shape, not a proof of absence — a
construction the rules do not name would pass, which is why the controls sit
beside the rules and grow when a dodge is found (U-70 names three that need one
more assertion each).

Shape, because the rounds kept finding the same test defect: a source guard
proves a call site exists, never that it runs, so every claimed protection is
either driven through the production seam (injected present completions,
suspended operations, substitutable dispatch) or pinned as a WHOLE guard body
with an explicit negative control that must fail. `CarPlayStartGate`'s truth
table is exhausted; `WatchAskDestinationRows` is a pure fixture; the expiry
budgets are asserted at 601 s and 86,401 s on both destinations; the lane
transitions establish a real pin, hold it through `.idle`, and only then start
the other lane, so deleting either production clear fails.

## Codex rounds

Three design rounds per lane before implementation, four implementation rounds
per lane over the finished diff, then one close-out round over all three lanes
together with the cross-lane fixes.

**Design** (`verify/codex-design-{watch,carplay,mac}-r1…r3.md`). Watch: 11 + 9 +
4 findings — the invisible destination during recording, the master switch read
only at draw, the empty-roster sentence, and the vacuity of the first test set
all changed the design; Work-first ordering and a list-sheet presentation were
weighed and refused, the latter kept as the remedy if the max-roster QA case
fails. CarPlay: 12 + 8 + 8 — the start race, the mic hint, Mute, the 600 s
expiry, the unparked transcript and the day-one order were all accepted; the
`.notSaved` line was refused. The both-doors chooser was refused at design time
and recorded as a standing disagreement, then taken by founder override and
built in the non-sticky action form Codex itself proposed — which is what closes
the disagreement rather than overrules it. Mac: 10 + 7 + 5 — the reading was confirmed in all three, and the
findings became the polish list. Share sheet: 3 + 1 + 0 — round 1 blocked twice
(a Try Again that read the current row, and the dead `sendCircle` that makes the
`send()` rename uncompilable unless it goes), round 2 re-cut the
no-pre-selection guard onto whitespace-collapsed source after a line-broken
assignment dodged the line rule, round 3 accepted as is with no disagreement
left. Its three taste calls — nothing pre-selected, "Where to?", Work last in its
own scrolling section — carry Codex's support and stay founder-reversible
(`design/share-work-destination.md` §10).

**Implementation.**

| Lane | R1 | R2 | R3 | R4 | Still open |
|---|---|---|---|---|---|
| Watch | 3 raised, all carried | 8 + 2 re-opened; 5 fixed | 10 raised; 6 fixed | 8 raised; 5 fixed | W-R4-1 (legacy deferred entries mint against the current default) → U-54; closed on merit three times and not re-raised in R5 |
| CarPlay | 10 raised; 5 fixed | 13 raised; 6 fixed | 11 raised; 2 fixed | 12 raised; 2 fixed | CP-R4-01 → U-48 (founder decision) · 02, 03, 04, 08 → closed by the cross-lane pass, with U-49 (CarPlay's own half), U-58 and U-63 as residuals · 05, 09 (closed by the Mac lane) · 07 (closed by the relay's parked words, U-57 residual) |
| Mac | 8 raised; 6 fixed | 10 raised; 7 fixed | 17 raised; 14 fixed | 19 raised; 13 fixed | MAC-R4-P1-A → U-48 (founder decision) · P2-C, P2-M → closed by the cross-lane pass, with U-59, U-60 and U-61 as residuals · P2-F (closed by the relay's parked words) · P2-G → U-53 |
| Share sheet | 5 raised, all P3; none fixed | — | — | — | S-R1-1 → U-68 · S-R1-2 → U-69 · S-R1-3…5 → U-70 |
| Cross-lane | — | — | — | 11 forwarded items fixed | CP-R4-01 / MAC-R4-P1-A → U-48 (closed by founder decision) · MAC-R4-P2-G → U-53 (declined on merit, below) · the CarPlay half of the microphone gate → U-49 |

A fifth round reads all three lanes and the cross-lane fixes in one pass
(`verify/codex-r5-work-destination-closeout.md`), judged against the founder's
stated boundary rather than a stricter reading of it. **No P1.** CP-R4-04,
CP-R4-08, the four CP-R4-10 out-of-lane guard rows and MAC-R4-P2-M's production
arms are closed; CP-R4-02 and CP-R4-03 are closed on their normal paths with one
residual each. The CarPlay chooser's Work row passes with no product finding, and
the founder's three options are met on all five surfaces with no destination
crossover. Seven items are raised, every one of them induced by a round-4 or
cross-lane fix rather than by a lane: four P2 (U-57 – U-60) and three P3
(U-61 – U-63), and all seven are fixed.

| Close-out round | Reads | Raised | Left standing |
|---|---|---|---|
| R5 | all three lanes and the cross-lane fixes in one pass (`verify/codex-r5-work-destination-closeout.md`) | 7, every one fix-induced: four P2 (U-57 – U-60), three P3 (U-61 – U-63) | all seven, each fixed below |
| R6 | the seven close-out fixes themselves, read-only over the working diff against the tip (`verify/codex-r6-work-destination-p2-pass.md`) | **clean — no P1, no P2**; two P3 residuals, both inside a fix rather than beside it | the busy-sentence assertion's breadth (U-59) and a queue arrival landing inside the consume read's own await (U-63) |

Three findings recurred in every round. The first is the only P1 among them:
**automated entry points reach Work with no foreground press** — the background
`CaptureWorkboardIntent`, `AddFilesToWorkIntent`,
`ConverseIntent(destination: .work)`, and the Siri record phrase whose route
opens a sheet that starts the microphone on appearance. Each lane forwarded it as
the intents lane's work, and Codex's answer each time was that forwarding assigns
the fix without resolving the violation. It is U-48, and it is **closed by
founder decision**: Work is meant to be reachable hands-free and by automation,
so the boundary is routing, not attendance — an implicit trigger that names no
destination goes to the default gateway, and only an explicit pick or a
parameter naming Work reaches the desk. The other two are closed by the
cross-lane pass: the phone refuses a capture while the car holds the session and
no longer tears that session down on its own stop, and both phone layouts observe
`PendingRetryStore.queueDidChangeNotification`. What is left of the microphone
gap is one line inside the CarPlay lane's own file (U-49).

Every documentation finding the rounds raised is closed here: the README's
"Record to Work…" (the menu says "Capture to Work…"), the handoff's Mute step and
its wrong entitlement key, the QA fixtures that prescribed outcomes their own
setup could not produce (a dead STT endpoint is retryable, not settled; a
zero-gateway headless press refuses; the empty-roster line cannot render under a
maximum roster), and the watch catalog's stale rows.

### Close-out fixes (R5-1 … R5-7)

- **R5-1 — the card's stored code is a DIAGNOSIS, not a verdict.**
  `refreshPendingRetryState` restores `pendingRetryIsRetryable` instead of
  deriving it from `PendingRetryStore.pendingErrorCode()`. That code answers for
  the NEWEST entry while the card speaks for the whole queue, so a terminal one —
  the relay's own parked `.work` / `.published` entry, code 23 — took Retry off an
  older Chat recording, and a re-read of the same persisted code never handed the
  button back however the key was restored. The withdrawal now belongs to the
  attempt that earned it, which `attemptPendingRetry` writes; the menu-bar
  popover already gated its Retry on the count alone, so the two hosts follow one
  rule. Both relay arms still park their words.
- **R5-2 — a refused CLAIM preserves nothing.** The last ownership question
  before the transcript write returns through `refuseOvertakenWorkCapture` rather
  than `failPendingWorkCapture`: the surface that overtook this run may have
  finished the recording and retired its entry, and preserving wrote that entry
  back under the same id with this run's stale words. The capture stays in hand
  with its retryable error and `retryRefusedBusy`; the durability reading still
  runs (a read, not a write); there is nothing to hand back, because the lapsed
  claim is dropped above the call.
- **R5-3 — the stopped state outlives a Try Again that never started.** The press
  no longer clears `transcriptionStopped`. A reservation refusal leaves the
  recorder `.idle` and returns an error `handle(_:)` prints nothing for, so
  clearing first put the sheet back on "Starting the microphone…" over no
  controls. It is cleared by the sheet's own start and by a capture that
  finished, and the stopped state now carries `pendingRetry.card.busy` while
  `retryRefusedBusy` stands.
- **R5-4 — the stopped-state receipt is the desk's answer.** It reads
  `WorkCaptureFacts.recordingOnDesk`, which the cancellation path's
  `refreshDeskFacts` has just re-read, instead of asserting a card from the
  retained capture. A card deleted on another device while recognition ran leaves
  the capture retained and the receipt false; the second sentence
  (`workboard.voice.stopped.body.noCard`) says what a retry can still do there.
- **R5-5 — the phase-two switch guard is bounded by its own braces.**
  `WatchWorkRelayPhoneTests` brace-matches the switch and pins each non-attached
  arm's COMPLETE body ending in `return`. The old extraction searched the rest of
  the file for the next `case `, so a catch arm's `return` far below satisfied it
  — measured: with the production `return` deleted the old guard passed and the
  new one fails.
- **R5-6 — the iOS microphone gate is asked on both sides of the permission
  prompt.** `AudioRecorder.startRecording()` re-reads
  `CarPlayRecordingService.anySessionActive` after the prompt and above the first
  line that takes the input, throwing the new typed
  `AudioRecorderError.microphoneBusy` (mapped to `.audioMicBusy` by
  `InAppAudioRecorder`, to `micBusyMessage` by both STT testers, and worded from
  the existing `audio.error.micBusy` row). The caller's own refusal is read BEFORE
  the sheet, so a drive that began while it stood was invisible to it. The
  activate-half skip below stays.
- **R5-7 — a skipped queue change is remembered.**
  `handlePendingRetryQueueChange` still steps aside for exactly `isRetrying` and
  `confirmingPendingRetryDiscard`, and now records
  `pendingRetryQueueChangeMissed`. `consumePendingRetryQueueChange(keepingVerdict:)`
  spends it at `runPendingRetry`'s single exit and in `discardPendingRetry` (count
  and presence only — the run wrote the verdict and the sticky line is the whole
  remedy) and in `releasePendingRetryDiscard` (full refresh — a cancelled question
  decided nothing). Any full `refreshPendingRetryState()` consumes it too.

### Share sheet — one implementation round

`verify/codex-r1-share-work-destination.md` reads the finished diff: **no P1 and
no P2**. The two inboxes stay separate roots with separate drainers whose
mandatory identity keys differ (`uuid` against `id`), so a misplaced envelope
fails decoding rather than becoming the other lane's input; both copies hold
exactly five destination assignments and all ten are row actions; the retry is
Work-only, the rows lock while a commit runs, and `begin()` claims the phase
synchronously; every paired file still matches below its header; and each catalog
carries exactly the keys its view asks for. Five P3 stand, none of them a
regression this change introduced, each carried as an open item:

- **S-R1-1 → U-68.** A query matching nothing hides the picked gateway row while
  the button still reads Send now and ⌘-Return still sends to it. The smallest
  fix asks whether the pick is still displayed and falls back to the neutral
  label — it picks nothing for anybody, so it does not contradict decision 15.
- **S-R1-2 → U-69.** The legacy "New conversation" row's all-nil routing fields
  enter the legacy resolver, which returns a live continuation on the default
  gateway. The resolver predates this branch; a row offering it BY NAME does not.
  QA step 128 says what that route actually delivers.
- **S-R1-3 → U-70.** The inbox-binding rule checks that the Work helper calls
  `onAddToWorkboard(`, never that it does NOT call `onSend(` — a helper doing
  both would pass. The shipped helper has no such leak; its guard misses it.
- **S-R1-4 → U-70.** The disabled-button rule matches the prefix
  `.disabled(destination == nil` whichever operator follows, so `&&` for `||`
  passes with the button live on an empty pick.
- **S-R1-5 → U-70.** The lifecycle rule reads comments as code: the tip fails
  rule (c) on the word "destination" inside an `onAppear` comment, and a comment
  added inside a clean `.task` would fail a clean view.

Compilation, rendered layout and announcements are outside a read-only round —
they are QA steps 121–133.

## Nobody undo

Every line here is a rule some round bought with a defect. They interlock — undo
one and another stops meaning what it says.

- **Ask opens the chooser on EVERY press.** A `count >= 1` bypass takes Work off
  the single-gateway path, which is the case the founder named.
- **A Work pick clears the Ask hint and every conversation pin; a gateway pick
  writes the hint.** Neither lane reads the other's state, and no lane recovers
  an explicit choice from the current default.
- **A deferred hop is handed the ref off its OWN queue entry.** Never the current
  default, never another capture's live hint. An entry that predates the field
  mints against the default and logs that it guessed (U-54).
- **A reply or a failure callback proves it owns the CURRENT capture before it
  touches live state** — destination and request identity, not `sessionActive`,
  and not "the pins are nil".
- **`WatchGatewayLabel` resolves the whole roster together and verifies
  uniqueness across all of it**, untouched short labels included; per-name
  shortening reintroduces the collision. The shared `shortDisplayName` policy
  stays exactly as it is — other surfaces depend on it — and VoiceOver always
  gets the full name.
- **One CarPlay start is claimed synchronously and re-validated after every
  suspension**, including inside both present completions; only the serial's
  holder releases it. A refused start dismisses a modal only when no claim and no
  session own it, because connection identity is not presentation identity.
- **A CarPlay Work note has no Mute and never re-arms**, and the mic-failure hint
  names the row that failed.
- **The drive-long override is `RemoteAgentRef`-typed.** Widening it to a
  destination is the drive-long Work mode this design refused.
- **The transcript is parked before the attach**, and ownership is asked AFTER
  the parking, because the parking is itself a suspension and its false answer
  has two opposite meanings.
- **`publishedWorkRetryTTL` applies only to `.work` + `.published`.**
  `isExemptFromExpiry` is a different idea — bytes that exist nowhere else — and
  merging them puts a clock on the only copy of a recording.
- **The router, the glyph, the click and the bail all yield to the live
  microphone.** All four or none: a click stops what the surface hides, and a ✕
  discards what it cannot show.
- **`bailWorkCapturePress()` moves the press generation unconditionally**, even
  when the bail deliberately leaves the Work recorder alone.
- **`⌃⌘W` asks `SpeechExclusivity` before it raises an overlay**, through
  `standDownForBusyMicrophone()` — never `showPopover()` inlined, and never a
  stop.
- **"Start Recording" in the status-item menu is `handleShortcutPress()`.** A
  menu door with an arm of its own re-arms a turn already in flight.
- **The typed receipt binds the drain AND the desk read-back.** The drain report
  identifies nobody, so it can say nothing about this capture.
- **The quit guard holds while a stopped capture has no durable copy**, and the
  unsaved-capture registration is balanced on discard and on sheet disposal.
- **The chooser's Work row is an ACTION: it claims the start BEFORE it pops,
  hands that same serial to `presentWorkNote`, and stores nothing.** No
  checkmark, no `sessionDefaultRefOverride`, no destination kept anywhere — the
  rows above it store this drive's gateway, and a Work row that stored anything
  would be the drive-long mode that hands a private thought to an AI after the
  next silent reconnect. Claiming after the pop re-opens the race with "New voice
  chat" one row underneath; claiming twice refuses the row with its own claim;
  presenting before the pop puts the voice modal over a chooser that is still
  animating away. The one-tap ROOT row stays — it is the only working row on day
  one — and both doors enter the SAME `presentWorkNote`, which is where g1 and
  the End-only button contract are proven.
- **The iOS microphone gate is TWO halves and both are load-bearing.**
  `InAppAudioRecorder.startRecording()` refuses with `.audioMicBusy` while
  `CarPlayRecordingService.anySessionActive`, and `AudioRecorder`'s iOS session
  activate AND both deactivate sites skip while the same flag is true. Delete the
  start half and a phone capture reconfigures the car's session; delete the
  release half and a capture that began before the car connected tears the
  driver's route down on its own stop. CarPlay registers nothing on
  `SpeechExclusivity` by construction, so the mirror is the only reachable owner
  signal — the same read `ThreadSpeaker` makes before it touches the playback
  session.
- **`PendingRetryStore.save` commits the index row BEFORE it reports a failed
  screenshot write.** The sidecar and the audio are already durable above it and
  `reconcile` step 5 adopts that pair regardless, so a throw taken at the picture
  produced a live entry its own author could neither reserve nor retire. The
  picture's failure travels as
  `PendingRetrySaveOutcome.recordingParkedWithoutPicture`, never as an abandoned
  arm.
- **`noteWorkDurability` answers for the two artifacts separately.**
  `pictureSafe` reads `parked && !armedRetryOmittedPicture`, not plain `parked`:
  an arm can hold the recording and not the picture, and an entry sheltering no
  picture is not a place the picture is safe.
- **Both relay acknowledgement arms park the words before they ship.** The typed
  `AppError` arm and the untyped `audioProcessingFailed` arm send the SAME
  sentence through the same one-way door — cached, and the wrist deletes its clip
  on reading it — so one arm that ships without `preserveRelayedWorkWords` is
  "Add the words on your iPhone" pointing at nothing.
- **The last ownership question comes immediately before the transcript write.**
  `reserveDurableRetry` revalidates a cached hold rather than trusting it, and
  `finishAndUpload` re-asks before phase two. The renewal loop deliberately never
  stops on a refusal, so without both, a recorder can arrive at the write certain
  it owns a capture another surface is finishing.
- **`releaseWorkPublication` decrements; it never assigns.** A count reset to
  zero lets one finishing publication drop another's quit protection — the menu
  bar's recorder and the desk sheet's are different instances.
- **The phone root's queue-change refresh steps aside for exactly two states and
  no others.** `isRetrying` (the run writes the card's verdict itself on every
  exit) and `confirmingPendingRetryDiscard` (the alert is attached to the card a
  refresh can remove). Any wider condition puts the observer back to sleep on the
  case it exists for.
- **A queue change the phone root steps aside for is REMEMBERED and consumed when
  the state that skipped it ends.** The announcement comes once; the exits re-read
  the queue for the capture they were working on, not for one another surface
  parked meanwhile. This extends the two-state rule above — the two states
  themselves are unchanged.
- **The retry card's stored error code is a DIAGNOSIS and never a verdict on the
  next tap.** It answers for the newest entry while the card speaks for the queue
  behind it, and it cannot tell a failure from one the person has since fixed.
  Retry is offered while anything is waiting; the withdrawal belongs to an attempt
  made in this session, and `refreshPendingRetryState` is the hand-back.
- **A refused CLAIM preserves nothing; only a refused WRITE does.**
  `failPendingWorkCapture` parks, `refuseOvertakenWorkCapture` does not — a
  capture another surface finished has a retired entry, and parking recreates it
  with stale words.
- **`transcriptionStopped` is cleared by a start and by a finish, never by the
  press that offers to finish.** That press can be refused, and a refusal leaves
  the recorder `.idle` with the stopped state as the only thing between it and a
  dead end.
- **The stopped state's receipt reads `WorkCaptureFacts.recordingOnDesk`.** A
  retained capture proves only that something is left to finish, never that its
  card is standing.
- **The iOS microphone gate is asked on BOTH sides of the permission prompt.** The
  caller's pre-prompt refusal answers for a moment that has passed; the
  primitive's own re-read is what refuses a session the car took while the sheet
  stood. This does not replace the two halves above: the start half is asked
  twice, and the activate-half skip with both deactivate sites stays, because
  that pair covers the capture that began before the car connected.
- **A switch-arm source guard is bounded by the switch's own braces and pins each
  arm's WHOLE body ending in `return`.** An unbounded search for the next `case `
  reads past the switch and is satisfied by an unrelated arm.
- **The share sheet pre-selects NOTHING.** `@State private var destination:
  ShareDestination?` has no initializer and no lifecycle hook assigns it; the only
  five assignment sites per copy are row `action:` closures. A default in either
  direction is the silent reroute the boundary names — Work's own cost a redone
  share, a gateway's costs a private document sent to an AI. Reversing it is a
  founder call (`design/share-work-destination.md` §10), never an implementer's.
- **The Work row renders OUTSIDE every branch, last, in its own section.** No
  search, no empty roster and no missing snapshot may take the destination away,
  and the header is load-bearing: the list pins section headers, so a header-less
  trailing row scrolls under RECENT CHATS and reads as a chat.
- **The pick is a `ShareDestination`, never a third `ShareTarget` case.** The send
  manifest writer takes only a `ShareTarget`, so the desk cannot reach the
  manifest however either view is edited. A `.work` case would give that writer's
  `switch` an arm that must never fire.
- **Try Again calls `addToWorkboard()`, never `commit()`, and the rows lock while
  a commit runs** (`.disabled(!selectable || submissionState.isCommitting)`). A
  retry replays what the person approved. The mode picker held that lock at the
  tip and the rows did not, because the pick could not change the inbox then; it
  can now. Either rule alone closes the round-1 reroute — pick Work → commit →
  tap a gateway during the copy → `.unavailable` → Try Again — and both are kept
  because each is one line and they fail independently.
- **The legacy "New conversation" row appears only when NO snapshot decoded, and
  it is tappable.** Undecoded is unknown, not empty. A decoded empty roster is
  told instead. Making the row non-selectable again is a dead end now that
  nothing is pre-selected.
- **Neither `ShareView` reads or writes a stored pick.** No defaults store, no
  scene storage, no key-value store, no file access anywhere in either view: the
  appex reads the snapshot through its host and writes envelopes, and nothing
  else. "No sticky Work state that survives to the next share" is the founder's
  verbatim rule, and a remembered GATEWAY pick is the same mechanism pointed the
  other way.
- **Both destination-list rules live in `ShareTargetFilter`, byte-identical below
  the header in both copies.** They are pure, so the truth table is unit-tested
  rather than QA'd, and the mirror guard fails the build if one copy moves.

## Known limits

- **One extra tap per Ask on a single-gateway watch.** The founder's own wording;
  the reversal costs Work its place on that path.
- **Work is one tap deeper on the wrist.** It left the launchpad for the chooser.
- **A long roster scrolls.** The `confirmationDialog` was kept rather than a list
  sheet; acceptance is the maximum supported roster with long similar names, at
  the largest text size, under VoiceOver, on a 41 mm face (QA 66f). The list
  sheet is the remedy if that fails, not the failure.
- **CarPlay has two doors to one action.** The permanent root row, and the last
  row of the "Choose AI" list wherever that list exists. The cost is the one the
  design named: more rows on a car screen, and one more template pop on the g1
  path. The list keeps its "Choose AI" title, which is narrower than its contents
  (U-64).
- **A published Work entry now lingers up to a day on every surface**, the Mac
  and phone included. The exit is the existing confirmed discard or the clock.
- **The share-and-go path is two taps** — row, then Send now — where the
  pre-Work sheet was one. The founder's own trade on the wrist, and the reversal
  (pre-select the first gateway) re-opens the direction the boundary calls
  unrecoverable.
- **Work is a scroll away on a long list.** Twelve recents plus the gateways put
  the row below the fold on an iPhone, as on the wrist: a stable relationship,
  not a fixed position. The remedy if QA disagrees is a fixed last row pinned
  beneath the scroll region, which costs a visual gap on a short list.
- **"No personal AI available." can render on a STALE snapshot**, hiding the send
  route until the app is opened once and the writer runs. Recorded, not guarded:
  the writer regenerates on every conversation and settings change.
- **U-48 through U-70** in the handoff. Closed there: the unattended-trigger
  boundary (founder decision), the phone's queue observer, the lapsed
  reservation, the partial retry save, the phone desk sheet after a cancelled
  transcription, the test that pinned a helper rather than the reply it feeds,
  all seven close-out items (U-57 – U-63), and the share sheet's own two —
  a disabled button drawn disabled (U-66) and comments that name the destination
  list (U-67). Still open: the CarPlay half of the microphone gate (U-49), a
  republished deleted card (U-53), the legacy deferred entry (U-54), the
  chooser's title (U-64), 140 pre-existing orphan catalog rows (U-65), and the
  two P3 residuals the sixth round left inside their own fixes — the
  busy-sentence assertion's breadth (U-59) and a queue arrival landing inside the
  consume read's await (U-63) — plus the share sheet's own three (U-68 – U-70).
