# e-carplay — CarPlay "Add to Work"

Slice E. A permanent picker row that records a ONE-SHOT voice note straight onto the
driver's own desk. Nothing on the lane touches `startConverseHop`, a gateway ref or a
conversation, and no Work card is ever drawn on a car screen.

## What changed

### `Conduck/Conduck/CarPlay/CarPlayRecordingService.swift`

| Symbol | What it is |
|---|---|
| `enum CarPlayCaptureDestination { chat, work }` | File-scope. Where a session's recording goes; chosen by the picker row, fixed for the session, deliberately not a mode the driver can switch mid-session. |
| `VoiceState.saving` + a fifth `CPVoiceControlState` | Identifier `"saving"`, title "Saving…". A TEMPLATE-only state: `State` gains no case, so the session stays `.processing` while it shows and the scene's `@Observable` state observer never fires and never repaints over it. |
| `sessionDestination` (`@ObservationIgnored private var … = .chat`) | Set to `.chat` in `beginSession`, `.work` in `beginWorkNote`, reset to `.chat` in BOTH `endSession` and `teardown`. Frozen into a local at the top of `processRecording`. |
| `beginWorkNote()` | `beginSession` minus `sessionConversationID`, `sessionDefaultRef` and `setActiveService(self)`. The last omission is the load-bearing one: `setActiveService` is what routes a background converse reply into this service to be SPOKEN, so a Work session claiming it would read an unrelated drive's late reply out over a private note. |
| `CarPlayRecordingService.WorkNoteCapture` | `{ captureID; audioFileURL; guardToken }`. Its existence IS the fork's verdict — non-nil means the bytes are queued AND the recording is a card. |
| `CarPlayRecordingService.WorkNoteOutcome` + `workNoteOutcome(recordingPublished:transcriptAttached:)` + `workNoteAcknowledgement(for:)` | The spoken acknowledgement as a pure function, extracted so it is testable without a head unit. |
| `secureWorkNote(compression:containerURL:attemptID:)` | PHASE 1. Writes the compressed copy under a `carplay_work_` name, arms `PendingRetryGuard` with `destination: .work`, deletes the container CAF, shows `saving`, publishes through `WorkVoiceCaptureCoordinator.publishRecording(… sourceDevice: "carplay")`, records `.published` / `.phaseOneFailed` on the queue entry, restores `processing`. |
| `attachWorkNoteTranscript(_:transcript:attemptID:)` | PHASE 2. `attachTranscript`, then `.attached` → disarm + "Saved to Work."; `.recordingMissing` / `.notAudio` → left armed, "Saved to Work. Add the words on your iPhone."; a THROW → left armed, same line. |
| `endRefusalBelowFork(_:chatLine:)` | One place where the two lanes' refusal copy diverges. Chat keeps its existing line verbatim; Work speaks the saved-without-words line. |
| `processRecording()` | Forks after `AudioCompressor.compress`. See the ordering table below. |

### `Conduck/Conduck/CarPlay/CarPlaySceneDelegate.swift`

| Symbol | What it is |
|---|---|
| `static func recentRowBudget(maximumItemCount:showsStartFailureHint:)` | The picker's row arithmetic, extracted pure. `recentCap(max − hint − 1)` — one more subtraction than before, for the permanent Work row. **`CarPlayConversationLabel.recentCap` is untouched.** |
| `makeWorkNoteItem(service:)` | The "Add to Work" row (`tray.and.arrow.down.fill`, no detail text). Used in BOTH picker states so the two cannot drift into different labels or handlers. |
| `startWorkNote(service:)` | `startSession` minus the whole gateway pre-flight — no `newChatPlan`, no ref, no snapshot, no chooser. `setMuteButton` → `ensureVoicePresented(voiceState: "listening", animated: false) { service.beginWorkNote() }`, so g1 (engine start INSIDE the present completion) holds verbatim. No `Task` hop: nothing here suspends. |
| `refreshPicker()` | Uses `recentRowBudget`; appends the Work row to `firstSectionItems` in the normal branch, and to the setup-hint row's section in the no-gateway branch. No tab bar, no nav-bar button. |

### Ordering in `processRecording` (the durability contract)

```
read CAF bytes
  ├─ .chat  → delete the CAF now (unchanged)
  └─ .work  → KEEP it: this is the lane that promises the recording survives, and
              a promise made while the only copy is a `Data` in a killable process
              is not one. `endSession` removes it on every terminal path.
state = .processing; beginBackgroundTask()
AudioCompressor.compress
── THE WORK FORK ───────────────────────────────────────────────────────────────
  isCurrentListen                       ← after compression
  write carplay_work_<id>.<ext>
  PendingRetryGuard.arm(destination: .work, requestNotificationAuthorization: false)
  delete the container CAF              ← FIRST instant at which it loses nothing
  isCurrentListen                       ← after the preserve
  voice state "saving"
  publishRecording(… sourceDevice: "carplay")
      success → recordPublicationState(.published)   (NOT cleared)
      throw   → recordPublicationState(.phaseOneFailed) → speak "Couldn't save that
                yet. Open Conduck to retry." (or the plain line if `arm` preserved
                nothing, since then there is nothing to retry)
  isCurrentListen                       ← after the publish
  voice state "processing"
  lease-renewal task (PendingRetryGuard.leaseRenewalInterval), cancelled by `defer`
────────────────────────────────────────────────────────────────────────────────
custom-endpoint refusal / STT key readiness   → endRefusalBelowFork
  isCurrentListen                       ← after key readiness (Work lane only)
STTClient.transcribe  (Work reuses the file written above; Chat writes its own)
  empty transcript → "Saved to Work. Add the words on your iPhone."  (never handleEmptyTurn)
  AppError / unknown → same line                                    (never speakErrorAndEnd)
  transcript → attachWorkNoteTranscript
      isCurrentListen                   ← after the attach
      .attached → disarm → "Saved to Work."
```

One-shot throughout: no re-arm, no follow-up listen. `endSession(speak:)` keeps the voice
modal presented for the acknowledgement and drops to `.idle` in the TTS completion, so the
scene dismisses the modal and releases the audio route only after the driver has heard it.

## New API

```swift
// CarPlayRecordingService.swift, file scope
enum CarPlayCaptureDestination: Sendable, Equatable { case chat, work }

// CarPlayRecordingService
func beginWorkNote()
struct WorkNoteCapture: Sendable { let captureID: UUID; let audioFileURL: URL; let guardToken: PendingRetryGuard.Token }
enum WorkNoteOutcome: Sendable, Equatable { case saved, savedWithoutWords, notSaved }
nonisolated static func workNoteOutcome(recordingPublished: Bool, transcriptAttached: Bool) -> WorkNoteOutcome
nonisolated static func workNoteAcknowledgement(for outcome: WorkNoteOutcome) -> String

// CarPlaySceneDelegate
static func recentRowBudget(maximumItemCount: Int, showsStartFailureHint: Bool) -> Int
```

Private (named because the guard tests scope to them): `secureWorkNote(compression:containerURL:attemptID:)`,
`attachWorkNoteTranscript(_:transcript:attemptID:)`, `endRefusalBelowFork(_:chatLine:)`,
`CarPlaySceneDelegate.makeWorkNoteItem(service:)`, `CarPlaySceneDelegate.startWorkNote(service:)`.

Nothing outside `Conduck/CarPlay/` changed. No existing signature changed.

## New strings

App catalog (`Conduck/Localizable.xcstrings`) — five rows, all `carplay.*`:

```
carplay.picker.addToWork.title | Add to Work | CarPlay picker row that records a spoken note straight onto the Work desk. Read at a glance from the driver's seat, so it must stay short.
carplay.voice.saving.title | Saving… | Title on the CarPlay voice screen while a spoken Work note is being written to the desk.
carplay.work.saved.speak | Saved to Work. | Spoken in the car when a Work voice note and its words are both on the desk.
carplay.work.savedWithoutWords.speak | Saved to Work. Add the words on your iPhone. | Spoken in the car when the recording reached the desk but transcription did not finish. Heard once at speed, so it must say both what happened and what to do.
carplay.work.notSaved.speak | Couldn't save that yet. Open Conduck to retry. | Spoken in the car when a Work voice note could not reach the desk. Only ever spoken while the recording is queued for retry.
```

Reused unchanged (existing rows, no new key): `Couldn't save — try again.`,
`Add your STT key in Conduck on your iPhone.`,
`Couldn't read your STT key. If your iPhone just restarted, unlock it and try again.`,
`Custom voice endpoints aren't available in the car. Pick another provider in Conduck on your iPhone.`

The `carplay.*` prefix is deliberate: `WorkboardCopyTruthGuardTests` rule (4) walks
`workboard.*` and `pendingRetry.*` in BOTH directions, so a `workboard.`-prefixed key
referenced in source before the copy agent writes the row would turn that guard red. None
of the five is an `intent.*` identity row, so rule (7) does not apply.

## Tests

`Conduck/ConduckTests/CarPlayWorkNoteTests.swift` — new, 18 cases, whole file inside
`#if os(iOS)` (both files under test are iOS-only, as the CarPlay half of
`HeadlessGatewayPreflightTests` is).

| Case | What it pins |
|---|---|
| `testTheWorkRowCostsExactlyOneRecentConversation` | `recentRowBudget == recentCap − 1` |
| `testTheStartFailureHintCostsAnotherOneOnTopOfIt` | hint still costs a row; 10 / 9 at a ceiling of 12 |
| `testTheFirstSectionAndTheRecentListAlwaysFitTheTemplateCeiling` | ceilings 0…16 × hint on/off: fixed rows + recents ≤ ceiling |
| `testATinyCeilingRefusesRecentsRatherThanGoingNegative` | floors at 0 |
| `testTheSessionDestinationFallsBackToChatAndIsAskedForOnlyByTheWorkRow` | the stored `.chat` default and all four mutation sites |
| `testTheWorkSessionStarterRegistersForNothingAGatewayWouldNeed` | `beginWorkNote` touches no `setActiveService` / ref / conversation |
| `testTheAcknowledgementIsDecidedByPublicationFirstAndWordsSecond` | the three real (published?, attached?) pairs |
| `testAnImpossibleStateNeverClaimsTheNoteIsSaved` | `(false, true)` → `.notSaved`, never `.saved` |
| `testTheThreeSpokenLinesAreDistinctAndNoneOfThemMentionsSending` | distinct, non-empty, and free of send/sent/dispatch/draft/brief/chat/conversation |
| `testOnlyTheUnsavedLineInvitesTheDriverBackToThePhoneToRetry` | only the queued outcome invites a retry |
| `testTheRecordingIsSecuredBeforeTheSpeechHopIsAttempted` | `secureWorkNote(` precedes `STTClient.shared.transcribe(` |
| `testTheBytesReachTheQueueBeforeTheContainerFileIsDeletedAndBeforeTheDeskWrite` | `arm` < CAF delete, `arm` < publish, plus `sourceDevice: "carplay"`, both publication verdicts, `requestNotificationAuthorization: false` |
| `testTheQueueEntryIsReleasedOnlyWhenTheWordsActuallyLanded` | exactly one `disarm`, inside `.attached` |
| `testEverySuspensionOnTheWorkLaneIsFollowedByAStalenessCheck` | ≥2 `isCurrentListen` in each Work-only function |
| `testTheWorkLaneReachesNoGatewayAndNeverReArmsTheMicrophone` | the three Work-only functions contain none of `startConverseHop` / `startDeferredConverseHop` / `handleQuickSend` / `handleEmptyTurn` / `speakThenRearm` / `reArmAfterSettle` / `speakErrorAndEnd` |
| `testTheSharedBodysGatewayAndReArmExitsSitBehindAForkTest` | in `processRecording`, every `handleEmptyTurn(` / `startConverseHop(` has a `workCapture` test within the preceding 10 code lines; ≥3 sites (non-vacuity) |
| `testTheWorkRowStartsASessionWithNoGatewayPreFlightAndKeepsTheAudioRaceContract` | `startWorkNote` runs no `newChatPlan` / `effectiveCarPlayRef` / snapshot / chooser, and `ensureVoicePresented` precedes `beginWorkNote()` |
| `testTheWorkRowIsOfferedInBothPickerStatesAndTheDeskIsNeverBrowsed` | exactly two `makeWorkNoteItem(` call sites in `refreshPicker`; the whole scene file reads no desk entity |

### Measured

Build: `xcodebuild build-for-testing` (iOS Simulator `04DEF4F5`, no `-configuration`,
`-derivedDataPath ~/Library/Caches/gigaduck-builds/work-e/dd`) —
**`** TEST BUILD SUCCEEDED **`, 0 `: error: `**.

`test-without-building`, every CarPlay class in `ConduckTests` (`grep -l CarPlay`) plus the
new one, in ONE invocation — **exit 0**:

```
CarPlayAttemptCancellationOutcomeTests   Executed  4 tests, 0 failures
CarPlayConversationLabelTests            Executed 17 tests, 0 failures
CarPlayConverseTrustVerdictTests         Executed  8 tests, 0 failures
CarPlayEmptyTurnPolicyTests              Executed 12 tests, 0 failures
CarPlayVADQuantizationTests              Executed 15 tests, 0 failures
CarPlayVoiceTimingContractTests          Executed 22 tests, 0 failures
CarPlayWorkNoteTests                     Executed 18 tests, 0 failures   ← new
──────────────────────────────────────────────────────────────────────
                                         Executed 96 tests, with 0 failures (0 unexpected)
```

Guards this slice could plausibly disturb, second invocation:

```
ErrorSurfaceDriftGuardTests              Executed  7 tests, 0 failures
HeadlessGatewayPreflightTests            Executed 10 tests, 0 failures
LoggingPrivacyDriftGuardTests            Executed  4 tests, 0 failures
WorkDeskWriteOwnershipDriftGuardTests    Executed  6 tests, 0 failures
```

**One failure in that run, and it is NOT this slice's** —
`WorkboardCopyTruthGuardTests.testEveryWorkCatalogRowIsReferencedInSource`:

```
workboard.material.preview.unavailable.title has a catalog row no app-target source
references — it outlived the surface it was written for.
```

That is rule (4)'s orphan half firing on Slice A's deletion of `WorkboardPreviewImage`, and
the plan already assigns it (§Slice A A3: "its `workboard.material.preview.unavailable.*`
keys are reused by the failure state or removed by the copy agent"). Verified not mine:
the string appears in zero files I own (`grep -c` = 0 across `Conduck/CarPlay/*.swift` and
`CarPlayWorkNoteTests.swift`); its only live reference is
`Views/Workboard/PersonalWorkbenchView.swift:707`. All five keys this slice adds are
`carplay.*`, and the guard's `catalogPrefixes` are `["workboard.", "pendingRetry."]`, so
none of them can reach either direction of rule (4).

The tree was red on two sibling slices' files for most of this slice's run
(`Intents/RecordWorkNoteIntent.swift:54` missing `await`, then
`Views/Workboard/PersonalWorkbenchView.swift` main-actor + missing `QuickLook` import);
both were fixed by their owners before the numbers above were taken. Three other agents'
`xcodebuild` runs were live against the same project throughout, so a couple of
invocations were starved mid-flight — every count above is from a run that reported its own
suite totals.

## Requests

1. **Copy agent** — the five `carplay.*` rows above. All five are SPOKEN or read at the
   wheel, so `Saving…` keeps its ellipsis character and the three spoken lines must stay
   short enough to finish before the driver's attention returns to the road.
   `carplay.work.*` rows also need the same language coverage as `Talk to you later.` —
   `CarPlayVoiceTimingContractTests.testTheBrokenCaptureLineExistsWithTheSignOffsLanguageCoverage`
   is the precedent, and a spoken English line in a German car is worse than the picker
   showing an untranslated row.
2. **Docs pass** — `docs/ai-context/spec.md:298` is now FALSE and must be rewritten. It
   says "On CarPlay there is no such place, and none is invented: that refusal loses the
   capture." CarPlay's Work lane preserves through `PendingRetryStore` exactly as the
   headless Shortcut does; the CHAT lane still preserves nothing, so the sentence has to
   be split by lane rather than deleted.
3. **Docs pass** — §Where the surfaces differ should gain the CarPlay Work row (record
   only, never browse) and the fact that a Work capture there is one-shot.
4. **Nobody** — `CarPlayConversationLabel.recentCap` is intentionally left answering the
   narrower "what does row 0 cost" question. Do not fold the Work row into it: other
   callers ask it, and `recentRowBudget` is where the picker's own budget is decided.

## Nobody undo

- **`sessionDestination` resets in BOTH `endSession` and `teardown`.** `teardown` runs on a
  disconnect that may skip a live session entirely, and `endSession` is guarded on
  `sessionActive` — so neither alone covers the other's path. A Work note that left the
  destination set would aim the next "New voice chat" at the desk, and a conversation the
  driver expects an answer to would become a silent note.
- **`beginWorkNote` must never call `setActiveService(self)`.** It is what routes a
  background converse reply here to be SPOKEN. A Work session that registered would read an
  unrelated drive's late reply out loud over a private note.
- **The Work lane keeps the container CAF until `PendingRetryGuard.arm` returns.** Deleting
  it where Chat deletes it (the moment the bytes are in memory) puts the only copy of the
  recording inside a process the OS can kill at any moment, which is exactly the promise
  this lane makes and Chat does not.
- **`.published` is recorded, not cleared.** The entry still covers the speech hop and the
  attach. Clearing on a successful publish would leave a card with no words and no way to
  finish it; and the verdict itself is what stops a later recovery reading the card's
  absence as licence to resurrect one the person deleted.
- **`.recordingMissing` / `.notAudio` leave the entry ARMED.** They are the two answers a
  car cannot settle: an id naming no card is either a deletion or a publication that never
  landed, and only `WorkVoiceCaptureCoordinator.recover` — reading the `.published` verdict
  this lane wrote — can tell them apart. Disarming there would drop the words on the floor.
- **`endRefusalBelowFork` is a fork test, not a copy switch.** Chat's four refusal lines are
  unchanged and still say what is true on the lane that preserves nothing. Do not
  "simplify" the two lanes onto one sentence.
- **`isCurrentListen` after every suspension.** The lane both SPEAKS and WRITES; a session
  that ended under any of these hops must reach neither. The one deliberate exception is
  the disarm in `attachWorkNoteTranscript`, which runs BEFORE its staleness check: the
  capture is finished either way, and leaving it queued would put a retry card on the phone
  for words that are already on the desk.
- **`ensureVoicePresented` before `beginWorkNote()` (g1).** Starting the engine before
  CarPlay finishes attaching the voice modal races `AVAudioSession.setActive` and yields
  `engine.start()` FourCC `'!obj'`. Same contract `startSession` keeps.
- **The `saving` voice state has no `State` case on purpose.** Adding one would fire the
  scene's `@Observable` state observer, which calls `applyState` → `ensureVoicePresented`,
  and the modal's live state would be re-derived from `voiceStateIdentifier(for:)` — which
  has no answer for it.
- **`requestNotificationAuthorization: false`.** CarPlay has nowhere to show a permission
  prompt and the road is not the place to answer one.

## Founder QA

Rig: `docs/qa/carplay-simulator-rig.md` — CarPlay Simulator (Additional Tools for Xcode →
`Hardware/`) on the Mac, the iPhone attached by cable, running a build of this branch.
**Pre-flight first**: if any earlier run showed `engine.start failed … 1852797029` ('nope'),
reboot the iPhone before concluding anything; confirm Siri hears you on the phone; allow
the CarPlay Simulator app under System Settings → Privacy & Security → Microphone.

The Simulator **cannot prove sync** — CloudKit propagation is a phone-and-desk question, so
every "and the card is there" step below is checked on the iPhone (and, if you want the
sync half, on the Mac afterwards).

1. **The row exists and is last.** Connect. The picker shows "New voice chat" and then
   **Add to Work** (tray-with-down-arrow glyph), with "Recent" below. Count the rows — the
   recent list should be one shorter than it was before this build on a busy account.
2. **Happy path.** Tap **Add to Work**, say a sentence, stop talking. Expect: "Listening" →
   "Thinking…" → briefly **"Saving…"** → "Thinking…" → **"Saving…"** → spoken **"Saved to
   Work."** → the voice screen dismisses back to the picker and the car radio comes back.
   *Failure cases to watch for:* a second listen starting after the acknowledgement (there
   must be none — this is one-shot); the radio staying muted after the modal closes.
3. **The card, on the phone.** Open Conduck → Work. A playable audio card with the
   transcript as its title/body. **Failure case:** a card titled as untranscribed with no
   words — that is step 5's outcome reached by accident.
4. **No gateway configured.** Easiest way in: a fresh install, or temporarily forget every
   gateway on the phone. The picker shows "Set up your AI on iPhone first." AND **Add to
   Work**, and the Work row still works end to end. **Failure case:** the Work row missing,
   or the row present but refusing with a spoken line about an AI.
5. **Words lost, recording kept.** On the phone, remove the STT key (Settings → the speech
   provider). Then in the car: **Add to Work**, speak. Expect the spoken line **"Saved to
   Work. Add the words on your iPhone."** — NOT "Add your STT key…", NOT a re-prompt, NOT a
   second listen. On the phone: the audio card is on the desk, AND the home screen shows a
   retry card for the recording. Put the key back, tap Retry, and the words should land on
   **that same card** rather than appearing as a second one beside it.
6. **Airplane mode (transient failure).** Turn the phone's data off, then **Add to Work** and
   speak. Same as step 5: "Saved to Work. Add the words on your iPhone.", card present,
   retry card offered. **Failure case:** the chat lane's error copy ("Something glitched…"),
   or a re-arm.
7. **Silence.** Tap **Add to Work** and say nothing for ~15 s. The session signs off and
   dismisses. (This is the pre-fork silence guard and behaves exactly as it does for a chat.)
8. **End mid-note.** Tap **Add to Work**, start speaking, tap **End**. Nothing is saved and
   the picker comes back. **Failure case:** a partial card appearing on the desk.
9. **Mute mid-note.** Tap **Add to Work**, tap **Mute** while it listens → "Muted", tap
   **Unmute** → it listens again, finish the note. It should still save. (Known rig quirk:
   in the FIRST session after launching the Simulator the End/Mute buttons can be dead
   because the host never delivers the touch — back out to the CarPlay grid and re-enter.)
10. **The next chat is still a chat.** Immediately after a Work note, tap **New voice chat**
    and ask something. It must reach the AI and speak a reply. **Failure case (the one this
    slice's reset exists for):** the question lands silently on the Work desk instead.
11. **Chat is unchanged.** Run one ordinary multi-turn conversation start to finish —
    including a follow-up turn after a reply — and confirm nothing about it moved.

## Open questions

1. **Entitlement category — for App Review, and the founder's call.** CarPlay's
   `com.apple.developer.carplay-communication` (voice-based communication) is granted for
   *communication* apps, and `spec.md:461` already records what it forbids: message content
   on a car screen. A **memo action that reaches no other person** is arguably outside what
   the entitlement was granted for — a voice-memo app is a different (and, as far as Apple
   publishes, unavailable) CarPlay category. Two readings, and I cannot settle which Apple
   takes: (a) the row is a capture affordance inside a communication app, draws no content,
   and is no more than a variation on the app's existing voice session — fine; (b) it is a
   note-taking feature riding a communication entitlement — rejectable. Mitigations already
   in the build if (b) bites: the row draws no desk content at all, so removing it is a
   one-row change and nothing else on the lane is user-visible. **Recommend raising it in
   the review notes rather than waiting to be asked.**
2. **A recovered CarPlay capture reads as the phone.** Carried forward from `f1`: the happy
   path stamps `sourceDevice: "carplay"`, but `WorkVoiceCaptureCoordinator.republishRecording`
   (the recovery lane, used when phase one failed and the retry card finishes the capture)
   re-publishes with the default. `PendingRetryStore` metadata carries no `sourceDevice`
   field. Costs nothing today — plan decision 9 says nothing renders the stamp yet.
3. **No ownership re-check before the attach.** `ConverseIntent` calls
   `PendingRetryGuard.stillOwnsCapture` before it acts on the transcript, because Chat's
   `runConverseHop` is not idempotent — two surfaces finishing one capture means two user
   turns and two gateway effects. On this lane both terminal acts ARE safe under a
   takeover: `attachTranscript` is idempotent by capture id (a second delivery writes
   nothing) and `disarm` goes through the reservation and is simply refused. So the check is
   deliberately not there. If a future Work lane ever gains a non-idempotent terminal step,
   it has to be added.
4. **The `saving` screen is brief.** On a fast desk write the driver may see "Thinking…" →
   "Saving…" → "Thinking…" flicker. It is honest and the alternative (holding "Saving…"
   across the speech hop) would be a lie about which hop is running. Founder call at QA
   step 2 — collapsing the second `saving` (around the attach) into `processing` is a
   one-line change if the flicker reads badly.
