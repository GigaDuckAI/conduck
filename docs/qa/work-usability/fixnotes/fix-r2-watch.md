# fix-r2-watch — Codex R2 finding on the Watch → Work slice

One finding (R1, MAJOR), **verified and fixed**. It is the same defect as c1's
recorded open question ("a TERMINAL transcription failure on a work request
tells the wrist the wrong story", `c1-phone-relay.md` §Open questions 1) and
handoff item **U-22** — c1 left it open because answering it needed a wire
semantic the c2 contract did not cover. R1 shows the R1-round retention fix
turned that copy defect into a **capacity** defect, so it is no longer
deferrable: the wrist now KEEPS the clip it used to (wrongly) delete.

Both are closed by this change. **U-22 can be struck from the handoff.**

## R1 — cached transcription failures strand saved Work entries — **fixed**

**Verified, not refutable.** Reading the source end to end:

1. `AppleSpeechRelayCoordinator.processRelayRequest` publishes the recording in
   phase 1 and holds the card id in `workCardID`.
2. Both phase-2 catch arms ignored `workCardID` and shipped a bare error code.
3. A TERMINAL code (18 `appleSpeechModelNotInstalled`, `audioProcessingFailed`,
   …) is admitted to `RelayReplyCache` (capacity 16, no expiry), so every
   re-fire of that requestID is answered from the cache — it never republishes
   and never re-transcribes.
4. Since round 1 the wrist RETAINS a Work entry after any failure
   (`leavesEntryQueued(after:destination:)`), and Work entries are exempt from
   both caps. So the entry is permanent: the card is already on the desk, the
   clip can never be claimed, and only a phone process restart or cache
   eviction changes the answer.
5. Ten such entries hit `refusesNewWorkCapture`, and `applyCaps` then evicts the
   only evictable thing left — a queued **Chat** recording (`:877`, audio
   deleted at `:914`).

The R1-round trade ("a wedged queue is recoverable, a deleted recording is
not") stands; what was missing is the phone telling the truth about a capture
it already saved, which un-wedges the queue without deleting anything.

### The reply: success-shaped, empty, stamped

Once phase 1 published, a SETTLED phase-2 failure ships
`result.work = true` with an **empty** `result.text` — no new wire literal
(both `Wire` enums still hold the same 14 ordered literals, unchanged), because
`result.text` + `result.work` are the two keys a stamped work reply already
carries. Emptiness IS the value: there are no words.

**Only for a SETTLED verdict** — `acknowledgesRecording(after:)` is exactly
`shouldCacheVerdict(for:)`, and the identity is the point:

| verdict | cached by the phone? | reply | wrist |
|---|---|---|---|
| terminal (18, `audioProcessingFailed`, `audioInvalid`, …) | yes, for ever | stamped + empty | settles, deletes its clip |
| retryable (20, 75, **78**) | never | error code, as before | retains, re-fires, can still win the words |
| phase-1 refusal (78, before publication) | never | error code, as before | retains — **unchanged** |
| old phone (no Work branch) | n/a | unstamped | words-only lane — **unchanged** |

Acknowledging a retryable verdict would throw away a transcript the next
attempt can still land, so the retryable path is untouched. The cache store for
the acknowledgement is unconditional rather than admission-gated: the desk
write happened once and cannot un-happen, so a replay must repeat it — that is
what makes a re-fire settle instead of replaying the old error.

### The wrist: settle, and say which half is missing

A stamped reply with no words claims the entry (the phone holds the durable
copy) and shows a NEW terminal line, mirroring CarPlay's wording for the
identical state: **"Saved to Work. Add the words on your iPhone."** Neither
existing line is true here — `saved` hides the one thing the person must still
do, `savedWordsOnly` says their recording was thrown away, which is the
opposite of what happened.

Side effect, and a second truth repaired: an ordinary SUCCESS whose transcript
is empty (a silent clip) also lands on the new line instead of claiming a clean
save.

## What changed

| File | Symbols |
|---|---|
| `Conduck/Conduck/Services/AppleSpeechRelayCoordinator.swift` | both phase-2 catch arms; new `acknowledgesRecording(after:)`, `workRecordingAcknowledgement()`, `shipWorkRecordingAcknowledgement(requestID:preferMessage:)`; header + phase-2 doc comments |
| `ConduckWatch Watch App/Services/AppleRelayPendingQueue.swift` | `RelaySettlement.workRecordingOnly`; `settlement(for:workSaved:hasWords:)` (defaulted third argument, so every existing call site and assertion keeps its spelling); new `carriesWords(_:)`; `applySettledSuccess` (one claim arm for both stamped answers); `postWorkNotification` third arm |
| `ConduckWatch Watch App/Services/WatchRecordingService.swift` | `WatchWorkCaptureOutcome.savedWithoutWords`; new `WatchWorkCaptureOutcome.forSettlement(_:)` — ONE mapping the live leg and the deferred leg both read; `noteWorkCaptureSettled` and `runRelay`'s `finishWork` closure now read it |
| `ConduckWatch Watch App/Views/WatchWorkCaptureView.swift` | `WatchWorkCaptureCopy.terminalLine/symbolName/isReassuring/logLabel` gain the case |
| `ConduckWatch Watch App/Localizable.xcstrings` | two rows (below) |
| `ConduckTests/WatchWorkRelayPhoneTests.swift` | +5 tests |
| `ConduckTests/RelayReplyCacheTests.swift` | +1 test |
| `ConduckWatchTests/WatchRelayQueueRetryabilityTests.swift` | +5 tests (§1e) |
| `ConduckWatchTests/ConduckWatchSmokeTests.swift` | +2 tests; `durableOutcomes` gains the new case so the existing ban-list and reassurance loops cover it |

`RelayReplyCache.swift` was NOT opened — the `workSaved` field it already
carries is the whole of what the acknowledgement needs.
`STTKeyBlackoutLaneTests` needed no re-anchoring (`runRelay`'s two
`deferred: true` arms and the `stt.prep.failed` ordering are untouched).
No `.xcdatamodeld`, no envelope schema, no new test FILE, no pbxproj edit.

## Catalog rows

Watch catalog only (`ConduckWatch Watch App/Localizable.xcstrings`), added in
the file's exact existing shape (`extractionState: extracted_with_value`,
`en` / `state: new`), in sorted position; parsed back with `json.load` — 316 →
**318** rows, keys still sorted, no duplicates.

| key | defaultValue | comment |
|---|---|---|
| `watch.work.capture.savedWithoutWords` | `Saved to Work. Add the words on your iPhone.` | none (this catalog has never carried one) |
| `watch.work.notification.savedWithoutWords` | `Saved to Work. Add the words on your iPhone.` | none |

Two keys, not one, on the same precedent as `.capture.saved` /
`.notification.saved`: a screen line and a notification body have different
length budgets and reading contexts. The notification needs its own arm because
a banner is often the ONLY thing read on a deferred settlement — a shared
"Saved to Work." would leave half of these people believing a card is finished.

## Pinning tests

**iOS** (`WatchWorkRelayPhoneTests`)

- `testASettledTranscriptionFailureOnAPublishedCaptureIsAcknowledged` — six
  settled verdicts, each asserted non-retryable first (fixture drift) then
  acknowledged.
- `testARetryableTranscriptionFailureStillTravelsBackAsAnError` — the negative
  control: 20 / 75 / 78 still travel back as errors, so the words can still
  arrive and the wrist still keeps its clip.
- `testTheAcknowledgementIsASuccessReplyWithNoWordsInIt` — 4 keys, empty
  `result.text`, `result.work == true`, no error slot.
- `testAReplayedAcknowledgementSettlesTheWristToo` — the cache replay carries
  the stamp (the re-fire path the finding turns on).
- `testBothTranscriptionFailureArmsAnswerAPublishedCaptureFirst` — source guard
  (`processRelayRequest` has no seam: it needs an activated `WCSession` and a
  paired watch). Bounded between the typed catch and the next declaration;
  requires TWO acknowledgement call sites, each BEFORE its arm's error reply,
  and requires the branch to read both facts (`workCardID != nil, Self.acknowledgesRecording(after:`).

**iOS** (`RelayReplyCacheTests`) —
`testAnEmptyTranscriptRoundTripsAsASuccessNotAnAbsence`: empty text is a value,
nil text is a failure; the LRU must not collapse the two.

**Watch** (`WatchRelayQueueRetryabilityTests` §1e)

- `testAStampedReplyWithNoWordsStillSettlesTheEntry` — `""`, `"   "`, `"\n"`:
  claims once, no converse hop, NO words written, `.applied(.workRecordingOnly)`.
- `testAStampedReplyWithWordsIsStillACleanSave` — negative control.
- `testTheWordlessAnswerIsScopedToAStampedWorkReply` — the classifier in both
  dimensions, including that an UNSTAMPED empty reply still takes the
  words-only lane and that chat is unaffected.
- `testAStampedEmptyReplyReleasesTheWristsClipAndNamesTheGap` — the LIVE leg
  end to end through the `relayTranscribe` seam against the real queue: entry
  gone, depth back to baseline, outcome `.savedWithoutWords`, machine `.idle`.
- `testADeferredSettlementWithNoWordsRepaintsTheLineItNames` — the deferred
  leg, including the R1-round correlation rule (a sibling's settlement still
  leaves the displayed line alone).

**Watch** (`ConduckWatchSmokeTests`) —
`testTheWordlessSaveNamesTheHalfThatIsMissing` (the sentence, distinctness
across all four durable lines, glyph, log label) and
`testEverySettlementNamesItsOwnLine` (the one settlement→line mapping).

### Measured red-without-the-fix

| mutation | result |
|---|---|
| both acknowledgement branches DELETED | `testBothTranscriptionFailureArmsAnswerAPublishedCaptureFirst` fails 2 assertions (0 call sites, missing both-facts read) |
| branches kept but condition forced false | same guard fails on the both-facts read |
| `hasWords: carriesWords(reply.text)` → `hasWords: true` | 7 failures across `testAStampedReplyWithNoWordsStillSettlesTheEntry` and `testAStampedEmptyReplyReleasesTheWristsClipAndNamesTheGap` (269 tests, 7 failures) |

Every mutation was reverted from a byte-copy backup and both suites re-run
green afterwards.

## Nobody undo (this round)

- **Only a SETTLED verdict is acknowledged.** Acknowledging a retryable one
  (20, 75, 78) throws away a transcript the next attempt can still land, and 78
  before publication has nothing to acknowledge at all. The predicate must stay
  `shouldCacheVerdict`, not "did phase 1 succeed".
- **The acknowledgement's cache store is unconditional.** It is the replay that
  settles a re-fire; gating it on the admission rule would re-open the finding
  through the front door.
- **No new wire literal.** `result.work` + an empty `result.text` is the whole
  encoding. Both `Wire` enums stay at their 14 identical literals; chat's
  three-key success shape is untouched (`RelayWireContractTests` green).
- **`.savedWithoutWords` and `.savedWordsOnly` are opposite halves.** One means
  the recording is on the desk without words; the other means the words are on
  the desk without the recording. Collapsing them tells half of these people
  the wrong thing.
- Every R1-round "Nobody undo" still holds: the destination-specific retention,
  write-then-claim on `workWordsOnly`, the settlement-token correlation, the
  `.work`-only wire stamp, `result.work` absent ⇒ false, the caps exemption
  plus `refusesNewWorkCapture`, `completeEntry` unrestructured, no new
  `WatchRecordingState` case, no Retry on the capture screen.

## Measured

| Run | Result |
|---|---|
| `xcodebuild test -scheme ConduckWatchTests` (watchOS sim `28AC563B…`) | **Executed 269 tests, 0 failures**, exit 0, `grep -c ': error: '` = 0 (baseline 262 + 7) |
| `xcodebuild build-for-testing -scheme Conduck` (iOS sim `04DEF…`) | exit 0, **0** `: error: ` |
| iOS `WatchWorkRelayPhoneTests` + `RelayWireContractTests` + `RelayWireSourceDriftGuardTests` + `RelayReplyCacheTests` + `STTKeyBlackoutLaneTests` + `WorkboardAudioCaptureTests` | **67 tests, 0 failures** |
| `scripts/add-spdx-headers.sh --check` | exit 0 |

No `-configuration` flag; caches under
`~/Library/Caches/gigaduck-builds/fix2-watch/`.

## Founder QA — the one path that changed

Both devices on this build.

1. **The words fail, the recording does not.** On the iPhone, pick Apple speech
   with the model NOT installed (Settings → Voice → Apple, before the download
   finishes). On the wrist: Save to Work, speak a sentence, Done. *Must be
   true:* the wrist ends on **"Saved to Work. Add the words on your iPhone."**
   with the tray glyph and a success buzz, and the iPhone's Work desk shows a
   playable card with no words on it. *Failure to report:* an error line on the
   wrist (the old behaviour — the card is on the desk and the wrist says it
   failed), or "Saved to Work." with no mention of the missing words.
2. **The queue empties.** Repeat step 1 several times, then check the wrist can
   still start a new Work capture (it must never refuse with "Work is waiting
   for your iPhone" while the phone is right there and every card is already on
   the desk). Then record a normal **Ask** — it must still answer and must not
   have been evicted.
3. **Deferred, then settled without words.** Phone in airplane mode → Save to
   Work → leave the screen open. Turn the phone's speech model off, then
   airplane mode off. *Must be true:* the notification and the screen both read
   "Saved to Work. Add the words on your iPhone."
4. **Nothing else moved.** Phone unreachable → the deferral line is still
   "Saved on your watch. It reaches Work when your iPhone is nearby.", and a
   normal Work capture with the phone nearby still ends on plain "Saved to
   Work." with words on the card.
