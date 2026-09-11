# a3-preview — tap-to-preview per kind, Mac sheet sizing, thumbnail backfill wiring

## What changed

**`Conduck/Conduck/Views/Workboard/WorkboardComponents.swift`**
- `View.workboardDesktopSheetFrame(minWidth:minHeight:)` gains three optional
  parameters: `idealWidth`, `idealHeight`, `maxWidth`, `maxHeight` (all `nil` by
  default, so `WorkboardTextMaterialSheet` and `WorkboardTutorialView` keep the
  exact frame they had). **Why:** a minimum-only frame makes macOS open the sheet
  AT that minimum. That is right for a form and wrong for a picture — a media
  sheet would launch at its floor and every image would arrive shrunk.

**`Conduck/Conduck/Views/Workboard/PersonalWorkbenchView.swift`**
- `MaterialPresentation.Content`: `.image(Data)` and `.file(URL, extractedText:)`
  are gone; `.imageGallery(pages:startIndex:)` replaces them. Files (and the
  recordings that reach the presenter through Open) no longer produce a sheet at
  all — they go to Quick Look.
- New nested `PersonalWorkbenchRouter.GallerySelection { pages; startIndex }`.
- `PersonalWorkbenchRouter` gains `let filePreview: FilePreviewCoordinator`
  (f2's type, `@ObservationIgnored`, injectable through a new
  `init(filePreview:)` whose default keeps `PersonalWorkbenchRouter()` valid) and
  `var deskMaterials: @MainActor () -> [WorkboardMaterialSnapshot]`, defaulted to
  `{ [] }`. **Why the coordinator lives on the ROUTER and not on the view:** the
  router's `destination` `didSet` must be able to invalidate an in-flight Quick
  Look claim (macOS `QLPreviewPanel` is application-shared with Chat's), and the
  desk shell is remounted by the platform shells — a `@State` presenter would
  lose the claim with the remount.
- `present(_:)`: `case .image` now covers EVERY lane (a >30 MB vault photo
  included) and reads NO bytes — it builds the gallery from the desk and commits.
  `case .file, .audio` makes the disposable copy, checks `isCurrent(token)`, and
  hands it to `filePreview.present(PreviewedFile(url:reclaim:), token:)`. The
  claim token is minted at the top of `present`, before any await.
- `closeMaterial()` now calls `filePreview.cancelPendingPresentation()`. It is
  already what the destination `didSet` runs, so leaving Work closes the Quick
  Look panel and invalidates every load still holding a presentation claim.
- New `nonisolated static gallerySelection(desk:tapped:)`,
  `nonisolated static galleryPage(for:)`,
  `nonisolated static imageBytes(materialID:)`,
  private `makeDisposablePreviewCopy(of:)`, private
  `nonisolated static writePreviewCopy(of:filename:)` (the in-store-bytes half of
  the copy, lifted out of `present` so both lanes write the same per-copy
  directory under the same container and one reclaim rule covers both).
- `import QuickLook` added beside `import SwiftUI` (the modifier lives in the
  SwiftUI×QuickLook cross-import overlay and `MemberImportVisibility` makes the
  second import mandatory), and the file's obsolete `#if canImport(UIKit)` block
  removed.
- Deleted: `previewFileURL`, `presentedRequestID`, `reclaimDismissedPreview()`,
  `commit`'s `previewURL:` parameter, the sheet's `onDismiss:`, the struct
  `WorkboardPreviewImage`, and the file's `#if canImport(UIKit)` import block
  (nothing in the file names `UIImage`/`NSImage` any more). Lifetime of a preview
  copy is now entirely the coordinator's `reclaim` closure.
- `PersonalWorkbenchModel.init` wires `router.deskMaterials` to
  `[weak workboardViewModel] in workboardViewModel?.desk?.materials ?? []`.
- `PersonalWorkbenchView.body`: `.quickLookPreview(workMaterialPreviewURL)` plus
  the dismissal `onChange` bridge, beside (not inside) the existing `.sheet`.
  New private `workMaterialPreviewURL: Binding<URL?>` using `@Bindable`, exactly
  Chat's `activePreviewURL` shape minus the destination gate (this shell hosts
  both sections, so there is nothing to gate against).
- `reconcileDurableWorkStorage()` runs
  `await ConversationStore.shared.repairMissingWorkThumbnails()` after
  `reconcileWorkAssetVault()`, in the same `Task` — f4's request, verbatim.
- `WorkboardMaterialPreviewView` now switches at the top: `.imageGallery` draws
  `AttachmentFullScreenView(pages:startIndex:loadFullBytes:fullDecodeMaxPixel: 4096)`
  with the media sheet frame (`min 640×480, ideal 900×640, max .infinity`);
  `.note`/`.link` keep the identical `NavigationStack` + Done + `min 360×340`.

**`Conduck/ConduckTests/WorkboardOpenPathTests.swift`** — updated for the new
content cases (below). **NEW `Conduck/ConduckTests/WorkboardGalleryPagesTests.swift`.**

## New API (exact signatures)

```swift
// WorkboardComponents.swift
func workboardDesktopSheetFrame(
    minWidth: CGFloat,
    minHeight: CGFloat,
    idealWidth: CGFloat? = nil,
    idealHeight: CGFloat? = nil,
    maxWidth: CGFloat? = nil,
    maxHeight: CGFloat? = nil
) -> some View
```

```swift
// PersonalWorkbenchRouter
struct MaterialPresentation.Content {
    case note(String)
    case link(URL)
    case imageGallery(pages: [AttachmentGalleryPage], startIndex: Int)
}

struct GallerySelection {
    let pages: [AttachmentGalleryPage]
    let startIndex: Int
}

// The parameter is OPTIONAL, not defaulted to a fresh coordinator: a default
// argument is evaluated in the caller's (nonisolated) context and
// `FilePreviewCoordinator.init` is main-actor isolated.
init(filePreview: FilePreviewCoordinator? = nil)

@ObservationIgnored let filePreview: FilePreviewCoordinator
@ObservationIgnored var deskMaterials: @MainActor () -> [WorkboardMaterialSnapshot]

// MainActor (the type's isolation), NOT nonisolated: `WorkboardCardActionPolicy`
// is main-actor isolated under the project's default-isolation setting, so a
// nonisolated projection could not consult the desk's own gate.
static func gallerySelection(
    desk: [WorkboardMaterialSnapshot],
    tapped: WorkboardMaterialSnapshot
) -> GallerySelection

static func galleryPage(
    for material: WorkboardMaterialSnapshot
) -> AttachmentGalleryPage

// nonisolated: the gallery calls it from a @Sendable loader closure.
nonisolated static func imageBytes(materialID: UUID) async throws -> Data
```

`imageBytes` THROWS (`WorkbenchPreviewError.unavailable`) when a card's bytes are
unreadable — never returns empty `Data` and never substitutes a thumbnail — which
is what makes f3's per-page Retry state reachable. It is ONE store call for both
lanes: `loadWorkMaterialPayload` already resolves a synced blob and a vault leaf
(`ConversationStore+Workboard.swift`, `case .localVault` → `workAssetVault.data(for:)`),
so no `localURLForWorkMaterial` round trip is spent to discover which lane a card
is on. The Quick Look path still takes the URL branch, because copying a vault
file with `copyItem` beats materialising its bytes in memory first.

## New strings

**None.** No key is added and no copy is reworded.

**Four `workboard.*` catalog rows are now ORPHANED** by the deletions above and
must be removed by the copy agent (see Requests):

```
workboard.material.file.ready
workboard.material.openFile
workboard.material.preview.unavailable.title
workboard.material.preview.unavailable.message
```

`common.share` is also unreferenced now (no `ShareLink` remains anywhere in
`Views/`); it is outside `WorkboardCopyTruthGuardTests`' prefixes, so it trips no
guard — the copy agent's call whether to drop it.

## Tests

`ConduckTests/WorkboardGalleryPagesTests.swift` — `WorkboardGalleryPagesTests`,
6 cases: only openable image cards become pages · a `syncPending` /
`unavailableOnThisDevice` card is never a page and the start index counts PAGES
not desk rows · a `.localOnly` vault picture is a page like any other (and
carries no persisted thumbnail) · board order survives every tap and the start
index points at the tapped card (all five positions) · a tapped card missing from
the desk (and an empty desk) still opens alone · a page carries the card's id,
its preview bytes and its NAME as the accessibility label.

`ConduckTests/WorkboardOpenPathTests.swift` — `testTheRouterRefusesACardWhoseBytesAreNotReadableHere`
now also puts the waiting card on a desk full of openable pictures and asserts it
reaches neither the sheet nor Quick Look; new
`testAnImageCardOfEitherLanePresentsAsAGallery` covers `.available` and
`.localOnly` (a 41 MB card) presenting as `.imageGallery` with no disposable copy
made.

Builds (`-derivedDataPath ~/Library/Caches/gigaduck-builds/work-a3/…`, no
`-configuration` flag):

| Target | Result |
|---|---|
| iOS `build-for-testing` (sim `04DEF4F5`) | exit 0, **0** `: error: ` |
| macOS `build` (`platform=macOS`) | exit 0, **0** `: error: ` |

Tests (`test-without-building`, one invocation over the six mandated classes plus
the two neighbouring suites that touch this slice's symbols):

```
Executed 39 tests, with 0 failures (0 unexpected) in 0.195 seconds
```

| Class | Result |
|---|---|
| `WorkboardOpenPathTests` | Executed 7 tests, 0 failures |
| `WorkboardGalleryPagesTests` | Executed 6 tests, 0 failures |
| `WorkboardDeskSurfaceDriftGuardTests` | suite passed (1 case — exactly one `workboardViewModel.load()`) |
| `MacWorkbenchShellDriftGuardTests` | Executed 4 tests, 0 failures |
| `WorkboardDeskViewModelTests` | Executed 5 tests, 0 failures |
| `WorkboardMaterialPresentationTests` | Executed 5 tests, 0 failures |
| `FilePreviewCoordinatorTests` (f2's, the coordinator this slice now drives) | Executed 11 tests, 0 failures |

`WorkboardCopyTruthGuardTests` — **Executed 9 tests, 1 failure**, run separately.
BOTH catalog failures it can report are copy-agent work, neither is a code defect:

- `testEveryWorkCatalogRowIsReferencedInSource` — `workboard.material.openFile has
  a catalog row no app-target source references`. That is this slice's orphan (the
  suite stops at the first key it hits; the other three orphans listed under New
  strings are behind it).
- `testEveryWorkKeyInSourceHasACatalogRow` — `workboard.menuBar.voice.cardMissing
  is referenced in the app target but has no catalog row`. **Slice D's**, not
  mine.

Zero warnings in the four files this slice touches, on both platforms.
`git diff --check` clean; `scripts/add-spdx-headers.sh --check` reports all
tracked source files carry the header.

## Requests (files I do not own)

1. **Copy agent** — delete the four orphaned `workboard.material.*` rows listed
   under New strings, or `WorkboardCopyTruthGuardTests.testEveryWorkCatalogRowIsReferencedInSource`
   stays red. Decide `common.share` at the same time.
2. **Nobody** needs to register anything in `ErrorSurfaceDriftGuardTests.retrySurfaces`
   for this slice: the only literal `Retry` is f3's, inside
   `AttachmentFullScreenView.swift`, which integrate-0 already registered.
   `PersonalWorkbenchView.swift` draws no Retry control.
3. **A2 (card layout agent)** — a card-level Share is now the only route to
   `ShareLink` for a picture (Quick Look supplies the system share for files and
   recordings, but images no longer pass through it). If the founder wants Share
   on an image, the natural home is the card's context menu in
   `WorkboardCaptureCanvas.swift`, not the gallery. See Open questions.

## Nobody undo

- **`gallerySelection` filters through `WorkboardCardActionPolicy.allows(.open,…)`,
  not through `availability.isAvailable`.** The gate the tap passed and the gate
  the page list passes must be the SAME one, or a card that is refused a tap can
  still be swiped onto — and a `syncPending` card carries a thumbnail, so the
  gallery would present that thumbnail as though the picture had landed.
- **The start index is computed against the FILTERED list.** Computing it against
  the desk and using it on the pages points at the wrong picture the moment one
  card is filtered out, and it looks correct until the person swipes.
- **A tapped card absent from the desk still opens, alone.** The desk is read at
  tap time from a live view model; a reload landing between the gesture and the
  read must not turn into a dead tap on a card the person is looking at.
- **`case .image` reads no bytes.** Lane-blind is the whole point: routing an
  image by where its bytes live is what sends a 40-megapixel original into the
  file branch. The gallery loads per page, when the page is resident.
- **`fullDecodeMaxPixel: 4096` and f3's strict decoder.** Work stores originals
  verbatim. Dropping the bound (or routing through `Image.decoded(from:maxPixel:)`,
  which falls back to an UNBOUNDED platform decode) re-opens the memory hazard on
  exactly the payloads the bound exists for.
- **`loadFullBytes` must throw, never return empty `Data`.** Empty bytes decode to
  nothing and the page spins forever; a throw is what draws Retry.
- **The Quick Look coordinator is the ROUTER's, and `closeMaterial()` cancels it.**
  macOS's `QLPreviewPanel` is application-shared, so Chat's
  `dismissTransientChatUI` and Work's `closeMaterial` are two halves of one rule:
  a hidden section never owns the panel.
- **`beginRequest()` is minted before the first `await` in `present`.** Moving it
  next to `filePreview.present` lets completion order decide which file wins the
  panel — the exact bug the token exists to prevent.
- **No macOS-side reclaim was added.** `FilePreviewReclaimPolicy.platformDefault`
  already withholds it there because "Open with" hands another app the live path;
  the copies are covered by `TempScratchSweeper.ownedPrefixes`
  ("Conduck-Workboard-Preview"), per f2.
- **The stale-claim branch in `case .file, .audio` reclaims its OWN copy.** That
  file was never shown, so nothing else can hold its path; leaving it for the
  sweep would keep a private material in `tmp` for up to two days for no reason.
- **`repairMissingWorkThumbnails()` runs AFTER `reconcileWorkAssetVault()` in the
  same `Task`.** The vault sweep decides which materials still have bytes; running
  the backfill first spends decodes on rows the sweep is about to write off.
- **`workboardDesktopSheetFrame`'s new parameters default to nil.** The two text
  sheets must keep a minimum-only frame — giving them an ideal size would make
  them open larger than the content they hold.
- **Exactly one `workboardViewModel.load()` remains in the file**
  (`WorkboardDeskSurfaceDriftGuardTests`); this slice added no reload path —
  `deskMaterials` READS the already-loaded desk and never triggers a fetch.

## Founder QA

**Mac** (Work section, desk with at least 4 image cards, one PDF, one recording,
and one photo larger than 30 MB):

1. Click **Photo 3**. A sheet opens at roughly **900×640** (not a small box, not
   the full 1100×760 window) with the picture fit inside it on black.
   *Failure:* it opens at ~640×480, or the picture is cropped.
2. Pinch or scroll-zoom in, drag to pan, double-click to reset.
3. Swipe (or drag) sideways, or press → / ←: **Photo 4** and **Photo 2**. The
   pictures are the desk's, in the desk's order, and the non-image cards are not
   in the sequence. *Failure:* a note or the PDF appears as a page; the order
   differs from the board; the first swipe lands on the wrong picture.
4. Press **Escape** or click the ✕: back to the desk, nothing left behind.
5. Click the **>30 MB photo**. It opens in the SAME gallery, full quality, and is
   one of the pages when you swipe. *Failure:* it opens as a document icon with
   an "Open File" button, or it is missing from the page sequence.
6. Click the **PDF card**. The **Quick Look panel** opens (the system one, with
   its own share and Open-with buttons) — not a Conduck sheet. Close it.
7. Click the **recording card's card body via its menu → Open** (the transport on
   the card itself still plays inline). Quick Look plays it.
8. With Quick Look open, click **Chats** in the section control. The panel closes
   immediately. *Failure:* it stays over the Chats window — that is the shared
   `QLPreviewPanel` bug this slice guards.
9. Open a **note** card and a **link** card. Both still open the small sheet with
   a Done button, unchanged.

**iPhone**:

1. Tap **Photo 3** on the desk: a sheet gallery, swipeable between the desk's
   pictures, page dots at the bottom, ✕ to close.
2. Pinch to zoom, double-tap to reset, swipe between pages.
3. Tap the **PDF card**: full-screen Quick Look with its own Share button. Dismiss
   it. *Failure:* the file's preview copy survives — after dismissal there should
   be nothing left in the app's tmp preview container (iOS reclaims on dismissal;
   macOS deliberately does not).
4. A card **still syncing from iCloud** must refuse the tap with the "still
   arriving" message, and must NOT appear as a page when you swipe through the
   gallery from a neighbouring picture.
5. Background and foreground the app once, then check any legacy image card that
   had no artwork: the thumbnail backfill fills it in within a moment
   (one bounded pass per foreground).

## Open questions

1. **No Share on an image any more.** Before this slice, Share reached an image
   only on the vault lane (a >30 MB photo), where the router fell into the file
   branch; the common inline-image path offered none. The gallery is
   `AttachmentFullScreenView`, which this slice does not own and which exposes no
   current-page hook, so adding a per-page `ShareLink` would mean owning selection
   state outside it. Founder call: leave images share-less (the file and recording
   lanes keep the system share through Quick Look), or ask A2 for a Share row in
   the card's context menu.
2. **Extracted text on a file card is no longer displayed.** The old `.file`
   sheet printed `material.textContent` above the buttons; Quick Look renders the
   file itself instead. Nothing else reads that field on this surface, and Quick
   Look shows a text file's contents directly, so this looks like a strict
   improvement — flagging it because it is a visible deletion.
3. f3's own open question stands: a gallery page released at 6× briefly shows a
   magnified thumbnail before the original re-decodes.
