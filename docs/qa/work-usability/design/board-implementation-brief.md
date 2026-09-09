# Conduck "Work" board — current implementation brief

Read-only survey of the shipped Work desk UI (Swift/SwiftUI, iOS + iPadOS + macOS).
All paths are relative to `/Users/peterkruck/repos/GigaDuck/Conduck/Conduck/Conduck/`
unless stated otherwise.

---

## 1. Data model

**Kinds** (`Models/WorkboardRecords.swift:139-155`): `note`, `link`, `image`, `file`,
`audio`, `transcript`, `unknown`. There is no screenshot kind and no web-page kind.
A screenshot is an ordinary `.image`; a shared web page arrives as note/link text
assembled by the share extension.

Work is **one desk** at a compile-time id (`Constants.workboardDeskItemID`). The
owning `WorkItemContent` carries `title`, `objective`, `context`, `desiredOutcome`,
`constraints`, `dueAt`, `preferredGatewayRef`, `isPinned`
(`Models/WorkboardRecords.swift:47-79`), and the desk writes **none of them**. They
are dormant columns from an older briefing model that the desk never populates.
`WorkItemRecord.boardOrder` is likewise unused for a single desk.

**Per-material fields** (`Models/WorkboardRecords.swift:369-420`): `id`, `workItemID`,
`kind`, `title`, `caption`, `textContent`, `urlString`, `filename`, `mimeType`,
`thumbnailData`, `width`/`height`, `byteSize`, `hasPayload`, `storageMode`,
`availability`, `contentHash`, `localVaultKey`, `sourceDevice`, `sequence`,
`cardSize`, `attachedToMaterialID`, `createdAt`, `updatedAt`.

**Ordering is an explicit dense integer rank**, not a date. Projection sorts
`(sequence, createdAt, id)` (`Services/Workboard/WorkboardLiveRepository.swift:243`);
a reorder rewrites the whole rank range from a complete permutation under one
compare-and-swap on the desk's revision
(`Services/ConversationStore+Workboard.swift:3301-3337`). The revision token is the
bit pattern of `updatedAt` (`Models/WorkboardRecords.swift:16-20`).

**Availability / storage** are two separate axes:
- `WorkMaterialStorageMode`: `metadataOnly`, `syncedPayload` (CloudKit-mirrored blob),
  `localVault` (App-Group vault, oversized payloads).
  `Models/WorkboardRecords.swift:157-170`
- `WorkMaterialAvailability`: `metadataOnly`, `synced`, `availableLocally`,
  `unavailableOnThisDevice`, `syncedPending`.
  `Models/WorkboardRecords.swift:207-224`
  The presentation enum the UI actually reads is
  `WorkboardMaterialAvailability` (`available`, `localOnly`,
  `unavailableOnThisDevice`, `syncPending`) at
  `ViewModels/WorkboardViewModel.swift:70-77`.

**Grouping barely exists.** The only link between two cards is
`attachedToMaterialID`: a *recording* naming the *picture* produced by the same
capture press (`Models/WorkboardRecords.swift:249-268`). The board renders that pair
as ONE folded card carrying a `companion`
(`ViewModels/WorkboardViewModel.swift:95-155`, `:183`). There are **no tags, no
folders, no collections, no arbitrary card-to-card links, no nesting**. The one
grouping primitive that exists is a two-member, kind-constrained, capture-derived pair.

`cardSize` (`small` / `standard` / `large`) is presentation-only and revision-neutral
by contract: writing it must not stamp `updatedAt` on the material or the desk
(`Models/WorkboardRecords.swift:170-205`, `ViewModels/WorkboardViewModel.swift:935-965`).
`standard` is stored as `nil` so an un-resized card leaves the CloudKit column empty.

---

## 2. Board rendering

**Tiles** use a custom SwiftUI `Layout` wrapping a pure placement engine
(`Views/Workboard/WorkboardMosaicLayout.swift:151-386`). It is a **unit-grid row-band
fill, not masonry**:

- Spans: `small` = 1x1, `standard` = 2x2, `large` = 4x2
  (`WorkboardMosaicLayout.swift:32-34`).
- Column count stays **even**, between 4 and 12, chosen by unit-width thresholds
  (minimum 64pt, comfortable 88pt, maximum 144pt) and scaled by Dynamic Type
  (`WorkboardMosaicLayout.swift:53-135`, `:259-276`).
- Placement is a plain band fill: a band's height is the tallest span in it, and a
  `large` card that will not fit wraps to a new band. Reading order is a **hard
  invariant**, so unused trailing units stay empty rather than being backfilled —
  backfilling would lift a later card above an earlier one
  (`WorkboardMosaicLayout.swift:11-15`, `:312-385`).
- The engine result is memoised per `(spans, width, metrics)` and mirrored for
  right-to-left at placement time (`WorkboardMosaicLayout.swift:410-553`).

**List** is a plain `VStack(spacing: 10)` of `WorkboardMaterialListRow`
(`Views/Workboard/WorkboardCaptureCanvas.swift:1288-1296`).

**The toggle** is a segmented `Picker` labelled "Board view" with Tiles / List,
persisted to `UserDefaults` under `Constants.workboardLayoutKey`
(`Views/Workboard/WorkboardArrangement.swift:12-35`;
`WorkboardCaptureCanvas.swift:1286-1298`). "Drag to reorder" beside it is a static
caption `Label` with a `hand.draw` glyph, not a mode
(`WorkboardCaptureCanvas.swift:1275-1284`).

**What a card shows.** An image card that already holds a thumbnail, at `standard`
or `large` footprint, draws **image-forward**: full-bleed thumbnail, gradient scrim,
name, and a size-plus-relative-age footer
(`WorkboardCaptureCanvas.swift:2148-2222`). Everything else draws the glyph/text
tile, whose density steps with card size — `small` is artwork plus one truncated
line, `standard` adds a 2-line preview body and footer, `large` is a horizontal
92pt artwork plus kind label plus 4-line preview
(`WorkboardCaptureCanvas.swift` `cardBody`, ~2101-2170). A non-`available` card
overlays an availability glyph: `internaldrive` (teal) for local-only,
`icloud.and.arrow.down` (tertiary) for syncing, `paperclip.badge.ellipsis` (warning)
for missing. Audio draws `WorkboardAudioCardView` with an inline transport instead.

The board sits inside a `ScrollView` capped at `WorkboardMetrics.contentMaxWidth`,
with the composer as a bottom safe-area inset
(`Views/Workboard/WorkboardDetailView.swift:33-81`).

---

## 3. Drag and drop

**Legacy API, not the modern one.** Each card gets `.onDrag { NSItemProvider }`
(`WorkboardCaptureCanvas.swift:1310-1319`); the board gets ONE `.onDrop(of:delegate:)`
with a hand-written `DropDelegate` (`WorkboardArrangement.swift:65-97`).
`WorkMaterialDragPayload` does conform to `Transferable`
(`WorkboardComponents.swift:38-45`) but **that conformance is unused** — the board
hand-rolls `registerDataRepresentation` for `UTType.conduckWorkboardMaterial` at
`visibility: .ownProcess`, so the pane-wide file importer cannot claim its own drag
(`WorkboardArrangement.swift:48-63`). Nothing in the app uses `.draggable` or
`.dropDestination`.

Works on **both platforms and in both layouts**. Hovering only moves an amber capsule
insertion marker; cards never shift under the finger, so their moving targets cannot
oscillate (`WorkboardCaptureCanvas.swift:1332-1345`).

**Index resolution differs per layout** (`WorkboardCaptureCanvas.swift:1321-1330`):
- Tiles: the same engine `Result` the layout placed with, via
  `WorkboardMosaicLayout.insertionIndex(at:in:containerWidth:layoutDirection:)`, which
  undoes the centring inset and any RTL mirror, then picks a row band and the first
  tile in it whose horizontal midpoint is past the point
  (`WorkboardMosaicLayout.swift:211-236`, `:522-537`).
- List: measured row frames collected through `WorkboardRowFramesKey`, compared by
  vertical midpoint (`WorkboardArrangement.swift:40-46`).

**Commit path** (`WorkboardCaptureCanvas.swift:1466-1490`): capture the visible
neighbour id and a `.before`/`.after` placement rather than a bare integer, return
`true` from `performDrop`, then decode asynchronously and hop to the main actor to
call `viewModel.reorderMaterial(_:relativeTo:placement:)`.

**No TODO or FIXME comments exist anywhere in the Workboard sources.** Things that
would plausibly read as flaky, from reading the code (not measured):

- The commit is a round trip *after* the visual drop: `performDrop` returns true
  immediately and the store call lands later.
- Appending past a completely full final band relies on the trailing 24pt padding
  region existing as a drop surface (`WorkboardCaptureCanvas.swift:1183-1187`); when
  the index equals the card count the code uses `.after` on the last card
  (`:1469-1472`).
- One drop target covers the whole grid. There are no per-card drop targets, so a
  drop landing on a card is resolved purely by geometry.
- On iOS `.onDrag` requires a long press and offers no custom lift preview or haptic.
- `dropLocation` is cleared on `dropExited`, so tracking across gaps can blink the marker.
- A concurrent capture or CloudKit arrival bumps the desk revision, the store refuses
  the reorder as stale, the optimistic order rolls back, a corrective load runs, and
  the user gets a "Couldn't update the board" alert
  (`ViewModels/WorkboardViewModel.swift:1052-1102`).
- Dragging is disabled outright while an import is running
  (`WorkboardCaptureCanvas.swift:1311-1312`) and whenever the Work destination is
  not the active one.
- A folded pair is expanded to `[picture, recording]` adjacency immediately before
  the store call, because the store demands every logical id exactly once
  (`ViewModels/WorkboardViewModel.swift:456-474`, `:1052-1102`).

Non-drag equivalents: `Move Earlier` / `Move Later` menu rows and accessibility
actions run the same planner and announce the new position
(`WorkboardCaptureCanvas.swift:1508-1523`; `ViewModels/WorkboardViewModel.swift:919-933`).

---

## 4. Card open and preview

**The Work path.** A tile tap goes through `WorkboardCardActionPolicy.performPrimaryAction`
(`WorkboardCaptureCanvas.swift:344-353`), which gates on availability: readable bytes
open, missing bytes reattach, syncing bytes do nothing
(`Views/Workboard/WorkboardCardActionPolicy.swift:41-92`). That reaches
`viewModel.openMaterial` and then `PersonalWorkbenchRouter.present`
(`Views/Workboard/PersonalWorkbenchView.swift:419-520`), which re-resolves the card
against the CURRENT desk (`:551-555`) and re-applies the same gate before branching:

- `note` → sheet with selectable text (`PersonalWorkbenchView.swift:1365-1400`).
- `link` → `ContentUnavailableView` with an Open Link button.
- `image` → `.imageGallery(pages:startIndex:)`, built from the whole desk's openable
  image cards filtered through the same availability gate
  (`PersonalWorkbenchView.swift:575-600`).
- `file`, `audio` → a disposable `WorkMaterialExportSnapshot` copy handed to
  `FilePreviewCoordinator`, presented by `.quickLookPreview`
  (`PersonalWorkbenchView.swift:487-513`, `:989`).

`WorkboardDetailView` is **not** the preview. It is the desk itself (board plus
pinned composer, `Views/Workboard/WorkboardDetailView.swift:16-82`). The preview
sheet is `WorkboardMaterialPreviewView` (`PersonalWorkbenchView.swift:1288-1408`).

**Are Work and Chat the same component? Yes, twice over.**

1. *The gallery.* `AttachmentFullScreenView` is deliberately model-free: a page is
   `AttachmentGalleryPage` (id, optional thumbnail bytes, accessibility label) and
   full bytes arrive through a caller-owned `loadFullBytes` closure
   (`Views/Conversation/AttachmentFullScreenView.swift:36-44`, header 10-16). Chat
   calls it at `Views/Conversation/ConversationThreadView.swift:1767`; Work calls it
   at `PersonalWorkbenchView.swift:1303`. **One component, two call sites.**
2. *Quick Look.* `FilePreviewCoordinator` is one type with two instances — Chat's is
   view `@State` (`ConversationThreadView.swift:168`), Work's is router-owned
   (`PersonalWorkbenchView.swift:415`). They are deliberately not shared because
   `QLPreviewPanel` is application-shared and responder-chain controlled on macOS, so
   the two sections must be able to invalidate each other
   (`Views/Components/FilePreviewCoordinator.swift:6-17`).

**Where the divergence actually comes from:** the wrapper, not the component.
- Work passes the **whole desk's** openable images as pages, so a swipe is not a dead
  end; Chat passes one message's image attachments.
- Work bounds the full decode at 4096 px because older cards may still hold 40+
  megapixel originals; Chat has no such bound
  (`PersonalWorkbenchView.swift:1313-1321`).
- Work fills the generic `PageActions` slot with a Share button that follows the
  current page and shares the ORIGINAL bytes; Chat passes `EmptyView`
  (`PersonalWorkbenchView.swift:1322-1340`; `AttachmentFullScreenView.swift:127-131`).
- Work overlays its own share-progress banner because the gallery sheet is opaque and
  covers the desk's (`PersonalWorkbenchView.swift:1341-1350`).
- Work sets an ideal macOS sheet frame of 900x640 (`PersonalWorkbenchView.swift:1354-1361`).

**What each supports.** Gallery: paged `TabView`, pinch-zoom with drag and
double-tap reset, black ground, Done/X, thumbnail-first render then full bytes with a
spinner, per-page lazy loading, a residency window that drops non-neighbour decodes
under memory pressure (`AttachmentFullScreenView.swift:6-27`, `:110-125`), plus
Work's Share. Quick Look: PDF, video, audio playback, text, Open With, and the
system share sheet — which is exactly why files never get a bespoke sheet
(`PersonalWorkbenchView.swift:322-330`).

Board audio cards never reach the router; they own an inline transport
(`WorkboardAudioCardView`). Only the explicit "Open Recording" row routes a recording
to Quick Look (`PersonalWorkbenchView.swift:487-490`).

Reclaim policy is platform-split: iOS reclaims the temp copy on dismissal, macOS
leaves it to a launch age-sweep because "Open with" hands the target app the live path
(`FilePreviewCoordinator.swift:43-61`).

---

## 5. Composer

The "Add to Work…" bar is a pinned `safeAreaInset(edge: .bottom)` over the desk
scroll view, on an `.ultraThinMaterial` band that reaches both window edges
(`Views/Workboard/WorkboardDetailView.swift:62-73`). It is the same
`WorkboardCaptureCanvas` type as the board, in `.composer` mode
(`WorkboardCaptureCanvas.swift:14-17`, `:96-104`).

It reuses **Chat's composer card chrome** with Work's wiring
(`WorkboardCaptureCanvas.swift:388-437`):

- A vertical-axis `TextField` with placeholder "Add to Work…"
  (`WorkboardCaptureCanvas.swift:25-30`, `:479-521`).
- An attach `Menu`: Photo Library, Take Photo (iOS only), Files, Add Link
  (`Views/Workboard/WorkboardComponents.swift:181-206`).
- A mic button opening `WorkboardVoiceCaptureView`, whose transcript is **appended to
  the draft rather than committed directly** (`WorkboardCaptureCanvas.swift:130-140`,
  `:523-543`).
- An up-arrow submit, disabled unless the view model says a draft exists
  (`WorkboardCaptureCanvas.swift:545-560`).

Layout: card on macOS and regular-width iPad, single docked row everywhere narrower
(`WorkboardCaptureCanvas.swift:415-425`).

**How a capture lands.** Submitted text becomes a `.note` material whose title is the
first non-empty line trimmed to 72 characters, or the localized "Thought"
(`ViewModels/WorkboardViewModel.swift:475-503`, `:643-674`). Photos, files and links
go through `importMaterials`, which serializes on a desk-mutation lane and CASes on
the desk revision (`ViewModels/WorkboardViewModel.swift:675-769`).

**Drops** are owned by ONE pane-wide modifier applied above both the scrolling canvas
and the pinned composer, accepting `fileURL`, `image`, `url`, `utf8PlainText`, and
showing a dashed amber "Drop into Work" overlay
(`WorkboardCaptureCanvas.swift:791-900`). Its comment records the bug it fixed:
nested drop handlers made the composer reject a valid drop while the populated desk
had no handler at all.

Oversized payloads raise a soft confirm before copying, saying they stay on this
device instead of syncing (`WorkboardComponents.swift:213-270`).

External captures (share sheet, Shortcuts, Watch, Mac menu bar, CarPlay) never touch
this view. They land in a durable inbox drained by `WorkCaptureDrainer` and refreshed
by `WorkCaptureRefreshCoordinator`, which is the board's **sole load owner**
(`PersonalWorkbenchView.swift:664-770`).

Reattachment reuses the same file importer, single-selection, with the pending
material held in view state (`WorkboardCaptureCanvas.swift:109-114`, `:365-370`).

---

## 6. Selection, multi-select, actions

**There is no multi-select, no edit mode, no rename, and no note editing.** The
complete mutation surface is the view model's dependency struct
(`ViewModels/WorkboardViewModel.swift:512-566`): `loadDesk`, `importMaterial`,
`removeMaterial`, `removeMaterialGroup`, `replaceMaterial` (reattach),
`openMaterial`, `shareMaterial`, `reorderMaterials`, `setMaterialCardSize`. Nothing
edits a card's text, title, or caption after capture.

**Per-card actions** (`WorkboardCaptureCanvas.swift:2566-2648`;
`Views/Workboard/WorkboardMaterialListRow.swift:249-300`):

- Open (absent when bytes are not readable)
- Share (same gate as Open)
- Open Recording / Share Recording / Reattach Recording — only on a folded card, each
  acting on the companion alone through single-material coordinators
  (`WorkboardCaptureCanvas.swift:1073-1120`)
- Reattach or Replace (only when bytes are missing)
- Card Size, an inline `Picker` over Small / Standard / Large
- Move Earlier / Move Later
- Remove Material, destructive, behind a `confirmationDialog` whose message names the
  pair for a folded card (`WorkboardCaptureCanvas.swift:1216-1258`)

Each action appears in **three** places: a hover-revealed ellipsis `Menu`, a
`.contextMenu`, and — because the menu is accessibility-hidden — a matching set of
`.accessibilityActions` (`WorkboardCaptureCanvas.swift:2652-2707`). A list row also
shows a non-interactive `line.3.horizontal` grip glyph
(`WorkboardMaterialListRow.swift:68-78`).

Playback on an audio card or folded row is a fourth verb, gated by
`WorkboardCardActionPolicy.allows(.play,…)` and never routed through the preview
funnel (`WorkboardCardActionPolicy.swift:63-75`).

Removal is not optimistic: the card leaves the board only when the store confirms
(`ViewModels/WorkboardViewModel.swift:970-1050`).

---

## 7. Platform split

The desk itself is **shared, not forked**. `WorkboardDetailColumn` →
`WorkboardDetailView` → `WorkboardCaptureCanvas` is identical everywhere
(`Views/Workboard/WorkboardView.swift:214-275`). `WorkboardExperience` splits the
surface into two reusable values — a column and a presentation modifier — so hosts can
mount them separately (`WorkboardView.swift:34-65`).

`PersonalWorkbenchView` is the **host shell**, not an alternative board:

- **iPhone (compact)**: a `TabView` with Work and Chats tabs
  (`PersonalWorkbenchView.swift:1080-1108`).
- **iPad (regular)**: both destinations mounted in a `ZStack`, each owning its own
  `NavigationStack` and navigation bar, switched by a segmented
  `WorkbenchSectionControl` in the toolbar and cross-faded by opacity
  (`PersonalWorkbenchView.swift:1120-1165`).
- **macOS**: Work mounts INTO the app's one persistent `NavigationSplitView` window
  as `WorkboardExperience.detailColumn`; the sidebar column is force-collapsed while
  Work is active so the desk gets the whole window; the section picker is a zero-size
  toolbar host declared LAST so it stays trailing-most and cannot be shoved sideways
  by Chat's conditional buttons (`Views/Conversation/MainWindowView.swift:574-650`).
  Work's layer unmounts when hidden; Chat's stays mounted because it owns a selected
  thread, an unsent composer and a live recorder
  (`MainWindowView.swift:564-573`).

`workbenchDestinationIsActive` is the environment gate that silences a hidden
destination's toolbar, title, sheets, alerts and system pickers
(`Views/Components/WorkbenchDestinationGate.swift:19-58`). Every Work presentation
binding is wrapped in `.gated(by:)`.

Other macOS-only differences: hover reveals the card menu
(`WorkboardCaptureCanvas.swift:2005-2007`), `.help` tooltips, ideal sheet sizing
(`WorkboardComponents.swift:60-90`), a 1...12 composer line limit versus 1...6, and
Quick Look reclaim on age-sweep rather than dismissal. `navigationBarTitleDisplayMode(.inline)`
is iOS-only (`WorkboardComponents.swift:47-58`).

---

## 8. Tests that pin behaviour

Roughly 35 `Workboard*` suites exist in `Conduck/ConduckTests/`. The ones a redesign
would collide with:

- **WorkboardOrderingTests** — drag order survives a fresh load and the next capture;
  a refused drag preserves cards and edits that arrived while it was saving; the drag
  provider carries identity without advertising a type the importer could claim.
- **WorkboardMosaicEngineTests** — tiles never overlap, frames stay inside the
  reported content box, reading order survives any mix of sizes, the column search
  behaves from narrow phone to wide Mac, degenerate widths stay finite, drop indices
  read in visual order in both layout directions.
- **WorkboardMaterialBoardActionsTests** — reorder rewrites canonical order and
  advances the owner revision; a resize is presentation and must leave it untouched.
- **WorkboardGalleryPagesTests** — which cards become pages, in what order, and where
  the tap landed; the availability filter must not let a syncing card's thumbnail
  stand in for a picture.
- **WorkboardOpenPathTests** — one place decides what a card's bytes permit; missing
  bytes permit only repair, arriving bytes permit nothing.
- **WorkboardImageCardLayoutTests** — when a tile is spent on the picture instead of
  a row about the picture.
- **WorkboardCompanionCardTests** — a folded card must show, name, play and speak its
  recording, and the band's placement and rows are pure rules.
- **WorkboardCompanionActionsTests / WorkboardCompanionFoldTests** — each companion
  route acts on the recording, never the picture; one Delete removes both members.
- **WorkboardDeskPresentationTests** — four surface states; the desk before its first
  capture keeps the pinned composer, a failed load does not.
- **WorkboardBoardProjectionTests** — the composer's emptiness flag normalizes before
  answering; a late mutation result never undoes a newer read.
- **WorkboardDeskSurfaceDriftGuardTests** — SOURCE guard that
  `WorkCaptureRefreshCoordinator` is the board's sole load owner; nothing may call
  `workboardViewModel.load()` directly.
- **MacWorkbenchShellDriftGuardTests** — SOURCE guard on the macOS window: sidebar
  collapsed while Work is active, Chat's own collapse state surviving the round trip,
  section-control placement.
- **WorkboardCopyTruthGuardTests** — seven copy rules read from the shipped `.xcstrings`
  catalog rather than through `String(localized:)`. Rule 1 is the vocabulary rule:
  Work opens, keeps and removes, and never sends, dispatches, briefs, or holds a
  draft. Rule 4 fails on both a key with no catalog row and a row no source
  references, so **any new or deleted Work string breaks the build until the catalog
  matches**.
- **WorkboardMaterialPresentationTests** — Work and Chat describe the same file once;
  glyphs and tints come from Chat's `AttachmentChipStyle`.

---

## The dispatch boundary ("no code path leads from Work to a gateway")

**Confirmed.** There is no gateway, dispatch, send, or transport symbol anywhere in
`Views/Workboard/`, `Services/Workboard/`, or `ViewModels/WorkboardViewModel.swift`.
Every "transport" match in those files is an audio playback control. The view model's
dependency struct offers no send closure at all
(`ViewModels/WorkboardViewModel.swift:512-566`). `WorkItemContent.preferredGatewayRef`
survives as a column the desk never writes
(`Models/WorkboardRecords.swift:47-79`).

**Where it is enforced.** Structurally rather than by a guard object: the capture
canvas has no transport dependency by construction, stated in its own header —
"this view has no transport dependency of any kind, so capture can never become a
send" (`WorkboardCaptureCanvas.swift:6-8`) — and the capture destination is a private
single-case enum the canvas states rather than a host argument, specifically to keep
a second destination from creeping back in (`WorkboardCaptureCanvas.swift:19-44`).
The behavioural backstop is `WorkboardCopyTruthGuardTests` rule 1, which fails the
build if any `workboard.*` string implies sending.

**`WorkbenchDestinationGate` is NOT this boundary.** It is the Work-versus-Chats
*presentation* gate that stops a hidden pane floating a picker or re-anchoring a sheet
over the visible one (`Views/Components/WorkbenchDestinationGate.swift:6-15`). The
Add-to-Work versus Ask-a-gateway split lives on the Chat side (the share sheet places
Work beside Send, never among the destinations) and in the capture canvas's own
dependency-free construction.

**One honest caveat.** The Work voice-capture sheet does have an outbound
destination: the speech provider the person configured, which may be a cloud AI. The
copy guard's rule 3 requires that sheet to name it rather than deny it, while
promising the boundary the desk does enforce — the audio is transcribed and never
becomes part of a conversation.
