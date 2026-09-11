# fix-r1-desk — Codex round-1 findings on the desk slice (cards + preview)

Findings file: `docs/qa/work-usability/verify/codex-r1-desk.json` (4: 1 major, 3 minor).
Base for every claim: `ec8b27f..692608d`. Slug `fix-desk`.

| id | severity | verdict |
|---|---|---|
| S1 | major | **fixed** |
| S2 | minor | **fixed** |
| S3 | minor | **open** (design change — founder call) |
| S4 | minor | **fixed** |

---

## S1 — thumbnail backfill could persist another row's picture (major, FIXED)

**Confirmed against the code.** `decodeWorkThumbnail(for:)` read its bytes through
`loadWorkMaterialPayload(id:)`, which resolves the CANONICAL row
(`workMaterialRow(id:)`, newest-wins) and answers with whatever lane and pairing that
row names. The candidate, however, is a PHYSICAL row selected by
`(kind == .image, storageMode == .syncedPayload, thumbnailData == nil)`, and
`writeWorkThumbnails` accepts a destination row on `namesSyncedPayload(row:contentHash:byteSize:)`
— the candidate's own pairing — without ever checking that the decoded bytes came from
that pairing. A CloudKit merge that leaves one card with two physical rows naming
different blobs (or a canonical row on the vault lane) therefore wrote the canonical
row's picture onto a row that still claims other bytes, on a CloudKit-mirrored column.

**What changed.** `ConversationStore+Workboard.swift:decodeWorkThumbnail(for:)` now reads
through `newestCompleteBlobPayload(materialID:pairedWith:)` with a
`WorkMaterialBlobPairing` built from the candidate's own `contentHash` + `byteSize`. A
throw and "no complete blob here yet" stay the same transient `.unavailable` answer
(`?? nil` flattens the `Data??`), so an iCloud-pending card is still never written off.
The transaction-time re-checks in `writeWorkThumbnails` are untouched, as instructed.

**Test that pins it.** `WorkboardThumbnailTests.testTheBackfillDecodesTheBytesTheRepairedRowNamesNotTheCanonicalRows`
— one card, two physical rows naming different blobs (the newer/canonical one names a
peer's payload and keeps its preview, so it is not a candidate), and the repaired row's
preview must be the one decoded from ITS payload. Negative control run: with the old
`loadWorkMaterialPayload` read restored, the test fails
(`("Optional(1803)") is not equal to ("Optional(1837)")` — it had persisted the peer
payload's thumbnail).

**Seam extended (test-only, `#if CONDUCK_TESTING`).**
`_clearWorkMaterialThumbnailForTesting(materialID:contentHash:)` gained the optional
`contentHash` filter. Without it every duplicate row ends in the same state, and the
row that is missing a preview is then also the canonical one — which hides the
mismatch entirely. Default `nil` keeps every existing call site byte-identical.

## S2 — a stale readable tap could reopen a card the desk now refuses (minor, FIXED)

**Confirmed against the code.** `openMaterial` schedules `Task { await router.present(material) }`,
so `present` runs with a snapshot captured at gesture time. The gate then asked that
SNAPSHOT's availability, and `gallerySelection`'s "not on the desk ⇒ open alone"
fallback treated a present-but-REFUSED card as absent — reinstating the stale readable
snapshot as a lone page and presenting its thumbnail as the picture.

**What changed.** `PersonalWorkbenchView.swift:PersonalWorkbenchRouter.present(_:)` reads
the desk ONCE, resolves the tapped id against it through the new
`PersonalWorkbenchRouter.currentDeskCard(in:for:)`, and runs the existing availability
gate on that current card; the `.image` branch reuses the same desk array rather than
re-reading it (two reads could disagree with each other). `gallerySelection` itself is
unchanged — the fallback survives verbatim for a genuinely ABSENT card (a3's "Nobody
undo"), and its doc now states why the fallback can no longer see a refused card.

**Tests that pin it.**
- `WorkboardOpenPathTests.testAStaleReadableTapIsRefusedWhenTheDeskCardIsNoLongerReadable`
  (router level: readable snapshot + same-id `.syncPending` card on the desk ⇒ nothing
  presented, refusal explained).
- `WorkboardOpenPathTests.testATapOnACardTheDeskNoLongerCarriesStillOpens` — the
  positive control, so the fix cannot degrade into "refuse everything".
- `WorkboardGalleryPagesTests.testTheDesksOwnCardAnswersForATapTakenBeforeItChanged`
  and `…testATapOnACardTheDeskNoLongerCarriesResolvesToItself` — the pure resolver.

Negative control run: with `let material = tapped` restored, the router test fails with
the gallery presented from the stale snapshot.

## S3 — vault images have no Share action (minor, OPEN — recorded, not fixed)

**Half refuted, half real.**
- Refuted: the plan's "Keep ShareLink" sits inside the `.file` → Quick Look bullet, and
  files and recordings DO keep the system share — Quick Look supplies it, per f2/a3.
  Nothing in the plan's image bullet asks for Share in the gallery.
- Real: at `ec8b27f` an OVERSIZED (vault-lane) image fell into the `.file` branch and so
  reached that sheet's `ShareLink(item: url)`. At HEAD every image routes to the gallery,
  which offers Done and Retry, so those images now have no export path. (A small synced
  image never had one: it rendered through `WorkboardPreviewImage`, which carried no
  share control.)

**Why it is not fixed here.** The remedy is a new user-facing affordance, not a repair:
a Share item on the desk card's context menu needs a new callback plumbed through
`WorkboardCaptureCanvas` → `WorkboardMaterialBoard` → `WorkboardSourceCard`, canvas-held
state for an ASYNC disposable copy (`ShareLink` wants a URL at menu-build time), a
platform share presentation on both iOS and macOS, a reclaim rule for the shared copy
(iOS on dismiss, macOS left to `TempScratchSweeper` — Open With hands the path to another
app), and a NEW catalog key. That is a product decision about whether and where Work
images offer Share; a3 already logged it as an open question and the founder has not
ruled. The alternative — a Share control in `AttachmentFullScreenView` — would also add
one to CHAT's gallery, which deliberately has none.

**No catalog row was minted** and `WorkboardCaptureCanvas.swift` was not touched.
Recommended shape if the founder wants it: card context menu item, gated on
`WorkboardCardActionPolicy.allows(.open, …)`, fed by `makeDisposablePreviewCopy` (which
already names the copy from the mime type), new key `workboard.material.share` —
never `common.share`, which the wave retired.

## S4 — macOS never released gallery neighbours under pressure (minor, FIXED)

**Confirmed:** the only `residencyRadius = 0` was inside `#if os(iOS)` on
`UIApplication.didReceiveMemoryWarningNotification`. AppKit posts no memory warning at
all, so a Mac gallery held up to three 4096 px bitmaps through the pressure.

**What changed.** `AttachmentFullScreenView.swift` gained a macOS-only
`MemoryPressureSignal.warnings()` — a `DispatchSource.makeMemoryPressureSource`
(`[.warning, .critical]`, main queue) wrapped in an `AsyncStream` whose
`onTermination` cancels the source — consumed by a `#if os(macOS)` `.task` that sets
`residencyRadius = 0` and stops. The `.task` owns the source's lifetime (created with
the presentation, cancelled with it) and nothing mutates view state from a queue
callback. The radius stays 0 for the life of the presentation, exactly as on iOS.

**Test that pins it.**
`AttachmentGalleryPageTests.testBothPlatformsShrinkTheResidencyWindowUnderMemoryPressure`
— a source-shape guard through `RefusalLaneSource` (neither signal can be raised from a
test; the arithmetic it drives is already pinned by `testRadiusZeroKeepsOnlyTheCurrentPage`).
It asserts both signals are wired and that exactly two `residencyRadius = 0` lanes exist.

---

## Catalog

**No new rows, no `.xcstrings` edit.** Every string on the fixed paths is an existing
key; S3, the only finding that would have needed one, is recorded as open.

## Invariants held

- Durable-before-hop, one desk write, nothing from the desk to a gateway: untouched —
  no write path, no capture lane and no gateway reference is in this diff.
- Frozen wire strings, envelope schema, `.xcdatamodeld`: untouched.
- `WorkboardDeskSurfaceDriftGuardTests` (one `workboardViewModel.load()`) still green;
  `WorkboardCopyTruthGuardTests` still green (77 tests, no orphaned or missing key).
- The backfill still writes NO `updatedAt` on the material or the desk row, still walks
  EVERY physical row, still re-checks `namesSyncedPayload` inside the transaction, and
  still remembers undecodable candidates by `(id, contentHash, byteSize)` — f4's
  "Nobody undo" list is intact; S1 changed only WHICH bytes are decoded.
- a3's "Nobody undo" list is intact: `gallerySelection` still filters through
  `WorkboardCardActionPolicy`, the start index is still computed against the FILTERED
  list, `case .image` still reads no bytes, `fullDecodeMaxPixel: 4096` and the strict
  decoder are unchanged, `loadFullBytes` still throws, and the absent-card fallback
  still opens alone.
- f3's "Nobody undo": `residencyRadius` still never re-widens after a pressure signal;
  the release still drops the full image and keeps the thumbnail.

## Nobody undo

- **The backfill's payload read is PAIRED to the candidate, not to the card.**
  `loadWorkMaterialPayload(id:)` answers for the canonical row; the row being repaired
  is frequently not that row. Routing this read back through the general loader
  re-opens S1 — one card's picture persisted onto another card's bytes, on a column
  that then syncs everywhere.
- **`present` reads the desk ONCE and gates on `currentDeskCard`.** Gating on the
  tapped snapshot lets a card that the desk already refuses open on a stale readability;
  reading the desk twice lets the gate and the page list disagree.
- **`currentDeskCard` falls back to the tapped card, and `gallerySelection` keeps its
  lone-card fallback.** They are two halves of one rule: the desk wins where it still
  holds the card, and a board reloaded underneath the gesture must not become a dead tap.
- **The macOS pressure source lives inside the `.task` that consumes it.** A source held
  in view state outlives the presentation unless something cancels it; the stream's
  `onTermination` is what makes cancellation automatic.
- **The `MemoryPressureSignal` loop breaks after the first signal.** Re-arming would let
  a later signal re-run nothing useful, and re-widening the radius is already forbidden.

## Builds and tests

- iOS `build-for-testing`: **0 errors** (log under the `fix-desk` build cache, swept by `clean-build-cache.sh fix-desk` at the end of the run).
- macOS `build` (`CODE_SIGNING_ALLOWED=NO`): **0 errors**.
- `WorkboardThumbnailTests` (10), `WorkboardGalleryPagesTests` (15),
  `WorkboardOpenPathTests` (22), `AttachmentGalleryPageTests` (4 + the rest of the class),
  `WorkboardDeskSurfaceDriftGuardTests`, `WorkboardCopyTruthGuardTests` (77),
  `WorkboardBlobPublicationTests` (8), `WorkboardSyncedRowRepairTests` (9):
  **0 failures**.
- Two negative controls were run and then reverted (S1, S2) — both new tests fail
  against the pre-fix code.

## Observed, not changed

`ConversationStore+Workboard.swift:2678` warns
`main actor-isolated let 'workThumbnailRepairDecodeWidth' cannot be accessed from
outside of the actor; this is an error in the Swift 6 language mode`. It predates this
round (it is f4's task-group loop, untouched here) and is not one of the findings, so
it was left alone to keep this diff finding-scoped. One-line fix when someone owns that
line next: hoist the global into a local before `withTaskGroup`.
