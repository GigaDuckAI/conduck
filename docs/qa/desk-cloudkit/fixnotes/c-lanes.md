# c-lanes — r3a#1, r3a#6, r3a#11 + adjudications O-7 and O-12. All three findings CONFIRMED and fixed; nothing refuted.

Slug `c-lanes`. Sim `5C851D88-959C-445E-ACC8-A4C6ADB2876C`. No commits, pushes, stash, checkout, reset
or index operations. `Identity-Override.xcconfig` untouched. Nothing under `docs/qa/desk-cloudkit/`
touched. **No `.xcstrings` opened.** No `.pbxproj` edit. No mirror triplet touched. No new file. No
file outside my ownership edited.

Files changed — seven, none new:

| File | Change |
|---|---|
| `Conduck/Conduck/Intents/ConverseIntent.swift` | r3a#1 + O-7 + O-11 consumption: phase-one verdict recorded (memory + slot), Work branch routed through `recover`, two new private helpers `stamped` / `parkRecoveryState`. **Chat branch byte-for-byte unchanged — measured, §Chat below** |
| `Conduck/Conduck/ContentView.swift` | O-7 + O-12 + r3a#5 consumption in `runPendingRetry`; new private `finishWorkRetry` / `releasePendingRetry` |
| `Conduck/Conduck/MenuBar/DictationService.swift` | same three, in `retryLast`; new private `finishWorkRetry` |
| `Conduck/Conduck/Services/STTClient.swift` | O-12's second half: new `multipartAudioPart(for:)`, multipart part built from it |
| `Conduck/ConduckTests/WorkboardVoiceLaneTests.swift` | r3a#11: rules extracted to `WorkVoiceIntentLaneRule` + `WorkVoiceIntentLaneValidator`; retry validator RETIRED; O-12 cases added. 12 → 11 cases |
| `Conduck/ConduckTests/RemoteAgent/HeadlessRetryGuardSpanTests.swift` | O-7 step (a): `workPublish` re-anchored. 11 cases, ordering unchanged |
| `Conduck/ConduckTests/WorkboardAudioCaptureTests.swift` | O-7 step (b): the ONE guard method I own, replaced. 19 cases |

`ContentView.swift`'s diff ALSO carries two hunks at `:290` and `:669` (`.openPersonalAISettings`
observers) that are **not mine** — another agent's O-6 slice, already in the tree when I started.

---

## Findings

### r3a#1 (major) — a phase-one store failure still lost the recording. CONFIRMED, fixed.

**Verified first, by call path, before changing anything.** At `801b937` `perform()`'s phase 1 caught
its publication failure, logged it and continued with NOTHING recorded (`:327-339`); the retry record
`arm` had already written carried `publicationState: nil`. STT then succeeded, `attachTranscript`
answered `.recordingMissing` (no row at the capture id), the branch published a note under
`fallbackNoteID`, and `PendingRetryGuard.disarm(guardToken)` ran unconditionally two lines later —
`PendingRetryStore.clear(ifCurrentID:)` deleting the only copy of the audio. Both halves hold
exactly as written: the words survive as a note, the recording does not, and nothing anywhere had
recorded that the desk had refused rather than that a card had been deleted.

**Fix, in three parts.**

1. **The verdict is observed.** `var workPublicationState: PendingRetryPublicationState?` is set on
   both arms of the phase-one `do`/`catch` (`.published` / `.phaseOneFailed`). In-process this is the
   authoritative fact; nothing has to be read back.
2. **The verdict is parked, for the recovery that happens in another process.** The catch calls
   `Self.parkRecoveryState(Self.stamped(pendingMetadata, publicationState: .phaseOneFailed), …)`,
   which re-commits the slot **only while this capture still owns it**
   (`PendingRetryStore.shared.currentSlot()?.id == metadata.id`). Success is deliberately NOT written
   — see §Decisions 2.
3. **The desk decision is one call, and the disarm hangs on its answer.** Phase 2 is
   `WorkVoiceCaptureCoordinator.recover(record, transcript:)` where `record` is
   `PendingRetryRecord(metadata: Self.stamped(pendingMetadata, publicationState: workPublicationState,
   transcript: transcript), audio: uploadData)`, and the disarm is `if await outcome.isTerminal`. So a
   refused phase one now REPUBLISHES the recording from those same bytes and attaches the words to it
   — one playable card — instead of writing a note and deleting the audio. A throw from `recover`
   parks the WORDS beside the recording (`parkRecoveryState` again, with `transcript`) and rethrows,
   so the retry keeps them and pays for no second transcription.

**Regression tests.** The behaviour of `recover` itself is c-recovery-core's 18 cases
(`WorkVoiceRecoveryTests`, 18/0 against my tree), including
`testAKnownFailedPublicationIsRepublishedFromTheParkedBytesAndTakesItsWords` and
`…ThatActuallyLandedRepairsTheSameCard`. What is mine to prove is that THIS lane reaches it with the
verdict in hand, and that is `WorkVoiceIntentLaneRule.aRefusedPublicationIsRecorded`,
`.theRecoveryCarriesTheCapturesRecord`, `.releasedOnlyOnATerminalOutcome` and `.publishedBeforeTheRecovery`
— all four run by `testTheShortcutsLaneSatisfiesEveryRuleOfTheWorkVoiceLane`.
*How I know they bite:* `testTheIntentLaneValidatorRefusesEveryShapeItExistsToRefuse` runs the SAME
predicate over a reconstruction of the shipped shape (`attachTranscript` + a fallback publish, no
verdict) and asserts it fails on exactly those four plus `.onePayloadForEveryUse` — an equality
assertion on the violation set, not a `contains`.

### r3a#6 (minor, O-12) — both retry surfaces named every recovered file `.m4a`. CONFIRMED, fixed, and it reached further than the finding said.

**Verified:** `ContentView.swift:1520` and `DictationService.swift:244` both wrote
`conduck_retry_<uuid>.m4a` unconditionally, while `AudioCompressor` returns `.wav` on an AAC encode
failure and passes the source container through untouched (CAF, from CarPlay's tap) — and both lanes
now preserve COMPRESSED bytes.

Both sites now name the staged file
`".\(PendingRetryAudioFile.extension(for: pending.audioData))"` (C6's helper, `SourceAudioContainer.sniff`).

**One thing the finding and O-12 both understate, worth recording:** the extension is not only
cosmetic on the way to a multipart upload. For the **in-process (Apple on-device) provider**,
`STTClient.transcribe` early-returns before any body is built and hands the runner the URL — so the
FILE NAME is what `AVAudioFile` / `SFSpeechURLRecognitionRequest` read the container from. A
`.m4a`-named RIFF file is a decode failure there, not a politeness issue.

**Regression test.** `testBothRetrySurfacesStageTheRecoveredBytesUnderTheirOwnContainer` — behavioural
over the helper (WAV → `wav`, `ftyp` → `m4a`, unrecognised → `m4a`) plus a call-site assertion on both
function bodies that the derivation is used and the literal `conduck_retry_\(UUID().uuidString).m4a`
is gone. *How I know it bites:* the literal it asserts absent is the exact text both files carried at
`801b937`, and the helper it asserts present did not exist there.

### O-12's second half — STTClient's multipart hardcoded `audio/mp4` + `audio.m4a`. Fixed.

`STTClient.multipartAudioPart(for: audioData) -> (mime: String, filename: String)` reads the container
off the bytes the request is about to carry; the multipart branch builds its part from that. **This is
a different mechanism from the one the adjudication proposes ("propagate the same container MIME and
filename through STTClient's multipart request") and it is strictly stronger** — the bytes the retry
surface staged are the bytes `transcribe` reads back off disk, so the two descriptions agree *by
construction* rather than by a caller passing the right thing, and every other caller (in-app
recorder, CarPlay, Chat) is corrected at the same time without touching a file I do not own. Threading
a parameter would have made "a caller passes a container that does not match its bytes" expressible;
this does not.

**Regression test.** `testTheMultipartAudioPartDescribesTheBytesItCarries` — behavioural over the new
member for WAV / M4A / CAF / unrecognised bytes, and then over `STTMultipartBuilder.build` to assert
the assembled body really carries `filename="audio.wav"` and `Content-Type: audio/wav`. Paired with
`testTheUploadBuildsItsAudioPartFromThatAnswer`, one narrow call-site check that `transcribe` asks
(it cannot be driven end to end without a provider on the other end).
*How I know they bite:* the member does not exist at `801b937`, so the behavioural case cannot compile
there; and the two literals the call-site check asserts absent are the exact ones at `:288-289`.

### r3a#11 (minor) — the "Rule 0 controls" did not run the production predicates. CONFIRMED, fixed.

**Verified:** at `801b937` `testTheOrderingCheckDistinguishesPublishAfterTranscriptionFromPublishBefore`
(`:153-174`) hand-wrote two `range(of:)` comparisons over fixtures while the production case asserted
five orderings plus three counts, and cases 7 and 8 had no control at all;
`testTheRetrySurfaceGuardsDistinguishTheCollapsingShape` (`:409-442`) likewise re-implemented
`contains` calls rather than running cases 10–11's logic. Both hold exactly.

**Fix.** Every rule the lane has is now a case of `WorkVoiceIntentLaneRule` (12), evaluated by one
`WorkVoiceIntentLaneValidator.violations(in:)`. The live-source case asserts the violation set is
empty; the control case runs **that same function** over a compliant fixture (empty) and over twelve
mutations, each asserted to yield **exactly** `[thatRule]` — plus the reconstructed shipped shape.
A missing anchor is a violation, never a silent pass, which is what the old `XCTUnwrap`s bought and
what an ordering comparison alone loses.

**The retry validator is RETIRED**, as r3a#11 directs: cases 10–12 are gone, because
`recover` now carries that behaviour and is driven against a real store in `WorkVoiceRecoveryTests`.
What is left of it is a call-site policy, in `WorkboardAudioCaptureTests` (§Guard verdicts).

---

## Adjudications

### O-7 (DECIDED) — route ALL THREE surfaces through `recover()`, then re-anchor. DONE, in the order c-recovery-core §Requests 2 specifies.

| Surface | Shape now |
|---|---|
| `ConverseIntent.perform()` | screenshot → `recover(record, transcript:)` → `if await outcome.isTerminal { disarm }` |
| `ContentView.finishWorkRetry` | screenshot → `recover(PendingRetryRecord(pending), transcript:)` → `guard outcome.isTerminal` → `releasePendingRetry(id:)` |
| `DictationService.finishWorkRetry` | same, ending in `clear` + `cancelDeferredNotification` + `state = .idle` |

Both retry surfaces got a **private `finishWorkRetry`** rather than an inline block, and that is
load-bearing rather than tidy: each file reaches `recover` from two places (a retry that had to buy
its words, and one whose words were already parked), so without the extraction the "exactly once per
surface" policy could not be true. The clear/release sits BELOW the recovery inside the same `do` in
both, so a throw skips it — the property the retired guard used to hold.

`WorkCaptureRetryCoordinator` now has **no production caller at all** (§Requests 1).

### O-11 consumption — the intent lane no longer gets a nil verdict for free.

c-recovery-core §Notes 6 asked for exactly this, and it is done for `.phaseOneFailed` (the reading
that matters). `.published` is deliberately not persisted — §Decisions 2.

### O-12 — see r3a#6 above; both halves closed, with WAV coverage on the helper, on the multipart part, and on both surfaces' call sites.

---

## Decisions

1. **The arm stays ABOVE phase one; the verdict is written after it.** Moving `PendingRetryGuard.arm`
   below the publication would have carried the verdict for free, and I refused it: the publication is
   a Core Data mount in a headless intent process before first unlock — precisely the case this whole
   lane exists for — so putting an unbounded store operation between the microphone and the only
   durable copy of the recording trades a certainty for a convenience. `WorkVoiceIntentLaneRule.armedBeforeThePublication`
   pins the order.
2. **Only a REFUSAL is written to the slot; success is not.** `recover` reads nil and `.published`
   identically, so the write would buy nothing there — and it would cost something: re-committing the
   single slot on the happy path can restore this capture over a second intent host that armed while
   the desk write was in flight, whose bytes have no other copy. On the failure path our bytes are the
   only copy of a recording that has no card, which is what justifies the write; even there it is
   gated on `currentSlot()?.id`. The stated cost of the asymmetry, written at the call site: a
   successful capture keeps a nil verdict, so `PendingRetrySlot.hasDurableRecording` reads it as
   irreplaceable and the in-app recorder declines to displace it — a pessimism that spends a later
   capture's WORDS (still in memory) to protect a recording that might be the only copy.
3. **A stale `.phaseOneFailed` is safe; a stale `.published` is not.** That asymmetry is why the
   pessimistic value is the one that gets persisted: republishing is idempotent by capture id and
   lands on the card already standing there (c-recovery-core's
   `testAKnownFailedPublicationThatActuallyLandedRepairsTheSameCard`), whereas a wrong `.published`
   sends the words to a note and clears the audio.
4. **`recover` is asked `isTerminal`, never matched case by case**, per C6's contract — including in
   `perform()`, where it needs an `await` (the property is main-actor isolated and `perform()` is
   nonisolated). `if await outcome.isTerminal` is warning-free; reading it without the `await` was the
   ONE warning my first draft introduced, and it is gone.
5. **The parked-transcript consumption (r3a#5's other half) IS implemented**, in both surfaces, as an
   early branch above the STT preamble rather than a conditional inside it. A Work record carrying
   words owes the desk a write and nothing else, so it must skip the key verdict too — a key removed
   since the capture would otherwise refuse a retry that needs no key, and the whole point is that
   this retry completes **with no network at all**.
6. **No Codex consult.** The one genuinely hard call (where the phase-one verdict gets written, given
   that `arm` must stay first and `PendingRetryStore` is not my file) is a trade with a stated rule,
   not a technical unknown; the rule and its cost are written out in §Decisions 2 and at the call site.

## Deviations

1. **O-12's mechanism.** Sniffing inside `STTClient` rather than threading the container from the two
   retry sites — stronger, and it needs no edit to a file I do not own. Reasoned above.
2. **Two new private methods per retry surface** (`finishWorkRetry`, and `releasePendingRetry` in
   ContentView), beyond a minimal edit. Required by O-7's "exactly once" policy; both are inside the
   Work retry path I own.
3. **One behavioural difference at the two retry surfaces, stated rather than hidden.** A Work desk
   failure that happens to be a typed `AppError` (reachable only through
   `WorkVoiceScreenshotCoordinator.publish` → `WorkCaptureInbox`) used to land in `runPendingRetry`'s
   / `retryLast`'s `catch let error as AppError` arm, which bumped `updateAttemptIfCurrent` and
   re-keyed the card to that code. It now lands in `finishWorkRetry`'s own catch and reads as
   *"Couldn't add this recording to Work. Try again."* — the same sentence the untyped case always
   got, and the honest one for a desk failure. Nothing is lost but a diagnostic attempt count; the
   record is kept either way.
4. **`WorkboardAudioCaptureTests`' guard method is RENAMED** —
   `testEveryRetrySurfaceRepairsTheRecordingBeforeItPublishes` →
   `testEveryRetrySurfaceMakesItsDeskDecisionThroughTheOneRecovery`. The old name asserts an order
   between two calls neither surface makes any more. Recorded here because integration notes track it
   by name; the class count is unchanged at 19.

---

## Chat — byte-for-byte unchanged, measured

`ConverseIntent.swift`'s Chat-only regions were extracted from `git show HEAD:` and from the working
tree by brace-matching and compared as strings:

```
payload_else:      IDENTICAL  (129 bytes)     ← uploadData = originalAudioData; audioFileExtension = "m4a"
chat_preflight:    IDENTICAL  (3140 bytes)    ← if destination == .chat { let preflight … }
notif_gate:        IDENTICAL  (71 bytes)      ← NotificationPermissions.ensureRequested()
screenshot_inline: IDENTICAL  (2430 bytes)    ← the inline-vision block + runConverseHop call
runConverseHop:    IDENTICAL  (11090 bytes)
```

Every hunk in the file's diff is the header comment, the phase-1 block, the phase-2 block, or the two
new private helpers. The Chat lane's upload is still the Shortcut's own recording, byte for byte, and
nothing on that branch touches Workboard persistence.

---

## Gates — what I actually ran

DerivedData under `~/Library/Caches/gigaduck-builds/c-lanes/{DerivedData,DerivedDataMac}`, every log
written there and grepped for `': error: '` and the verdict strings — never judged from tail or exit
code. **No `-configuration` passed anywhere.**

- **iOS `build-for-testing`** → `ios-bft-5.log` (final): `grep -c ': error: '` = **0**,
  `** TEST BUILD SUCCEEDED **`. (`ios-bft-1..4` also 0 errors — no run ever failed on a foreign file.)
- **iOS `test-without-building`**, thirteen quoted `-only-testing:` flags → `test-5.log`:
  `** TEST EXECUTE SUCCEEDED **`,
  `Executed 152 tests, with 0 failures (0 unexpected) in 6.917 (6.951) seconds`,
  `grep -cE '\.swift:[0-9]+: error: '` = **0**.

| Class | Result line |
|---|---|
| `WorkboardVoiceLaneTests` | `Executed 11 tests, with 0 failures (0 unexpected) in 0.120 (0.122) seconds` (was 12) |
| `HeadlessRetryGuardSpanTests` | `Executed 11 tests, with 0 failures (0 unexpected) in 0.038 (0.040) seconds` |
| `WorkboardAudioCaptureTests` | `Executed 19 tests, with 0 failures (0 unexpected) in 0.135 (0.139) seconds` |
| `STTKeyBlackoutLaneTests` | `Executed 11 tests, with 0 failures (0 unexpected) in 1.671 (1.675) seconds` |
| `WorkVoiceRecoveryTests` | `Executed 18 tests, with 0 failures` |
| `PendingRetryDestinationTests` | `Executed 6 tests, with 0 failures` |
| `HeadlessRefusalLaneDriftGuardTests` | `Executed 5 tests, with 0 failures` |
| `ErrorSurfaceDriftGuardTests` | `Executed 7 tests, with 0 failures` |
| `STTProviderTests` | `Executed 17 tests, with 0 failures` |
| `STTCustomModelTests` | `Executed 19 tests, with 0 failures` |
| `AudioCompressorTests` | `Executed 7 tests, with 0 failures` |
| `WorkCaptureDrainerTests` | `Executed 10 tests, with 0 failures` |
| `TempScratchSweeperTests` | `Executed 11 tests, with 0 failures` |

  Beyond the four the brief names I ran every class that could scope the STT multipart change
  (`STTProviderTests`, `STTCustomModelTests`, `AudioCompressorTests` — all three build multipart
  bodies with their own literals and are unaffected), the temp-file sweeper (it enumerates
  `conduck_retry_*` and `audio.m4a` names), the two refusal-lane guards over `ConverseIntent`, the
  error-surface registry, and the coordinator's own behavioural suite.

  **One infrastructure flake, reported rather than smoothed over:** `test-3.log` died with
  `Simulator device failed to launch ai.gigaduck.AgentRelay … Busy ("Application failed preflight
  checks")` before any case ran — no test failure, no compile error (`grep -c error:` = 0). Retried
  once per the brief's rule (`test-4.log`), green, and green again in `test-5.log`. No `simctl
  shutdown` was needed.
- **macOS `build -destination 'platform=macOS'`** → `mac-3.log`: 0 `error:`, `** BUILD SUCCEEDED **`,
  `Signing Identity: "Apple Development: Peter Krueck (Z4PNDLZK98)"`. **Signed through the identity
  override; no `CODE_SIGNING_ALLOWED=NO` fallback needed or used.**
- **Warnings: I added none, and removed none of anyone else's.**
  `ContentView.swift`: **zero** warnings on either platform.
  `ConverseIntent.swift`: four, all pre-existing at unchanged identifiers (`maxAudioSize`,
  `displayName(for:customs:)`, `RemoteAgentDiagnostics.log`, `play(mode:)`).
  `DictationService.swift`: two, both the pre-existing `startDisplayTimer` self-capture pair, at a
  shifted line.
  `STTClient.swift`: 13, all pre-existing in kind (`STTProbe`, `Transport: Equatable`,
  `effectiveModel`, `customSTTRequestTimeout`, `STTMultipartBuilder.build`, `jsonBodyFactory`×2,
  `buildRequestBody`, `apply(to:apiKey:)`, `map`, `decode`, `jsonBodyFactory`, `decodeResponse`). My
  first draft inlined `SourceAudioContainer.sniff` in `transcribe` and added **two** (`ios-bft-1.log`
  `:296`, `:299`); the `@MainActor multipartAudioPart` hop removes both (`ios-bft-4.log` onward), and
  the `build(…)` diagnostic that remains is the same one that call has always carried — the callee's
  isolation and the caller's are unchanged by my edit.
- `bash scripts/check-storage-seam.sh` → `✓ storage seam intact — 795 Swift files scanned…`, exit 0.
  `check-folder-map.sh`, `check-spec-cites.sh`, `check-legal-copies.sh` → all `✓`, exit 0.
- `git diff --check` → no output, exit 0. `git status --short` for `*.xcstrings`, `*.pbxproj`,
  `Conduck/Configs`, `docs/qa`, and all three mirror triplets → **empty**. `git diff --cached --stat`
  → **empty**. `git status --short` over my seven files shows ` M` on exactly those seven and no
  untracked file from me.
- **NOT run, plainly: the full iOS suite and the watch suite.** Neither is in my brief, no watch sim
  is assigned to me, and other agents are editing this tree — a full run now would report their
  in-flight state as mine. Expect **−1** on the iOS executed count from this slice
  (`WorkboardVoiceLaneTests` 12 → 11; `WorkboardAudioCaptureTests` and `HeadlessRetryGuardSpanTests`
  unchanged at 19 and 11). **The watch target compiles none of my four production files** —
  `ConverseIntent.swift`, `ContentView.swift`, `MenuBar/DictationService.swift` and
  `Services/STTClient.swift` are all absent from the `ConduckWatch Watch App` membership-exception
  list, and the watch's own STT lane is `STTClient+Background.swift`, which I did not touch.
- Build cache removed at end of task with `.claude/scripts/clean-build-cache.sh c-lanes`, so the logs
  no longer exist; re-run if you need them. No bare `rm -rf`, no `/tmp`. The only throwaway tree copy
  (two `ConverseIntent.swift` revisions, for the Chat byte-comparison) lived under the slug dir and
  went with it.

---

## Catalog

**Keys I ADDED in source: NONE.** The two retry surfaces' Work failure arms reuse the existing
`workboard.capture.retry.voice.message` = `Couldn't add this recording to Work. Try again.`, which
they already carried; `finishWorkRetry`'s non-terminal arm uses the same key rather than minting a
second sentence for a state a person cannot tell apart from the first.

**Keys I made DEAD: NONE.** Every string-bearing branch I moved kept its key.
`workboard.capture.note` = `Share note` is untouched and still referenced by the drainer's own note
branch — the fallback note the surfaces used to publish through `WorkCaptureRetryCoordinator` now goes
through `recover`, which names itself from the transcript (c-recovery-core §Deviations 3), so the key's
liveness does not depend on my slice either way.

**No `.xcstrings` file was opened.** Nothing for the serial copy agent to splice from this slice.

---

## Requests

1. **Someone with ownership of `Conduck/Conduck/Services/Workboard/WorkCaptureRetryCoordinator.swift`
   — it now has ZERO production callers.** All three were mine and all three route through
   `WorkVoiceCaptureCoordinator.recover`. `grep -rn WorkCaptureRetryCoordinator Conduck/Conduck` returns
   one line, and it is a prose reference in `WorkVoiceScreenshotCoordinator.swift:20` explaining why
   the screenshot rides the inbox. Two remaining test mentions are string literals inside fixtures
   (`WorkboardAudioCaptureTests:748` asserts its ABSENCE; `WorkboardVoiceLaneTests:242` is inside the
   reconstructed shipped-shape fixture) — neither calls it, so deleting the file compiles.
   I did not delete it: not my file, and a delete in a parallel phase is the wrong shape.
2. **Owner of `Conduck/Conduck/Services/STTClient+Background.swift` — the Watch lane still hardcodes
   `audio/mp4` + `audio.m4a` (`:267-268`).** Not urgent and not a defect today: the wrist records AAC
   M4A natively and never carries a compressed-retry payload, so the label is true there. It becomes
   false the moment anything else feeds that lane. One line, the same
   `STTClient.multipartAudioPart(for:)` I added.
3. **Owner of the JSON-transport providers — two more hardcoded container claims, out of O-12's
   scope.** `QwenSTTProvider.swift:55` builds `data:audio/mp4;base64,…` and
   `GeminiSTTProvider.swift:66` sets `audio/mp4`, both for whatever bytes they are handed. Same
   defect class as `:288-289` was, on a path a Work retry can reach if either provider is selected.
   Neither is my file and neither is multipart.
4. **Whoever owns `PendingRetryStore.swift` next session — a targeted verdict write would retire the
   one wart in my fix.** `parkRecoveryState` re-commits the whole slot (audio bytes included) to
   record one field, guarded by a `currentSlot()` read that is a TOCTOU window however small. A
   `recordPublicationState(_:transcript:ifCurrentID:)` on the store — metadata-only, inside the same
   `withExclusiveLock` as the ownership check, exactly like `updateAttemptIfCurrent` — closes the
   window and drops the write to a UserDefaults set. I did not add it: not my file, parallel phase.
5. **Nobody undo these** — they interlock:
   - The arm stays ABOVE the phase-one publication, and the publication stays above the key verdict
     and the STT hop. Three of the twelve rules pin it.
   - The disarm/release hangs on `isTerminal`, in all three surfaces. Disarming on the absence of an
     error is r3a#1 restored.
   - `.phaseOneFailed` is the pessimistic value and is the one persisted. Persisting `.published`
     instead (or as well, on the happy path) re-commits a slot a newer capture may own.
   - Each surface reaches `recover` exactly once. Two call sites in one file is the same decision
     spelled twice, which is what the retired guard existed to prevent and what
     `testEveryRetrySurfaceMakesItsDeskDecisionThroughTheOneRecovery` now prevents.
   - Filenames and MIME types for audio come from `SourceAudioContainer.sniff`, at the staging sites
     and in the upload. A fixed pair is a claim about the container.
6. **Founder QA (Gate 2) — four items this slice adds, none reachable by a unit test.**
   (a) **Shortcut / Action Button, Destination = Work, with the app force-quit and the device just
   rebooted (not yet unlocked)** so the desk write fails: the retry card must appear, and finishing it
   later must leave ONE playable card carrying the words — not a note beside a missing recording.
   (b) Same lane, but let phase one succeed and STT fail (airplane mode): the untranscribed card is on
   the desk, and the in-app Retry fills in its words on that SAME card.
   (c) **A Work capture whose words were already recognised** (desk write failed after STT): tap Retry
   with the device in airplane mode. It must COMPLETE — no key prompt, no network — because the words
   are parked on the record. This is the path §Decisions 5 adds and the one most worth checking.
   (d) **macOS menu bar**, same three, plus: a Work retry that fails the desk write must leave the
   Retry affordance live with the recording still recoverable.

---

## Refuted

**None.** All three findings were traced against the current tree by call path before any code
changed, and all three hold exactly as written. Two qualifications, stated as such rather than as
refusals:

- **r3a#6 is CONSERVATIVE.** Its evidence names the multipart upload as the cost; the sharper one is
  the in-process Apple provider, where the file NAME is the only container signal the runner has.
- **O-12's proposed mechanism was not implemented literally.** Its requirement ("propagate the same
  container MIME and filename through STTClient's multipart request") is met by deriving both inside
  `STTClient` from the same bytes, which makes disagreement unrepresentable rather than merely
  avoided; the reasoning is in §Findings O-12's second half. The adjudication's other two clauses
  (sniff once when re-materialising each retry; add WAV coverage for both surfaces) are implemented
  as written.

---

## Guard verdicts

- **`WorkboardAudioCaptureTests.testEveryRetrySurfaceRepairsTheRecordingBeforeItPublishes`** (rated
  `convert` in round 2; KEPT by fix2-recorder, fix2-voice-lanes and c-recovery-core, each saying the
  conversion had to wait for the hoist) — **CONVERTED and RENAMED** to
  `testEveryRetrySurfaceMakesItsDeskDecisionThroughTheOneRecovery`, now that the hoist has landed.
  It no longer orders two calls; it asserts a CALL-SITE POLICY, comment-stripped, per surface file:
  `WorkVoiceCaptureCoordinator.recover(` appears **exactly once**, `WorkCaptureRetryCoordinator.publish(`
  **not at all**, `WorkVoiceCaptureCoordinator.attachTranscript(` **not at all**. The second and third
  are the load-bearing ones: a surface keeping a private fallback arm beside the shared entry point is
  a second answer to the question `recover` exists to answer.
- **`HeadlessRetryGuardSpanTests`** — **RE-ANCHORED**, exactly as c-recovery-core §Requests 2(a)
  specifies and no further: the `workPublish` needle moves from `"WorkCaptureRetryCoordinator.publish"`
  to `"WorkVoiceCaptureCoordinator.recover("`, and **the ordering it asserts is unchanged** —
  `transcriptCaptured = true` < the Work publication < the Work disarm < the catch gate, with the
  disarm count still pinned at exactly 3. Two doc comments describing the third disarm were retold to
  say what it now hangs on. No assertion was weakened, added or removed. 11/11.
- **`WorkboardVoiceLaneTests`' three retry-surface guards (cases 10, 11, 12 at `801b937`)** —
  **RETIRED**, as r3a#11 directs ("retire the retry validator once `recover()` carries the
  behaviour"). What they asserted — no `try?` collapse, the clear below the attach, no fallback at the
  capture id — is now either structurally impossible (there is no attach and no fallback at these
  surfaces) or asserted behaviourally against a real store in `WorkVoiceRecoveryTests`. Nothing they
  covered is unguarded: the call-site half moved to the case above.
- **`WorkboardVoiceLaneTests`' three intent guards (cases 1, 2, 3) and their control (case 9)** —
  **CONVERTED, not deleted**, into `WorkVoiceIntentLaneRule` (12 rules) + one predicate, run by two
  cases: the live source, and twelve one-rule mutations plus a compliant fixture plus the
  reconstructed shipped shape. Every rule now has a fixture that fails on it, which is precisely what
  r3a#11 says the old controls did not have. The file-level "one compressor site in the whole intent"
  half became its own case (`testOnlyOneSiteInTheWholeIntentReachesTheCompressor`).
- **Two NEW source-scoped assertions, both narrow and both paired with behaviour:**
  `testBothRetrySurfacesStageTheRecoveredBytesUnderTheirOwnContainer` (behavioural over
  `PendingRetryAudioFile.extension(for:)`, plus a call-site check on the two staging functions) and
  `testTheUploadBuildsItsAudioPartFromThatAnswer` (behavioural over `STTClient.multipartAudioPart`
  lives in the case beside it; this one only checks that `transcribe` asks). Neither can be driven end
  to end: both surfaces are a SwiftUI view method and a menu-bar service, and `transcribe` needs a
  provider on the other end.
- **I added no test seam.** Nothing under `#if CONDUCK_TESTING` was touched, added or removed by this
  slice; `STTClient.multipartAudioPart(for:)` is ordinary production code that happens to be nameable,
  which is why the behavioural case can call it.
