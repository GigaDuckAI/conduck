# e-queue — the queue gains a DURABLE per-entry shape and a CLAIM API. All four findings CONFIRMED and fixed; nothing refuted.

Slug `e-queue`. Sim `6C3FB33E-D89F-4D1E-9F0D-3FAC0C089228`. No commits, pushes, stash, checkout, reset
or index operations. `Identity-Override.xcconfig` untouched. Nothing under `docs/qa/desk-cloudkit/`
touched. **No `.xcstrings` opened.** No `.pbxproj` edit. No mirror triplet touched. No file outside my
ownership edited (`git status --short` over the tree lists my three plus four that belong to
e-drainer, and nothing else).

Files changed — three, of which one is new:

| File | Change |
|---|---|
| `Conduck/Conduck/Services/PendingRetryStore.swift` | the durable shape (sidecar + tombstone + shape marker), the reconciliation, the claim API, `PendingRetryFiles`, `PendingRetryDefaultsKeys`, `PendingRetryLease`, `PendingRetrySidecar`, `PendingRetryClaim`, `PendingRetrySurface`; two `#if CONDUCK_TESTING` seams |
| `Conduck/ConduckTests/PendingRetryDurabilityTests.swift` | **NEW**, 21 cases — the write orders, the reconciliation, the reservation |
| `Conduck/ConduckTests/PendingRetryDestinationTests.swift` | 6 → 11 cases (the sidecar's wire shape, the lease horizon, the filename round trip, and the fixed name matching nothing) |

`Conduck/ConduckTests/PendingRetryQueueTests.swift` is mine and is **unchanged** — its 17 cases all
still pass, because `PendingRetryQueue`'s pure rules (`ordered`/`upserting`/`removing`/
`partitioningExpired`/`updating`/`decoding`) are untouched and all six are still called by the actor.

---

## The on-disk shape, VERBATIM

App Group container (`Constants.appGroupID`), or the injected directory under `CONDUCK_TESTING`:

```
pending_retry_entry_<id>.json        SIDECAR — the whole PendingRetryMetadata + the lease over it
pending_retry_audio_<dest>_<id>.m4a  the recording, `.completeFileProtection`
pending_retry_work_image_<id>.bin    optional Work screenshot bytes
pending_retry_tomb_<id>.tombstone    "this capture is being deleted"
pending_retry_audio_<id>.m4a         transitional dev-build path, READ + reclaimed, never written
pending_retry_audio.m4a              pre-id-scoped Chat path — copied under an id ONCE, then retired;
                                     read by nothing and deleted only by the explicit discard
pending_retry.lock                   the cross-process advisory flock
```

App-Group `UserDefaults` (`PendingRetryDefaultsKeys`):

```
"pending_retry_queue"      JSON [PendingRetryMetadata]  ← the INDEX
"pending_retry_metadata"   JSON PendingRetryMetadata    ← the single slot an older release wrote
"pending_retry_shape"      Int                          ← which layout wrote this container (2 = this one)
```

`PendingRetryMetadata` is **byte-identical on the wire** to what wave D shipped — nine fields, the last
three optional. No field was added, removed or made required. `PendingRetrySidecar` is a NEW persisted
shape: `{ metadata, lease? }`, the lease optional so a record written without one decodes as "nobody
holds this".

**Write order — ARM** (`save`), each step under the cross-process lock:
1. reconcile (this read finishes any interrupted clear and adopts any interrupted arm)
2. remove any tombstone over this id (a re-arm is a legitimate answer to a half-finished clear)
3. **sidecar** (atomic, `.completeFileProtectionUntilFirstUserAuthentication`) — carrying any live lease forward
4. **audio** (atomic, `.completeFileProtection`), then the optional Work screenshot
5. **index row** LAST

**Write order — CLEAR** (`finishLocked`, used by `clear(_ claim:)`, `clear(ifCurrentID:)`, the expiry
sweep and the "its recording is gone" path):
1. **tombstone** — REQUIRED. A capture that cannot be tombstoned stays queued rather than being
   deleted unsafely, because without the tombstone the residue is indistinguishable from an arm.
2. **index row** removed
3. sidecar + audio (both id-scoped layouts) + work image
4. **tombstone** last

**Adoption table** — every locked queue read, in this order:

| State on disk | Verdict |
|---|---|
| tombstone present | finish the deletion: drop the index row if any, delete every payload, delete the tombstone. **Never adopted.** |
| legacy pointer naming an unqueued capture | COPY the fixed-name recording under the capture's own id, write its sidecar, fold the entry in; retire the pointer and then the fixed-name file only after the queue commits. If the copy fails, the entry is dropped back out and the pointer is LEFT, so the next read tries again. |
| fixed-name recording + a Chat entry with no bytes of its own (first reconcile only) | copy it under that entry's id (oldest such entry wins), retire the original after the commit |
| sidecar + audio, no index row, no tombstone | **adopt with FULL metadata** from the sidecar (unreadable sidecar → salvage id/destination/mtime rather than delete the recording) |
| sidecar, no audio, no index row | delete the sidecar — an arm whose bytes never landed |
| audio, no sidecar, no index row, shape marker present | **delete** — residue a clear did not finish |
| audio, no sidecar, no index row, shape marker ABSENT | **adopt once** — the previous layout committed the index last and wrote no sidecar, so this is an arm it could not describe (see §Deviations 1) |
| index row with no sidecar | write the sidecar from the index row (upgrade, and repair) |

**Expiry** is unchanged: `isExemptFromExpiry` and `transcriptionRetryTTL = 600` are byte-identical,
and an expired capture is finished through the same CLEAR order.

---

## The claim API as implemented

```swift
typealias PendingRetrySurface = PendingRetryDestination           // §Decisions 1

nonisolated struct PendingRetryLease: Codable, Sendable {
    let token: UUID
    let expiresAt: Date
    func isLive(at now: Date) -> Bool
}

nonisolated struct PendingRetrySidecar: Codable, Sendable {
    let metadata: PendingRetryMetadata
    let lease: PendingRetryLease?
    init(metadata: PendingRetryMetadata, lease: PendingRetryLease? = nil)
}

nonisolated struct PendingRetryClaim: Sendable {
    let entry: PendingRetryEntry
    let token: UUID
    var id: UUID { entry.metadata.id }
}

actor PendingRetryStore {
    static let claimLeaseDuration: TimeInterval = 600

    func claimNext(surface: PendingRetrySurface? = nil) async -> PendingRetryClaim?
    func pendingCount() async -> Int
    func release(_ claim: PendingRetryClaim) async
    @discardableResult func clear(_ claim: PendingRetryClaim) async -> Bool
    @discardableResult func recordPublicationState(
        _ claim: PendingRetryClaim,
        transcript: String? = nil,
        publicationState: PendingRetryPublicationState
    ) async -> Bool
    @discardableResult func updateAttempt(_ claim: PendingRetryClaim, lastErrorCode: Int?) async -> Bool
}
```

Semantics E2 agents must code against:

- **`claimNext`** scans newest-first over RECORDS only. It skips a capture whose lease is live, and
  a capture whose destination is not `surface` when one is given. It reads exactly ONE recording — the
  reserved one's — writes the lease into that capture's sidecar, and returns. A capture whose recording
  file is GONE is finished here (full CLEAR order) rather than offered; a recording that is PRESENT but
  unreadable (`.completeFileProtection` before first unlock) is skipped and kept. If the lease cannot
  be written, nothing is offered — better than handing two surfaces the same capture.
- **`pendingCount`** counts every live capture, INCLUDING one another surface is holding: a reservation
  says who is finishing a recording, not whether it is still waiting.
- **`release`** drops the lease and keeps everything else. It is a no-op unless the token matches.
- **`clear` / `recordPublicationState` / `updateAttempt`** all require the claim's token to equal the
  sidecar's current lease token. An EXPIRED lease whose token still matches is honoured — expiry makes
  a reservation stealable, it does not retire the holder — so a slow surface nobody overtook can still
  finish. A holder that WAS overtaken gets `false` and nothing is written.
- **`recordPublicationState`/`updateAttempt`** write the sidecar FIRST and the index second, so the
  durable copy is never behind the one a crash would lose.

Superseded and kept for one wave, each marked `// Superseded by …; delete when no caller remains`:
`load()`, `clear(ifCurrentID:)`, `updateAttemptIfCurrent(id:lastErrorCode:)`,
`recordPublicationState(id:transcript:publicationState:)`. They all go through the new write orders, so
a caller that has not migrated is still crash-safe; `load()` is deliberately lease-BLIND, which is
exactly why it is superseded. `hasPending()`, `pendingErrorCode()`, `diagnosticSnapshot()`,
`cleanupExpired()`, `clear()`, `save(audioData:metadata:workImageData:)` and the
`PendingRetryQueueWriting` protocol keep their exact signatures — **the recorder's injected lane
double compiles untouched.**

---

## Findings

### r5a#1 (major) — adoption could not tell an interrupted arm from an interrupted clear. CONFIRMED, fixed.

**Verified first, by call path.** At `f794856` `save()` wrote the audio at `:444` and the index row at
`:459`; `clear(ifCurrentID:)` persisted the removal at `:565` and deleted the files at `:566`. Both
crash windows leave the identical residue — a destination-scoped recording the index does not name —
and `adoptOrphans` (`:687-725`) reconstructed only `id` + `destination` + the file's mtime, with
`preferredLanguage: nil, attemptCount: 1, lastErrorCode: nil` (`:710-720`) and therefore
`transcript: nil` and `publicationState: nil`. So a pre-phase-one Work orphan came back as UNKNOWN —
the one verdict `WorkVoiceCaptureCoordinator.recover` must not act on — and a post-clear orphan was
resurrected. Both halves hold exactly as written.

**Fix = contract K3.** The sidecar names an arm and the tombstone names a clear, so the two states are
no longer the same bytes on disk. Table above.

**Regression tests** (all in `PendingRetryDurabilityTests`):
- `testAnArmInterruptedBeforeTheIndexCommitsKeepsEveryFieldOfItsRecord` — arms a Work capture with a
  transcript, `.phaseOneFailed`, a language, `attemptCount: 3` and an error code, removes the index row
  to stage the crash, and asserts the claim carries **all five** back plus the right bytes.
- `testAClearInterruptedBeforeTheFilesGoDoesNotBringTheCaptureBack` — stages the exact state `clear`
  passes through (tombstone + sidecar + audio, index row gone) and asserts `pendingCount() == 0`,
  `claimNext() == nil`, and that all three files are gone afterwards.
- `testARecordingLeftBehindByAFinishedCaptureIsNotResurrected` — the steady state: audio with neither
  record nor index row is reclaimed.
- `testAnArmWhoseBytesNeverLandedLeavesNoWaitingCapture` — the other side of the same rule.

### r5a#2 (major, r4a#1 partial) — clearing ANY modern Chat entry deleted the fixed-name legacy recording. CONFIRMED, fixed.

**Verified:** `readableAudioURL` returned the fixed name for **every** Chat entry whose own file was
missing (`:740-743`), and `removeFiles(for:)` deleted it for **every** Chat entry with no ownership
test at all (`:763-764`). A capture armed today, finishing normally, deleted a recording parked by a
build that predates ids.

**Fix = K3's fold-in rule.** The bytes are COPIED under the legacy capture's own id before its entry is
trusted; the pointer is retired only after the queue naming the copy commits, and the fixed-name file
only after that. `readableAudioURL` has **no** fixed-name branch left, and per-capture deletion is
`removeFiles(forID:)` — keyed by id, so it cannot name a file that carries none. The one operation
allowed to delete it is `clear()`, the explicit discard a person asked for.

**Regression tests.** `testTheLegacyRecordingSurvivesAChatCaptureFinishingBesideIt` (the finding
itself: a newer Chat capture is claimed and cleared, and the parked recording is still claimable with
its own bytes) · `testTheFoldRetiresThePointerAndTheFixedNameOnceTheQueueCommits` ·
`testACaptureFoldedInWithoutItsBytesGetsThemOnTheFirstReadOfTheNewLayout` (the entry an earlier build
folded in without moving the bytes) · `PendingRetryDestinationTests.testThePreIdScopedRecordingIsNamedByNoCapture`
(the invariant as a pure assertion: the fixed name matches no scan this store performs, and neither
does the lock file).

### r5a#3 (major) — `load()` read every queued recording to hand back the first. CONFIRMED, fixed.

**Verified:** `load()` called `Data(contentsOf:)` per entry (`:475-495`); both consumers took `.first`
(`ContentView.swift:1457`, `MenuBar/DictationService.swift:193`). With `isExemptFromExpiry` keeping
non-`.published` Work captures forever, the queue is unbounded in exactly the case whose entries are
maximum-size recordings.

**Fix = K2.** `claimNext` reads one; `pendingCount` reads none. `load()` stays, marked superseded, and
is what the test measures against.

**Regression tests.** `testClaimingTheNextCaptureReadsExactlyOneRecording` — three captures armed,
`claimNext` makes **1** read and `load()` makes **3**, counted through the `CONDUCK_TESTING`
`audioReadsForTesting` counter, which sits at the ONE place this store reads parked bytes ·
`testCountingWhatIsWaitingReadsNoRecordingAtAll` — `pendingCount() == 3` with **0** reads.

### r5a#5 (minor) — no reservation: two surfaces could transcribe and finish the same capture. CONFIRMED, fixed.

**Verified:** `MenuBar/DictationService.swift:193` and `ContentView.swift:1457` both take
`load().first` and both later `clear(ifCurrentID: pending.metadata.id)`; nothing between them says who
is holding what. (`WorkboardVoiceCaptureView.swift:209` reaches the same capture through
`InAppAudioRecorder.retryWorkCapture()`, which finishes the recorder's in-memory `pendingWorkCapture`
and releases the SAME queue entry at `InAppAudioRecorder.swift:936` — so the overlap is real across
all three surfaces, though only the two store readers can pick the same entry out of the queue.)

**Fix = K2's lease.** 10 minutes, id-scoped, in that capture's sidecar, written under the cross-process
lock; expired leases are claimable by whoever comes next, and `release` gives one back early.

**Regression tests.** `testACaptureAnotherSurfaceIsHoldingIsNotOfferedAgain` ·
`testAReservationNobodyFinishedIsOfferedAgainOnceItLapses` (and the second holder gets its OWN token) ·
`testReleasingACaptureOffersItAgainAndFinishesNothing` ·
`testAStaleReservationNeitherRecordsAVerdictNorFinishesTheCapture` (all three token-guarded operations
answer `false` and the record is byte-identical afterwards) ·
`testTheHolderRecordsItsVerdictAndFinishesItsOwnCapture` (the positive control) ·
`testTwoWaitingCapturesAreOfferedOneAtATimeAndNeverTheSameOne` ·
`testASurfaceIsOfferedOnlyTheCapturesItCanFinish`.

---

## How I know the tests bite — MEASURED, not argued

I built a counterfactual copy of the tree under
`~/Library/Caches/gigaduck-builds/e-queue/cf-tree` (rsync, `.git` excluded) and reverted **only the
mechanisms the findings name**, keeping the new API surface so the cases still compile:

| Mutation | What it restores |
|---|---|
| M1 | adoption rebuilds the record from the FILENAME only (the old `adoptOrphans`) |
| M2 | no tombstone step; every unnamed recording is adopted (the old rule) |
| M3 | the fold copies nothing; the fixed name is any Chat capture's payload again, and any Chat capture's completion deletes it |
| M4 | `claimNext` materialises the whole queue |
| M5 | `claimNext` ignores a live lease |
| M6 | ownership checks ignore the token |

`** TEST BUILD SUCCEEDED **`, `grep -c ': error: '` = 0, then:

```
** TEST EXECUTE FAILED **
	 Executed 21 tests, with 30 failures (0 unexpected) in 0.976 (0.981) seconds
```

**12 of the 21 cases go red, each on the mechanism it names**, with the failure text confirming the
attribution:

| Case | First failure on the counterfactual |
|---|---|
| `testAnArmInterruptedBeforeTheIndexCommitsKeepsEveryFieldOfItsRecord` | `:78 XCTAssertEqual failed: ("nil") …` — the verdict, then `:86 :87 :89` nil for transcript/language/error code and `:88 ("1")` for the attempt count |
| `testAClearInterruptedBeforeTheFilesGoDoesNotBringTheCaptureBack` | `:129 ("1") is not equal to ("0")` — the finished capture is back, plus `:130` a non-nil claim and `:131-133` all three files still there |
| `testARecordingLeftBehindByAFinishedCaptureIsNotResurrected` | `:152 ("1") is not equal to ("0")` |
| `testTheLegacyRecordingSurvivesAChatCaptureFinishingBesideIt` | `:180 XCTUnwrap failed` — the parked recording is gone after the newer Chat capture finished |
| `testTheFoldRetiresThePointerAndTheFixedNameOnceTheQueueCommits` | `:200-203` |
| `testACaptureFoldedInWithoutItsBytesGetsThemOnTheFirstReadOfTheNewLayout` | `:219 XCTAssertFalse failed` |
| `testClaimingTheNextCaptureReadsExactlyOneRecording` | `:245 ("4") is not equal to ("1")` |
| `testACaptureAnotherSurfaceIsHoldingIsNotOfferedAgain` | `:287 XCTAssertNil failed: "PendingRetryClaim(…)"` |
| `testAReservationNobodyFinishedIsOfferedAgainOnceItLapses` | `:298 XCTAssertNil failed` |
| `testAStaleReservationNeitherRecordsAVerdictNorFinishesTheCapture` | `:349 :350 :351` all three ownership checks pass for the overtaken holder, then `:354 :356` the capture is gone |
| `testTwoWaitingCapturesAreOfferedOneAtATimeAndNeverTheSameOne` | `:405` the second claim is the same capture |
| `testTheLaunchSweepReclaimsOnlyWhatNoWaitingCaptureNames` | `:500 XCTAssertFalse failed` — M2 adopts the stray rather than reclaiming it |

The nine that stay green on the counterfactual are the ones whose mechanism it does not touch (the
positive controls and the previous-layout cases). The CF tree went with the build cache at end of task.

---

## Decisions

1. **`PendingRetrySurface` is a `typealias` for `PendingRetryDestination`, not a new enum.** K2 allowed
   either. The destination a capture was armed with IS the surface that can finish it — a Work
   recording belongs on the desk and a Chat recording in a conversation, and neither can complete the
   other's — so a second two-case enum would be one more thing to keep in step for no information.
   E2 agents write `claimNext(surface: .work)` and it compiles.
2. **The whole store, not a extracted value type, is what the new tests drive.** d-retry's honest limit
   was that "the actor's file I/O and its cross-process lock are not driven by a unit test", and every
   defect this round is precisely there. The `#if CONDUCK_TESTING` initializer runs the REAL
   `withExclusiveLock`, the REAL `contentsOfDirectory` scan and the REAL write orders against an
   isolated temporary directory and an isolated `InMemoryDefaultsStore`. That closes the gap rather
   than testing a copy of the logic.
3. **The sidecar's protection class is `.completeFileProtectionUntilFirstUserAuthentication`, not
   `.complete`.** It holds nothing the index in App-Group `UserDefaults` does not already hold at
   exactly that level (transcript included), and a headless capture arming before the device has ever
   been unlocked has to be able to READ what is already parked or it cannot reconcile at all. The
   RECORDING keeps `.completeFileProtection`, unchanged.
4. **A recording that is present but unreadable is skipped, never deleted.** The old `load()` doomed an
   entry on `Data(contentsOf:)` failing, which before first unlock is every `.complete` file on the
   device — the exact window d-retry's Founder-QA item 4 exercises. `readableAudioURL` now decides with
   `fileExists` (which works on a locked file) and only a file that is genuinely GONE finishes the
   entry. Strictly safer than the code the findings describe, and inside my ownership.
5. **The tombstone write is required, not best-effort.** If it fails the capture stays queued. Deleting
   without one reintroduces r5a#1 exactly: the sidecar-and-audio left behind would be adopted as an arm.
6. **`clear(_ claim:)` validates the token.** K2 states that requirement explicitly only for
   `recordPublicationState`, but the brief's test list asks for "clear with a stale token returns false
   and changes nothing" — and a clear is the destructive one, so it is the last operation that should
   trust an overtaken holder.
7. **`PendingRetryQueueWriting` is unchanged.** Adding the claim methods to it would break
   `WorkVoiceRecoveryTests`' `RecordingRetryLane` double, which I do not own. §Requests 2 says what to
   do if a surface needs the recorder to select by claim.
8. **No Codex consult.** The one genuinely hard call — what a `firstReconcile` must do with a recording
   the previous layout could not describe — is settled by the standing rule ("legacy on-disk data is
   READ and migrated, never deleted") rather than by an unknown.

## Deviations

1. **K3 says "audio without sidecar → delete (post-clear orphan)". I delete it only once the container
   carries the shape marker.** On the FIRST read of a container the previous layout wrote, a recording
   with no sidecar and no index row is an arm that layout could not describe (it committed the index
   last and wrote no sidecar), not residue — and deleting it would destroy a parked recording on the
   founder's dev device at upgrade. The marker (`pending_retry_shape`) is written only after the
   reconciliation commits, so the one-time adoption happens exactly once and every later orphan is
   deleted as K3 requires. `testARecordingThePreviousLayoutCouldNotDescribeIsAdoptedOnce` and
   `testARecordingLeftBehindByAFinishedCaptureIsNotResurrected` pin the two sides.
2. **The sidecar and tombstone filenames are namespaced.** K3 names them `<id>.json` and
   `<id>.tombstone`; they are `pending_retry_entry_<id>.json` and `pending_retry_tomb_<id>.tombstone`.
   The App-Group container is shared with the Watch and Widget targets and with `WorkCaptureInbox`,
   `WorkAssetVault` and `ShareTargetsSnapshotWriter` — a bare `<id>.json` there would be a name any of
   them could also write. Shape, order and meaning are exactly as decided.
3. **`clear()` (discard everything) also deletes the pre-id-scoped recording.** It is the only operation
   that may, and it is the only user-visible way that file can leave when no entry ever claimed it
   (§Requests 4).
4. **A fixed-name recording nobody claims is LEFT, not deleted.** If the first reconciliation finds it
   with no legacy pointer and no byte-less Chat entry, it stays where it is. Adopting it under a fresh
   id would mint a different id on every launch; deleting it is deleting an unowned recording, which is
   the failure class this round exists to remove. One bounded file, reachable by `clear()`.

---

## Gates — what I actually ran

DerivedData under `~/Library/Caches/gigaduck-builds/e-queue/{DerivedData,DerivedDataMac,DerivedDataCF}`,
every log written there and grepped for `': error: '` and the verdict strings — never judged from a
tail or an exit code. **No `-configuration` passed anywhere.** No `/tmp`, no bare `rm -rf`. The one
throwaway tree copy lived under the slug dir and went with it.

- **Simulator TCC checked BEFORE trusting any run**, per the standing rule:
  `sqlite3 …/6C3FB33E…/data/Library/TCC/TCC.db "select service, client, auth_value from access where
  client='ai.gigaduck.AgentRelay';"` → **no rows**, exit 0 (`.notDetermined`). No stale denial.
- **iOS `build-for-testing`** → `ios-bft-5.log` (final): `grep -c ': error: '` = **0**, and:
  ```
  ** TEST BUILD SUCCEEDED **
  ```
- **iOS `test-without-building`**, eleven quoted `-only-testing:` flags → `test-4.log`:
  ```
  ** TEST EXECUTE SUCCEEDED **
	 Executed 139 tests, with 0 failures (0 unexpected) in 4.033 (4.061) seconds
  ```
  `grep -cE '\.swift:[0-9]+: error: '` = **0**.

  | Class | Result line |
  |---|---|
  | `PendingRetryDurabilityTests` (**new**) | `Executed 21 tests, with 0 failures (0 unexpected) in 0.091 (0.095) seconds` |
  | `PendingRetryQueueTests` | `Executed 17 tests, with 0 failures (0 unexpected) in 0.008 (0.011) seconds` (unchanged) |
  | `PendingRetryDestinationTests` | `Executed 11 tests, with 0 failures (0 unexpected) in 0.011 (0.013) seconds` (was 6) |
  | `WorkVoiceRecoveryTests` | `Executed 20 tests, with 0 failures (0 unexpected) in 0.125 (0.129) seconds` |
  | `HeadlessRetryGuardSpanTests` | `Executed 11 tests, with 0 failures (0 unexpected) in 0.040 (0.041) seconds` |
  | `WorkboardAudioCaptureTests` | `Executed 19 tests, with 0 failures (0 unexpected) in 0.135 (0.139) seconds` |
  | `WorkboardVoiceLaneTests` | `Executed 11 tests, with 0 failures (0 unexpected) in 0.076 (0.078) seconds` |
  | `AudioExclusivityCrossSurfaceTests` | `Executed 7 tests, with 0 failures (0 unexpected) in 0.225 (0.227) seconds` |
  | `ErrorSurfaceDriftGuardTests` | `Executed 7 tests, with 0 failures (0 unexpected) in 2.942 (2.943) seconds` |
  | `TempScratchSweeperTests` | `Executed 11 tests, with 0 failures (0 unexpected) in 0.369 (0.370) seconds` |
  | `DiagnosticsFocusTests` | `Executed 4 tests, with 0 failures (0 unexpected) in 0.012 (0.013) seconds` |

  Beyond the classes the brief names I ran the error-surface registry, the temp-file sweeper (it
  enumerates `conduck_retry_*`) and the Diagnostics focus cases, because all three read this store's
  neighbourhood.
- **One run died before any test case started** (`test-3.log`): `Simulator device failed to launch
  ai.gigaduck.AgentRelay … Busy ("Application failed preflight checks")`, `Executed` line absent
  entirely. Retried once with no change to the tree → `test-4.log` green. Reported rather than hidden;
  three other agents share this simulator.
- **macOS `build -destination 'platform=macOS'`** → `mac-2.log`: `grep -c ': error: '` = **0**, and:
  ```
  ** BUILD SUCCEEDED **
      Signing Identity:     "Apple Development: Peter Krueck (Z4PNDLZK98)"
  ```
  **Signed through the identity override; no `CODE_SIGNING_ALLOWED=NO` fallback needed or used.**
- **`bash scripts/check-storage-seam.sh`** → `✓ storage seam intact — 802 Swift files scanned…`, exit 0.
  `PendingRetryStore.swift` keeps its existing `CONTAINER_ALLOWLIST` row and is still the only file of
  mine that names `containerURL(forSecurityApplicationGroupIdentifier:)`; the new test file names none.
- **`git diff --check`** → no output, exit 0. `git status --short` for `*.xcstrings`, `*.pbxproj`,
  `Conduck/Configs`, `docs/qa` and all three mirror triplets → **empty**. The two untracked files
  checked by hand (`git diff --check` cannot see them): **0 trailing-whitespace lines, 0 tab lines**,
  and each opens with `// SPDX-License-Identifier: Apache-2.0` + a header comment.
- **Warnings: 13 in `PendingRetryStore.swift` on BOTH platforms, all one pre-existing class** — the
  main-actor-isolated `DefaultsStore` methods called from this actor's synchronous locked helpers
  (`data`/`integer`/`set`/`removeObject`/`synchronize`). d-retry measured **10** of exactly that kind;
  the **+3** are the shape marker's `integer(forKey:)` and `set(_:forKey:)` and one more
  `synchronize()`. **Zero** in `PendingRetryDurabilityTests.swift`, `PendingRetryDestinationTests.swift`
  and `PendingRetryQueueTests.swift` on both platforms. I added no warning of any other kind.
- **NOT run, plainly: the full iOS suite and the watch suite.** Neither is in my brief, no watch sim is
  assigned, and other agents were editing this tree throughout — a full run would report their
  in-flight state as mine. **Suite delta from this slice: +26** (`PendingRetryDurabilityTests` NEW 21,
  `PendingRetryDestinationTests` 6 → 11; every other class unchanged in count). **The watch target
  compiles none of my files** — checked, not assumed: `grep -c` for `PendingRetryStore.swift`,
  `PendingRetryDurabilityTests.swift` and `PendingRetryDestinationTests.swift` in
  `Conduck.xcodeproj/project.pbxproj` is **0** for all three, and the string `PendingRetry` appears
  nowhere in the file, so none of them is in any `membershipExceptions` list — the watch target's own
  inclusion mechanism. **No `.pbxproj` edit was needed or made** (`git status --short -- '*.pbxproj'`
  → empty); the synchronized group covers the new test file, as every new `ConduckTests` source this
  round has.
- Build cache removed at end of task with `.claude/scripts/clean-build-cache.sh e-queue` → `removed:
  e-queue`; every log quoted above went with it, and so did the counterfactual tree. Re-run to reproduce.

## What I did NOT verify, plainly

- **Two PROCESSES contending on `pending_retry.lock` are still untested.** The new cases drive the real
  `flock` path, but from one process. Founder QA below, and O-1's Gate 2.
- **No migration was run against a real device's App Group.** Both fold-ins are proven against a real
  directory, but a synthetic one.
- **No UI, no screen.** The retry card's behaviour with two queued captures and the new count is a
  founder-QA item, and the card itself is e-surfaces' file.
- **`.completeFileProtection` behaviour before first unlock is reasoned, not measured** — a simulator
  has no lock state. Decision 4 is what makes the failure safe either way.
- **I ran no other agent's counterfactual and did not re-run theirs.**

---

## Catalog

**Keys I ADDED in source: NONE.**

**Keys I made DEAD: NONE.** No string-bearing branch was added, deleted or moved; this store carries no
user-facing copy at all.

**No `.xcstrings` file was opened.** Nothing for the serial copy agent to splice from this slice.

---

## Requests

1. **Owner of `ViewModels/DiagnosticsRunner.swift` (O-17) — the one-line call.** Beside the existing
   `let pendingRetry = await PendingRetryStore.shared.diagnosticSnapshot()`
   (`DiagnosticsRunner.swift:751`), add:
   ```swift
   let pendingRetryCount = await PendingRetryStore.shared.pendingCount()
   ```
   It is metadata-only (measured: 0 recording reads) and answers "N recordings waiting".
   `diagnosticSnapshot()` keeps its exact signature and its meaning for the newest capture, so the row
   gains a count without changing what it already says. O-17 is closable with that line plus a string.
2. **e-surfaces — the recorder's injected lane still speaks the old protocol.**
   `PendingRetryQueueWriting` is unchanged (`save` + `clear(ifCurrentID:)`) because
   `WorkVoiceRecoveryTests.RecordingRetryLane` conforms to it and neither file is mine. If
   `WorkboardVoiceCaptureView`'s Try Again must select through `claimNext` rather than through
   `InAppAudioRecorder.pendingWorkCapture`, the protocol needs `claimNext`/`release`/`clear(_ claim:)`
   added AND that double updated in the same edit — one change, two files, both outside my ownership.
   The store is ready either way.
3. **Owner of `MenuBar/DictationService.swift` — a bookkeeping URL now collides with a reserved name.**
   `preserveForRetry` builds `…/pending_retry_audio.m4a` (`:706`) purely as `metadata.audioFileURL`
   bookkeeping; the store has never read it and still does not. But that filename is now the
   pre-id-scoped recording, which the reconciliation treats specially, and a reader will assume the two
   are the same thing. It creates no file, so there is no hazard today — please point it at the
   id-scoped name or drop the field's use here when you touch the file.
4. **Whoever owns the discard affordance (O-16) — `clear()` is the one operation that retires the
   pre-id-scoped recording.** It stays zero-callers today. If a "Discard recording" affordance lands
   per K5, it should call `clear(_ claim:)` for one capture — NOT `clear()`, which discards everything
   including a capture another surface is holding.
5. **Nobody undo these** — each is pinned by a case measured red on the counterfactual:
   - The sidecar is written BEFORE the bytes and the index row LAST. Reversing either makes an
     interrupted arm indescribable again.
   - The tombstone is written BEFORE the index row is removed and deleted LAST, and its write is
     REQUIRED. Skipping it resurrects finished captures.
   - `readableAudioURL` has no fixed-name branch, and per-capture deletion is keyed by id. Restoring
     either is r5a#2 exactly.
   - `claimNext` reads ONE recording. Reading more is r5a#3, and the classes it hurts are the ones that
     never expire.
   - Ownership is checked by TOKEN, not by presence of a lease. An expired-but-unstolen lease is
     honoured; an overtaken one is refused.
   - `pending_retry_shape` is written only after the reconciliation commits. Writing it eagerly turns
     the previous layout's parked recordings into residue on the next read.
   - d-retry's seven "nobody undo" clauses all still hold: `save()` deletes no file and removes no
     entry, `isExemptFromExpiry` is still the single expression every reader inherits, a verdict is
     still written through `recordPublicationState` inside one `withExclusiveLock`, and the legacy
     pointer is still read on every load and retired only after the queue carrying it commits.

---

## Refuted

**None.** All four findings were traced against the current tree by call path before any code changed,
and all four hold exactly at the anchors quoted in §Findings. The decided design directions (K2 and K3)
were implementable as specified; the two places the letter of K3 moved are recorded as deviations —
the one-time adoption of a recording the previous layout could not describe (§Deviations 1), which the
standing "legacy on-disk data is READ and migrated, never deleted" rule requires, and the namespacing
of two filenames in a shared container (§Deviations 2).

One qualification, stated as such rather than as a refusal: r5a#5's finding names
`WorkboardVoiceCaptureView.swift:209` as one of the two racing surfaces. That surface does not read
this store — it finishes `InAppAudioRecorder.pendingWorkCapture` and releases the queue entry through
`clear(ifCurrentID:)` — so the lease cannot cover it until a caller migrates it to `claimNext`
(§Requests 2). The two surfaces that DO select from the queue, the menu bar and the iOS retry card, are
covered as decided.

---

## Founder QA — device-only checks this change needs

These ADD to d-retry's seven, which all still apply.

1. **The upgrade itself, which is the one-way step.** Before installing this build, park a Work voice
   note on the device (airplane mode, let STT fail) so a recording exists under the OLD layout. Install
   this build, open the app, and confirm the retry card is still there and finishing it produces ONE
   playable card with the words. *Nothing about this is reversible: the container is rewritten on first
   launch.*
2. **Two surfaces, one recording (macOS).** With a capture waiting, open the menu bar's Retry and the
   main window's retry at the same time and press both. Exactly one must do the work; the other must
   say there is nothing to retry, or wait — never produce a second card or a duplicate transcript.
3. **Force-quit while a retry is in flight.** Start a retry, force-quit the app mid-transcription,
   reopen. The capture must be offered again — not immediately (the reservation is ten minutes), but
   certainly after that, and never lost. If the founder can wait out ten minutes, confirm it comes back
   on its own.
4. **First unlock, again — this is the case decision 4 changes.** Reboot the iPhone, do NOT unlock it,
   fire the Action Button with Destination = Work so a capture arms before first unlock. Unlock, open
   the app: the retry card must be there. Previously a read of the protected file could fail and drop
   the entry.
5. **Two processes, one queue.** While a Shortcut capture is in flight, start an in-app capture that
   also fails. Neither recording may disappear, and Diagnostics afterwards must name both.
6. **Nothing accumulates.** After all of the above, discard everything from Settings and confirm
   Settings → Diagnostics reports no parked recording, and that a later launch does not resurrect one.

---

## Settled facts — one sentence each, for whoever writes the docs

- Each waiting capture keeps a small record of itself beside its recording, so a capture whose queue
  entry never committed is recovered with everything it knew — the words already recognised, the
  verdict about its card, the language — rather than as a nameless recording.
- A capture being deleted is marked as such before its entry is removed, so a deletion interrupted
  part-way finishes on the next launch instead of bringing the capture back.
- A recording with no record and no queue entry beside it is something a deletion did not finish, and
  it is reclaimed rather than offered as a retry.
- The recording a build before capture identifiers parked is copied under an identifier the first time
  this build runs, and nothing reads or deletes the old fixed name afterwards — so finishing one
  capture can no longer take another's recording.
- A retry surface takes one capture at a time and reserves it for ten minutes, so two surfaces open at
  once can never transcribe or finish the same recording; a reservation nobody finished lapses and the
  capture is offered again.
- Asking how many recordings are waiting reads no recording at all, and offering one reads exactly one.
- A recording that is present but unreadable — the device has not been unlocked since it restarted — is
  left waiting, and only a recording that is genuinely gone ends its capture.
- A capture's recording, its record and its screenshot are all named with the capture's own identifier,
  so no operation on one capture can name a file belonging to another.
