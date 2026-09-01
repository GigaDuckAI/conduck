# fix-drainer — Codex findings on `WorkCaptureDrainer` (1 critical + 2 major). BOTH CONFIRMED, both fixed, gates green.

Parallel phase. No commits/pushes/stash/checkout. `Identity-Override.xcconfig` untouched. **No `.xcstrings` file opened.** Nothing under `docs/qa/desk-cloudkit/` touched. No mirror triplet touched. No file outside my ownership list opened for editing.

I edited exactly TWO files:
- `Conduck/Conduck/Services/Workboard/WorkCaptureDrainer.swift` (+165 / −45)
- `Conduck/ConduckTests/WorkCaptureDrainerDurabilityTests.swift` (NEW, 5 cases) — took the "one new file" option rather than growing the existing 9-case class: every case here needs the import hold, an injected clock, or a payload sized to pick a storage lane, and `WorkCaptureDrainerTests`' helpers are `private`. Synchronized `ConduckTests` group → **no pbxproj edit** (confirmed: it compiled and ran without touching `project.pbxproj`).

`WorkCaptureDrainerTests.swift` is **unmodified** — I added no case to it, weakened nothing in it, and all 9 still pass.

---

## 1. Verification of the findings (FIX PROTOCOL step 1)

Both re-located by symbol against the current tree (`39d19d1` + the wave's uncommitted work), not by the cited line numbers.

| Finding | Verdict | Evidence at time of check |
|---|---|---|
| critical + major #3 — `confirmDurablyImported` proves ids, not bytes | **CONFIRMED** | `private func confirmDurablyImported(_ materialIDs: [UUID])` did exactly `Set(materialIDs).isSubset(of: deskMaterialIDs())` and nothing else; `PersistedCapture` carried only `materialIDs`. The `BYTE-SYNC EXTENSION POINT:` comment was still the unimplemented placeholder desk-drainer.md §2 left. |
| major #2 — no `refreshLease` caller | **CONFIRMED** | `grep -rn refreshLease --include='*.swift' Conduck/` → exactly two hits: the declaration in `WorkCaptureInbox.swift` and `WorkCaptureInboxLeaseTests.swift:174`. Zero production callers. |

Nothing refuted; no `## Refuted` section.

## 2. (a) The durable-readability barrier

**`PersistedCapture` now carries `payloadBearingIDs: Set<UUID>`** — the ids for which `persist` passed `sourceFileURL:` to `upsertDeskMaterial`, i.e. the cards whose bytes came out of the claimed directory. Notes, shared text and links are not in the set: their whole content is in the row, so requiring a payload of them would refuse every valid capture (there is a test for that direction too).

**`confirmDurablyImported(_ capture: PersistedCapture)`** — ONE desk fetch, then per id:
- row absent → `WorkboardStoreError.materialNotFound` (unchanged behaviour)
- payload-bearing and `!material.hasPayload` → **`WorkboardStoreError.materialPayloadUnavailable`**

Either throw lands in the existing `catch`, which calls `inbox.release(claim)` and rethrows. **Nothing is acknowledged and the queue copy is never deleted.**

**Why `hasPayload` rather than a new probe.** `WorkMaterialRecord.hasPayload` is `availability == .synced || .availableLocally`, and availability is decided by `ConversationStore`'s single batch pass (availability.md §1–2): `.syncedPayload` → complete blob row required; `.localVault` → vault leaf required; `.metadataOnly` → exempt. That is *exactly* the predicate the task specifies, resolved for the whole capture in one fetch that already batches the vault hop and the blob-completeness fetch. So this **consumes** `WorkMaterialBlobRecord.isComplete`, never restates it (availability.md §Requests 5), and adds **no per-material `await` loop** (desk-drainer.md §Requests 1's explicit prohibition). blob-io.md §Requests 1's shape is satisfied without touching the store at all.

`deskMaterialIDs()` became `deskMaterials() -> [WorkMaterialRecord]`; `persist` maps it to ids for the replay check. Same one fetch as before, richer projection, no extra round trip.

The `BYTE-SYNC EXTENSION POINT:` placeholder comment is gone — replaced by the constraint the code now enforces.

## 3. (b) The lease heartbeat

**`withLeaseHeartbeat(for:_:)`** wraps the whole per-claim region. A `Task.detached(priority: .utility)` loop sleeps `leaseHeartbeatInterval` and calls `inbox.refreshLease(claim, now: now())`; `defer { heartbeat.cancel() }` stops it on **every** exit path — success, barrier throw, persistence throw, acknowledge throw, release throw, cancellation.

The region now spans `persist → confirmDurablyImported → acknowledge`, **and the `release` in the catch**, because a release moves the very files the horizon protects. Structurally the old `do/catch` moved *inside* the wrapper; the counter arithmetic moved out. `drainAvailableCaptures()`'s signature, `Report`'s four fields and every call site are unchanged.

| Decision | Why |
|---|---|
| `static let defaultLeaseHeartbeatInterval: Duration = .seconds(60)` | 5 renewals per 300 s horizon: four consecutive misses still leave the claim covered. Pinned by a test so nobody raises it toward the horizon silently. |
| `Task.detached`, not `Task {}` | Isolation inheritance would put the renewal on the drainer's own executor — the one a long import occupies. The beat is a hop onto the inbox actor and nothing else. |
| Errors swallowed, beat continues | `.staleClaim` means the claim is gone and the import's own next inbox call surfaces it; a momentarily unreadable marker must not disarm the protection for the rest of a long import. Stopping on the first error is the worse failure. |
| Post-completion ticks are inert | After `acknowledge`/`release`, `requireActive` throws before anything is written, and `writeLease` into a removed directory fails anyway. Verified by reading `WorkCaptureInbox`, not assumed. |
| `now: @Sendable () -> Date = Date.init` init param | The horizon is five minutes and no suite can wait one. Same shape the inbox already uses (`claimNext(now:)`, `reconcile(now:)`), defaulted so no call site moves. |

## 4. The one test seam I added

`#if CONDUCK_TESTING` `importHoldForTesting` + `_setImportHoldForTesting(_:)`, awaited between `persist` and the barrier, with a "WHY IT HAS TO EXIST" header in the blob-io precedent. Nil on every production path. It exists because **both** new properties live in a window a bounded envelope crosses in milliseconds: the heartbeat's claim is about an import that outlives the horizon, and the barrier's claim is about a payload that disappears *between the write and the acknowledgement*. Without it neither could be staged — only raced.

## 5. Tests + counts (exact lines)

Slug `fix-drainer`, derivedData `~/Library/Caches/gigaduck-builds/fix-drainer/DerivedData`, every log written there and grepped. No `-configuration` passed anywhere. Sim `C26F4ECE-16AC-40B7-8D6A-BBF82B5BBA5D`.

- iOS `build-for-testing` → `bft-10.log`: `grep -c ': error: '` = **0**, `** TEST BUILD SUCCEEDED **`. **Zero warnings in either of my files.**
- **The VERIFY set + insurance** (`test-4.log`, `** TEST EXECUTE SUCCEEDED **`, total `Executed 101 tests, with 0 failures (0 unexpected) in 2.021 (2.045) seconds`):

| Class | Result |
|---|---|
| `WorkCaptureDrainerDurabilityTests` | `Executed 5 tests, with 0 failures (0 unexpected) in 0.142 (0.144) seconds` |
| `WorkCaptureDrainerTests` | `Executed 9 tests, with 0 failures (0 unexpected) in 0.344 (0.346) seconds` |
| `WorkCaptureInboxLeaseTests` | `Executed 14 tests, with 0 failures (0 unexpected) in 0.059 (0.062) seconds` |
| `WorkCaptureInboxTests` | `Executed 30 tests, with 0 failures (0 unexpected) in 0.132 (0.138) seconds` |
| `WorkCaptureRefreshCoordinatorTests` | `Executed 6 tests, with 0 failures (0 unexpected) in 1.014 (1.016) seconds` |
| `WorkboardAvailabilityTests` | `Executed 9 tests, with 0 failures (0 unexpected) in 0.078 (0.080) seconds` |
| `WorkboardBlobGCTests` | `Executed 6 tests, with 0 failures (0 unexpected) in 0.058 (0.060) seconds` |
| `WorkboardBlobPublicationTests` | `Executed 12 tests, with 0 failures (0 unexpected) in 0.111 (0.113) seconds` |
| `WorkboardDeskUpsertTests` | `Executed 10 tests, with 0 failures (0 unexpected) in 0.083 (0.085) seconds` |

- `git diff --check` → clean, exit **0**. `bash scripts/check-storage-seam.sh` → `✓ storage seam intact — 777 Swift files scanned…`, exit **0**.
- **Suite delta: +5 iOS executed.** No assertion anywhere was weakened, deleted or narrowed.
- **NOT run:** macOS build, full iOS suite, watch suite. My changed file is `#if !os(watchOS)`, my test file is test-bundle only, and neither contains platform-conditional code — but I did not prove the macOS build myself, and the tree was being edited by three other agents throughout, so a full-suite number from me would have been theirs, not mine.
- Build cache removed: `.claude/scripts/clean-build-cache.sh fix-drainer` → `removed: fix-drainer`. **The logs no longer exist**; re-run if you need them.

### The 5 new cases, and why none is vacuous

| Case | Asserts | Fails on the old code because |
|---|---|---|
| `testAPendingSyncedCardBlocksAcknowledgementAndKeepsTheQueueCopy` | the blob rows are deleted inside the hold → drain throws `.materialPayloadUnavailable`; card is `.syncedPayload` / `.syncedPending` / `hasPayload == false`; `pendingCount == 1`; the queue file is byte-identical. **And it asserts the desk holds BOTH ids** — the exact condition the old id-subset check accepted | the old barrier's predicate is satisfied (both ids present), so it would acknowledge and delete the last copy of the bytes |
| `testAMissingVaultLeafBlocksAcknowledgementAndKeepsTheQueueCopy` | payload sized `workboardSyncCeilingBytes + 1` takes `.localVault`; its leaf is removed inside the hold → `.materialPayloadUnavailable`; card `.unavailableOnThisDevice`; `pendingCount == 1`; queue bytes intact; same both-ids-present assertion | same reason, vault lane |
| `testACaptureWithoutBytesStillAcknowledges` | note + text + url → 3 `.metadataOnly` cards, `pendingCount == 0` | guards the *other* direction: a barrier that demanded a payload of every card would refuse every note capture |
| `testTheHeartbeatKeepsALongImportOwnedPastTheStaleHorizon` | import parked in the hold, clock advanced to `horizon + 60`; an independent second `WorkCaptureInbox` reconciling at `horizon + 61` reports `respectedLeaseCount == 1` / `releasedClaimCount == 0`, its `claimNext` returns nil, the claim directory survives; then the owner completes and consumes the queue | with no renewal the marker keeps its claim-time stamp, so that reconcile requeues the directory (`releasedClaimCount == 1`) out from under a live import |
| `testTheHeartbeatIntervalLeavesRoomForMissedRenewals` | `defaultLeaseHeartbeatInterval > .zero` and `× 4 < .seconds(staleClaimHorizon)` | pins the "safely below" property no behavioural test can see |

**Honesty note on the counterfactual.** I did NOT run the tests against a reverted drainer to watch them go red: temporarily weakening `confirmDurablyImported` in a tree three other agents were building against would have made my file the source of somebody else's confusing red run. The non-vacuity argument above is instead *inside* the tests — both barrier cases assert that every id the capture wrote is on the desk, which is precisely the predicate the old code checked and passed.

## 6. Two things I got wrong first, recorded because they will bite the next reader

1. **`WorkCaptureInbox` changed under me mid-run.** `fix-inbox` landed generation-scoped claim directories (`<envelopeID><sep><epochSeconds><sep><generation>`), `activeClaims` keyed by generation, and a `generation` field on `ClaimLease`. My first test build hardcoded `processing/<envelopeID>/` and found nothing. **Do not reconstruct a claim path** — my helper now lists `processing/`'s children instead. `refreshLease(_:now:)`'s signature was unaffected, so the production change needed nothing.
2. **A lease timestamp does not compare exactly across the JSON round trip.** `refreshedAt` is `.secondsSince1970`, so `lease.refreshedAt >= writtenInstant` can be false for the very write that produced it. The test now asserts the property reconciliation actually asks — *does this marker still cover instant X* — which is both robust and closer to the thing under test.

## 7. Build blockage I hit (not mine, reported per the parallel rule)

Between `bft-4` and `bft-7` (~25 min) the shared target would not compile, in a file I do not own:
```
Conduck/Conduck/Views/Workboard/WorkboardCaptureCanvas.swift:1170:21: error: cannot convert value of type 'WorkboardMaterialKind' to expected argument type 'UTType'
Conduck/Conduck/Views/Workboard/WorkboardCaptureCanvas.swift:1632:30: error: type 'WorkboardMaterialKind' has no member 'audio'
```
Cause: the canvas referenced `WorkboardMaterialKind.audio` before `case audio` existed in `ViewModels/WorkboardViewModel.swift`. I waited past the mandated 120 s and retried four times rather than return unverified; it cleared on its own once `case audio` landed, and every number in §5 comes from after that. **I edited nothing to work around it.**

---

## Call-site touches

**NONE.** `drainAvailableCaptures()` kept its signature and `Report` kept all four fields, so `WorkboardLiveRepository.drainCaptures()` and `WorkCaptureRetryCoordinator.publish` needed no edit — neither file was opened. The two new `init` parameters are defaulted.

---

## Catalog

**Keys I ADDED in source: NONE.** This slice adds no user-facing copy — the barrier and the heartbeat are both headless, and `WorkboardStoreError.materialPayloadUnavailable` is a pre-existing case whose copy (if any) is decided elsewhere.

**Keys I found DEAD: NONE.** I deleted no code that referenced a key. The five keys desk-drainer.md listed as live in this file are all still live and still reachable: `workboard.capture.note` · `workboard.capture.sharedText` · `workboard.capture.image` · `workboard.capture.webPage` · `workboard.capture.file`.

**No `.xcstrings` file was opened.**

---

## Requests

1. **`fix-inbox` / whoever owns `WorkCaptureInbox.swift` — nothing is owed, but two facts are now load-bearing for me.** (a) `refreshLease(_:now:)` has a production caller as of this slice; its "callers that finish inside the horizon never need it" doc line is still true but no longer describes the only caller. (b) The heartbeat calls it on a cadence and **relies on a refusal being cheap and side-effect-free**. If a future `refreshLease` gains a destructive failure path (e.g. dropping the claim on a filesystem hiccup rather than only on a proven takeover), tell me — the beat swallows errors by design and would keep calling into it.
2. **Serial integrator — the drainer's two new `init` parameters are test seams with production defaults.** `leaseHeartbeatInterval` and `now` are defaulted, so no call site moved. Do not "tidy" them away: without an injectable clock the heartbeat cannot be tested at all (the horizon is 5 minutes), and `defaultLeaseHeartbeatInterval` is asserted against `WorkCaptureInbox.staleClaimHorizon` by `testTheHeartbeatIntervalLeavesRoomForMissedRenewals`.
3. **Nobody widen the barrier to a per-material probe.** `confirmDurablyImported` reads the desk ONCE and consumes `hasPayload`. A loop of `fetchWorkMaterial`/`vault.contains` per id is the shape plan §C removed elsewhere, and `WorkboardAvailabilityTests.testAvailabilityIsResolvedOncePerFetchRatherThanOncePerCard` guards the store side of it.
4. **Nobody move `acknowledge` earlier.** It is still the last statement of the import, now after a barrier that proves bytes rather than ids (inbox-lease.md §Requests 1's contract, strengthened). A capture that fails the barrier is released, and its deterministic material ids make the replay idempotent — the card that already landed is repaired, not duplicated.
5. **Docs agent — one fact is now settled by code.** The queue is consumed only when every card the capture wrote is readable on this device: a complete blob row on the synced lane, a present leaf on the vault lane, nothing required of a metadata-only card. A capture whose payload does not read back goes **back into the queue** rather than becoming a card with no bytes behind it. And a long import keeps its claim by renewing a filesystem lease, so the app and a headless intent process cannot both drain one capture.
6. **Founder QA (Gate 2) — one item to add.** Share a large file (above 30 MB, so it takes the device-local vault) from another app while the device is busy, and confirm it appears on the desk exactly once and opens. That exercises both fixes at once: the vault lane's readability check and a drain long enough to need a renewal. A capture that *disappears* from the share sheet without reaching the desk is the failure this slice is meant to make impossible.
7. **Orchestrator — expect +5 on the iOS executed count** from this slice (new class `WorkCaptureDrainerDurabilityTests`). `WorkCaptureDrainerTests` stays at 9; `WorkCaptureInboxLeaseTests` was at 14 when I ran it (fix-inbox's +5, not mine). Full iOS, watch and macOS unrun by me.
