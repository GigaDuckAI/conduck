# c1-phone-relay — the phone half of the Watch → Work relay

## What changed

### `Conduck/Conduck/Services/AppleSpeechRelayCoordinator.swift`

- **`Wire`** gains THREE literals at the END of the enum, in this order. These
  are the exact lines the watch copy must mirror (c2 already has them; verified
  byte-identical on disk):

  ```swift
        static let destinationKey = "destination"
        static let destinationWork = "work"
        static let resultWorkSavedKey = "result.work"
  ```

  Doc comments differ between the two copies on purpose — the drift guard
  compares name→value maps, not bytes.

- **`handleIncomingRelayFile(at:metadata:)`** reads
  `metadata[Wire.destinationKey] as? String` and threads it on. The file channel
  and the inline channel are the SAME request in two envelopes; a destination
  visible on only one would route a private wrist note to a gateway whenever
  reachability decided which envelope was used.

- **`processRelayRequest(…)`** gains `destination: String?` as the last
  parameter, **with no default** — both ingress channels must state it, so a
  future third channel cannot silently inherit chat.

- **Work phase 1** sits after the idempotency ledger, after the in-flight
  insert, after both `defer`s and after `beginBackgroundTaskIfPossible`, and
  BEFORE the transcribe arms. It reads the bytes off the temp file (the STT arms
  hand that URL to `STTClient`, which defer-deletes it) and publishes through
  `WorkVoiceCaptureCoordinator.publishRecording(…, sourceDevice: "watch")`. A
  throw replies `AppError.workDeskWriteFailed` (78, **retryable**) and returns —
  never cached, because `shouldCacheVerdict` refuses retryables and a memoized
  storage blip would poison every re-fire.

- **Work phase 2** runs inside the existing `do` after the transcript is in
  hand: `attachRelayedWorkTranscript` handles `.attached` / `.recordingMissing`
  / `.notAudio` explicitly and NEVER fails the wrist — the card is already
  durable and the transcript is already owed, so the two non-attached answers are
  logged as bugs and the reply ships regardless.

- **Reply**: `sendReply(requestID:text:workSaved:preferMessage:)` gains a
  defaulted `workSaved`; the cache store on the success path carries
  `workSaved: true` on the work branch.

- New `// MARK: - Work destination (Watch → Work relay, phone half)` section
  holds `workPublicationFailure`, `isWorkDestination`, `workCaptureID`, the two
  `publishRelayedWorkRecording` overloads, `attachRelayedWorkTranscript`, the
  fixed `m4a` / `audio/mp4` / `"watch"` constants, and a `Logger`.
  New imports: `CryptoKit` (UUIDv5), `OSLog` (the logger).

### `Conduck/Conduck/Services/PhoneSessionManager.swift`

- `session(_:didReceiveMessage:replyHandler:)`, inline relay branch: reads
  `message[RelayWire.destinationKey] as? String` and passes it to
  `processRelayRequest`. Nothing else changed in the file.

### `Conduck/Conduck/Services/RelayReplyCache.swift`

- `CachedReply` gains `let workSaved: Bool?` plus an explicit
  `init(text:errorCode:workSaved: Bool? = nil)` so the chat call sites keep
  spelling the verdict in two fields. `payload(requestID:)` writes
  `Wire.resultWorkSavedKey: true` **only when `workSaved == true`** — a false or
  absent value never reaches the wire, so chat's frozen three-key success shape
  is untouched.

### Tests

- `Conduck/ConduckTests/RelayWireSourceDriftGuardTests.swift` — literal count
  **11 → 14**, plus three named sanity assertions
  (`destinationKey`/`destinationWork`/`resultWorkSavedKey`) so a copy that never
  landed on EITHER side fails loudly rather than passing on equality.
- `Conduck/ConduckTests/RelayWireContractTests.swift` — three literal pins,
  `testChatIsNeverSpelledOnTheWire`,
  `testWorkSuccessReplyCarriesTheChatKeysPlusTheWorkStamp` (exactly 4 keys),
  `testChatSuccessReplyCarriesNoWorkStamp` (3 keys, no stamp, and a `false`
  stamp is not a stamp). The stale "exactly the 11 relay literals" comment in
  `testSettingsPullKindMatchesCrossTargetContract` now reads 14.
- NEW `Conduck/ConduckTests/WatchWorkRelayPhoneTests.swift`.

## New API

```swift
// AppleSpeechRelayCoordinator.Wire
static let destinationKey = "destination"
static let destinationWork = "work"
static let resultWorkSavedKey = "result.work"

// AppleSpeechRelayCoordinator  (@MainActor)
func processRelayRequest(
    requestID: String,
    audioURL: URL,
    language: String?,
    providerID: String?,
    replyPrefersMessage: Bool,
    destination: String?          // NEW, no default
) async

static let workPublicationFailure: AppError            // .workDeskWriteFailed (78, retryable)
static func isWorkDestination(_ raw: String?) -> Bool
static func workCaptureID(forRequestID requestID: String) -> UUID

@discardableResult
static func publishRelayedWorkRecording(
    requestID: String,
    audioURL: URL,
    createdAt: Date = Date(),
    store: ConversationStore = .shared
) async throws -> UUID

@discardableResult
static func publishRelayedWorkRecording(
    requestID: String,
    audio: Data,
    createdAt: Date = Date(),
    store: ConversationStore = .shared
) async throws -> UUID

static func attachRelayedWorkTranscript(
    _ transcript: String,
    toCard captureID: UUID,
    store: ConversationStore = .shared
) async                                                 // never throws

// RelayReplyCache.CachedReply
let workSaved: Bool?
init(text: String?, errorCode: Int?, workSaved: Bool? = nil)
```

**Capture-id derivation, as asked in the brief:** `workCaptureID(forRequestID:)`
returns `UUID(uuidString: requestID)` when the requestID parses (the wrist mints
UUIDs, so this is the live path and the card id IS the request id). A requestID
that does NOT parse is hashed to a **UUIDv5 (SHA-1, RFC 4122 §4.3)** over the
private namespace `3EA1CA9D-0000-4000-A000-000000000001`, declared in this file
alone. A random id would turn each retry of one utterance into another card.

**Collision escape:** a phase-1 `WorkboardStoreError.invalidMaterialOwner` is
answered, not thrown — the bytes go back under
`WorkMaterialCollisionEscape.materialID(forCapture:)`, the single escape the
drainer and the recovery lane already use. Reason it matters HERE specifically:
plan §Slice C exempts Work entries from `maxEntryAge` AND from count eviction, so
a refusal that never clears would strand that queue entry **for ever**, not for
24 h.

## New strings

None. No user-facing copy on this slice — the phone half speaks only in wire
values and error codes; every word the person reads is rendered on the wrist
(c2) or on the desk.

## Tests

`ConduckTests/WatchWorkRelayPhoneTests` (new, 12 cases):

| Case | Claim |
|---|---|
| `testAnAbsentDestinationIsAChatAskAndOnlyWorkIsWork` | absent/""/"chat"/"workboard" ⇒ chat; only "work" is Work |
| `testARequestIdThatIsAUuidIsTheCardIdItself` | the live path is an identity |
| `testAForeignRequestIdStillDerivesOneStableCardId` | stable, distinct, v5 bits + variant |
| `testARelayedCaptureBecomesAPlayableCardStampedWatchBeforeAnyTranscript` | `.audio`, `sourceDevice == "watch"`, `textContent == nil`, untranscribed title, bytes read back |
| `testTheClipIsReadOffDiskBeforeTheTranscribeArmsCanDeleteIt` | the card survives deletion of the temp file it came from |
| `testARefireOfOneUtteranceRepairsTheSameCardRatherThanAddingASecond` | one desk row for inline-send + file-fallback |
| `testACaptureIdAlreadyHeldByAnotherKindEscapesInsteadOfStrandingTheWrist` | lands on the escape id; the pre-existing note is untouched |
| `testAPhaseOneRefusalTravelsBackOnACodeTheWristLeavesQueued` | unusable store throws; code 78, `isRetryable`, NOT cached; `audioProcessingFailed`/`audioInvalid`/`audioTooLarge` pinned as the wrong answers |
| `testTheTranscriptLandsOnTheRelayedCardRatherThanBesideIt` | one card, still `.audio`, words + title |
| `testACardDeletedMidTranscriptionDoesNotFailTheWrist` | attach to a missing id writes nothing and does not throw |
| `testOnlyAWorkReplyCarriesTheSavedStamp` | 4 keys work / 3 keys chat / no stamp on a refusal |
| `testAReplayedWorkVerdictStillCarriesItsStamp` | cache round-trips `workSaved`; a chat verdict reads nil, never false-positive Work |
| `testTheRelayCoordinatorNeverReachesAGatewayOrAConversation` | **structural**: reads the coordinator's own source with comments stripped and refuses `startConverseHop`, `startDeferredConverseHop`, `handleQuickSend`, `RemoteAgentRef`, `BackgroundRemoteAgent`, `ConversationRecord`, `upsertConversation` |

The isolation test strips comments before scanning ON PURPOSE: the coordinator's
own doc comments name those symbols to say it must not use them, so a naive
`contains` would fail on the prose that documents the rule. An extractor-sanity
assertion (`code.contains("publishRelayedWorkRecording")`) proves the stripper
did not simply empty the file.

**MEASURED** — `xcodebuild test-without-building`, one invocation, nine classes (my six plus the three relay-adjacent guards that read `PhoneSessionManager` / the watch relay leg off disk),
no `-configuration` flag, derived data under `~/Library/Caches/gigaduck-builds/work-c1/dd`:

| Class | Executed | Failures |
|---|---|---|
| `WatchWorkRelayPhoneTests` (new) | 13 | 0 |
| `RelayWireContractTests` | 7 | 0 |
| `RelayWireSourceDriftGuardTests` | 1 | 0 |
| `RelayReplyCacheTests` | 9 | 0 |
| `RelayRoutingDecisionTests` | 4 | 0 |
| `WorkboardAudioCaptureTests` | 20 | 0 |
| `PhoneSessionResendTests` | 7 | 0 |
| `WatchCourierIngressKeyGuardTests` | 2 | 0 |
| `STTKeyBlackoutLaneTests` | 11 | **1** — c2's file, see Requests §4 |
| **Total** | **74** | **1 (not mine)** |

```
Executed 74 tests, with 1 failure (0 unexpected) in 2.475 (2.492) seconds
```

Nine `Test Suite … started` lines confirm every named class actually ran, and
`grep -ci skipped` = 0, so nothing passed vacuously through an `XCTSkip`. Every
class that touches a file I own is 0-failure (my six: 54/54). The one failure
reads a watch file I never edited.

**The cross-target drift guard PASSES**, which is the one result neither agent
could produce alone: `testWatchAndIOSWireEnumsHaveIdenticalStringLiterals` reads
both source files off disk and found 14 identical `name = "value"` pairs. The
iOS and Watch `Wire` enums are byte-identical on the values.

### A WIDER run — nine classes — turns up ONE failure, and it is not this slice's

Re-run adding every remaining class that a
`grep -l 'AppleSpeechRelayCoordinator\|PhoneSessionManager\|RelayReplyCache'`
over `ConduckTests` names (`PhoneSessionResendTests` 7/0,
`WatchCourierIngressKeyGuardTests` 2/0, `STTKeyBlackoutLaneTests` 11/**1**):

```
Executed 74 tests, with 1 failure (0 unexpected) in 2.475 (2.492) seconds

STTKeyBlackoutLaneTests.swift:397: error:
  -[STTKeyBlackoutLaneTests testTheWristRelayDefersABlackoutInsteadOfClaimingTheQueueEntry]
  XCTAssertEqual failed: ("0") is not equal to ("2")
```

That guard reads `ConduckWatch Watch App/Services/WatchRecordingService.swift`,
extracts the body of `runRelay`, and requires exactly TWO
`lastErrorIsRelayDeferral = true` assignments in it — the reply-wait timeout and
the code-75 blackout. It now finds **zero inside `runRelay`, and one in the whole
file**: the wrist's `runRelay` rework (`+406/−75` on that file) moved the
deferral flag out of the function. I own no watch source and never touched it.

**Why it must not be waved through:** that flag is what keeps a code-75 blackout
DEFERRING rather than claiming, and a claim deletes the recording the person
spoke on their wrist (`AppleRelayPendingQueue.swift:~202`, invariant I6). It is
the wrist-side twin of this slice's own retryable phase-1 verdict — the same
recording, protected at the other end of the same wire.

## Build status

| Target | Result |
|---|---|
| iOS `build-for-testing` (sim `04DEF4F5`) | **exit 0, 0 `: error: `** |
| macOS `build` (`platform=macOS`) | exit 65, 15 errors — **all slice D's**, see Requests |

**Zero diagnostics, error or warning, in any file I own**, on every pass.

The macOS failure is entirely `MenuBar/MenuBarCoordinator.swift` vs
`MenuBar/MenuBarCoordinator+WorkContract.swift` declaring the same six members
twice (`workVoiceRecorder` :214, `workCaptureFeedbackIsShowing` :800,
`openComposeForWorkOnly()` :1843, `workCaptureIsActive` :1881,
`beginWorkVoiceCapture()` :1912, `finishWorkVoiceCapture()` :1932), which makes
every use of them in `MenuBarController` ambiguous. `RelayReplyCache.swift` is my
only file that compiles on macOS (the bare LRU, outside the `#if os(iOS)`
payload extension) and it type-checked clean in that same pass — the module
type-checks as a whole, so an error in it would have been reported alongside the
MenuBar ones.

**Worktree history worth recording:** getting to a green iOS build took nine
`build-for-testing` invocations across ~75 minutes, every failure in another
slice's files — the watch target is a build dependency of the `Conduck` scheme,
so one agent's half-written file blocks every other agent's measurement.
The sequence was `settleSuccess` missing → `RelayReply`/`String` mismatch →
`WatchCaptureDestination` declared in two watch files (48 errors) →
`WatchWorkCaptureOutcome` the same → `RecordWorkNoteIntent.swift:54` missing an
`await` → `PersonalWorkbenchView.swift` missing `import QuickLook` + a
nonisolated `FilePreviewCoordinator()`. The recurring shape is TWO agents landing
the same contract type in two files; it has now happened three times (watch
destination enum, watch outcome enum, MenuBar work contract). Worth a rule for
the next wave.

## Requests

1. **Slice D / integrator — the macOS build is RED and it is not mine.**
   `MenuBarCoordinator.swift` and `MenuBarCoordinator+WorkContract.swift` declare
   the same six members twice (list in "Build status"). Keep exactly one
   declaration of each; the 9 `MenuBarController` "ambiguous use" errors clear on
   their own once they do. No macOS result in this wave is trustworthy until then.

2. **c2-watch-services / whoever owns `WatchRecordingService.swift`** — restore
   the two `lastErrorIsRelayDeferral = true` assignments inside `runRelay`, or
   re-anchor `STTKeyBlackoutLaneTests:397` on wherever the deferral now lives.
   Never delete the assertion: it protects invariant I6. Detail in "A WIDER run"
   above. A six-class run does not see this; the integrator's final pass must
   include `STTKeyBlackoutLaneTests`.

3. **c2-watch-services**: my three `Wire` lines are quoted verbatim at the top of
   this note. I read your copy off disk at 14 literals, same names, same values,
   same order — no action expected, but diff them if you re-touch that enum.

4. Nobody needs an edit in a file I do not own. `processRelayRequest` has exactly
   one non-test caller outside its own file (`PhoneSessionManager`), which I own.

4. **c2-watch-services — a foundation-era source guard now fails against your
   `runRelay`.** `STTKeyBlackoutLaneTests.testTheWristRelayDefersABlackoutInsteadOfClaimingTheQueueEntry`
   (`ConduckTests/STTKeyBlackoutLaneTests.swift:397`) extracts the body of
   `func runRelay` in `ConduckWatch Watch App/Services/WatchRecordingService.swift`
   (:1650 on disk now) and counts `lastErrorIsRelayDeferral = true` — expects
   exactly 2 (reply-wait timeout arm + blackout arm), measured **0**. The whole
   file has 1 occurrence, so the deferral-flag writes moved out of `runRelay` in
   the restructure (or the extractor's brace-matcher stops early on the new
   body). The guard's own message names the stake: a blackout that stops setting
   the flag "has taken the claim shape" and the queued wrist audio gets deleted
   (I6). Either restore both `lastErrorIsRelayDeferral = true` writes inside
   `runRelay`'s body, or — if the flag now lives in a helper by design —
   re-anchor the guard on that helper and say so in your fixnote. The other 10
   cases in that class pass, so it is that one arm, not the lane.

5. **Whoever runs the build-cache cleanup:** `~/Library/Caches/gigaduck-builds/work-c1/`
   was wiped from under me twice mid-`xcodebuild` (03:40 and again during the
   first macOS pass — the dir came back with a fresh mtime and no `dd/`). My
   numbers above were captured before each wipe, so they stand, but a sweep that
   removes sibling slugs (`work-*` glob, or a janitor threshold below the
   wave's runtime) turns another agent's in-flight build into a phantom
   failure. Clean only your own slug.

## Nobody undo

- **`workPublicationFailure` must stay `isRetryable`.** The wrist's
  `AppleRelayPendingQueue.leavesEntryQueued(after:)` reads `AppError.isRetryable`
  and NOTHING else; claiming an entry deletes the audio at
  `AppleRelayPendingQueue.swift:~202`. Swapping in `audioProcessingFailed`
  "because the audio failed" destroys a recording the next attempt would have
  delivered. It is a named constant so this property is reviewable at the
  declaration instead of invisible at the call site.
- **Phase 1 stays ABOVE the transcribe arms and reads the bytes itself.** Both
  STT arms hand `audioURL` to `STTClient`, which defer-deletes it; so does this
  scope's own defer. A publication moved below transcription has nothing to
  publish, and the recording exists nowhere but on the wrist.
- **The phase-1 verdict is never cached.** `shouldCacheVerdict` already refuses
  retryables; do not "optimise" by storing it — every re-fire would replay the
  outage and the wrist's queue head would be blocked behind it for ever (Work
  entries do not age out).
- **`result.work` is written only for `true`.** Chat's success reply is a frozen
  three-key shape. Do not "normalise" the field onto every reply, and do not send
  `false` — the wrist reads the stamp's ABSENCE as "an older iPhone kept no
  recording", and a `false` would be indistinguishable from that only by luck.
- **`destination` has no default on `processRelayRequest`.** That is what forces
  a new ingress channel to decide rather than inherit chat.
- **`isWorkDestination` is an exact match.** Not case-folded, not a prefix. The
  value comes from our own wrist build's shared literal; anything else is drift,
  and guessing at drift picks a destination nobody chose.
- **The isolation test strips comments before scanning.** Do not "simplify" it to
  a raw `contains` — it will fail on the coordinator's own doc comments, and the
  fix someone reaches for is deleting those comments, which loses the rule.
- `attachRelayedWorkTranscript` does not throw ON PURPOSE. Its failure cannot
  cost the recording (already durable) or the words (already in the reply), so
  making it throw would only teach the caller to fail a wrist that is owed a
  transcript.

## Founder QA

Requires a paired Apple Watch running the c2 build and this phone build.

1. **Happy path.** Phone unlocked and nearby, Watch → launchpad → **Save to
   Work** → speak a short note → stop. Wrist should end on the Work terminal
   line. On the phone open the Work desk: **one** card, playable, whose title is
   the first line of what you said and whose body is the transcript. Play it —
   the audio must be your recording, not silence.
2. **The recording survives a failed transcription.** Settings → STT → a custom
   endpoint whose server is off (or turn on Airplane Mode on the phone only after
   the clip has transferred). Record a Work note on the wrist. The desk must
   still show a **playable** card, titled with the untranscribed default and with
   no words. That is the whole feature: the words are optional, the recording is
   not.
3. **Phone out of range.** Walk away from the phone, record a Work note, come
   back. The card appears once the queue drains. Nothing on the wrist should
   claim success before the phone answers.
4. **No duplicates.** Record one Work note with the phone at the very edge of
   range (so the inline send fails and the file transfer retries). Exactly ONE
   card must appear, not two.
5. **Chat is unaffected — the regression to watch for.** From the wrist, use the
   normal **Ask** flow. The reply must still come back and land in a conversation
   exactly as before, and nothing may appear on the Work desk. Then check the
   desk after a chat ask: it must be empty of that utterance.
6. **Failure case worth trying deliberately:** kill Conduck on the phone right
   after the wrist says it is sending. Relaunch the phone app. The wrist should
   re-fire and you should end with one card, not zero and not two.
7. **What you will NOT see yet:** the `sourceDevice` stamp ("watch") is stored
   but nothing renders it — plan decision 9. There is no way to tell a wrist card
   from a phone card by looking.

## Open questions

1. **A TERMINAL transcription failure on a work request tells the wrist the wrong
   story.** Phase 1 succeeded, so the recording IS on the desk; but the phase-2
   throw ships an error reply with no `result.work`, so the wrist claims its
   entry, deletes its (now redundant) clip and reports a failure. The data is
   safe and the copy is wrong. Fixing it means replying success-shaped with an
   empty `result.text` plus the stamp — a wire semantic the c2 contract does not
   cover, so I did not invent it. **Founder/integrator call.**
2. **The escape id is derived from the capture id, not re-derived per attempt**,
   which is correct — but if BOTH the capture id and its escape name cards of
   another kind, the second `publishRecording` throws and the wrist re-fires for
   ever (Work entries do not age out). `WorkMaterialCollisionEscape`'s own
   contract says there is no third id; the recovery lane answers that state by
   publishing a fallback NOTE. This lane cannot, because it has no
   `PendingRetryStore` record. Extremely unlikely (two UUIDv5 collisions on one
   capture) and out of this slice's ownership, but it is the one state with no
   exit.
3. **f1's recovery-stamp gap applies here too**: a relayed capture whose phase 1
   failed and is later recovered on the phone through `republishRecording` will
   stamp `"iphone"`, because `PendingRetryStore` metadata carries no
   `sourceDevice`. Same open question f1 filed; nothing renders the stamp yet.
