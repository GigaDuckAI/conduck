# f-queue — the record becomes authoritative, and a reservation becomes renewable and addressable by id. All three findings CONFIRMED and fixed; nothing refuted.

Slug `f-queue`. Sim `6C3FB33E-D89F-4D1E-9F0D-3FAC0C089228`. No commits, pushes, stash, checkout, reset
or index operations. `Identity-Override.xcconfig` untouched. Nothing under `docs/qa/desk-cloudkit/`
touched. **No `.xcstrings` opened.** No `.pbxproj` edit. No mirror triplet touched. No file outside my
ownership edited — `git status --short` at end of task lists my three plus four that belong to other
f-agents (`ConversationStore+Workboard.swift`, `WorkCaptureDrainer.swift`,
`WorkboardSyncedRowRepairTests.swift`, `WorkCaptureDrainerRetirementTests.swift`), none of which I
opened.

Files changed — three, of which one is new:

| File | Change |
|---|---|
| `Conduck/Conduck/Services/PendingRetryStore.swift` | sidecar authority + deferral in `queueLocked`; `claim(id:duration:)`, `renew`, `confirmOwnership`; `isReserved`, `reserveLocked`, `legacyRecordingIsDuplicated`; live reservations exempt from the expiry sweep; the legacy fold made cleanup-idempotent and its two retirements reordered; `PendingRetryMetadata: Equatable`; `PendingRetryLease.duration` |
| `Conduck/ConduckTests/PendingRetryDurabilityTests.swift` | 21 → 26 cases (the record outranking its row, the deferral, and the two fold crash windows + one control) |
| `Conduck/ConduckTests/PendingRetryLeaseTests.swift` | **NEW**, 13 cases — addressing by id, renewal, ownership, and the clock |

`Conduck/ConduckTests/PendingRetryQueueTests.swift` is mine and is **unchanged** — its 17 cases still
pass; `PendingRetryQueue`'s pure rules are untouched and all six are still called by the actor.
`PendingRetryDestinationTests.swift` is NOT in my ownership this wave and was **not opened** (its 11
cases still pass unchanged; `PendingRetryLease`'s new field is optional with a defaulted initializer
precisely so its two two-argument constructions keep compiling).

---

## The API as implemented, VERBATIM

```swift
nonisolated struct PendingRetryLease: Codable, Sendable {
    let token: UUID
    let expiresAt: Date
    let duration: TimeInterval?                                   // NEW, optional on the wire
    init(token: UUID, expiresAt: Date, duration: TimeInterval? = nil)
    func isLive(at now: Date) -> Bool
}

nonisolated struct PendingRetryMetadata: Codable, Sendable, Equatable   // + Equatable

actor PendingRetryStore {
    static let claimLeaseDuration: TimeInterval = 600

    // wave E, unchanged
    func claimNext(surface: PendingRetrySurface? = nil) async -> PendingRetryClaim?
    func pendingCount() async -> Int
    func release(_ claim: PendingRetryClaim) async
    @discardableResult func clear(_ claim: PendingRetryClaim) async -> Bool
    @discardableResult func recordPublicationState(
        _ claim: PendingRetryClaim, transcript: String? = nil,
        publicationState: PendingRetryPublicationState
    ) async -> Bool
    @discardableResult func updateAttempt(_ claim: PendingRetryClaim, lastErrorCode: Int?) async -> Bool

    // NEW — the lease contract (L1, L2, L3)
    func claim(
        id: UUID,
        duration: TimeInterval = PendingRetryStore.claimLeaseDuration
    ) async -> PendingRetryClaim?
    @discardableResult func renew(_ claim: PendingRetryClaim) async -> Bool
    func confirmOwnership(_ claim: PendingRetryClaim) async -> Bool
}
```

Semantics E2 agents must code against, beyond e-queue's (which all still hold):

- **`claim(id:duration:)` ADDRESSES; `claimNext` SELECTS.** It answers only for the capture named. Nil
  when the capture is not queued, when another live reservation holds it (an id is not a way around
  somebody else's hold), or when its recording cannot be read. A capture whose recording is GONE is
  finished here, exactly as `claimNext` finishes one. It reads exactly ONE recording — the named one's.
- **`duration` is the caller's own horizon** and is recorded in the sidecar, so a renewal extends by
  the horizon the holder was granted rather than by the store's default. **L4: the headless lane takes
  `claim(id:, duration: 90)`** — that is the simpler half of L4's choice, because an intent process may
  be killed at any instant and a short hold needs no timer to be safe, whereas a renew loop in a
  process that is about to die is a timer that will not fire.
- **`renew`** is token-checked and extends from NOW by the recorded duration. An expired-but-unstolen
  lease renews (expiry makes a reservation stealable; it does not retire the holder). An overtaken one
  answers false and nothing is written.
- **`confirmOwnership`** is token-checked and mutates nothing — measured: the sidecar's bytes are
  byte-identical across the call. It answers false when the capture is no longer queued (finished, or a
  deletion this read finished) and when the token no longer matches. It runs the RECONCILED queue but
  deliberately NOT the expiry-swept one: a question about ownership may finish an interrupted deletion,
  but it may not itself retire a capture on the clock.
- **A live reservation exempts its capture from the expiry sweep.** Without it `renew` is decorative for
  the class of capture that needs it most: the TTL is 600 s and a custom STT request is allowed 300 s
  and attempted three times, so the sweep deleted the recording out from under the surface transcribing
  it. The exemption is the reservation, not a disabled clock — the moment nobody holds the capture, the
  same budget retires it (both sides pinned by cases).

## The reconciliation table as implemented

Every locked queue read, in this order. Rows in **bold** changed this wave.

| # | State on disk | Verdict |
|---|---|---|
| 1 | tombstone present | finish the deletion: drop the index row, delete every payload, delete the tombstone. Never adopted |
| 2 | **legacy pointer whose capture already has id-scoped bytes** | **retire the fixed name — whether or not the index already names the capture** (this is r6a#5) |
| 2 | legacy pointer naming an unqueued capture with no bytes of its own | COPY the fixed-name recording under the capture's id, fold the entry in; retire the fixed name and then the pointer only after the queue commits. Copy fails → entry dropped back out, pointer LEFT |
| 3 | fixed-name recording + a Chat entry with no bytes (first reconcile only) | copy it under that entry's id (oldest such entry wins) |
| **3b** | **fixed-name recording, no pointer, byte-identical to a queued capture's own recording (first reconcile only)** | **reclaim it — the bytes are proven preserved. Any other fixed-name recording is LEFT** |
| **4** | **index row and a READABLE sidecar that differ** | **the sidecar wins; the row is rewritten from it** |
| **5** | sidecar + audio, no index row, no tombstone | **readable → adopt with FULL metadata; UNREADABLE → DEFER (audio kept, sidecar kept, nothing persisted, retried next read). No filename reconstruction** |
| 5 | sidecar, no audio, no index row | delete the sidecar — an arm whose bytes never landed |
| 6 | audio, no sidecar, no index row, shape marker present | delete — residue a clear did not finish |
| 6 | audio, no sidecar, no index row, shape marker ABSENT | adopt once (e-queue §Deviations 1, unchanged) |
| 7 | index row with no sidecar | write the sidecar from the index row |

Commit order at the end of a reconciliation is now: **persist the queue → delete the fixed-name
recording → retire the pointer** (the pointer moved LAST; see r6a#5).

---

## Findings

### r6a#3 (major) — a stale index row outranked a durable record, and an unreadable record was replaced by a lossy one. CONFIRMED, fixed.

**Verified first, by call path, at the anchors given.** `restateLocked` writes the sidecar
(`PendingRetryStore.swift:1226-1229` at `1e9a004`) and then the index (`:1231`). `queueLocked` read a
sidecar in exactly two places: `:1090-1100`, guarded by `where !entries.contains(where: { $0.id == id })`
— i.e. only for a capture the index does NOT name — and `:1132-1139`, which only backfilled a MISSING
sidecar (`entries.filter { !files.sidecars.contains($0.id) }`). A capture that has both therefore had
its index row honoured and its record ignored, so a death between the two writes left `.phaseOneFailed`
in charge over a durable `.published` — which is a licence to republish a card that already exists, and
the transcript went with it. Second half also holds exactly: `:1100`'s `adoptedMetadata` fallback
produced `preferredLanguage: nil, attemptCount: 1, lastErrorCode: nil` and therefore `transcript: nil`
and `publicationState: nil` (`:1353-1370`), persisted that row, and — because of the same
`!entries.contains` guard — the row then blocked the real record for ever, including after the sidecar
became readable again. Write asymmetry as stated: sidecars are `.atomic` (`:1428`), the index is
`defaults.set` + unchecked `synchronize` (`:1242-1243`).

**Fix = L6.** New step 4 rewrites a differing index row from its readable sidecar (requires
`PendingRetryMetadata: Equatable`, added). Step 5's salvage branch is DELETED: an unreadable sidecar
defers — the recording is kept, the sidecar is kept, nothing is persisted, and the next read tries
again. Step 6 cannot delete the bytes in the meantime because the sidecar FILE is present in the
inventory (readability is not what the inventory measures), and step 7 cannot clobber the sidecar for
the same reason.

**Regression tests** (`PendingRetryDurabilityTests`):
- `testARecordRestatedBeforeTheCrashOutranksItsStaleIndexRow` — arms, claims, restates to `.published`
  with words, then rewrites the index back to the pre-restatement row. Asserts the entry reads
  `.published` **and** that the persisted index itself was repaired. Counterfactual: `:515`
  `("…phaseOneFailed") is not equal to ("…published")`, `:519` nil transcript, `:522` the row unrepaired.
- `testAnUnreadableRecordDefersItsCaptureRatherThanRebuildingItBadly` — arm, remove the index row,
  corrupt the sidecar: `pendingCount() == 0`, `claimNext() == nil`, the recording still on disk, and
  **nothing written** to the index. Then restores the record and claims it whole. Counterfactual:
  `:554 ("1") is not equal to ("0")`, `:560 XCTAssertNil failed: "442 bytes"` (the lossy row it
  persisted), and `:570 :571 :572 :573` — verdict, words, language and attempt count all gone after the
  record became readable again, which is the "blocks later restoration" half of the finding.

### r6a#2 (major, store half) — a 600 s reservation could not be renewed, and the clock deleted the recording under its holder. CONFIRMED, fixed.

**Verified:** the lease was minted once at `claimNext` (`:725-728` at `1e9a004`) with
`Self.claimLeaseDuration` and no operation extended it; `grep 'func renew\|func confirmOwnership\|func claim(id:'`
returned nothing. The budget it has to outlast: `STTClient.swift:299-304` sets a **300 s** timeout on a
custom request and `:375-404` retries up to **three** attempts, so one transcription can run past both
the 600 s reservation and the 600 s `transcriptionRetryTTL` — and `liveQueueLocked` (`:1171-1182`)
applied that TTL with no regard for who was holding the entry, so the sweep could delete the recording
the holder was still transcribing.

**Fix = L1 + L2 + L3, plus the one thing that makes them mean anything.** `claim(id:duration:)`,
`renew` and `confirmOwnership` are all token-checked under the cross-process lock. `claimNext` and
`claim(id:)` now mint through one `reserveLocked`, so they cannot drift on what a reservation is.
`isReserved` is the single reservation predicate and answers YES for an unreadable sidecar — not
knowing who holds a capture is not a licence to take it. **And the expiry sweep now skips a capture
under a live reservation**, without which a renewable lease still loses the recording at 600 s.

**Regression tests** (`PendingRetryLeaseTests`, all NEW):
- `testALaneReservesTheCaptureItNamesRatherThanTheNewestOne` + `testHoldingOneCaptureLeavesTheRestOfTheQueueClaimable`
  — addressing by id (CF `:68 :69`, `:87`: the newest capture is handed back instead).
- `testAShortLivedLaneTakesAHoldThatLapsesLongBeforeTheStandardOne` — L4's 90 s hold (CF
  `:124 ("599.999…") is greater than ("90.0")`).
- `testTheHolderExtendsItsReservationAndKeepsTheCapture` — renew keeps the capture (CF `:153` renew
  refused, `:155 XCTAssertNil failed: "PendingRetryClaim(…)"` — another surface took it).
- `testARenewalExtendsByTheHorizonTheHolderWasGrantedNotTheDefault` (CF `:169`, `:172 ("-1.0007…") is
  not greater than ("0.0")`).
- `testAnOvertakenHolderCanNeitherRenewNorConfirm` (CF `:192 XCTAssertFalse failed` — the overtaken
  holder is confirmed as owner).
- `testTheExpirySweepDoesNotReachACaptureUnderALiveReservation` (CF `:266 ("0") is not equal to ("1")`,
  `:267` the recording deleted, `:269 :271` ownership and completion both gone) — with
  `testTheSameCaptureExpiresOnceNobodyIsHoldingIt` as the control that keeps the clock honest.
- `testConfirmingOwnershipChangesNothingAtAll`, `testAFinishedCaptureIsOwnedByNobody`,
  `testALapsedButUnstolenReservationStillConfirms`,
  `testACaptureAnotherSurfaceIsHoldingCannotBeAddressedByIdEither`,
  `testAddressingACaptureThatIsNotQueuedReservesNothing` — the positive and negative controls.

### r6a#5 (minor) — the legacy fold was not cleanup-idempotent. CONFIRMED, fixed.

**Verified:** step 2's gate was `!queuedIDs(in: queueData).contains(slot.id)` (`:1048-1050` at
`1e9a004`). After a death between `persist` (`:1146`) and the two retirements (`:1150-1154`), the next
read finds the id already queued, so the whole recognition is skipped and `retireLegacyRecording` stays
false — while `decoding` still reports `migratedLegacy`, so `retireLegacyPointer` is true and the
pointer, the last thing that could name the file, is retired at `:1150`. Step 3 cannot rescue it: its
`orphaned` list is Chat entries with **no audio**, and this entry has its copy. `pending_retry_audio.m4a`
then survives every later read.

**Fix, in two parts.** (a) The recognition is no longer conditioned on the entry being absent from the
index: a pointer whose capture already has id-scoped bytes retires the fixed name whether or not the
queue names it. (b) The two retirements are REORDERED — the fixed-name recording is deleted BEFORE the
pointer, so a death between them leaves the pointer standing over a file that is already gone rather
than a file with nothing left to name it. (c) For a container a build BEFORE that ordering already left
in the bad state, one first-reconcile step reclaims the fixed name **only on proof**: byte-for-byte
equality (`FileManager.contentsEqual`) with a queued capture's own recording. Not size, not mtime —
an inference there deletes a recording that may exist nowhere else; an unreadable file compares unequal,
so a locked device leaves it.

**Regression tests** (`PendingRetryDurabilityTests`):
- `testACrashBetweenTheQueueAndTheFixedNameStillRetiresTheOldRecording` — the finding's own window (CF
  `:596 XCTAssertFalse failed - the fixed name goes even though the capture was already queued`).
- `testACrashAfterThePointerWasRetiredStillReclaimsTheDuplicateRecording` — the window the brief names
  second (CF `:620 XCTAssertFalse failed`).
- `testAFixedNameRecordingNoQueuedCaptureDuplicatesIsLeftWhereItIs` — the control on (c), green on both
  trees by design: a fixed-name recording nothing duplicates is never deleted.

---

## How I know the tests bite — MEASURED, not argued

A counterfactual copy of the tree under `~/Library/Caches/gigaduck-builds/f-queue/cf-tree` (rsync,
`.git` excluded), with **only the mechanisms the findings name** reverted and the whole new API surface
kept so every case still compiles:

| Mutation | What it restores |
|---|---|
| M1 | the record is no longer authoritative over its index row |
| M2 | an unreadable record is rebuilt from the filename again (the old salvage) |
| M3 | the fold skips a capture the index already names |
| M4 | no duplicate-proof reclamation of the fixed name |
| M5 | `claim(id:)` answers "the newest capture" instead of the one named |
| M6 | a reservation cannot be extended (`renew` writes nothing, answers false) |
| M7 | the expiry sweep ignores reservations |
| M8 | ownership is not checked by token |
| M9 | `claim(id:)` ignores the caller's own horizon |

`** TEST BUILD SUCCEEDED **`, `grep -c ': error: '` = 0, then:

```
** TEST EXECUTE FAILED **
	 Executed 67 tests, with 24 failures (0 unexpected) in 1.108 (1.137) seconds
```

**11 of my 18 new cases go red**, each on the mechanism it names (per-class on the CF tree:
`PendingRetryDurabilityTests` 26 executed / 11 failures, `PendingRetryLeaseTests` 13 / 13,
`PendingRetryQueueTests` 17 / 0, `PendingRetryDestinationTests` 11 / 0). The failing cases:

| Case | First failure on the counterfactual |
|---|---|
| `testARecordRestatedBeforeTheCrashOutranksItsStaleIndexRow` | `:515 ("…phaseOneFailed") is not equal to ("…published")` |
| `testAnUnreadableRecordDefersItsCaptureRatherThanRebuildingItBadly` | `:554 ("1") is not equal to ("0")` |
| `testACrashBetweenTheQueueAndTheFixedNameStillRetiresTheOldRecording` | `:596 XCTAssertFalse failed` |
| `testACrashAfterThePointerWasRetiredStillReclaimsTheDuplicateRecording` | `:620 XCTAssertFalse failed` |
| `testALaneReservesTheCaptureItNamesRatherThanTheNewestOne` | `:68` the newest capture's id, `:69` its bytes |
| `testHoldingOneCaptureLeavesTheRestOfTheQueueClaimable` | `:87` id mismatch |
| `testAShortLivedLaneTakesAHoldThatLapsesLongBeforeTheStandardOne` | `:124 ("599.999…") is greater than ("90.0")` |
| `testTheHolderExtendsItsReservationAndKeepsTheCapture` | `:153`, then `:155 XCTAssertNil failed: "PendingRetryClaim(…)"` |
| `testARenewalExtendsByTheHorizonTheHolderWasGrantedNotTheDefault` | `:169`, `:172 ("-1.0007…") is not greater than ("0.0")` |
| `testAnOvertakenHolderCanNeitherRenewNorConfirm` | `:192 XCTAssertFalse failed` |
| `testTheExpirySweepDoesNotReachACaptureUnderALiveReservation` | `:266 ("0") is not equal to ("1")` |

The seven that stay green are the controls whose mechanism the counterfactual does not touch —
`testAFixedNameRecordingNoQueuedCaptureDuplicatesIsLeftWhereItIs`,
`testTheSameCaptureExpiresOnceNobodyIsHoldingIt`, `testConfirmingOwnershipChangesNothingAtAll`,
`testAFinishedCaptureIsOwnedByNobody`, `testALapsedButUnstolenReservationStillConfirms`,
`testAddressingACaptureThatIsNotQueuedReservesNothing` and
`testACaptureAnotherSurfaceIsHoldingCannotBeAddressedByIdEither` (single-entry, so M5 cannot pick a
different capture). The CF tree went with the build cache at end of task.

---

## Decisions

1. **The reservation's duration lives in the LEASE, not in the claim.** L2 says "extension by the
   claim's duration"; `PendingRetryClaim` is `{entry, token}` in K2 and is constructed outside my
   ownership (`ConverseIntent.swift:779`, `WorkVoiceRecoveryTests.swift:1021`), so adding a field there
   would break two files I do not own. The lease is durable and cross-process, so a renewal knows the
   horizon even if the claim crossed a boundary. Same meaning, no foreign edit.
2. **The expiry sweep skips a live reservation.** Not in the letter of L1–L3, but without it the whole
   of r6a#2 is only half fixed: the reservation would survive the 900 s transcription and the ENTRY
   would not, because `transcriptionRetryTTL` is the same 600 s the lease was. Inside my ownership,
   pinned by a case and by its control.
3. **`confirmOwnership` also requires the capture to still be QUEUED.** A token check alone answers true
   for a capture whose deletion another process committed but did not finish — the sidecar is still
   there under a tombstone. Running the reconciliation first makes the answer honest and costs no
   recording read.
4. **An unreadable sidecar blocks a claim** (`isReserved` answers yes), where before the lease check
   simply saw no lease. Two surfaces cannot be handed the same capture because one of them could not
   read who held it. It has no user-visible cost: before first unlock the RECORDING cannot be read
   either, so `claimNext` was already offering nothing in that window.
5. **The fixed-name reclamation compares CONTENT, not size or mtime.** `copyItem` preserves both, so
   they would be a cheaper signal — but a wrong answer deletes a recording that may exist nowhere else,
   and byte equality is proof rather than evidence. It runs once per container (first reconcile only),
   bounded by the queue length, and only when a fixed-name recording is present that nothing else
   claimed.
6. **`PendingRetryQueueWriting` is UNCHANGED.** Widening it breaks `WorkVoiceRecoveryTests`'
   `RecordingRetryLane` double, which is not mine and would fail the build for every parallel agent.
   §Requests 1 has the exact edit, and it is now the ONLY thing left in O-1.
7. **No Codex consult.** Nothing here was a genuinely open question once L6 and L1–L3 were decided; the
   one judgement call (Decision 5) is settled by the standing "never delete an unowned recording" rule.

## Deviations

1. **A permanently unreadable sidecar defers for ever.** L6 says "retried next load", which for a
   truncated or corrupt record means never adopted. The residue is bounded (one recording + one
   sidecar, reachable by Settings' discard) and it is strictly the safer half of the trade: the
   alternative is L6's stated failure — a lossy row that is authoritative for ever. Stated, not hidden.
2. **`claim(id:)` finishes a capture whose recording is GONE**, rather than merely answering nil. That
   is `claimNext`'s existing rule (`readableAudioURL == nil` → full CLEAR order) and applying it in one
   place and not the other would leave an entry whose retry button fails every time it is pressed.

---

## Gates — what I actually ran

DerivedData under `~/Library/Caches/gigaduck-builds/f-queue/{DerivedData,DerivedDataMac,DerivedDataCF}`,
every log written there and grepped for `': error: '` and the verdict strings — never judged from a
tail or an exit code. **No `-configuration` passed anywhere.** No `/tmp`, no bare `rm -rf`.

- **Simulator TCC checked BEFORE trusting any run:**
  `sqlite3 …/6C3FB33E…/data/Library/TCC/TCC.db "select service, client, auth_value from access where
  client='ai.gigaduck.AgentRelay';"` → **no rows**, exit 0. No stale denial.
- **iOS `build-for-testing`** → `ios-bft-1.log`: `grep -c ': error: '` = **0**, `** TEST BUILD SUCCEEDED **`.
- **iOS `test-without-building`**, seven quoted `-only-testing:` flags → `test-2.log`:
  ```
  ** TEST EXECUTE SUCCEEDED **
	 Executed 115 tests, with 0 failures (0 unexpected) in 2.483 (2.550) seconds
  ```
  `grep -cE '\.swift:[0-9]+: error: '` = **0**.

  | Class | Result line |
  |---|---|
  | `PendingRetryDurabilityTests` | `Executed 26 tests, with 0 failures (0 unexpected) in 0.136 (0.142) seconds` (was 21) |
  | `PendingRetryLeaseTests` (**new**) | `Executed 13 tests, with 0 failures (0 unexpected) in 0.075 (0.077) seconds` |
  | `PendingRetryQueueTests` | `Executed 17 tests, with 0 failures (0 unexpected) in 0.035 (0.073) seconds` (unchanged) |
  | `PendingRetryDestinationTests` | `Executed 11 tests, with 0 failures (0 unexpected) in 0.014 (0.016) seconds` (unchanged, not edited) |
  | `PendingRetrySurfaceHandoffTests` | `Executed 9 tests, with 0 failures (0 unexpected) in 1.810 (1.812) seconds` |
  | `WorkVoiceRecoveryTests` | `Executed 27 tests, with 0 failures (0 unexpected) in 0.362 (0.368) seconds` |
  | `HeadlessRetryGuardSpanTests` | `Executed 12 tests, with 0 failures (0 unexpected) in 0.051 (0.054) seconds` |

  **The legacy-caller census in `PendingRetrySurfaceHandoffTests` is green on the unchanged legacy API**
  — I added no production caller of anything.
- **One run died before any test case started** (`test-1.log`): `Simulator device failed to launch
  ai.gigaduck.AgentRelay … Busy ("Application failed preflight checks")`, no `Executed` line at all.
  Retried once with no change to the tree → `test-2.log` green. Reported rather than hidden; other
  agents share this simulator. I did NOT `simctl shutdown all`, deliberately — it would have killed
  their in-flight runs, and one retry was enough.
- **macOS `build -destination 'platform=macOS'`** → `mac-1.log`: `grep -c ': error: '` = **0**, and:
  ```
  ** BUILD SUCCEEDED **
      Signing Identity:     "Apple Development: Peter Krueck (Z4PNDLZK98)"
  ```
  **Signed through the identity override; no `CODE_SIGNING_ALLOWED=NO` fallback needed or used.**
- **`bash scripts/check-storage-seam.sh`** → `✓ storage seam intact — 805 Swift files scanned…`, exit 0.
- **`git diff --check`** → no output, exit 0. The new file: **0 tab lines, 0 trailing-whitespace lines**,
  opens with `// SPDX-License-Identifier: Apache-2.0` + a header comment. `git status --short` for
  `*.xcstrings`, `*.pbxproj`, `Conduck/Configs` and `docs/qa` → **empty**.
- **Warnings: 13 in `PendingRetryStore.swift` on BOTH platforms — the same count and the same single
  pre-existing class e-queue measured** (main-actor-isolated `DefaultsStore` methods called from this
  actor's synchronous locked helpers). **Zero** in all three test files on both platforms. I added no
  warning of any kind.
- **Suite delta from this slice: +18** (`PendingRetryLeaseTests` NEW 13, `PendingRetryDurabilityTests`
  21 → 26). **The watch target compiles none of my files** — `grep -c` for `PendingRetryLeaseTests` in
  `project.pbxproj` is 0, and `PendingRetry` appears nowhere in that file, so no
  `membershipExceptions` list can name it; the synchronized group covers the new test source and **no
  `.pbxproj` edit was needed or made**.
- **NOT run, plainly: the full iOS suite and the watch suite.** Neither is in my brief, no watch sim is
  assigned, and three other f-agents were editing this tree throughout (four of their files are
  modified in `git status` at end of task) — a full run would report their in-flight state as mine.
- Build cache removed at end of task with `.claude/scripts/clean-build-cache.sh f-queue` → `removed:
  f-queue`; every log quoted above went with it, and so did the counterfactual tree.

## What I did NOT verify, plainly

- **Two PROCESSES on one container are still untested** (e-queue's O-5 / Gate 2). The new cases drive
  the real `flock`, the real directory scan and the real write orders, but from one process.
- **`.completeFileProtection` before first unlock is reasoned, not measured** — a simulator has no lock
  state. The unreadable-sidecar cases simulate it with a corrupt record, which is the same code path
  through `readSidecar` and the only one a unit test can reach.
- **No renewal timer exists anywhere yet.** The store can be renewed; nothing renews it (§Requests 2).
- **No UI, no screen, no device.**

---

## Catalog

**Keys I ADDED in source: NONE.** **Keys I made DEAD: NONE.** No `.xcstrings` file was opened. This
store carries no user-facing copy at all — nothing for the serial copy agent to splice from this slice.

---

## Requests

1. **O-1 is now ONE edit in TWO files, and neither is mine.** `claim(id:duration:)` exists and is
   tested. What remains is:
   ```swift
   // in PendingRetryStore.swift — protocol PendingRetryQueueWriting
   func claim(id: UUID, duration: TimeInterval) async -> PendingRetryClaim?
   func renew(_ claim: PendingRetryClaim) async -> Bool
   func confirmOwnership(_ claim: PendingRetryClaim) async -> Bool
   func release(_ claim: PendingRetryClaim) async
   @discardableResult func clear(_ claim: PendingRetryClaim) async -> Bool
   ```
   plus the same five on `WorkVoiceRecoveryTests.RecordingRetryLane`. I did NOT widen the protocol
   myself: its declaration is in my file but its only other conformer is in a test file I do not own,
   and widening it alone breaks the build for every parallel agent. **Do both halves in one edit.**
   Once `InAppAudioRecorder`, `PendingRetryGuard` and `ConverseIntent` address their captures through
   `claim(id:)`, `load()`, `clear(ifCurrentID:)` and `recordPublicationState(id:)` have no production
   caller and go, and the census allowlist empties with them (L5).
2. **Every surface that transcribes must renew (L2), and nothing does yet.** A timer no slower than
   every 120 s while work is live, stopped on every exit. Without it a transcription longer than the
   horizon still loses the reservation to whoever asks next — the store now makes that survivable (the
   capture and its recording are both still there, and an unstolen holder still confirms) but not
   impossible.
3. **The headless lane takes `claim(id: captureID, duration: 90)`** (L4), not the default. Its deferred
   notice fires at 90 s telling the person to tap and retry; a ten-minute hold from a process that may
   already be dead is exactly the state `ConverseIntent.swift:766-773` describes and refuses to create.
   With `claim(id:duration:)` that refusal is no longer necessary, and `recordRecoveryState`'s durable
   `.published` write (`ConverseIntent.swift:825`, currently the `recordPublicationState(id:)` form)
   becomes a token-checked write the store honours — the residual hazard O-1 names.
4. **Owner of `MenuBar/DictationService.swift`** — e-queue §Requests 3 still stands unchanged:
   `preserveForRetry` builds `…/pending_retry_audio.m4a` (`:706`) as bookkeeping only. It creates no
   file, so there is no hazard today, but that name is the pre-id-scoped recording and the
   reconciliation now treats it specially in one more way (the duplicate-proof reclamation). Point it at
   the id-scoped name when you touch the file.
5. **Nobody undo these** — each is pinned by a case measured red on the counterfactual. e-queue's seven
   and d-retry's seven all still hold; these are new:
   - **A readable sidecar outranks its index row.** Reverting it puts a crashed `.phaseOneFailed` row
     back in charge of a published card.
   - **An unreadable sidecar DEFERS.** Reconstructing the entry from the filename is r6a#3's second
     half exactly, and the lossy row it writes can never be repaired.
   - **The expiry sweep skips a live reservation** — and only a live one. Removing the skip deletes a
     recording mid-transcription; removing the "only a live one" makes the clock decorative.
   - **`claim(id:)` answers for the id it was given**, and refuses while another lease is live.
   - **The fixed-name recording is deleted BEFORE the pointer is retired**, and its recognition does not
     depend on the capture being absent from the index. Either reversal leaks the recording for ever.
   - **The fixed name is reclaimed only on byte equality.** Size and mtime would be cheaper and would
     eventually delete a recording that exists nowhere else.
   - **Ownership is checked by TOKEN, and `confirmOwnership` mutates nothing.**

---

## Refuted

**None.** All three findings were traced against the current tree by call path before any code changed,
and all three hold exactly at the anchors quoted. The decided design directions (L1, L2, L3, L6) were
implementable as specified; the two places the letter moved are recorded as decisions rather than
refusals — the reservation's duration living in the lease instead of the claim (§Decisions 1, forced by
K2's claim shape and by two foreign construction sites), and the expiry exemption that L1–L3 do not
mention but without which a renewable reservation still loses its recording at 600 s (§Decisions 2).

One qualification, stated as such: r6a#2's fix is only HALF landed after this wave. The store can now be
renewed and addressed by id; no surface does either yet (§Requests 2, 3). Until they do, a transcription
longer than ten minutes still hands the capture to whoever asks next — but it no longer loses the
recording, and the original holder can still confirm and finish if nobody overtook it.

---

## Founder QA — device-only checks this change needs

These ADD to e-queue's six and d-retry's seven, which all still apply. Two of them are the same upgrade
step seen from a different side, so do them in one sitting.

1. **A transcription longer than ten minutes.** On a deliberately terrible connection (or a custom STT
   endpoint that stalls), start a Work retry and let it run past ten minutes. The recording must still
   be there afterwards — before this change the launch sweep could delete it mid-transcription — and
   the retry card must not have quietly emptied while the spinner was up.
2. **Force-quit mid-retry, then retry immediately.** Reopen and press retry at once. It is expected to
   say nothing is waiting for up to ten minutes (the reservation is honoured), and then to offer the
   capture again. What must NEVER happen is two cards or two transcripts for one recording.
3. **The upgrade, from a container the fold half-finished.** Anything left of
   `pending_retry_audio.m4a` on the device is now reclaimed on first launch only if its bytes are
   already parked under a capture id. After the first launch of this build, Settings → Diagnostics must
   report the same number of waiting recordings as before it, and no recording may have vanished.
4. **Two surfaces, one recording (macOS), while one is slow.** Start the menu-bar retry, let it run,
   then press the main window's retry. The second must refuse or wait — never start a second
   transcription of the same recording — and when the first finishes, exactly one card appears.
5. **A Shortcut capture and an in-app capture failing at once.** Both must still be listed in
   Diagnostics afterwards, and finishing either must not disturb the other.

---

## Settled facts — one sentence each, for whoever writes the docs

- The small record kept beside each waiting recording is the authority: when it and the queue disagree,
  the queue is corrected from the record, because the record is always written first and a disagreement
  can only mean the app stopped between the two.
- A record the app cannot read — the device has not been unlocked since it restarted, or the file was
  cut short — leaves its recording waiting untouched and is tried again on the next launch, rather than
  being replaced by a guess that would then be permanent.
- A retry surface reserves the recording it is working on and extends that reservation while it works,
  so a transcription that takes longer than usual cannot have its recording taken or deleted underneath
  it.
- The ten-minute limit on how long a recording waits for its words applies only when nobody is working
  on it; a recording somebody is finishing is never retired on the clock.
- A lane that made a recording asks for that recording by name rather than for whichever is newest, and
  it can hold it for a short time — ninety seconds where the app may be shut down at any moment —
  instead of the ten minutes a person's retry button takes.
- Before a surface hands over the words it recognised, it checks that the recording is still its own;
  if another surface took it over, it stops rather than writing the same words twice.
- The recording a build before capture identifiers parked is deleted only once its bytes are provably
  parked under an identifier, and it is deleted before the last thing that names it — so an interrupted
  upgrade can never leave it stranded in the container for ever.
