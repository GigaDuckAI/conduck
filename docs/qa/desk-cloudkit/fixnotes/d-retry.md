# d-retry — §D made sound: `PendingRetryStore` is now a UUID-KEYED QUEUE. All four r4a findings CONFIRMED and fixed; nothing refuted.

Slug `d-retry`. Sim `6C3FB33E-D89F-4D1E-9F0D-3FAC0C089228`. No commits, pushes, stash, checkout, reset
or index operations. `Identity-Override.xcconfig` untouched. Nothing under `docs/qa/desk-cloudkit/`
touched. **No `.xcstrings` opened.** No `.pbxproj` edit. No mirror triplet touched. No file outside my
ownership edited.

Files changed — twelve, of which one is new:

| File | Change |
|---|---|
| `Conduck/Conduck/Services/PendingRetryStore.swift` | **rewritten as a queue**: `PendingRetryQueue` (pure rules), `PendingRetryEntry`, `recordPublicationState(id:transcript:publicationState:)`, expiry exemption; `PendingRetrySlot` + `currentSlot()` DELETED; protocol renamed `PendingRetrySlotWriting` → `PendingRetryQueueWriting` |
| `Conduck/Conduck/Services/InAppAudioRecorder.swift` | r4a#1 — the decline-to-arm rule DELETED from `preserveForRetry`; new `speechAuthorizationForTesting` seam (O-1) |
| `Conduck/Conduck/Services/Workboard/WorkVoiceCaptureCoordinator.swift` | r4a#3 — `recover` republishes `.phaseOneFailed` audio ABOVE the no-transcript guard |
| `Conduck/Conduck/Intents/ConverseIntent.swift` | r4a#3 + r4a#4 — both pre-transcript disarms gated on `workPublicationState != .phaseOneFailed`; `parkRecoveryState` → `recordRecoveryState` (metadata-only); `.published` now recorded too |
| `Conduck/Conduck/ContentView.swift` | `load()` is plural → `.first`; `finishWorkRetry(_ pending: PendingRetryEntry, …)` |
| `Conduck/Conduck/MenuBar/DictationService.swift` | same two |
| `Conduck/ConduckTests/PendingRetryQueueTests.swift` | **NEW**, 17 cases — the queue's own rules |
| `Conduck/ConduckTests/WorkVoiceRecoveryTests.swift` | queue-backed `RecordingRetryLane`; 2 eviction cases rewritten, 2 cases added (18 → 20) |
| `Conduck/ConduckTests/RemoteAgent/HeadlessRetryGuardSpanTests.swift` | re-anchored + STRENGTHENED (11 cases, ordering + disarm count unchanged) |
| `Conduck/ConduckTests/AudioExclusivityCrossSurfaceTests.swift` | `makeRecorder()` seam only (O-1) |
| `Conduck/ConduckTests/WorkboardVoiceLaneTests.swift` | two collision counterfactuals re-anchored onto the store's NEW refusal (foreign landing, §Requests 1) |
| `Conduck/ConduckTests/WorkboardAudioCaptureTests.swift` | one collision counterfactual, same reason |

`Services/VoicePermissions.swift`, `Views/Workboard/WorkboardVoiceCaptureView.swift` and
`ConduckTests/PendingRetryDestinationTests.swift` are mine and are **unchanged** — reasons under
§Decisions 5 and 6.

---

## The on-disk queue shape, VERBATIM

App Group container (`Constants.appGroupID`), unchanged filenames:

```
pending_retry_audio_<destination>_<id>.m4a   compressed bytes, `.completeFileProtection`
pending_retry_work_image_<id>.bin            optional Work screenshot bytes
pending_retry_audio_<id>.m4a                 transitional dev-build path, READ only
pending_retry_audio.m4a                      pre-id-scoped Chat path, READ only
pending_retry.lock                           the cross-process advisory flock
```

App-Group `UserDefaults`:

```
"pending_retry_queue"      JSON `[PendingRetryMetadata]`   ← the queue
"pending_retry_metadata"   JSON `PendingRetryMetadata`     ← the single slot an older release wrote
```

`PendingRetryMetadata` is byte-identical on the wire to what wave C shipped — nine fields, the last
three optional. **No field was added, removed or made required.** The queue is an ARRAY of exactly
that record under a NEW key.

**Migration, stated exactly.** Every locked read decodes `pending_retry_queue`, then decodes
`pending_retry_metadata` and folds that record in when the queue does not already name its id
(`PendingRetryQueue.decoding(queue:legacy:)`). The legacy key is removed **only after the queue
carrying it is committed**; a failed commit leaves the pointer alone and the next read folds it in
again. It is never deleted unread. A migration that runs twice adds nothing
(`testAMigrationThatRunsTwiceAddsNothing`). Rollback to a build that reads only the old key sees the
legacy pointer if the fold never committed, and otherwise sees nothing — the audio FILES are
untouched by the migration, so nothing is destroyed either way.

**Orphan adoption.** Every locked read also scans the container for
`pending_retry_audio_<destination>_<id>.m4a` files the queue does not name and adopts each as its own
entry (`createdAt` = the file's modification time, `attemptCount` 1, no verdict). This generalizes the
old `recoverNewestOrphan` from "the newest one, when the pointer is missing" to "all of them, always",
which is what makes a file sweep safe.

**File reclamation.** `save()` deletes NOTHING. Files leave with the entry that names them
(`clear(ifCurrentID:)`, the expiry sweep) or on an explicit discard (`clear()`), and
`cleanupExpired()` — launch only, after adoption and the expiry purge — reclaims any retry file no
queued entry names. The pre-existing `removeRetryFiles(except: metadata.id)` inside `save()`, which
was r4a#1's mechanism, is gone.

**Expiry.** `PendingRetryMetadata.transcriptionRetryTTL = 600` and
`isExpired(at:)` are unchanged for the records the TTL is about, and

```swift
var isExemptFromExpiry: Bool { resolvedDestination == .work && publicationState != .published }
```

is the new gate. Chat retries and `.published` Work captures expire after 600 s exactly as before;
`.phaseOneFailed` and nil-verdict Work captures never expire.

---

## Findings

### r4a#1 (major) — a new capture deleted an older recording whose slot held its only copy. CONFIRMED, fixed.

**Verified first, by call path, before any edit.** At `effc664` `save()` ended with
`removeRetryFiles(except: metadata.id)` inside the lock (`PendingRetryStore.swift:299`), which deletes
every `pending_retry_audio_*` / `pending_retry_work_image_*` file whose id is not the incoming one —
so any arming save destroyed every other capture's bytes. `PendingRetryGuard.arm` (`:80`) calls it
unconditionally with no eviction check. The recorder's only defence was
`preserveForRetry`'s `if publicationState == .published, … !incumbent.hasDurableRecording { return }`
(`InAppAudioRecorder.swift:963-968`), which fires **only** when the arriving capture is already
published — so a `.phaseOneFailed` capture, and every headless `PendingRetryGuard.arm`, overwrote the
incumbent. `WorkVoiceRecoveryTests.testACaptureWhoseRecordingIsSafeNeverEvictsTheOnlyCopyOfAnother`
pinned that policy verbatim. Both halves hold exactly as written.

**Fix — the queue, per the decided design.** `save()` is now
`persist(PendingRetryQueue.upserting(metadata, into: existing))` and deletes no file at all; the queue
is read BEFORE the payload lands so this capture's own file is never briefly an orphan the same read
would adopt. `clear(ifCurrentID:)` removes exactly one entry and exactly that entry's files. The
recorder's decline-to-arm rule and the `currentSlot()` read it needed are DELETED, and with them
`PendingRetrySlot` and `PendingRetrySlot.hasDurableRecording`, which existed for nothing else.

**Regression tests.**
- `PendingRetryQueueTests.testASecondCaptureIsAddedRatherThanReplacingTheFirst` and
  `…testRearmingOneCaptureRestatesItsEntryInPlace` — the upsert rule itself, keyed by id.
- `PendingRetryQueueTests.testClearingOneCaptureLeavesEveryOtherQueued` /
  `…testClearingACaptureThatIsNotQueuedRemovesNothing`.
- `WorkVoiceRecoveryTests.testASecondCaptureIsQueuedBesideTheFirstRatherThanReplacingIt` — the
  recorder end to end: a seeded Chat capture and a Work capture whose STT fails are BOTH queued
  afterwards, the Chat capture's bytes are the ones it was armed with, and `lane.saves` names only the
  arriving capture.
- `WorkVoiceRecoveryTests.testAPublicationTheDeskRefusedIsQueuedBesideWhateverElseIsWaiting` — the
  same from the other side, with the `.phaseOneFailed` verdict asserted.
- `WorkVoiceRecoveryTests.testTwoQueuedCapturesEachFinishOntoTheirOwnCard` — the brief's
  "both finish onto their own cards": two queued captures recovered one at a time leave two `.audio`
  cards carrying their own words, and clearing the first leaves the second untouched.

*How I know they bite.* Argument from the assertion, against code I can point at.
(a) The old `save` calls `removeRetryFiles(except:)`, and the old `RecordingRetryLane` holds
`current: (metadata, audio)?` — a SINGLE optional — so `Set(queued.map(\.id)) == [chatID, workID]`
cannot be true there: the type has no room for two entries, and the production store deletes the
second one's file. (b) `testTwoQueuedCapturesEachFinishOntoTheirOwnCard` calls
`lane.save` twice and then asserts both ids are still queued; on the old double the second save
overwrites the first. (c) The two rewritten recorder cases previously asserted the OPPOSITE outcome
(`armed?.id == chat.metadata.id` and `saves.isEmpty`), which is the policy this round deletes — the
new bodies fail on the old recorder because it returns from `preserveForRetry` without writing.

### r4a#2 (major) — a `.phaseOneFailed` recording was deleted after ten minutes. CONFIRMED, fixed.

**Verified:** `isExpired` was `Date().timeIntervalSince(createdAt) > 600` with no destination or
verdict test (`:125-127`), and `load()`/`hasPending()`/`pendingErrorCode()`/`diagnosticSnapshot()`/
`cleanupExpired()` each called `clearLocked`, which deletes the audio (`:571-585`). For
`.phaseOneFailed` those bytes are the only recording, so `spec.md`'s never-lost claim was false after
ten minutes.

**Fix.** `isExemptFromExpiry` (above), consulted by `isExpired(at:)`, so the exemption is one
expression that every reader inherits — there is no second place to forget it. The TTL keeps its exact
meaning for the records it was written for.

**Regression tests.** `PendingRetryQueueTests.testAPublicationTheDeskRefusedNeverExpires` (601 s and
30 days), `…testAWorkCaptureWithNoVerdictIsTreatedAsIrreplaceable`,
`…testChatAndPublishedWorkCapturesStillExpireOnTheTenMinuteBudget` (599 s / 601 s on both, and the
600 s constant), `…testTheExpirySweepReachesOnlyTheCapturesTheClockGoverns`.
*How I know they bite:* the old `isExpired` is a pure function of `createdAt`, so
`XCTAssertFalse(capture.isExpired(at: armed + 601))` is false by construction there for every
destination; and `isExemptFromExpiry` does not exist on the old type, so the case cannot compile.

### r4a#3 (major) — a terminal STT verdict disarmed a `.phaseOneFailed` capture, and `recover` could not secure the audio without words. CONFIRMED in both halves, fixed in both.

**Verified:** `ConverseIntent.swift:412` disarmed unconditionally in the `.notConfigured` arm, and
`:677`'s `if !transcriptCaptured { … disarm }` covered every pre-transcript `AppError` — neither read
`workPublicationState`, which is in scope at both (declared `:342`). `PendingRetryGuard.disarm` →
`PendingRetryStore.clear(ifCurrentID:)` → `clearLocked` deletes the audio. And
`WorkVoiceCaptureCoordinator.recover` returned `.retryKept(.noTranscript)` at `:227`, four lines
ABOVE its republication block (`:235`), so a capture with no words could never get its recording back.

**Fix, three parts.**
1. `recover` republishes first: the `.phaseOneFailed` block now runs immediately after the
   `notAWorkCapture` guard, and the `guard !words.isEmpty` moved below it. A wordless recovery of a
   refused publication now leaves a playable card on the desk and answers `.retryKept(.noTranscript)`
   — non-terminal, so the entry stays armed for the words it is still owed. **C6's signature and its
   four outcomes are unchanged** (see §Deviations 1 for the one contract line that did change, and it
   is not `recover`'s).
2. `.notConfigured` disarms only `if workPublicationState != .phaseOneFailed`.
3. The known-`AppError` catch gate is `if !transcriptCaptured, workPublicationState != .phaseOneFailed`.

**Regression tests.**
- `WorkVoiceRecoveryTests.testAPublicationTheDeskRefusedIsPutBackEvenWhenNoWordsExistYet` — the
  behavioural half: `.phaseOneFailed` + an empty transcript leaves an `.audio` card at the capture id
  carrying the parked bytes, with `textContent` still nil, and a non-terminal outcome.
- `HeadlessRetryGuardSpanTests.testPerformDisarmsOnProvableAbsenceAndOtherwiseOnlyBeforeTheWordsExist`
  — two NEW assertions: the catch gate is literally
  `if !transcriptCaptured, workPublicationState != .phaseOneFailed`, and
  `armGuardsOnTheFailedPublication(arm: "case .notConfigured:", …)` is true. Both on comment-stripped
  source (`RefusalLaneSource.source(at:)` strips).
- `HeadlessRetryGuardSpanTests.testTheAbsenceDisarmCheckDistinguishesTheMissingAndOvershotShapes` —
  Rule 0 for the new matcher: an ungated arm reads false, a gated one true, a missing arm false.

*How I know they bite:* (a) on the old `recover` the no-words guard precedes the republication, so
`desk.materials.first` is nil and the `XCTUnwrap` fails — the case cannot pass there; (b) the two
literals the source guard requires do not exist at `effc664` (`if !transcriptCaptured {` and a bare
`await PendingRetryGuard.disarm(guardToken)` in the absence arm), so both assertions fail on the old
text; the control proves the matcher itself distinguishes the two shapes.

### r4a#4 (major, O-7) — `parkRecoveryState` was check-then-save across two awaited actor calls. CONFIRMED, fixed.

**Verified:** `ConverseIntent.swift:762-767` — `guard await PendingRetryStore.shared.currentSlot()?.id
== metadata.id` and then `try? await PendingRetryStore.shared.save(audioData:…)`, two separate actor
hops. A capture armed in between owned the slot at the save, and `save` removed its files at `:299`.

**Fix.** `PendingRetryStore.recordPublicationState(id:transcript:publicationState:)` — the id lookup
(`PendingRetryQueue.updating(id:in:_:)`) and the metadata write happen inside ONE `withExclusiveLock`,
which is also the cross-process boundary. It carries no payload argument at all, so it cannot rewrite
audio, and it maps the queue leaving every other entry identical, so it cannot reach another capture.
A capture that is no longer queued answers `false` and nothing is created.
`ConverseIntent.recordRecoveryState` is the one caller shape, at all three sites.

**Regression tests.** `PendingRetryQueueTests.testRecordingOneCapturesVerdictLeavesEveryOtherEntryIdentical`
(the bystander armed "in between" keeps its verdict, its `createdAt` and its `attemptCount`),
`…testRecordingAVerdictForACaptureThatIsGoneCreatesNothing`,
`…testANilFieldKeepsWhatTheRecordAlreadyCarries`.
*How I know they bite:* `PendingRetryQueue.updating` does not exist at `effc664`, and the operation it
replaces takes `audio:` and `workImageData:` — a test asserting "no other entry changed" cannot even
be spelled against a whole-slot `save`, because the old store has no other entry.

---

## Decisions

1. **`load()` returns EVERY entry, newest first, and the surfaces take `.first`.** The brief's
   "ordered by createdAt" plus "newest first is fine" collapse to one order, stated once, so no caller
   has to remember which end is which. Both retry surfaces finish one capture per tap and re-read
   `hasPending()` afterwards, which they already did — so a second queued capture simply keeps the
   card up. The cost, stated: `load()` materialises every queued capture's bytes, bounded by
   `Constants.maxAudioSize` (15 MB) per entry and a queue that is realistically one or two deep.
2. **`ConverseIntent` now records `.published` as well as `.phaseOneFailed`** — c-lanes §Decisions 2
   deliberately did not, and c-lanes §Requests 5 says not to. **Its reason is gone, and the reason it
   gave is the one that changed**: "persisting `.published` re-commits a slot a newer capture may own"
   was true of a whole-slot `save` on a single slot. `recordPublicationState` is metadata-only, keyed
   by id, and cannot reach another entry — which is exactly what c-lanes §Requests 4 asked for. And it
   is now load-bearing rather than free: with expiry exempting every non-`.published` Work record, a
   headless capture that DID publish would otherwise keep a nil verdict and its audio would never be
   reclaimed. c-lanes §Decisions 3's asymmetry survives where it matters: a stale `.published` is
   still the dangerous value, and this one is written in the same process, immediately after a
   `publishRecording` that returned a record.
3. **`PendingRetrySlot`, `currentSlot()` and `hasDurableRecording` are DELETED rather than left
   unused.** They existed for one caller — the eviction check the queue makes meaningless — and a
   metadata view named "the current slot" is a false description of a queue. The protocol
   `PendingRetrySlotWriting` is renamed `PendingRetryQueueWriting` for the same reason; both its
   conformers are files I own.
4. **The queue's rules are a pure value (`PendingRetryQueue`), not actor internals.** Everything that
   destroys a recording lives in those rules, and none of it is reachable by a test that must first go
   through the App-Group container and a process-global `UserDefaults` domain — which is also the one
   slot every other capture test in this bundle shares. 17 deterministic cases against the rules; the
   actor is a thin I/O shell over them. §What I did NOT verify records the half that leaves.
5. **`WorkboardVoiceCaptureView` unchanged, deliberately** — c-recovery-core §Decisions 5's reasoning
   is untouched by the queue: widening the Try Again gate would put a retry on `.noSpeechDetected`,
   where it cannot work. `ErrorSurfaceDriftGuardTests` 7/0.
6. **The TCC seam went on `InAppAudioRecorder`, not on `VoicePermissions`.** The brief allowed either.
   The recorder's `startRecording()` is the only production path these five cases run, the file
   already carries the seam block and its header, and a static override on `VoicePermissions` would be
   reachable from `DictationService`, the Setup Guide and onboarding — three lanes no test here
   drives. One value, one consult site, nil in every other build.
7. **No new rule in `WorkboardVoiceLaneTests` for the disarm gate.** `HeadlessRetryGuardSpanTests`
   already owns "where a disarm may sit in `perform()`", and r3a#11's whole lesson was that one rule
   spelled in two files is how the two drift. The gate is asserted once, with a control.
8. **No Codex consult.** The one genuinely hard call — whether to persist `.published` against
   c-lanes' explicit "nobody undo this" — is a trade whose premise I could check directly in the code
   (§Decisions 2), not a technical unknown.

## Deviations

1. **`PendingRetryRecord.init(_ loaded: (audioData:metadata:workImageData:))` is replaced by
   `init(_ entry: PendingRetryEntry)`** — c-recovery-core stated the tuple form verbatim in its C6
   contract, so it is recorded here verbatim as changed. `PendingRetryEntry` keeps the tuple's field
   NAMES and order (`audioData`, `metadata`, `workImageData`), so every call site reads identically
   and `WorkboardVoiceLaneTests`' `pending.audioData` guard is untouched. `recover`'s own signature and
   its four outcomes are unchanged.
2. **`load()` changed shape** — `(audioData:metadata:workImageData:)?` → `[PendingRetryEntry]`. Forced
   by the queue; the alternative (a `loadNext()` beside it) is two APIs for one question.
3. **Three collision counterfactuals in my test files were re-anchored onto a FOREIGN change that
   landed mid-wave** — see §Requests 1. Not a weakening: each now measures the store REFUSING the
   collision and asserts the recording is untouched, where before it measured the damage.
4. **`import Speech` added to two test files.** The seam's type is
   `SFSpeechRecognizerAuthorizationStatus`; implicit-member lookup on a type from a module the test
   file does not import is not something I wanted to rely on.

---

## Gates — what I actually ran

DerivedData under `~/Library/Caches/gigaduck-builds/d-retry/{DerivedData,DerivedDataMac}`, every log
written there and grepped for `': error: '` and the verdict strings — never judged from a tail or an
exit code. **No `-configuration` passed anywhere.** No `/tmp`, no bare `rm -rf`, no throwaway tree
copy.

- **iOS `build-for-testing`** → `ios-bft-5.log` (final): `grep -c ': error: '` = **0**, and:
  ```
  ** TEST BUILD SUCCEEDED **
  ```
- **iOS `test-without-building`**, fourteen quoted `-only-testing:` flags → `test-2.log`:
  ```
  ** TEST EXECUTE SUCCEEDED **
	 Executed 147 tests, with 0 failures (0 unexpected) in 6.922 (6.955) seconds
  ```
  `grep -cE '\.swift:[0-9]+: error: '` = **0**.

| Class | Result line |
|---|---|
| `WorkVoiceRecoveryTests` | `Executed 20 tests, with 0 failures (0 unexpected) in 0.550 (0.554) seconds` (was 18) |
| `PendingRetryQueueTests` (**new**) | `Executed 17 tests, with 0 failures (0 unexpected) in 0.008 (0.013) seconds` |
| `PendingRetryDestinationTests` | `Executed 6 tests, with 0 failures (0 unexpected) in 0.005 (0.006) seconds` |
| `WorkboardAudioCaptureTests` | `Executed 19 tests, with 0 failures (0 unexpected) in 0.127 (0.131) seconds` |
| `WorkboardVoiceLaneTests` | `Executed 11 tests, with 0 failures (0 unexpected) in 0.078 (0.079) seconds` |
| `HeadlessRetryGuardSpanTests` | `Executed 11 tests, with 0 failures (0 unexpected) in 0.039 (0.041) seconds` |
| `STTKeyBlackoutLaneTests` | `Executed 11 tests, with 0 failures (0 unexpected) in 1.651 (1.653) seconds` |
| `AudioExclusivityCrossSurfaceTests` | `Executed 7 tests, with 0 failures (0 unexpected) in 0.105 (0.107) seconds` |
| `RemoteAgentRecoveryCopyLaneTests` | `Executed 12 tests, with 0 failures (0 unexpected) in 0.008 (0.011) seconds` |
| `ErrorSurfaceDriftGuardTests` | `Executed 7 tests, with 0 failures (0 unexpected) in 2.858 (2.860) seconds` |
| `TempScratchSweeperTests` | `Executed 11 tests, with 0 failures (0 unexpected) in 0.377 (0.379) seconds` |
| `HeadlessRefusalLaneDriftGuardTests` | `Executed 5 tests, with 0 failures (0 unexpected) in 1.102 (1.103) seconds` |
| `DiagnosticsFocusTests` | `Executed 4 tests, with 0 failures (0 unexpected) in 0.010 (0.011) seconds` |
| `VoicePermissionsTests` | `Executed 6 tests, with 0 failures (0 unexpected) in 0.003 (0.004) seconds` |

  Beyond the classes the brief names I ran the two refusal-lane guards over `ConverseIntent`, the
  error-surface registry over the voice sheet, the temp-file sweeper (it enumerates `conduck_retry_*`)
  and the speech-permission matrix the new seam stands beside.

- **Re-run at end of task, after the other agents had gone on editing the tree** → `ios-bft-6.log`
  (`0` errors, `** TEST BUILD SUCCEEDED **`) and `test-3.log`
  (`** TEST EXECUTE SUCCEEDED **`, `Executed 147 tests, with 0 failures (0 unexpected) in 6.932
  (6.969) seconds`, `grep -cE '\.swift:[0-9]+: error: '` = **0**). Identical result, no code change
  between the two runs.
- **macOS `build -destination 'platform=macOS'`** → `mac-1.log`: `grep -c ': error: '` = **0**, and:
  ```
  ** BUILD SUCCEEDED **
      Signing Identity:     "Apple Development: Peter Krueck (Z4PNDLZK98)"
  ```
  **Signed through the identity override; no `CODE_SIGNING_ALLOWED=NO` fallback needed or used.**
  `DictationService` and `ContentView` compile there.
- **`bash scripts/check-storage-seam.sh`** → `✓ storage seam intact — 798 Swift files scanned…`, exit 0.
- **`git diff --check`** → no output, exit 0. `git diff --cached --stat` → **empty**.
  `git status --short` for `*.xcstrings`, `*.pbxproj`, `Conduck/Configs`, `docs/qa` and all three
  mirror triplets → **empty**. `git status --short` over my files lists exactly the eleven modified
  plus `?? Conduck/ConduckTests/PendingRetryQueueTests.swift`, and nothing else.
- **Warnings: I ADDED none and removed 2.** `PendingRetryStore.swift` carries **10**, all the
  pre-existing main-actor `DefaultsStore` class (`set`/`data`/`removeObject`/`synchronize`), now
  concentrated in `persist`, `queueLocked` and `clear()`; c-recovery-core measured **12** of the same
  kind before this slice, spread across six methods. **Zero** in `InAppAudioRecorder.swift`,
  `WorkVoiceCaptureCoordinator.swift`, `ContentView.swift` and all six test files, on both platforms.
  `ConverseIntent.swift` has the same four pre-existing ones c-lanes recorded (`maxAudioSize`,
  `displayName(for:customs:)`, `RemoteAgentDiagnostics.log`, `play(mode:)`); `DictationService.swift`
  the same two (`startDisplayTimer`).
- **Simulator TCC checked before trusting any audio run**, per the brief:
  `sqlite3 …/6C3FB33E…/data/Library/TCC/TCC.db "select service, client, auth_value from access where
  client='ai.gigaduck.AgentRelay';"` → **no rows** (exit 0), i.e. `.notDetermined`. So the five cases
  the seam protects were already green here; the seam is what makes them green on a machine where
  they are not.
- **The build failed three times before green, and twice it was NOT my code.** `ios-bft-1.log`: one
  error, mine (`'async' call in an autoclosure` at `InAppAudioRecorder.swift:348`) — fixed by binding
  the status before the `??`. `ios-bft-2.log`: three errors, two mine (`WorkVoiceRecoveryTests.swift:606`,
  the same autoclosure shape) and one foreign (`WorkboardDeskUpsertTests.swift:800`). `ios-bft-3.log`:
  **1 error, foreign only** (`WorkboardDeskUpsertTests.swift:800`, an agent mid-edit) and **0 in my
  files** — waited 125 s and retried per the parallel rule; `ios-bft-retry-1.log` green on the first
  retry. `ios-bft-4.log`: one error, mine (`fetchWorkMaterial` is `private`) — the re-anchored
  counterfactuals now read the card through `fetchWorkItem`.
- **NOT run, plainly: the full iOS suite and the watch suite.** Neither is in my brief, no watch sim
  is assigned, and two other agents are editing this tree — a full run now would report their
  in-flight state as mine. **Suite delta from this slice: +19** (`PendingRetryQueueTests` NEW 17,
  `WorkVoiceRecoveryTests` 18 → 20; every other class unchanged in count). **The watch target compiles
  none of my production files** — `PendingRetryStore.swift`, `InAppAudioRecorder.swift`,
  `WorkVoiceCaptureCoordinator.swift`, `ConverseIntent.swift`, `ContentView.swift` and
  `MenuBar/DictationService.swift` are all absent from the `ConduckWatch Watch App`
  `membershipExceptions` list (checked, not assumed).
- Build cache removed at end of task with `.claude/scripts/clean-build-cache.sh d-retry`, so the logs
  no longer exist; re-run to reproduce.

---

## Catalog

**Keys I ADDED in source: NONE.**

**Keys I made DEAD: NONE.** No string-bearing branch was deleted or moved. The two retry surfaces'
Work failure arms keep `workboard.capture.retry.voice.message`; `workboard.voice.error.deskWrite`
stays on `AppError.workDeskWriteFailed`; `workboard.voice.recording.untitled` stays on
`WorkVoiceCaptureCoordinator.untranscribedTitle`, and the republication-before-the-words path now
reaches it MORE often (a wordless recovered card is titled with it), which is a use, not a change.

**No `.xcstrings` file was opened.** Nothing for the serial copy agent to splice from this slice.

---

## Requests

1. **Owner of `Services/ConversationStore+Workboard.swift` (the store agent) — your id-collision
   refusal landed mid-run and turned three of my counterfactuals red; I re-anchored them and the fix
   is in my tree, but you should know which cases now depend on your `invalidMaterialOwner`.**
   VERIFIED: `upsertDeskMaterial` now throws `WorkboardStoreError.invalidMaterialOwner` when the
   existing card at a draft's id is of another KIND (`ConversationStore+Workboard.swift:594`, plus
   `requireMatchingKind` at `:1512`). The three cases that deliberately publish a colliding draft —
   `WorkboardAudioCaptureTests.testTheFallbackNoteIdIsDerivedFromTheCaptureAndCannotCollideWithIt`,
   `WorkboardVoiceLaneTests.testAScreenshotPublishedAtTheCaptureIdIsRefusedRatherThanBecomingTheRecording`
   (renamed from `…WouldReplaceTheRecordingsBytes`) and
   `WorkboardVoiceLaneTests.testTheFallbackNoteLandsBesideTheRecordingRatherThanVanishingIntoIt` — now
   assert the refusal and that the recording's bytes and kind are untouched. **Your change is strictly
   better and I did not weaken anything to accommodate it**; the derived-id argument is unchanged, and
   each case says so in its message ("a capture cannot rely on a store's refusal to publish its own
   artifacts correctly").
2. **One consequence of that refusal, for whoever adjudicates it.** `recover`'s republication of a
   `.phaseOneFailed` capture calls `publishRecording` under the capture id. If that id ever names a
   card of another kind, the republication now THROWS instead of overwriting it — correct, and better
   than the old repair-the-payload behaviour — but the entry then stays queued and every retry fails
   the same way, with no path forward. Reachable only through a genuine UUID collision or a merge that
   produced a foreign-kind row at a capture id, and `.notAudio` already covered the attach half. I did
   not design for it; recording it so nobody discovers it as a surprise.
3. **Owner of `Views/PendingRetryCard` / Settings — an exempt entry has no user-facing discard.**
   The design says a `.phaseOneFailed` capture leaves "when publication succeeds or the user
   explicitly discards it". `PendingRetryStore.clear()` (discard everything) exists and has **zero**
   production callers; the retry card offers Retry and Troubleshoot and no dismiss. Today that is
   sound — the capture is genuinely irreplaceable and the retry eventually succeeds — but it means an
   un-finishable Work capture keeps its bytes in the App Group indefinitely. A "Discard recording"
   affordance on the card, or in Settings, would close it in one call.
4. **Owner of `ViewModels/DiagnosticsRunner.swift` — the parked-retry row now describes the NEWEST of
   possibly several.** `diagnosticSnapshot()` keeps its exact signature and its meaning for one
   capture; it simply cannot say "and two more are waiting". If the Voice section should report a
   count, the store can answer it in one line — I did not widen the signature, because the file is not
   mine.
5. **Nobody undo these** — they interlock, and each is pinned by a test that measures the cost:
   - `save()` deletes NO file and removes NO entry. Reintroducing a sweep there is r4a#1 exactly.
   - `isExemptFromExpiry` stays the single expression every reader inherits. A second expiry test
     anywhere is a second place to forget the exemption.
   - A verdict is written through `recordPublicationState`, never by re-saving the record. The check
     and the write must stay inside one `withExclusiveLock`; splitting them is r4a#4.
   - `recover` republishes BEFORE it looks at the transcript. Reversing that order is r4a#3's second
     half, and it strands a recording behind a transcription that may never arrive.
   - Both pre-transcript disarms in `perform()` stay gated on `workPublicationState != .phaseOneFailed`.
   - The legacy `pending_retry_metadata` key is READ on every load and removed only after the queue
     carrying it commits. Deleting it eagerly strands the one recording a mid-capture upgrade parked.
   - `nil` publication state keeps meaning UNKNOWN, and UNKNOWN keeps meaning "may be the only copy" —
     for expiry as well as for `recover`.

---

## Refuted

**None.** All four findings were traced against the current tree by call path before any code changed,
and all four hold exactly as written, at the exact anchors quoted in §Findings. The decided design
directions were implementable as specified; the only contract line that had to move is
`PendingRetryRecord`'s tuple initializer (§Deviations 1), which the queue forces because `load()` no
longer returns a tuple, and it is recorded verbatim.

One qualification, stated as such rather than as a refusal: r4a#3's brief says "a terminal STT verdict
… never deletes the recording". I implemented that as *the entry is not disarmed*, not as *the
recording is published on the spot*. Publishing it there would need a second
`WorkVoiceCaptureCoordinator.recover(` call inside `perform()`, which `HeadlessRetryGuardSpanTests`
orders against the first and `WorkboardVoiceLaneTests`' `.releasedOnlyOnATerminalOutcome` reads
positionally — both would need re-anchoring for a card the next retry publishes anyway, now that
`recover` secures the audio before it looks at the words. The recording is never lost either way.

---

## Guard verdicts

- **`HeadlessRetryGuardSpanTests.testPerformDisarmsOnProvableAbsenceAndOtherwiseOnlyBeforeTheWordsExist`**
  — **KEPT, RE-ANCHORED and EXTENDED.** The needle for the catch gate moves from
  `"if !transcriptCaptured {"` to `"if !transcriptCaptured"` (the brace moved because the gate gained
  a second clause), and TWO assertions were added: the literal
  `if !transcriptCaptured, workPublicationState != .phaseOneFailed`, and the absence arm's own gate.
  **The disarm COUNT is unchanged at exactly 3 and every ordering assertion is byte-identical** —
  `firstDisarm < gateAt`, `transcriptRaised < workPublish`, `workPublish < workDisarm`,
  `workDisarm < gateAt`, `gateAt < catchDisarm`. Nothing was weakened, removed or re-aimed. 11/0.
- **`HeadlessRetryGuardSpanTests.testTheAbsenceDisarmCheckDistinguishesTheMissingAndOvershotShapes`**
  — **KEPT, EXTENDED by a Rule-0 control for the new matcher** (ungated / gated / missing-arm), so the
  added assertion is not one nobody has seen bite. The four existing controls are untouched.
- **`WorkboardVoiceLaneTests`' twelve-rule validator** — **KEPT, unchanged.** All twelve rules still
  pass against the rewritten `perform()`: `.onePayloadForEveryUse` still counts three `audio:` uses,
  all `uploadData` (the two `parkRecoveryState` calls that carried a fourth and fifth are gone, and
  `recordRecoveryState` carries no payload); `.aRefusedPublicationIsRecorded` still finds
  `.phaseOneFailed`; `.theRecoveryCarriesTheCapturesRecord` still reads `pendingMetadata` +
  `audio: uploadData`; `.releasedOnlyOnATerminalOutcome` still finds `isTerminal` between the recovery
  and the disarm below it. I added no rule — the disarm gate is asserted once, in the file that owns
  disarm placement (§Decisions 7).
- **`WorkboardAudioCaptureTests.testEveryRetrySurfaceMakesItsDeskDecisionThroughTheOneRecovery`** —
  **KEPT, unchanged and untouched.** Both surfaces still reach `recover(` exactly once and carry no
  `WorkCaptureRetryCoordinator.publish(` or `attachTranscript(` of their own; my edits to
  `finishWorkRetry` are its parameter type only.
- **`WorkboardVoiceLaneTests.testBothRetrySurfacesStageTheRecoveredBytesUnderTheirOwnContainer`** —
  **KEPT, unchanged**, and deliberately protected: `PendingRetryEntry`'s field is named `audioData`
  (not `audio`) precisely so `pending.audioData` at both staging sites still reads as the guard
  requires.
- **Three collision counterfactuals CONVERTED, none deleted** (§Requests 1). Each still measures a
  real outcome; the outcome the store produces changed under them mid-wave.
- **Test seams: ONE added, none removed.** `InAppAudioRecorder.speechAuthorizationForTesting:
  SFSpeechRecognizerAuthorizationStatus?`, inside the existing `#if CONDUCK_TESTING` block under a
  header saying why it must exist. It is consulted at exactly one point — the `#if !os(watchOS)`
  speech preflight in `startRecording()` — is nil in every other build, and the whole block compiles
  only under `CONDUCK_TESTING`. Set by `WorkVoiceRecoveryTests.workRecorder` and
  `AudioExclusivityCrossSurfaceTests.makeRecorder`, which is the entire O-1 remedy: five cases that
  hard-FAILED on a machine whose Speech-Recognition TCC row is `denied` now assert what they are named
  for. **No skip was added** — the alternative remedy O-1 lists would have removed the assertions
  silently on exactly the machines where they matter.
- **The macOS `SpeechExclusivity` regions in `InAppAudioRecorder` are byte-for-byte untouched**:
  `git diff -U2` over that file matches no line containing `SpeechExclusivity`, `acquireMicLease`,
  `recordingAuthority` or `claim(`.

## What I did NOT verify, plainly

- **The actor's file I/O and its cross-process lock are not driven by a unit test.** `save`, `load`,
  `clear`, `cleanupExpired` and `recordPublicationState` are thin shells over `PendingRetryQueue`,
  which is exhaustively covered; what is untested is the App-Group write path itself, the orphan scan
  against a real directory, and two PROCESSES contending on `pending_retry.lock`. Same limit
  c-recovery-core recorded for the same reason (the store is a process-global singleton over one file
  the whole bundle shares). It is a Founder-QA item below.
- **No migration was run against a real device's App Group.** The fold is proven as a pure function
  over the two encoded blobs; the key swap itself is not.
- **No UI.** There is no UI-test target, by decision; the retry card's behaviour with two queued
  captures is a founder-QA item.
- **I did not re-run any other agent's counterfactual**, and I did not run the full iOS or watch
  suites (reasons in §Gates).

---

## Founder QA — device-only checks this change needs

1. **Two recordings waiting at once, which is the whole point.** In airplane mode: make a Work voice
   note from the app (it fails at STT), then immediately run the bundled Shortcut / Action Button with
   Destination = Chat and let that fail too. Come back online and tap Retry twice. BOTH must complete:
   the Work note's words land on its own playable card, and the Chat capture reaches its conversation.
   Before this round the second capture deleted the first one's recording.
2. **A recording the desk refused outlives ten minutes.** Fill the device (or otherwise make the desk
   write fail) and make a Work voice note; leave the app for **over ten minutes**, then reopen it. The
   retry card must still be there and finishing it must produce ONE playable card carrying the words —
   not a note, and not nothing.
3. **A key that is gone does not take the recording.** With the desk write failing as in (2) and NO
   STT key configured, run the Shortcut with Destination = Work. It refuses ("No STT API key set"),
   and the retry card must SURVIVE that refusal. Add a key, tap Retry: one playable card with words.
4. **First unlock.** Reboot the iPhone, do not unlock it, fire the Action Button with Destination =
   Work. The desk write fails before first unlock; the retry card must appear and later finish onto a
   single card. Repeat once WITH the device unlocked so the card lands, and confirm that retry
   completes and the card is not duplicated.
5. **Force-quit mid-queue.** Arm two captures as in (1), force-quit the app before retrying either,
   reopen. Both must still be offered, one after the other.
6. **Nothing accumulates.** After (1)–(5) are all finished, Settings → Diagnostics must report no
   parked recording, and a later launch must not resurrect one.
7. **Two processes, one queue** (the untested half): while a Shortcut capture is in flight, start an
   in-app capture that also fails. Neither recording may disappear.

---

## Settled facts — one sentence each, for whoever writes the docs

- Conduck keeps every unfinished voice capture in a queue keyed by the capture's own id, so a second
  capture arming while a first is still waiting never displaces it.
- Finishing or discarding one capture removes exactly that capture's recording and leaves every other
  one waiting.
- The ten-minute limit on a parked capture is a limit on retrying a TRANSCRIPTION, and it applies only
  where the recording itself is safe — a Chat capture, or a Work capture whose card is already on the
  desk.
- A Work recording the desk never accepted is kept until it reaches the desk or the person discards
  it, however long that takes.
- A recovered Work capture gets its recording back onto the desk BEFORE its words are considered, so a
  transcription that never succeeds cannot keep the recording off the desk.
- A verdict about the speech-to-text key, or about the audio itself, ends a capture's transcription
  and never deletes its recording.
- A capture whose queue entry a build wrote before the queue existed is read and folded in on first
  launch, never discarded.
