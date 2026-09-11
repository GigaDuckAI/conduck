# f4-thumbnails — A1 thumbnails at the one import site + legacy backfill

## What changed

`Conduck/Conduck/Services/ConversationStore+Workboard.swift` (only app file touched)

- **`ConversationStore.imagePresentationThumbnail(payload:sourceFileURL:)`** — new
  `@concurrent private nonisolated static`. Prefers `ImageProcessor.thumbnailOnly(fromFileAt:)`
  when a source URL is present, else `thumbnailOnly(from:)`. `@concurrent` is load-bearing: a
  plain `nonisolated async` would run the ImageIO pass ON the store actor.
- **`publishWorkMaterial`** (behind `upsertDeskMaterial`) — decodes `publishedThumbnail` AFTER
  staging and BEFORE the write context, gated on
  `existing == nil && draft.kind == .image && draft.thumbnailData == nil && staged?.storageMode == .syncedPayload`.
  Gating on the STAGED lane (not the draft's) is what keeps a vault image from paying for a
  decode nothing will persist.
- **`ConversationStore.apply(_:workItemID:…)`** — new `thumbnailData: Data? = nil` override
  parameter, applied as `thumbnailData ?? draft.thumbnailData`. The existing
  `storageMode == .syncedPayload ? … : nil` guard is intact — vault bytes still never sync.
  (The override replaces "rebuild the draft": `WorkMaterialDraft` lives in
  `Models/WorkboardRecords.swift`, which this slice does not own, and a hand-copied 20-field
  rebuild would silently drop any field added later.)
- **`replaceWorkMaterialPayloadFile`** — decodes `replacementThumbnail` after staging (from the
  still-on-disk `sourceURL`), for `existing.kind == .image && staged.storageMode == .syncedPayload`
  only. The row loop now writes `row.setValue(replacementThumbnail, forKey: "thumbnailData")`
  instead of hard `nil`, so every other reattach still clears the column.
- **`repairMissingWorkThumbnails()`** — new, plus private `runWorkThumbnailRepairPass()`,
  `decodeWorkThumbnail(for:)`, `writeWorkThumbnails(_:)`.
- **New file-scope types**: `WorkThumbnailRepairReport` (internal), `WorkThumbnailCandidate`,
  `WorkThumbnailDecodeOutcome`, `actor WorkThumbnailBackfillMemory` + the global
  `workThumbnailBackfillMemory`, and the bounds `workThumbnailRepairPassLimit = 96`,
  `workThumbnailRepairDecodeWidth = 4` (all private except the report).
- **Test seams**: `WorkMaterialRowProbe` gains `thumbnailByteCount: Int?`;
  new `_clearWorkMaterialThumbnailForTesting(materialID:)`.

`Conduck/ConduckTests/WorkboardThumbnailTests.swift` — new.

## New API (exact signatures)

```swift
@discardableResult
func repairMissingWorkThumbnails() async -> WorkThumbnailRepairReport
```
```swift
nonisolated struct WorkThumbnailRepairReport: Sendable, Equatable {
    let examined: Int    // cards attempted this pass, after undecodable ones were filtered
    let filled: Int      // cards whose physical rows gained a preview
    let undecodable: Int // cards written off this pass
    static let empty: WorkThumbnailRepairReport
}
```
```swift
// CONDUCK_TESTING only
func _clearWorkMaterialThumbnailForTesting(materialID: UUID) async
// CONDUCK_TESTING only — WorkMaterialRowProbe gained:
let thumbnailByteCount: Int?
```

## New strings

None. Nothing in this slice is user-facing.

## Tests

`ConduckTests/WorkboardThumbnailTests.swift` — `WorkboardThumbnailTests`, 7 cases:
`testAnInlineImageCaptureGetsAPresentationThumbnail`,
`testAFileBackedImageCaptureGetsAPresentationThumbnail`,
`testAVaultLaneImageKeepsNoPersistedThumbnail`,
`testANonImageCardGetsNoThumbnail`,
`testAReattachedImageGetsAFreshThumbnail`,
`testTheBackfillFillsALegacyRowWithoutMovingAnyRevision`,
`testTheBackfillWritesOffBytesThatAreNotAnImageAndDoesNotRetryThem`.
PNG/JPEG bytes are synthesised in-test (CGContext → CGImageDestination); no fixtures.

Measured (`test-without-building`, one destination, 0 build errors):

- `WorkboardThumbnailTests` — Executed 7 tests, 0 failures
- `WorkboardDeskUpsertTests` — Executed 16 tests, 0 failures
- `WorkboardBlobPublicationTests` — Executed 22 tests, 0 failures
- `WorkboardSyncedRowRepairTests` — Executed 4 tests, 0 failures
- combined run: **Executed 49 tests, 0 failures**

Regression sweep over the neighbouring Workboard suites (`WorkboardPersistenceTests`,
`WorkboardBoardProjectionTests`, `WorkboardAvailabilityTests`, `WorkboardChatCaptureTests`,
`WorkboardMaterialPresentationTests`, `WorkboardBlobGCTests`, `WorkboardOpenPathTests`,
`WorkboardModelMigrationTests`): **Executed 52 tests, 0 failures**.

`build-for-testing`: 0 errors. No `.xcdatamodeld` edit; model stays at version 16.

## Requests (files I do not own)

1. **`Conduck/Conduck/Views/Workboard/PersonalWorkbenchView.swift`** — in
   `reconcileDurableWorkStorage()` (~L922), add the backfill after the vault reconcile:

   ```swift
   private func reconcileDurableWorkStorage() {
       Task {
           _ = try? await ConversationStore.shared.reconcileWorkAssetVault()
           await ConversationStore.shared.repairMissingWorkThumbnails()
       }
   }
   ```
   `repairMissingWorkThumbnails()` never throws and is `@discardableResult`, so no `try`/`_ =`
   is needed. It is self-limiting (one pass per store at a time), so it is safe on both the
   `.onAppear` and the `scenePhase == .active` call sites that already exist there.

2. **A2 (image-forward cards)** — nothing needed from me. `WorkboardLiveRepository`
   already projects `thumbnailData: record.thumbnailData ?? transientThumbnail`
   (`WorkboardLiveRepository.swift:244`), so a synced card now arrives with persisted bytes and
   a vault card keeps the transient lane. Both reach `WorkboardMaterialSnapshot.thumbnailData`
   identically.

3. **Optional, only if A2 needs aspect ratio**: `ImageProcessor` (read-only for me) exposes no
   pixel-size read, and `thumbnailOnly` returns bytes alone — so `width`/`height` on the
   material row are NOT filled by this slice (see Open questions). The thumbnail JPEG preserves
   the source aspect ratio, so a card can take the ratio from the preview it already has.

## Nobody undo

- **`@concurrent` on `imagePresentationThumbnail`.** Dropping it (or making the function plain
  `nonisolated async`) puts the ImageIO decode back on the store actor's executor, where it
  blocks every queued Work read and write for the length of the decode. Same reason
  `WorkboardLiveRepository` fans its previews into a task group.
- **The lane gate is on `staged?.storageMode`, not `draft.storageMode`.** The draft's mode is
  the caller's claim; only `stageWorkMaterialBytes` knows what
  `WorkMaterialStoragePolicy.mode(kind:byteSize:)` decided. Reading the draft would persist
  previews for vault cards — file content on a CloudKit-mirrored row.
- **`repairMissingWorkThumbnails` writes NO `updatedAt`, on the material row or the desk row.**
  Both revisions are derived from `updatedAt` (`workRevision(for:)`), so one stamp raises
  "Changed after this was sent" on a brief nobody edited and invalidates an approved preflight.
  This is the same contract `setWorkMaterialCardSize` holds; do not "tidy" the two writes into
  a shared helper that stamps.
- **The backfill writes EVERY physical row** (`Self.workMaterialRows`), not the canonical one.
  A CloudKit merge leaves several rows per logical card and any of them can win the canonical
  read.
- **`namesSyncedPayload` is re-checked INSIDE the write transaction.** A reattach can commit
  while the bytes are decoding; without the re-check the card gets a preview of a payload it no
  longer holds. Do not hoist that check to selection time.
- **The undecodable memory is keyed by `(id, contentHash, byteSize)`, not by id.** Keying by id
  alone would make a reattach inherit the old verdict and never get a preview.
- **`propertiesToFetch` in the candidate query deliberately omits `thumbnailData`.** Projecting
  it would realize the preview bytes of every card that already has one just to discover that it
  has one.
- **Bytes are loaded inside each decode job, not up front.** Pre-loading the 96-card window
  would hold up to 96 ceiling-sized (30 MB) payloads at once; the width of 4 is the memory bound
  as much as the CPU one.
- **`_clearWorkMaterialThumbnailForTesting` is not dead code.** Every shipping path now mints a
  preview at capture and at reattach, so the legacy nil-preview row is unreachable through the
  public surface — without the seam the backfill and its no-timestamp contract have no test.

## Open questions

1. **`width`/`height` are still nil for images captured here.** The draft carries the fields and
   the columns exist, but `ImageProcessor.thumbnailOnly` returns only bytes and I may not edit
   `ImageProcessor.swift`, so filling them would mean a SECOND ImageIO read owned by the store —
   duplicating the "one ImageIO decode primitive" that file claims. Nothing in `Views/Workboard`
   or `Services/Workboard` reads `WorkMaterialRecord.width`/`.height` today (only
   `WorkCaptureDrainer.swift:427` passes an envelope's declared values through). Left alone
   deliberately; if A2 or A3 needs true source dimensions, the right fix is a
   `nonisolated static func pixelSize(fromFileAt:)/(from:)` on `ImageProcessor` plus a second
   override parameter on `apply`.
2. **Stale doc comment, pre-existing, untouched**: `ConversationStore+Workboard.swift` has a
   truncated `/// Pin or unpin one project…` comment sitting directly above
   `func loadWorkMaterial(id:)`. It documents a function that is not there. I left it as found
   to keep this diff to the slice — worth a one-line fix in the docs pass.
