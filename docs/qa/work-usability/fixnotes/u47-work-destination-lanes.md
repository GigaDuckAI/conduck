# U-47 — Work as a destination: the wrist, the car, and the Mac's third capture

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
around it rather than a re-cut. On all three, a Work pick is one speech hop and
no LLM step.

Each lane was designed before it was cut (`design/watch-work-destination.md`,
`design/carplay-work-destination.md`, `design/mac-work-destination.md`), each
design was read three times by Codex, each implementation four times more, and
the finished wave once more end to end.

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
a singular header), and the four `quitGuard.unsaved.*.v2` rows whose wording is
capture-neutral. CarPlay adds none: `carplay.picker.addToWork.title`,
`carplay.hint.captureStartFailed.detail{,.work}` and the two saved lines all
already existed.

Both catalogs: `plutil -convert xml1`, `python3 -m json.tool`, and a duplicate-key
load with `object_pairs_hook` — clean, and round-trip fidelity was checked against
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

**Shared:** `Services/PendingRetryStore.swift` (`publishedWorkRetryTTL`) ·
`Services/InAppAudioRecorder.swift` (durability accounting, cancellation at the
write) · `Services/AppleSpeechRelayCoordinator.swift` (parked words before a
wordless acknowledgement) · `Services/Workboard/WorkVoiceCaptureCoordinator.swift`
· `Services/AudioRecorder.swift`.

## Tests

The iOS suite goes 5,433 → 5,485 and the watch suite 269 → 302; both green, one
known environment skip. Two new files, `ConduckTests/MenuBarEscCancellationContractTests.swift`
and `ConduckTests/WatchWorkRelayRecoveryTests.swift` (the watch target's own
files needed no `pbxproj` edit because everything was appended to existing
classes — `ConduckWatchTests` has no synchronized group).

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
findings became the polish list.

**Implementation.**

| Lane | R1 | R2 | R3 | R4 | Still open |
|---|---|---|---|---|---|
| Watch | 3 raised, all carried | 8 + 2 re-opened; 5 fixed | 10 raised; 6 fixed | 8 raised; 5 fixed | W-R4-1 (legacy deferred entries mint against the current default) → U-54; closed on merit three times and not re-raised in R5 |
| CarPlay | 10 raised; 5 fixed | 13 raised; 6 fixed | 11 raised; 2 fixed | 12 raised; 2 fixed | CP-R4-01 → U-48 (founder decision) · 02, 03, 04, 08 → closed by the cross-lane pass, with U-49 (CarPlay's own half), U-58 and U-63 as residuals · 05, 09 (closed by the Mac lane) · 07 (closed by the relay's parked words, U-57 residual) |
| Mac | 8 raised; 6 fixed | 10 raised; 7 fixed | 17 raised; 14 fixed | 19 raised; 13 fixed | MAC-R4-P1-A → U-48 (founder decision) · P2-C, P2-M → closed by the cross-lane pass, with U-59, U-60 and U-61 as residuals · P2-F (closed by the relay's parked words) · P2-G → U-53 |
| Cross-lane | — | — | — | 11 forwarded items fixed | CP-R4-01 / MAC-R4-P1-A → U-48 (closed by founder decision) · MAC-R4-P2-G → U-53 (declined on merit, below) · the CarPlay half of the microphone gate → U-49 |

A fifth round reads all three lanes and the cross-lane fixes in one pass
(`verify/codex-r5-work-destination-closeout.md`), judged against the founder's
stated boundary rather than a stricter reading of it. **No P1.** CP-R4-04,
CP-R4-08, the four CP-R4-10 out-of-lane guard rows and MAC-R4-P2-M's production
arms are closed; CP-R4-02 and CP-R4-03 are closed on their normal paths with one
residual each. The CarPlay chooser's Work row passes with no product finding, and
the founder's three options are met on all five surfaces with no destination
crossover. Seven items are open, every one of them induced by a round-4 or
cross-lane fix rather than by a lane: four P2 (U-57 – U-60) and three P3
(U-61 – U-63).

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
- **U-48 through U-65** in the handoff. Closed there: the unattended-trigger
  boundary (founder decision), the phone's queue observer, the lapsed
  reservation, the partial retry save, the phone desk sheet after a cancelled
  transcription, and the test that pinned a helper rather than the reply it
  feeds. Still open: the CarPlay half of the microphone gate, a republished
  deleted card, the legacy deferred entry, the seven close-out residuals
  (U-57 – U-63), the chooser's title (U-64) and 140 pre-existing orphan catalog
  rows (U-65).
