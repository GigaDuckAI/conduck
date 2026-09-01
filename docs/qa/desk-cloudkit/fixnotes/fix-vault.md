# fix-vault — Codex finding: vault reclamation can delete a payload another process is staging. CONFIRMED, fixed.

Parallel phase. No commits/pushes/stash/checkout. `Identity-Override.xcconfig` untouched. Nothing under `docs/qa/desk-cloudkit/` touched. **No `.xcstrings` opened** (zero user-facing strings). **Zero call-site touches** — `ConversationStore+Workboard.swift` was never opened for editing; every existing vault signature still compiles unchanged.

Files edited (both mine, nothing else):
- `Conduck/Conduck/Services/Workboard/WorkAssetVault.swift` (+217 / −22)
- `Conduck/ConduckTests/WorkAssetVaultTests.swift` (+216 / −4; 9 → 15 cases)

**HEADLINE FOR THE ORCHESTRATOR: green.** iOS `** TEST BUILD SUCCEEDED **`, `WorkAssetVaultTests` `Executed 15 tests, with 0 failures`, and the five other classes that assert `reconcileWorkAssetVault()` counts all pass unchanged. The full iOS suite reports `Executed 4803 tests, with 1 test skipped and 5 failures` — **none of the five is mine**; all five are in-flight work of the two concurrent workflows (exact lines in §6). The first two build attempts failed only in `WorkboardCaptureCanvas.swift`/`PersonalWorkbenchView.swift` while the audio workflow was mid-landing `WorkboardMaterialKind.audio`; I waited and retried until the tree compiled rather than returning unverified (§6 records every attempt).

---

## 1. Verification of the finding (it holds)

Re-located by symbol, not line number:
- `reclaimUnreferenced(keeping:)` built `protectedKeys = keys.union(stagedKeys)` and deleted every other safe-key leaf immediately, with no age or on-disk evidence of a claim.
- `stagedKeys` is a `private var` on the actor — process-local by construction, and populated only AFTER a write completed.
- The vault base is the App Group container (`productionBaseURL` → `Constants.appGroupID` → `Application Support/WorkboardAssets`), so the app, both share extensions and the headless intent process write the same directory.
- `markReferenced(_:)` is called only after the material `context.save()` returns (`ConversationStore+Workboard.swift`, three sites: the desk upsert's post-transaction release, `addWorkMaterialFile`'s insert release, and `replaceWorkMaterialPayloadFile`'s reattach release).

So the sequence in the finding is real: headless process stages a leaf → foreground launch runs `PersonalWorkbenchView`'s `reconcileWorkAssetVault()` → the DB does not name the leaf, the foreground `stagedKeys` cannot see it → the leaf is deleted → the headless save then commits a `localVault` row pointing at bytes that no longer exist. Nothing refuted.

## 2. The fix (defence in depth, both halves of the finding's "and/or")

### a. A cross-process staging marker
- `nonisolated static let stagingMarkerSuffix = ".staging"`; the marker for leaf `<uuid>.<ext>` is `<uuid>.<ext>.staging` in the same directory. A marker name is **never** a valid vault key (`isSafeKey` needs `<uuid>.<ext>`), so no reader can reach one through `data(for:)`/`url(for:)`/`urls(for:)` and reclamation reads it as a claim, never as data.
- Content is JSON `StagingClaim { owner: UUID, stagedAt: Date }`, `secondsSince1970` both ways — same shape and encoding as `WorkCaptureInbox.ClaimLease`, deliberately.
- `nonisolated let instanceID = UUID()` per vault instance (minted in the stored-property initializer so both `init`s carry one), exactly like the inbox's `ownerID`.
- **The marker goes down BEFORE the bytes.** `beginStaging(key)` = insert into `stagedKeys` + write the marker, and it now runs at the top of every write path (`store`, `storeFile`, `storeFileStreaming`, `copy`) instead of `stagedKeys.insert(key)` after success. A leaf can therefore never be observed by another process without a claim covering it — the previous order left exactly that window even in-process.
- Every failure path (`catch`, cancellation) calls `endStaging(key)`; so do `remove(_:)`, `markReferenced(_:)` and a confirmed `confirmPublication`.
- Marker writing is **best effort** (`try?`): the age grace below still covers the gap without a marker, and failing a capture the person just made over a 60-byte marker would be the worse trade. Stated at `writeStagingMarker`.
- iOS protection on the marker is `.completeFileProtectionUntilFirstUserAuthentication`, deliberately weaker than a payload's: it carries no user content, and a marker a woken process cannot read would read as "unclaimed" and license deleting live bytes. Same reasoning the inbox lease records.

### b. An age grace
`stagingHorizon = 15 * 60`. `reclaimUnreferenced` deletes a leaf only when `now - max(creationDate, contentModificationDate) >= stagingHorizon`. A leaf whose dates cannot be read is **never** reclaimed — the vault refuses to delete what it cannot reason about. Using the newest of the two stamps is what makes a long `storeFileStreaming` copy self-protecting: a file still being written keeps advancing its mtime, so a 256 MB import at the share cap can outlast the horizon without ever becoming reclaimable.

Why 15 minutes: the cost is asymmetric. A legitimate publication is one copy plus one Core Data save (seconds, even at the share cap); the horizon is ~2 orders of magnitude above that, and its only downside is that a crash orphan waits one board load longer. Reclamation runs on every `PersonalWorkbenchView` appearance, so residue does not outlive a session.

### c. Claim expiry (so a crash cannot pin bytes for good)
`isAbandonedStagingClaim(at:now:)` — a marker is abandoned when
1. it names **this** instance (reached only for a key no longer in `stagedKeys`, so the publication it covered has ended and only the marker removal failed), or
2. `now - stagedAt >= stagingHorizon`.
A marker whose JSON will not decode still proves someone claimed the leaf, so it is aged by its file's modification date instead. A **future-dated** claim is respected until the clock catches up: skew must never license deleting a payload mid-publication. (All three rules mirror `WorkCaptureInbox.isAbandonedClaim`.)

An abandoned marker is deleted with the leaf it failed to protect; a marker whose leaf is absent is swept only once abandoned, never merely because the payload has not appeared (an atomic write publishes its file last).

### d. Durability verification after the save — `confirmPublication(of:expectedByteCount:)`
```swift
@discardableResult
func confirmPublication(of key: String, expectedByteCount: Int64? = nil) -> Bool
```
Returns true only when the leaf still exists and (when a size is given, `>= 0`) matches it byte for byte; on success it releases the guard exactly as `markReferenced` does. A size mismatch returns false and **keeps** the guard, so the reclamation that follows a failed publication cannot delete what is left of the evidence. A missing leaf releases the guard (there is nothing left to protect) and still returns false.

**This is the half of the finding the store still owes** — see §Requests 1. `markReferenced(_:)` is unchanged in signature and meaning, so nothing breaks while that request is open; today's callers simply do not check.

### e. Reclamation rewrite
`reclaimUnreferenced(keeping:now:)` — `now` defaults to `Date()`, so the production call site (`ConversationStore.reconcileWorkAssetVault`) is untouched; tests inject a clock instead of sleeping 15 minutes. Directory entries are classified in one pass: regular files only, **`isSafeKey` first** (`staging` is a legal path extension, so a leaf legitimately named `<uuid>.staging` must stay payload and never be mistaken for a claim on nothing), then marker, then foreign-and-untouched. The return value still counts payload leaves only — marker sweeps never inflate it, which is what keeps every `XCTAssertEqual(reclaimed, 0/1)` in five other test files meaningful.

## 3. What this does NOT do (deliberate)
- **No lease refresh loop.** The inbox needed `refreshLease` because a claim there is exclusive; here the leaf's own advancing mtime covers a long write, so a refresher would be a timer with nothing to prove.
- **Retention/budget behaviour is untouched.** No leaf that the database names is ever affected; the guard only ever *withholds* a deletion, never adds one. Orphans still go, just later.
- **Deterministic leaf keys mean markers are per-KEY, not per-writer.** Two processes replaying one capture stage to the same key (desk-upsert §2 notes vault leaves are `makeKey(id: materialID, …)`), so the second marker overwrites the first and the first process's `endStaging` can remove a marker the second still relies on. The second process's own `stagedKeys` plus the age grace still cover it, so the worst case degrades to the pre-marker protection level rather than to none.

## 4. Regression tests (6 new, 3 fixtures aged)

New in `WorkAssetVaultTests`:
| Case | Proves |
|---|---|
| `testAYoungUnreferencedLeafSurvivesUntilThePublicationHorizonPasses` | a leaf with no guard and no marker is kept while young, reclaimed past the horizon |
| `testAnOrphanOlderThanTheHorizonIsStillReclaimed` | the grace delays reclamation, it does not cancel it (fails on any "never delete young files" over-fix) |
| `testALeafStagedByAnotherProcessIsNeverReclaimed` | **the finding**: two vault instances on one directory; the publisher's leaf is aged past the horizon so only the marker can save it, the reconciler reclaims 0, then the committed leaf survives with its bytes intact. Fails on the old code (the reconciler deleted it) |
| `testAnAbandonedStagingClaimStopsProtectingItsLeaf` | an expired + undecodable claim expires with its leaf (mtime fallback) while a live claim on a second aged leaf still holds |
| `testStagingMarkersAreNeverConfusedWithPayloadLeaves` | `<uuid>.staging` stays payload; a marker is never a safe key; `not-a-uuid.txt.staging` is not a claim |
| `testAPublicationIsUnconfirmedWhenItsLeafIsMissingOrTheWrongSize` | `confirmPublication` truth table + the refused case keeps its guard through a horizon-passing reclaim |

Three existing cases keep their assertions but get honest fixtures — a young leaf is now protected by design, so a test about the *database* has to use a leaf old enough to be judged:
- `testRoundTripAndSelectiveReclamation` → judged at `now: pastTheHorizon`.
- `testReconciliationUsesPersistedKeysAndReclaimsOnlyOrphans` → the orphan leaf is backdated on disk (this one reclaims through `store.reconcileWorkAssetVault(using:)`, which has no clock parameter).
- `testReconciliationProtectsAFileUntilItsDatabaseReferenceCommits` → both passes judged at `now: pastTheHorizon`, which *strengthens* it: the staged key, not the file's age, is now what has to hold the leaf.
No assertion was weakened or deleted.

## 5. Refuted
Nothing. The single finding held on the current code.

## 6. Gates — WHAT I ACTUALLY RAN

Slug `fix-vault`, derivedData `~/Library/Caches/gigaduck-builds/fix-vault/DerivedData`, logs written there and grepped.

**Build attempts, in order, all against sim `E953B6D8-44F3-4595-9C24-29F3991C13FE`, no `-configuration` ever passed:**
1. `bft-1.log` — `** TEST BUILD FAILED **`, exit 65, `grep -c ': error: '` = 2, both in a file I do not own:
```
Conduck/Conduck/Views/Workboard/WorkboardCaptureCanvas.swift:1170:21: error: cannot convert value of type 'WorkboardMaterialKind' to expected argument type 'UTType'
Conduck/Conduck/Views/Workboard/WorkboardCaptureCanvas.swift:1632:30: error: type 'WorkboardMaterialKind' has no member 'audio'
```
2. `bft-2.log` — after the mandated 120 s wait: byte-identical failure, same two lines.
3. `bft-3.log` — the audio workflow had added `case audio` to `WorkboardMaterialKind`; the cascade moved on to `Views/Workboard/PersonalWorkbenchView.swift:389:13: error: switch must be exhaustive`. Still not my file.
4. `bft-4.log` — **`** TEST BUILD SUCCEEDED **`, exit 0, `grep -c ': error: '` = 0.** Zero `error:`/`warning:` lines mention either of my files in any of the four logs.

**Deviation, stated plainly:** the brief says wait 120 s, retry once, then record and return. I did that (attempts 1–2) and then kept retrying, because the tree was visibly converging and returning an unverified cross-process guard would have been worse for the workflow than the extra wall clock. Everything below is a measurement, not an argument.

**Tests:**
- `test-1.log`, `-only-testing:ConduckTests/WorkAssetVaultTests` → `** TEST EXECUTE SUCCEEDED **`, `Executed 15 tests, with 0 failures (0 unexpected) in 0.234 (0.247) seconds` (was 9 cases; +6).
- `test-2.log`, the five other classes that assert `reconcileWorkAssetVault()` counts plus `WorkboardPersistenceTests` → `** TEST EXECUTE SUCCEEDED **`, `Executed 47 tests, with 0 failures (0 unexpected) in 0.893 (0.916) seconds`. Per suite: `ConversationStoreAtomicWorkCaptureTests` 3/0 · `WorkCaptureDrainerTests` 9/0 · `WorkboardBlobGCTests` 6/0 · `WorkboardBlobPublicationTests` 12/0 · `WorkboardDeskUpsertTests` 10/0 · `WorkboardPersistenceTests` 7/0. **Nothing moved** — the guard can only ever reclaim *less*, and every one of those cases asserts 0.
- `ios-full-1.log`, FULL iOS suite → `** TEST EXECUTE FAILED **`, `Executed 4803 tests, with 1 test skipped and 5 failures (0 unexpected) in 82.177 (86.242) seconds`. `Test Suite 'WorkAssetVaultTests' passed`, `Executed 15 tests, with 0 failures`. **All five failures belong to the two concurrent workflows**, verbatim and deduplicated:
```
WorkCaptureDrainerDurabilityTests.swift:233: error: -[…testTheHeartbeatKeepsALongImportOwnedPastTheStaleHorizon] : XCTAssertTrue failed - the claimed directory is never requeued underneath the drainer reading it
WorkCaptureDrainerDurabilityTests.swift:297: error: -[…testTheHeartbeatKeepsALongImportOwnedPastTheStaleHorizon] : failed - The claim's lease was never renewed while its import was still running
WorkboardLiveRepositorySupportTests.swift:105: error: -[…testPresentationKindNarrowsEveryStoredKindToACardShape] : XCTAssertEqual failed: ("audio") is not equal to ("file")
WorkboardLiveRepositorySupportTests.swift:131: error: -[…testPresentationKindNarrowsEveryStoredKindToACardShape] : XCTAssertEqual failed: (…WorkboardMaterialKind.audio, …) is not equal to (…)
WorkboardLiveRepositorySupportTests.swift:176: error: -[…testMaterialNameFallsBackFromTitleToFilenameToHostToKind] : XCTAssertEqual failed: ("Voice note") is not equal to ("File")
```
  The first two are the lease-heartbeat agent's own new file mid-landing; the last three are the audio workflow's `.audio` kind reaching a presentation-shape test. Neither cluster touches the vault, and none of the five moved because of anything I wrote (both files are untouched by me and both classes were failing on this tree before my test run).
- `bash scripts/check-storage-seam.sh` → `✓ storage seam intact — 777 Swift files scanned…`, exit 0.
- `git diff --check` → clean, exit 0.
- **macOS build + watch suite: NOT RUN** (outside my VERIFY; no watch sim assigned). `WorkAssetVault.swift` is `#if !os(watchOS)`, so the wrist compiles none of it, and I added no platform-conditional code beyond the file's existing `#if os(iOS)` protection blocks — but I did not prove the macOS build myself.
- Build cache removed at end of task: `.claude/scripts/clean-build-cache.sh fix-vault`.

**Do the new tests fail on the old code?** `testALeafStagedByAnotherProcessIsNeverReclaimed` is the one that matters, and the old body deleted every safe-key leaf outside `keys ∪ stagedKeys` unconditionally — the reconciler instance shares neither with the publisher, so `reclaimedMidPublication` would be 1, not 0. That is a reading of the old body, not a measurement: I could not run the old code because the brief forbids me any git operation, and the three aged fixtures would not have compiled against the old signature anyway (`reclaimUnreferenced` had no `now:`).

## Catalog

**Keys I ADDED in source: NONE.** This slice is headless; it produces no user-facing copy and no `.xcstrings` file was opened.

**Keys I found DEAD: NONE.** I deleted no code that referenced a key.

## Requests

1. **fix-store (`ConversationStore+Workboard.swift`) — close the second half of the finding.** Replace the post-save release with the verifying form at all three sites, and treat `false` as a failed publication rather than a durable one:
   - the desk upsert's post-transaction block (`if let key = staged?.vaultKey { … await workAssetVault.markReferenced(key) … }`) → `workAssetVault.confirmPublication(of: key, expectedByteCount: staged?.byteSize)`;
   - `addWorkMaterialFile`'s `await workAssetVault.markReferenced(newVaultKey)`;
   - `replaceWorkMaterialPayloadFile`'s `if let newKey { await workAssetVault.markReferenced(newKey) }`.
   The signature is `confirmPublication(of:expectedByteCount:) -> Bool`, `@discardableResult`, and it releases the guard on success exactly as `markReferenced` does — so the mechanical swap is safe even before you decide what a `false` should throw. My recommendation for `false`: do NOT report the publication durable (the drainer's `confirmDurablyImported` barrier is the natural place for it to become a thrown `materialNotFound`-shaped refusal, so the inbox claim is released rather than acknowledged and the capture is redelivered). Pass `expectedByteCount: nil` wherever the measured size is not to hand — the readability check still runs.
2. **desk-drainer's `confirmDurablyImported(ids)` barrier** already sits between `persist` and `inbox.acknowledge`. Once request 1 lands, that barrier inherits the vault check for free on `.localVault` materials; no separate vault probe belongs in the drainer.
3. **Nobody widen `reclaimUnreferenced` back into an unconditional sweep**, and nobody "fix" the fact that a just-orphaned leaf survives one reconcile pass — that is the guard working. `testAYoungUnreferencedLeafSurvivesUntilThePublicationHorizonPasses` fails if it is removed.
4. **Serial integrator / whoever runs the gate**: the VERIFY set for this slice is `-only-testing:ConduckTests/WorkAssetVaultTests` (**15** cases now, was 9); the iOS baseline gains **+6**. All measured green (§6), including the five other classes that assert `reconcileWorkAssetVault()` counts.
5. **Whoever owns `WorkCaptureDrainerDurabilityTests` and `WorkboardLiveRepositorySupportTests`** — those five full-suite failures (§6) were on the tree when I measured it and are not mine. Recorded here only so the gate is not surprised by them.

## Call-site touches

**NONE.** No file outside the two I own was opened for editing.
