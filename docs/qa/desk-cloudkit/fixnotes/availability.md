# availability — plan §C "availability proves completeness" (Codex #7). DONE.

Serial phase. No commits/pushes/stash/checkout. `Identity-Override.xcconfig` untouched. Nothing under `docs/qa/desk-cloudkit/` touched. **No `.xcstrings` file opened** (I added zero string keys — see §Catalog).

I edited exactly FIVE files, all mine:
- `Conduck/Conduck/Services/ConversationStore+Workboard.swift` (projection + both fetch paths)
- `Conduck/Conduck/Services/Workboard/WorkboardLiveRepository.swift` (two visibility changes + one comment)
- `Conduck/Conduck/Services/Workboard/WorkAssetVault.swift` (header only)
- `Conduck/Conduck/Views/Workboard/WorkboardCaptureCanvas.swift` (desk banner)
- `Conduck/ConduckTests/WorkboardAvailabilityTests.swift` (new, 9 cases)

**Headline: iOS 4756 executed / 1 skip / 4 failures — the SAME four blob-io reported, verbatim, in files neither of us owns.** No test moved because of my change. Full quotes in §5.

---

## 1. The projection contract

`StoredWorkMaterial.record(availableLocalKeys:)` → **`record(availableLocalKeys:completeBlobMaterialIDs:)`** (`ConversationStore+Workboard.swift`, the `StoredWorkMaterial` struct near the end of the file — re-locate by symbol, not by line).

```swift
case .syncedPayload:
    availability = completeBlobMaterialIDs.contains(id) ? .synced : .syncedPending
```

- `.metadataOnly` and `.localVault` arms are byte-for-byte unchanged.
- `hasPayload` is untouched (`availability == .synced || .availableLocally`) and followed for free: a pending card reports `hasPayload == false`, asserted.
- Membership of `completeBlobMaterialIDs` IS `WorkMaterialBlobRecord.isComplete` — the set is built from `workMaterialBlobCompleteness`'s keys, which already filters on it. **`isComplete` is stated in exactly one place and I did not restate it** (blob-io §4.1).
- The record struct reaches nothing: both sets arrive whole. That signature is the guard — a projection that could probe the filesystem or the payload store per card cannot be written through it.

## 2. The batch shape

New `private func workMaterialRecords(for: [StoredWorkMaterial]) async throws -> [WorkMaterialRecord]` — **the ONE place a card's availability is decided**, and the only caller of `record(...)`. Both fetch paths go through it:

| Path | Before | After |
|---|---|---|
| `fetchWorkMaterial(id:)` | `if let key = stored.localVaultKey, await workAssetVault.contains(key)` | `try await workMaterialRecords(for: [stored]).first` |
| `fetchWorkItems(itemID:captureEnvelopeID:)` | `for key in Set(...) { if await workAssetVault.contains(key) … }` | `try await workMaterialRecords(for: canonicalMaterials)` |

Inside it, two batched resolutions and nothing else:
1. **Vault** — `await workAssetVault.urls(for: vaultKeys)`, ONE hop onto the actor for the whole board (blob-io §4.6 flagged it as the unused batch resolver; it now has its production caller). `urls(for:)` drops unsafe and missing keys exactly as `contains` did, so the resulting key set is identical — only the number of suspensions changed. `WorkAssetVault.contains(_:)` now has **no production caller** and survives as the single-key form six test files use; I did not touch it (header-only ownership).
2. **Blobs** — `try await workMaterialBlobCompleteness(materialIDs: syncedIDs)`, ONE `.dictionaryResultType` fetch, `materialID`/`byteSize`/`contentHash`/`createdAt`/`updatedAt`, **never `payload`**. `syncedIDs` is narrowed to rows that CLAIM `.syncedPayload`, so the `IN` predicate carries exactly the ids whose answer is read.

**Ordering change worth knowing:** `fetchWorkItems` now deduplicates BEFORE resolving availability. A physically duplicated CloudKit row is not a second card, so it must not become a second vault probe or a second id in the blob predicate. The projected result is identical (only canonical rows were ever projected); the work is strictly less.

`presentationAvailability` **still fails closed** — verified, unchanged: `.syncedPending` sits with `.unavailableOnThisDevice` and returns `.unavailableOnThisDevice`, whose `isAvailable` is false. Asserted directly in `testACardClaimingSyncedBytesWithNoBlobIsPendingAndCannotBeOpened`.

**Cost note for the next reader:** `fetchWorkMaterial` is on the write hot path (six callers inside `upsertDeskMaterial`/reattach), so a `.syncedPayload` row now costs one extra dictionary fetch with a single-id predicate per call. `upsertDeskMaterial`'s repair decision reads `existing.availability` only in the `.localVault` arm, so nothing about repair changed — checked before and after.

## 3. Chip

**No new key, no new component, and no canvas edit was needed.** The pending chip is the card's own detail line, produced by `WorkboardLiveRepository.materialDetail` from the key foundation.md already added: `workboard.material.syncPending` = "Waiting for iCloud…". It reaches the card because `WorkboardMaterialSnapshot.detail` is `previewText` for `.image`/`.file` cards, which are the only kinds that can ever be pending. Both halves are asserted end-to-end (the pending copy present, the `unavailableHere` "Reattach…" copy absent).

**The one wart I did NOT fix, deliberately — see §Requests 1.** `presentationAvailability` collapses `.syncedPending` into `WorkboardMaterialAvailability.unavailableOnThisDevice`, so the canvas cannot tell the two apart: a pending card draws the reattach glyph, its a11y label says "Reattach", and tapping it opens the file importer. The fix is one case on `WorkboardMaterialAvailability` — which lives in `ViewModels/WorkboardViewModel.swift`, **not a file I own**, so I left it and wrote the exact change up as a request rather than take it.

## 4. Desk banner hookup

`WorkboardCaptureCanvas`: `@State private var syncMonitor = CloudSyncMonitor.shared` + a new `deskSyncBanner` at the head of `boardStack`, above `importProgress`.

- **Account-level only.** It renders `ICloudUnavailableBanner(reason:)` off `syncMonitor.showsBanner` / `syncMonitor.unavailableReason` — i.e. `noAccount`/`restricted`/`quotaExceeded`. It reads no event, and a source guard fails if `recentSyncEventLines` ever appears in the file (spike pitfall 5: with two mirrored stores the last failed event can be one payload while the desk syncs fine).
- **Existing component, existing copy — zero new keys.** Dismissal is the same sticky per-outage flag the conversation list uses: the account is broken in one place, so being asked to dismiss it twice would be the same interruption charged again.
- **Where it appears:** `boardStack` renders only in `.sources` mode, and `WorkboardDetailView` mounts that only when the desk has cards. So the banner shows on a desk with material and not on an empty one. That reads right — the claim is "your cards are not reaching your other devices" — but it IS a behavioural consequence of where I was allowed to edit, not a decision I could make in `WorkboardDetailView`.
- **Two cosmetic facts for founder QA:** `ICloudUnavailableBanner` bakes in `.padding(.horizontal)` + `.padding(.top, 8)`, so on the desk it sits ~16pt inset from the cards. And its copy names *conversations* ("iCloud is signed out — your conversations won't sync across your devices"), which on the Work desk is off-subject. Both are one-line fixes for whoever owns plan §E copy — see §Requests 2.

## 5. Tests + counts (exact lines)

Slug `desk-availability`, derivedData `~/Library/Caches/gigaduck-builds/desk-availability/{DerivedData,DerivedDataMac}`, every log written there and grepped. No `-configuration` passed anywhere.

- iOS `build-for-testing`, sim `1DCDF41E-D223-48B4-AA8E-147B0A9E2CE1` → `ios-bft-1.log`: `grep -c ': error: '` = **0**, `** TEST BUILD SUCCEEDED **`. Zero warnings in any of my five files.
- macOS `xcodebuild build -destination 'platform=macOS'` → `mac-1.log`: 0 `error:` lines, `** BUILD SUCCEEDED **`. Signed through the identity override; **no `CODE_SIGNING_ALLOWED=NO` fallback needed**.
- **The VERIFY set** (`ios-test-1.log`, `** TEST EXECUTE SUCCEEDED **`, total `Executed 25 tests, with 0 failures (0 unexpected) in 0.641 (0.648) seconds`):

| Class | Result |
|---|---|
| `WorkboardAvailabilityTests` | `Executed 9 tests, with 0 failures (0 unexpected) in 0.105 (0.108) seconds` |
| `WorkboardBlobPublicationTests` | `Executed 12 tests, with 0 failures (0 unexpected) in 0.502 (0.505) seconds` |
| `WorkboardBoardProjectionTests` | `Executed 1 test, with 0 failures (0 unexpected) in 0.001 (0.001) seconds` |
| `WorkboardLiveRepositorySupportTests` | `Executed 3 tests, with 0 failures (0 unexpected) in 0.033 (0.034) seconds` |

- **FULL iOS suite** (`ios-full-1.log`, `** TEST EXECUTE FAILED **`) — run because I changed the projection every board read goes through:
```
Executed 4756 tests, with 1 test skipped and 4 failures (0 unexpected) in 64.085 (65.456) seconds
```
  4756 = blob-io's 4747 + my 9. **All four failures, verbatim — identical to blob-io §7, none of them mine, none of them touched:**
```
ConversationStoreAtomicWorkCaptureTests.swift:41: error: -[ConduckTests.ConversationStoreAtomicWorkCaptureTests testInitialMaterialPublishesOwnerAndPayloadTogether] : XCTAssertEqual failed: ("Optional(Conduck.WorkMaterialAvailability.synced)") is not equal to ("Optional(Conduck.WorkMaterialAvailability.availableLocally)")
WorkCaptureDrainerTests.swift:119: error: -[ConduckTests.WorkCaptureDrainerTests testTheNoteAndEveryAttachmentLandOnTheDeskTogether] : XCTAssertEqual failed: ("synced") is not equal to ("availableLocally")
WorkboardDeskUpsertTests.swift:228: error: -[ConduckTests.WorkboardDeskUpsertTests testReplayRepairsACardWhoseVaultBytesAreGone] : XCTAssertEqual failed: ("synced") is not equal to ("availableLocally")
WorkboardDeskUpsertTests.swift:229: error: -[ConduckTests.WorkboardDeskUpsertTests testReplayRepairsACardWhoseVaultBytesAreGone] : XCTUnwrap failed: expected non-nil value of type "String"
```
  Note they still say **`synced`**, not `syncedPending` — those cards have complete blobs, so my projection agrees with blob-io's. blob-io's Requests §1 remains the exact fix and is still unactioned.
- `bash scripts/check-storage-seam.sh` → `✓ storage seam intact — 771 Swift files scanned…`, exit 0. `git diff --check` → clean, exit 0.
- **Watch: NOT RUN, and not implicated.** No watch sim was assigned. `ConversationStore+Workboard.swift` is not in the watch membership-exception list; `WorkAssetVault.swift` and `WorkboardLiveRepository.swift` are `#if !os(watchOS)`; `WorkboardCaptureCanvas.swift` is app-target only. Nothing I wrote compiles on the wrist.
- Build caches removed with `/Users/peterkruck/repos/GigaDuck/.claude/scripts/clean-build-cache.sh desk-availability` (the script lives in the MAIN repo `.claude/`, not in this worktree). **The logs no longer exist**; re-run if you need them.
- The new test file is in the synchronized `ConduckTests` group — compiled and ran with **no pbxproj edit**.

### The 9 new cases

**Behaviour (5).** A complete blob → `.synced`, `hasPayload`, presentation `.available`, payload readable, no waiting copy · a `.syncedPayload` card whose blob is gone → `.syncedPending`, `hasPayload == false`, presentation `.unavailableOnThisDevice` with `isAvailable == false`, `loadWorkMaterialPayload` nil, detail carries "Waiting for iCloud…" and NOT the reattach copy · an incomplete row (no hash, no size) never counts as a payload and is never deleted to resolve the read · duplicate blobs resolve to the newest COMPLETE row, a newer incomplete row does not hide it, all three physical rows survive · **one board pass answers every lane at once** — synced + pending + over-ceiling vault + note in a single `fetchWorkItem`, then the vault leaf is removed and that card becomes `.unavailableOnThisDevice` (a reattach, never a pending arrival) while the synced card beside it is untouched.

**Structural (2), both `#filePath`-anchored source guards in the precedent of `WorkboardDeskIdentityDriftTests`.** The completeness fetch's `propertiesToFetch` lists the four metadata columns and **never `payload`** · `ConversationStore+Workboard.swift` contains no `workAssetVault.contains(`, `workMaterialRecords(for: ` is called from exactly the two fetch paths, and `availableLocalKeys: availableLocalKeys` appears exactly once (one projection call site). These two properties are invisible to any assertion about one card, which is why they are guarded in source.

**Banner (2).** The canvas reads `CloudSyncMonitor.shared` + `showsBanner`/`unavailableReason`, reuses `ICloudUnavailableBanner`, and never names `recentSyncEventLines` · the three actionable reasons say three different things (`CloudSyncMonitorTests` already pins non-emptiness and the actionable/silent split, so I did not restate those — only the distinctness the desk's single banner slot depends on).

## 6. Deviations from the brief, with reasons

1. **The canvas chip/badge is unchanged** (§3). The distinction needs a case on `WorkboardMaterialAvailability` in `WorkboardViewModel.swift`, which is not in my ownership list, and the standing rules make that a review failure. The plan's letter is met without it — the chip copy renders and pending fails closed — so I wrote the refinement up as §Requests 1 instead of taking the file.
2. **Two `private static` funcs in `WorkboardLiveRepository` became internal**: `presentationAvailability` and `materialDetail`, each with the reason in its doc comment. This is the file's own precedent (`presentationKind` carries "Internal so the tests can drive the real mapping instead of a copy of it"), and without it the fails-closed claim and the chip copy could only be tested against a transcription of the mapping — which is the thing that drifts.
3. **`WorkAssetVault.contains(_:)` left in place** despite losing its last production caller. Six test files use it and it is the honest single-key form; deleting it is a call for whoever owns those tests, not for a header-only edit.
4. **No `-Blobs`-store defensiveness added anywhere.** store-descriptions §6.1 guarantees both stores are mounted after `ensureLoaded()`, and §6.4 proves losing the payload store degrades to exactly `.syncedPending`. That degradation is now the tested path.
5. **No Codex consult.** The one genuinely hard call was the ownership question in §Requests 1, which is a process decision, not a technical one.

---

## Call-site touches

**NONE outside my own files.** No signature I changed is visible outside `ConversationStore+Workboard.swift` (`record(...)` and `workMaterialRecords(...)` are both private to that file); the two `WorkboardLiveRepository` funcs only widened.

---

## Catalog

**Keys I ADDED in source: NONE.** The chip reuses `workboard.material.syncPending` (foundation.md) and the banner reuses `sync.icloud.banner.*` + `sync.icloud.banner.openSettings` / `sync.icloud.banner.dismiss`, all already in the catalog. No `.xcstrings` file was opened.

**Keys I found DEAD: NONE.** I deleted no code that referenced a key.

---

## Requests

1. **Whoever owns `ViewModels/WorkboardViewModel.swift` (desk-vm, or the serial integrator) — one case, and the desk stops asking people to reattach bytes that are on their way.** Today a `.syncedPending` card is presented as `.unavailableOnThisDevice`, so `WorkboardSourceCard.availabilityGlyph` draws `paperclip.badge.ellipsis` in `AppColors.warning`, `availabilityLabel` reads "Reattach" to VoiceOver, `cardMenuContent` offers Reattach (`WorkboardCaptureCanvas:1066`) and tapping the card opens the file importer (`openMaterial`, `:288`). The card's own detail line says "Waiting for iCloud…" at the same time, so a person is told both things at once. The change, in three files:
   - `WorkboardViewModel.swift`: add `case syncPending` to `WorkboardMaterialAvailability`, and make `isAvailable` `self == .available || self == .localOnly` (it is `self != .unavailableOnThisDevice` today, which would fail OPEN for the new case; it has **zero call sites**, so nothing else moves).
   - `WorkboardLiveRepository.presentationAvailability`: `case .syncedPending: return .syncPending`. **It must stay non-available** — `unavailableOnThisDevice` and `syncPending` are both "no readable bytes here", they differ only in what the person can do about it.
   - `WorkboardCaptureCanvas`: `availabilityGlyph` → `arrow.trianglehead.2.clockwise.rotate.90.icloud` (or `icloud.and.arrow.down`) in `AppColors.textTertiary`; `availabilityLabel` → the existing `workboard.material.syncPending`; `openMaterial` and the menu's `onReattach` gate on `== .unavailableOnThisDevice` only, which they already write literally, so a new case is excluded for free.
   My `testACardClaimingSyncedBytesWithNoBlobIsPendingAndCannotBeOpened` asserts `presentationAvailability(card) == .unavailableOnThisDevice`; that one line is what to update.
2. **Plan §E copy owner — two desk-banner strings.** `sync.icloud.banner.{noAccount,restricted,quota}` all say "your conversations", which the Work desk now renders verbatim. Either widen the existing copy to name what actually stops syncing, or give the desk its own three keys. Also: `ICloudUnavailableBanner` carries `.padding(.horizontal)` + `.padding(.top, 8)` internally, so on the desk it is inset ~16pt from the cards — fine if intended, a two-line change if not.
3. **Serial integrator — blob-io §Requests 1 is still open and is still the whole failing set.** I re-measured all four and they are unchanged; deleting `WorkboardDeskUpsertTests.testReplayRepairsACardWhoseVaultBytesAreGone` (blob-io's own recommendation, since `WorkboardBlobPublicationTests.testAPayloadAboveTheCeilingTakesTheVaultAndAReplayRestoresIt` covers it) plus two `.availableLocally` → `.synced` edits takes the suite to 0.
4. **Docs agent** — beyond blob-io §Requests 5, one fact is now settled by code: a card's availability is decided by whether a COMPLETE blob row exists, never by what its `storageMode` column claims, and a card that claims synced bytes with no blob behind it is `.syncedPending` — visible, un-openable, and repaired by CloudKit rather than by the person. That is what makes losing the payload store non-corrupting.
5. **Nobody re-derive completeness.** `WorkMaterialBlobRecord.isComplete` is stated once and reached only through `workMaterialBlobCompleteness`; the projection consumes its keys. A second "does this blob look finished?" check is how the read path and the write path start disagreeing.
6. **Nobody reintroduce a per-card availability probe.** `WorkboardAvailabilityTests.testAvailabilityIsResolvedOncePerFetchRatherThanOncePerCard` fails on `workAssetVault.contains(` appearing in `ConversationStore+Workboard.swift` at all, and on a second `record(...)` call site. Both are deliberate.
7. **Founder QA (Gate 2) — spike §checklist steps 6, 10 and 18 are now the exact shape this slice implements.** Step 6: on device B the cards arrive first and read "Waiting for iCloud…", cannot be opened, then flip without a relaunch. Step 10: delete only `ConversationBlobs.sqlite` with the app closed — every synced card must come back pending, not broken. Step 18: signing out of iCloud must show the banner **on the desk**, not only in Chats.
