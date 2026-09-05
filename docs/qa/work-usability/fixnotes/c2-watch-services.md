# c2-watch-services — the wrist's Work lane, end to end

Slice C2. The Watch can now record a thought that lands on the Work desk instead of
at a gateway. The microphone, the compressor and the relay are shared with Chat; the
destination, the retention rule, the reply type and the settlement are not.

## What changed

### `ConduckWatch Watch App/Services/AppleSpeechRelayCoordinator.swift`

- **`Wire`** gains the three contract literals, appended at the END in the agreed
  order: `destinationKey = "destination"`, `destinationWork = "work"`,
  `resultWorkSavedKey = "result.work"`. Verified byte-identical against the iOS copy
  by re-running `RelayWireSourceDriftGuardTests`' own extractor locally: both enums
  parse to the same 14-pair name→value map, and c1 has already moved the guard's
  sanity count 11 → 14.
- **`RelayReply { text; workSaved }`** replaces the bare `String` reply.
  `RelayReplyOutcome.success` carries it; `pending` is
  `[String: CheckedContinuation<RelayReply, Error>]`.
- **`relay(requestID:audioFileURL:language:providerID:destination:skipOutstandingCheck:)
  -> RelayReply`**. `destination` stamps the request **only for `.work`** — Chat's
  payload is byte-identical to what it always was, so an iPhone build predating Work
  sees the dictionary it has always seen.
- **`handleReply`** reads `result.work` as `?? false`. Absence is not a durability
  claim: an old iPhone says nothing there, and "nothing" must not be read as "the
  recording is safe on the phone".

### `ConduckWatch Watch App/Services/AppleRelayPendingQueue.swift`

- **`Entry.destination: String?`**, appended last, additive Codable, nil ⇒ chat.
  Written **only for `.work`**, so a chat entry's blob keeps its pre-Work shape.
  `Entry.captureDestination` decodes it with the legacy reading built in.
- **`enqueue(…, destination:)`** persists it. Persisted, not remembered: the reply
  that settles an entry may land in a process that never saw the capture, and that
  field is the only thing that can keep it out of the converse hop.
- **Retention.** `enforceCaps` now delegates to the pure
  `applyCaps(to:now:)`. A Work entry is exempt from `maxEntryAge` **and** from count
  eviction; count eviction drops the oldest **chat** entry and stops when there is no
  chat entry left, so a queue of ten Work captures simply stays at ten. The pressure
  is answered at the other end by `refusesNewWorkCapture(queueDepth:)`. Because Work
  never reaches the evictor, `postEvictionNotification`'s copy stays true for
  everything it can describe (brief item 7 — the eviction path is destination-aware
  by construction, and there is no lossy Work arm to word).
- **Settlement.** `RelaySettlement { converseHop, workAcknowledged, workWordsOnly }`
  + pure `settlement(for:workSaved:)` + `applySettledSuccess(…) -> RelaySettlementResult`,
  whose effects are closures so the two contracts are unit-testable without a paired
  iPhone, a `WCSession` or the singleton's disk-touching `init`:
  a Work entry never reaches the converse hop, and a words-only Work reply claims
  (which **deletes the recording**) only after the desk write succeeds.
  `peekEntry(requestID:)` is the non-destructive lookup that makes read-then-decide-
  then-claim possible.
- **`reconcile` and `drain`** both route their success arm through the private
  `settleSuccess`, which supplies the real closures. `drain`'s re-fire carries
  `entry.captureDestination`. `completeEntry` is untouched and is now reached only
  through the CHAT closure — in particular the `clearRelayDeferralError()` →
  `startDeferredConverseHop` pair inside it, which must not suspend, was not moved,
  re-ordered or wrapped.
- **`writeWorkWords(_:requestID:createdAt:)`** writes the words-only note through
  `ConversationStore.upsertDeskMaterial(WatchWorkboardCapture, id:createdAt:)` — no
  new desk writer, no Core Data insert, so `WorkDeskWriteOwnershipDriftGuardTests` is
  unaffected. Returns false on any refusal, which is the caller's signal to KEEP the
  entry.
- **`finishWorkEntry` + `postWorkNotification`** — the deferred terminal: fixed copy
  on both arms (the transcript never enters a notification body, for
  `postTranscriptNotification`'s reasons), then `noteWorkCaptureSettled` on the
  service.
- **`WatchWorkRelayNoteIdentity`** (file-level enum): UUIDv5 over the claim token in
  a frozen namespace, so a re-fired capture REPAIRS one card instead of leaving one
  per attempt. `Insecure.SHA1` via CryptoKit — an identity derivation, never a
  signature.

### `ConduckWatch Watch App/Services/WatchRecordingService.swift`

- **`WatchCaptureDestination: String, Codable, Sendable { chat, work }`**,
  **`WatchWorkCaptureOutcome: Equatable, Sendable { saved, deferredToPhone,
  savedWordsOnly, refused(reason:) }`**, **`WatchWorkCaptureRefusal: Error, Equatable
  { busy, queueFull }`** (with `.message`) — all top-level, the c3 contract verbatim.
- `private(set) var captureDestination` and `private(set) var workCaptureOutcome`
  (observable). `WatchRecordingState` was NOT extended: every case is switched
  exhaustively across the wrist's views, and Work settles minutes after the machine
  has returned to `.idle`.
- **`canStartWorkCapture() -> WatchWorkCaptureRefusal?`** and
  **`@discardableResult startWorkCapture(requestID:) -> WatchCaptureStartOutcome`**,
  mirroring `startCapture(boundTo:requestID:)` — same error supersede, same idle
  guard, same `alreadyRunning`-vs-`refusedBusy` split for the deliberate double start.
  A capacity refusal returns `.refusedBusy` and leaves its sentence on
  `workCaptureOutcome`, so the pushed view renders it even without a pre-check.
  `clearWorkCaptureOutcome()` for the UI's dismissal.
- Every chat entry point (`startCapture`, `startRecording(boundTo:)`,
  `sendTypedText`) now STAMPS `.chat` rather than inheriting the previous lane;
  `cancelRecording` and `retireSupersededRelay` reset it.
- **`processRecording`** reads the lane once beside the supersede token and forces
  the relay for Work regardless of provider — the relay is not just how the wrist
  transcribes, it is how the BYTES reach the iPhone, and the wrist mounts no payload
  store so it cannot write a recording to the desk itself.
- **`runRelay(…, destination:)`** enqueues with the lane and settles through the same
  `applySettledSuccess`. `surfaceRelayVerdict(_:destination:deferred:)` lands every
  failure on the right lane (Chat keeps `.error` + the deferral provenance flag; Work
  goes idle with a terminal line). `retireSupersededRelay` replaces three copies of
  the claim-nil reset and keeps `captureDiscardCount` a chat-only concern.
- `discardTooShortCapture()` gives the two SILENT discards (double-tap grace, byte
  floor) a Work line — without it the capture screen sits on "Saving…" after a
  mis-tap.

### Deleted: `ConduckWatch Watch App/Services/WatchWorkCaptureContract.swift`

c3's temporary compile stub, whose own header says "delete this whole file the moment
the Watch Work SERVICES slice lands". Moved to the session scratchpad, not `rm`'d.
Its two shapes are now real stored properties; `WatchWorkCaptureOutcome` kept the
`Sendable` conformance the stub declared.

### `ConduckWatchTests/WatchCaptureGuardTests.swift` — 4 lines, mechanical

**Not in my ownership**, but unavoidable: the `relayTranscribe` seam gained a
`destination` parameter and now returns `RelayReply`, so its two closure literals
would not compile. Only the two `service.relayTranscribe = { … }` lines changed;
no assertion was touched.

## New API

```swift
// AppleSpeechRelayCoordinator.swift (Watch)
struct RelayReply: Equatable, Sendable { let text: String; let workSaved: Bool }
enum RelayReplyOutcome { case success(RelayReply); case failure(AppError) }
AppleSpeechRelayCoordinator.Wire.destinationKey      // "destination"
AppleSpeechRelayCoordinator.Wire.destinationWork     // "work"
AppleSpeechRelayCoordinator.Wire.resultWorkSavedKey  // "result.work"
func relay(requestID: String, audioFileURL: URL, language: String?,
           providerID: String? = nil,
           destination: WatchCaptureDestination = .chat,
           skipOutstandingCheck: Bool = false) async throws -> RelayReply

// WatchRecordingService.swift
enum WatchCaptureDestination: String, Codable, Sendable { case chat, work }
enum WatchWorkCaptureOutcome: Equatable, Sendable {
    case saved, deferredToPhone, savedWordsOnly
    case refused(reason: String)
}
enum WatchWorkCaptureRefusal: Error, Equatable { case busy, queueFull
    var message: String { get } }
WatchRecordingService.captureDestination: WatchCaptureDestination   // private(set)
WatchRecordingService.workCaptureOutcome: WatchWorkCaptureOutcome?  // private(set)
func canStartWorkCapture() -> WatchWorkCaptureRefusal?
@discardableResult func startWorkCapture(requestID: UUID) -> WatchCaptureStartOutcome
func clearWorkCaptureOutcome()
func noteWorkCaptureSettled(_ settlement: AppleRelayPendingQueue.RelaySettlement)
var relayTranscribe: @MainActor (String, URL, String?, String?, WatchCaptureDestination)
                     async throws -> RelayReply            // seam, signature CHANGED
func runRelay(audioFileURL: URL, originalFileURL: URL, providerID: String?,
              destination: WatchCaptureDestination = .chat) async

// AppleRelayPendingQueue.swift
AppleRelayPendingQueue.Entry.destination: String?          // additive, nil ⇒ chat
AppleRelayPendingQueue.Entry.captureDestination: WatchCaptureDestination
static let maxEntryCount: Int                              // was private
static let maxEntryAge: TimeInterval                       // was private
func enqueue(requestID:audioFileURL:language:providerID:conversationID:
             destination: WatchCaptureDestination = .chat) -> URL
func peekEntry(requestID: String) -> Entry?
enum RelaySettlement: Equatable { case converseHop, workAcknowledged, workWordsOnly }
enum RelaySettlementResult: Equatable {
    case applied(RelaySettlement), superseded, workWordsUnwritten }
static func settlement(for: WatchCaptureDestination, workSaved: Bool) -> RelaySettlement
@MainActor static func applySettledSuccess(
    destination: WatchCaptureDestination, reply: RelayReply,
    claim: () -> Bool, completeChat: (String) async -> Void,
    writeWorkWords: (String) async -> Bool, finishWork: (RelaySettlement) -> Void
) async -> RelaySettlementResult
static func applyCaps(to: [Entry], now: TimeInterval) -> (kept: [Entry], evicted: [Entry])
static func refusesNewWorkCapture(queueDepth: Int) -> Bool
func writeWorkWords(_ text: String, requestID: String, createdAt: Date) async -> Bool

enum WatchWorkRelayNoteIdentity {
    static let namespace: UUID
    static func materialID(forRequestID: String) -> UUID
    static func uuidV5(namespace: UUID, name: String) -> UUID
}
```

## New strings — ALL IN THE **WATCH** CATALOG

```
WATCH: watch.work.notification.saved | Saved to Work. | Local notification on the watch when a deferred Work recording the iPhone published finally settles.
WATCH: watch.work.notification.wordsOnly | Saved the words to Work. Update Conduck on your iPhone to keep recordings. | Local notification when the paired iPhone returned a transcript but kept no recording (a build predating Work).
WATCH: watch.work.refusal.busy | Finish what you’re doing first, then try again. | Shown when a Work capture is refused because another turn owns the wrist.
WATCH: watch.work.refusal.queueFull | Work is waiting for your iPhone. Bring it nearby first. | Shown when a Work capture is refused because the relay queue is full of recordings still waiting on the iPhone.
WATCH: watch.work.noteUnwritten | Couldn’t add that to Work yet. It’s still on your watch. | Shown when a relayed Work transcript could not be written to the desk; the recording stays queued on the watch.
WATCH: watch.work.tooShort | That was too short to save. Try again and speak a little longer. | Shown when a Work capture is discarded as a mis-tap or a header-only recording.
```

None says send/dispatch/draft/brief. No App Intent title or description was touched.

## Tests

Additions to the two existing watch classes (no new watch test FILES).

`ConduckWatchTests/WatchRelayQueueRetryabilityTests.swift` — 7 → **15** tests:

| Test | What it locks |
|---|---|
| `testTheEntryRoundTripsItsDestinationAndALegacyBlobReadsAsChat` | Codable both ways; a chat entry serializes NO `destination` key; a hand-written legacy blob decodes `.chat` |
| `testTheCapsNeverEvictAWorkEntryForAgeOrForRoom` | Age + count exemption, and an all-Work queue stays whole |
| `testTheCapsStillEvictChatEntries` | Negative control — the caps still bound the chat lane, oldest-first |
| `testANewWorkCaptureIsRefusedAtCapacityRatherThanEvicting` | `refusesNewWorkCapture` at 0 / cap-1 / cap |
| `testAWorkReplyNeverReachesTheConverseHop` | Both Work arms, stamped and not: hop count 0 |
| `testAChatReplyStillClaimsAndDispatchesTheHop` | Negative control for the above |
| `testAWordsOnlyWorkReplyClaimsOnlyAfterTheNoteIsWritten` | Failed write ⇒ `["write"]` only; success ⇒ `["write","claim","finish"]` |
| `testASupersededVerdictSettlesNothingOnEitherLane` | Exactly-once on both lanes |

The five pre-existing CHAT retryability assertions (`leavesEntryQueued`, the 75
notification arm, the two-call-site source guard) are **byte-for-byte unchanged** and
green — including `testBothDispatchPathsClassifyThroughThePredicate`, whose
"exactly two `leavesEntryQueued(after:` call sites" count I deliberately did not
disturb.

`ConduckWatchTests/ConduckWatchSmokeTests.swift` — 7 → **9** tests:
`testTheWorkRelayNoteIDIsDerivedFromTheClaimTokenAndIsStable` (determinism, distinct
per token, v5 + RFC-4122 variant bits) and `testTheDerivationMatchesTheRFCsWorkedExample`
(DNS namespace + `www.example.com` → `2ed6657d-e927-568b-95e1-2665a8aea6a2`).

**Full watch suite, run three times, latest:**

```
Executed 252 tests, with 0 failures (0 unexpected) in 9.302 (9.432) seconds
```

Baseline was 232; +10 mine, +10 from c3's UI slice landing in parallel.
`xcodebuild test -scheme ConduckWatchTests -destination 'platform=watchOS Simulator,
id=28AC563B…' -derivedDataPath ~/Library/Caches/gigaduck-builds/work-c2a/ddwatch`,
exit 0, **0** `: error: `. No `-configuration` flag anywhere.

`scripts/add-spdx-headers.sh --check`: exit 0.

**iOS side.** The iOS target was broken by other slices' in-flight files for most of
this session (first Slice B's `RecordWorkNoteIntent.swift`, then Slice A's
`PersonalWorkbenchView.swift`); both cleared before I finished.
`xcodebuild build-for-testing -scheme Conduck` then exited **0** with **0**
`: error: `, and:

| Suite | Result |
|---|---|
| `RelayWireSourceDriftGuardTests` | **1 test, 0 failures** — the two `Wire` enums are identical at 14 literals, so c1's copy and mine agree |
| `RelayWireContractTests` | 7 tests, 0 failures |
| `LoggingPrivacyDriftGuardTests` | 4 tests, 0 failures — my new `WatchLog` fields (`"how"` / `"why"` carrying enum case names, `"id"` carrying `shortID`) pass Rule 3 |
| `WorkDeskWriteOwnershipDriftGuardTests` | 6 tests, 0 failures — `writeWorkWords` goes through the door, it does not become a second one |
| `WorkboardCopyTruthGuardTests` | **1 failure, NOT MINE** (see below) |

The one failure is Slice A's orphaned catalog row, exactly the one the plan anticipated:

```
WorkboardCopyTruthGuardTests.swift:359: XCTAssertTrue failed -
workboard.material.preview.unavailable.title has a catalog row no app-target source
references — it outlived the surface it was written for.
```

`WorkboardPreviewImage` was deleted by Slice A; the plan assigns those
`workboard.material.preview.unavailable.*` keys to the failure state or to the copy
agent for removal. I opened no `.xcstrings` and minted no `workboard.*` key.

One simulator-level failure on the first attempt (`Simulator device failed to launch
… Application failed preflight checks`, the shared sim under contention); the retry
above is the reported run.

## Requests

- **Copy agent** — the six `WATCH:` rows above go in the **Watch** catalog.
- **Integrator** — run `-only-testing:ConduckTests/RelayWireSourceDriftGuardTests`
  (and `LoggingPrivacyDriftGuardTests`, which scans `WatchLog.*` call sites; my new
  fields are `"how"` / `"why"` carrying enum case names and `"id"` carrying
  `WatchLog.shortID`) once Slice A's `PersonalWorkbenchView.swift` compiles.
- **c3 / UI** — `canStartWorkCapture()` exists and is currently unused:
  `WatchNoteView.beginWorkCapture` pushes the route and then calls
  `startWorkCapture`, which is CORRECT as written (the refusal lands on
  `workCaptureOutcome` and the pushed view renders it). Asking first would avoid
  pushing a screen only to show a refusal on it — c3's call, not mine.
- **Docs pass** — the spec's three Watch sections now have a second lane to
  describe: a wrist Work capture always relays (whatever the STT provider), the
  iPhone publishes the recording, and the wrist deletes its copy only on
  `result.work == true` or an explicit discard. The Watch entry's retention is
  destination-specific.
- **Nobody** needs to add a `leavesEntryQueued(after:` call site: the source guard
  counts exactly two.

## Nobody undo

- **`Entry.destination` is written only for `.work`.** Persisting `"chat"` would
  change the on-disk shape of every capture that never needed it and break the
  legacy-blob equivalence the round-trip test pins.
- **The wire stamp is `.work`-only too.** Chat's request bytes must stay identical or
  an iPhone build predating Work sees a payload it has never seen.
- **`result.work` absent ⇒ `false`.** Never default it true, and never infer
  durability from the presence of `result.text`. The whole words-only fallback exists
  because an old phone answers with a transcript and keeps nothing.
- **Write, THEN claim, on `workWordsOnly`.** A claim deletes the recording. Reordering
  these two lines trades the person's audio for a note that may never be written.
  `applySettledSuccess`'s closure shape exists so that ordering is testable; do not
  collapse it back into direct calls.
- **Work is exempt from BOTH caps, and the refusal is the compensating bound.**
  Deleting `refusesNewWorkCapture` (or letting `applyCaps` evict Work "just for the
  age cap") reintroduces unbounded growth or destroys the only copy of a recording.
- **`completeEntry` was not restructured.** The `clearRelayDeferralError()` →
  `startDeferredConverseHop` pair inside it must stay adjacent and unsuspended; the
  settlement closure boundary sits OUTSIDE it deliberately.
- **The Work terminal is `workCaptureOutcome`, not a new `WatchRecordingState` case.**
  Adding one is a source change in every exhaustive switch on the wrist for a value
  none of them mean.
- **`WatchWorkRelayNoteIdentity.namespace` is frozen.** Changing it orphans every card
  a re-fire would otherwise repair.
- **`retireSupersededRelay` bumps `captureDiscardCount` for Chat only.** Bumping it on
  the Work lane pops an unrelated draft thread.

## Founder QA

Pair the watch with the phone, both on this build. On the wrist:

1. **Happy path.** Launchpad → **Save to Work** → speak ~5 s → stop.
   *Must be true:* the screen shows Starting… → recording → Saving… → **Saved to
   Work.**; the card appears on the iPhone/Mac desk as a **playable audio card**
   (not a note), and it survives force-quitting the watch app.
   *Failure to watch for:* a conversation appearing anywhere. Nothing on this lane may
   reach a gateway — check the Conversations list is unchanged.
2. **Phone out of range.** Leave the iPhone in another room (or turn it off), then do
   (1).
   *Must be true:* "Saved on your watch. It reaches Work when your iPhone is nearby."
   Bring the phone back / open Conduck on it. Within a minute or two the watch posts
   a **"Saved to Work."** notification and the card is on the desk with its audio.
   *Failure:* the recording vanishing, or the words landing as a note-only card while
   the audio is lost.
3. **Cancel and mis-tap.** Start a Work capture and tap the X. Then start one and
   double-tap immediately.
   *Must be true:* the X returns to the launchpad with nothing on the desk; the
   double-tap shows "That was too short to save…" rather than sitting on "Saving…".
4. **Chat is unchanged.** Do a normal **Ask** with the phone out of range, then bring
   it back.
   *Must be true:* the old behaviour exactly — "Sent to iPhone. Your transcript will
   arrive when it reconnects.", then the transcript notification and the reply.
   *Failure:* an Ask landing on the Work desk, or a Work capture landing in a thread.
5. **Queue capacity (hard to reach deliberately, worth knowing).** With the phone off,
   record ten Work captures, then try an eleventh.
   *Must be true:* the eleventh is refused with "Work is waiting for your iPhone.
   Bring it nearby first." — and the ten already queued are still there when the phone
   comes back. *Failure:* the oldest recording being silently deleted to make room.
6. **Provider independence.** Switch the phone's STT to a cloud provider (not
   apple-on-device) and repeat (1).
   *Must be true:* identical result. Work always relays, because the phone is what
   writes the recording to the desk.

Not reachable by QA on a current pair: the **words-only** fallback, which needs an
iPhone running a build that predates `result.work`. Its ordering is covered by test
instead.

## Open questions

- **A cancel landing inside the words-only write.** `runRelay` re-checks the cancel
  generation before settling, but the desk write is a real suspension: a
  `cancelRecording()` during it claims the entry, so the note is written and then the
  claim fails (`.superseded`). The capture is kept rather than discarded. I judged
  keeping the person's words the better error — the alternative is deleting a note we
  just wrote — but it is a deliberate asymmetry with Chat, where a cancel drops
  everything.
- **An empty transcript on the words-only path parks the entry.** `prepare` refuses
  empty text, so the entry stays queued and Work entries never age out. That is
  bounded (ten entries, then new Work captures are refused) and self-healing (updating
  the iPhone makes the next re-fire settle properly), but a person with a permanently
  old phone and a silent recording would sit at capacity. Worth a founder call on
  whether a Work entry should ever be claimable with nothing saved — I decided no.
- **`sourceDevice` on a recovered capture** — unchanged from f4's open note: the
  wrist stamps `"watch"` on the happy path, but a phone-side recovery through
  `PendingRetryStore` will read as the phone. Not this slice's to fix.
