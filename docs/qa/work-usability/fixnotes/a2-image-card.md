# a2-image-card — image-forward desk cards + the voice-launch route consumer

## What changed

`Conduck/Conduck/Views/Workboard/WorkboardCaptureCanvas.swift` (the only app file touched)

**Task 1 — image-forward cards**

- **`enum WorkboardCardArtworkMode`** — new, file-scope, internal. `resolve(kind:hasThumbnail:footprint:)`
  answers `.imageForward` for `.image` + thumbnail bytes at `.standard`/`.large`, `.inline`
  everywhere else. Pure, so the rule is asserted directly instead of inferred from a
  rendered card.
- **`WorkboardSourceCard.tile`** — was one chain, is now a `@ViewBuilder` switch on
  `artworkMode` over two chains: `inlineTile` (today's padded text layout, moved
  VERBATIM, not re-expressed) and the new `imageForwardTile`. Two chains rather than one
  chain with a branching background, so the glyph card's geometry cannot be moved by the
  photo card's existence.
- **`imageForwardTile`** — `Color.clear` states the geometry, the thumbnail fills it as an
  overlay, `.clipShape` turns the `scaledToFill` overflow into a fill. Same card shape,
  same `AppColors.cardBackgroundElevated` behind it, same `borderSubtle` stroke, same
  `contentShape`. `Color.clear` is load-bearing: a `scaledToFill` image proposes a size of
  its own, and letting that reach the mosaic slot would make one photo's aspect ratio move
  the card it sits in.
- **`imageForwardArtwork`** — `stagedThumbnail(data:placeholder:)` with the card's own
  surface (`AppColors.backgroundSecondary`) as the decode-gap placeholder, not a glyph: a
  symbol at tile size flashes big and vanishes, which reads as a failure.
- **`imageForwardAvailability`** — the SAME `availabilityGlyphName` / `availabilityGlyphTint`
  as the text layout, top-leading, on a `Color.black.opacity(0.45)` disc so the tint
  survives an arbitrary photo. An `.available` card draws nothing, exactly as before.
- **`imageForwardCaption`** — name (`.subheadline.weight(.semibold)`, `Color.white`,
  2 lines) over `footerRow(tint: .white.opacity(0.85))`, on a bottom-anchored
  black 0 → 0.45 → 0.78 `LinearGradient`. The gradient is the caption's own `.background`,
  not a fixed slice of the tile, so it grows WITH Dynamic Type instead of letting a
  large-type name climb off the dark band onto the photo.
- **`cardFooter`** — split into `cardFooter` (delegate, tint `AppColors.textTertiary`) and
  `footerRow(tint:)`. The row is byte-identical; only the tint became a parameter, because
  the tertiary text colour disappears over a photograph.
- **`stagedThumbnail(data:placeholder:)`** — new, generic over the placeholder, returning
  `StagedImageTile<Placeholder>`. `artwork(dimension:cornerRadius:)` now builds through it,
  so the small artwork and the full-bleed tile share ONE `DecodedImageCache` key
  (`id`, byte count, `ImageProcessor.thumbnailMaxPixel`, `material.revision`).
- **`enum WorkboardCardAccessibility`** — new, file-scope, internal. `previewText(for:)`,
  `summary(material:cardSize:boardPosition:boardCount:)`, `boardPositionLabel(position:count:)`,
  `availabilityLabel(for:)` — all lifted VERBATIM out of the private card, which now holds
  three one-line delegates. The composition is unchanged; it moved so the spoken card can
  be asserted, since the image-forward tile hands VoiceOver no picture and the words are
  therefore the whole card there. `WorkboardSourceCard.boardPositionLabel` is kept as a
  delegate so the canvas's existing announcement call site is untouched.
- **`cardBody`, `previewBody`, `artworkPlaceholder`, `availabilityGlyph`,
  `availabilityGlyphName`, `availabilityGlyphTint`, `cardMenu`, `menuHitDimension`,
  `layoutSize`, the `body` ZStack and the mosaic** — untouched. The menu corner is drawn by
  `body`'s `ZStack(alignment: .topTrailing)` OUTSIDE `tile`, so it is in the same place on
  both layouts by construction.

**Task 2 — voice-launch route consumer**

- **`consumeVoiceCaptureLaunchRoute()`** — new private method on `WorkboardCaptureCanvas`,
  wired from `.onAppear`, `.onReceive(.showWorkboardVoiceCapture)` and the `isActive` branch
  of the existing `.onChange(of: workbenchDestinationIsActive)`. It sets `showsVoiceCapture`,
  the same state the mic button sets.
- The existing `.onChange(of: workbenchDestinationIsActive)` gained an `else` — the
  `if !isActive { dismissTransientCaptureUI() }` behaviour is unchanged, the new `if isActive`
  branch lands a request that arrived while the pane was hidden.
- **I did NOT create the placeholder.** `Views/Workboard/WorkVoiceCaptureLaunchRoute.swift`
  was already on disk from b2 when I reached this task, with exactly the contracted shape
  (`static let shared`, `func request()`, `func consume() -> Bool`, and
  `Notification.Name.showWorkboardVoiceCapture`). I coded against it as found.

`Conduck/ConduckTests/WorkboardImageCardLayoutTests.swift` — new.
`Conduck/ConduckTests/WorkboardMaterialPresentationTests.swift` — one case added.

## New API (exact signatures)

```swift
enum WorkboardCardArtworkMode: String, Equatable, Sendable {
    case imageForward
    case inline

    static func resolve(
        kind: WorkboardMaterialKind,
        hasThumbnail: Bool,
        footprint: WorkMaterialCardSize
    ) -> WorkboardCardArtworkMode
}
```
```swift
enum WorkboardCardAccessibility {
    static func previewText(for material: WorkboardMaterialSnapshot) -> String?
    static func summary(
        material: WorkboardMaterialSnapshot,
        cardSize: WorkMaterialCardSize,
        boardPosition: Int,
        boardCount: Int
    ) -> String
    static func boardPositionLabel(position: Int, count: Int) -> String
    static func availabilityLabel(
        for availability: WorkboardMaterialAvailability
    ) -> LocalizedStringResource
}
```

Both are MainActor-isolated by the target's `SWIFT_DEFAULT_ACTOR_ISOLATION`, like the rest
of this file. `WorkboardSourceCard` stays `private`.

## New strings

**None.** The image-forward card draws `material.name` and the same footer the text layout
draws; the availability glyph reuses the existing keys through
`WorkboardCardAccessibility.availabilityLabel`. No key was reworded, added or removed.

## Tests

`ConduckTests/WorkboardImageCardLayoutTests.swift` — `WorkboardImageCardLayoutTests`, 6 cases:
`testAnImageWithAThumbnailFillsTheStandardAndLargeFootprints`,
`testTheSmallFootprintNeverFillsItsTileWithThePicture`,
`testAnImageWithoutAThumbnailKeepsTheTextLayoutAtEveryFootprint`,
`testNoOtherKindGoesImageForwardEvenWithThumbnailBytes`,
`testTheWholeKindThumbnailFootprintMatrixMatchesTheStatedRule` (all 5 kinds × 2 × 3 = 30
combinations, and the count itself is asserted so a kind added later cannot slip through),
`testTheGrantedFootprintIsWhatDecides`.

`ConduckTests/WorkboardMaterialPresentationTests.swift` — one addition,
`testAnImageForwardCardStillSpeaksItsKindNameAndAvailability`: a `syncPending` large photo
resolves `.imageForward`, its spoken summary still contains the kind title, the name, the
availability line and the board position, and the SAME card without thumbnail bytes
(which resolves `.inline`) speaks an identical string — losing the picture must not lose
the words.

Measured on the shared worktree, one `test-without-building` invocation, 4
`Test Suite … started` lines (so no `-only-testing` filter passed vacuously):

| Suite | Result |
|---|---|
| `WorkboardImageCardLayoutTests` | **Executed 6 tests, 0 failures** |
| `WorkboardMaterialPresentationTests` | **Executed 5 tests, 0 failures** |
| `WorkboardMosaicEngineTests` | **Executed 26 tests, 0 failures** |
| `WorkboardCopyTruthGuardTests` | Executed 10 tests, **8 failures — none mine**, see below |
| combined | Executed 47 tests, 8 failures |

Builds, `~/Library/Caches/gigaduck-builds/work-a2/`, no `-configuration` flag:

| Target | Result |
|---|---|
| macOS `build` (`platform=macOS`, `ddmac`) | exit 0, **0** `: error: ` |
| iOS `build-for-testing` (sim `04DEF4F5`, `dd`) | exit 0, **0** `: error: ` |

**The 8 `WorkboardCopyTruthGuardTests` failures belong to other slices and to the copy
agent that has not run yet.** This slice added, removed and reworded ZERO catalog keys, so
none of the eight can be mine:

- `testEveryWorkKeyInSourceHasACatalogRow` — 4 NEW keys with no catalog row yet:
  `workboard.menuBar.compose.work.title`, `…compose.work.placeholder`,
  `…saved.open.help`, `…voice.cardMissing` (slice D).
- `testEveryWorkCatalogRowIsReferencedInSource` — 4 ORPHANED rows:
  `workboard.material.preview.unavailable.title`, `…unavailable.message`,
  `workboard.material.openFile`, `workboard.material.file.ready` (slice A3 deleted
  `WorkboardPreviewImage`; the plan hands those rows to the copy agent to reuse or remove).

Cleaned with `.claude/scripts/clean-build-cache.sh work-a2`.

## Requests

1. **Copy agent** — nothing from me (zero new/changed keys). Noted only so the 8 guard
   failures above are not mistaken for a regression in this slice: 4 are slice D's new
   `workboard.menuBar.*` rows and 4 are slice A3's orphans.
2. **Nobody else** — no file outside my ownership needed a change. In particular I did NOT
   touch `WorkVoiceCaptureLaunchRoute.swift` (b2's, already correct) or
   `PersonalWorkbenchView.swift`.

## Nobody undo

- **`Color.clear` is the geometry of `imageForwardTile`, and the image is an overlay.**
  Collapsing that into `StagedImageTile(...).frame(maxWidth: .infinity, maxHeight: .infinity)`
  puts a `scaledToFill` image's own proposed size back into the layout, so a portrait photo
  and a landscape one in adjacent slots stop agreeing about the card height the mosaic
  granted.
- **The scrim is the caption's `.background`, never a fixed-height band over the tile.**
  A fixed band is right at one type size and wrong at every other; at accessibility sizes
  the name lands on the photograph and becomes unreadable, which is the exact failure the
  scrim exists to prevent.
- **`Color.white` in the caption is a literal, not `AppColors.textPrimary`.** The surface
  underneath is a photograph, which does not follow the appearance — a semantic colour goes
  dark-on-dark in light mode.
- **`stagedThumbnail` is the ONE construction site for this card's decode.** A second
  `StagedImageTile(...)` written inline would drift one component of the cache key
  (`id`, byte count, `maxPixel`, `revision`) and pay for the same picture twice, once per
  footprint — the cost `StagedImageTile` exists to remove.
- **`resolve` is asked about `layoutSize`, never `size`.** `layoutSize` is the footprint the
  mosaic GRANTED; a `large` card clamped to a standard slot must caption a standard tile.
- **The `.inline` verdict for a thumbnail-less image card is deliberate, not a fallback.**
  A card with no preview bytes drawn image-forward is an empty frame with a caption floating
  over nothing.
- **`inlineTile` is today's chain, moved without re-expression.** It is not
  `imageForwardTile` with a different background: keeping them apart is what makes "every
  non-image card is unchanged" a structural claim rather than a visual one.
- **In `consumeVoiceCaptureLaunchRoute()` the gates come BEFORE `consume()`.** `consume()`
  is one-shot read-and-clear, so claiming first and then refusing to present (hidden pane,
  `.sources` canvas, a sheet already up) SPENDS the request and shows nothing. A hidden
  Work pane must leave the route pending — which is why the `isActive` branch of
  `.onChange(of: workbenchDestinationIsActive)` exists at all: `RecordWorkNoteIntent` posts
  `.showWorkboardVoiceCapture` BEFORE `.showWorkboard`, so on a warm app the notification
  always arrives while the desk is still hidden.
- **The `mode == .composer` guard.** Both canvases are mounted together and only the
  composer one owns the voice sheet; consuming in `.sources` would take the request away
  from the surface that can honour it.

## Founder QA

Desk, **Mac** (`⌘,`-free path: open the app, switch to Work):

1. **Standard image card.** Drop a photo on the desk. The card is the PHOTO, edge to edge,
   with its name and the size/age footer on a dark band across the bottom. The band must be
   dark enough to read white text on a white photo — try a screenshot of a blank document.
2. **Large image card.** Card menu (the `…` corner) → Card Size → Large. Same treatment,
   wider. Then narrow the window until the grid can no longer grant four columns: the card
   falls back to the standard footprint and must still be a photo, not a text row.
3. **Small image card.** Card Size → Small. It goes BACK to today's layout: a 30pt
   thumbnail with one line of name beside it. A caption over the photo here would be a bug.
4. **A text card is unchanged.** Type a thought into the composer and add it. The note card
   must look exactly as it did before this wave — glyph, name, preview text, footer, no
   scrim, no photo treatment. Same for a dropped PDF and a dropped link.
5. **Hover.** The `…` menu corner still fades in on hover over a photo card and sits in the
   same corner as on a text card; the whole card still lights on hover and still opens on
   click.
6. **A `syncPending` image card still refuses the tap.** Easiest on the second Mac/iPhone
   right after adding a photo on the other one: while the card shows the
   `icloud.and.arrow.down` glyph, the glyph must be visible ON the photo (dark disc,
   top-left) and clicking the card must do NOTHING — no sheet, no gallery, no beep. It must
   also not draw as a button (no hover lift).
7. **A `localOnly` / reattach card.** Same check for the teal `internaldrive` and the amber
   `paperclip.badge.ellipsis` glyph: visible on the photo, and the tap offers Reattach
   rather than opening.

Desk, **iPhone**: repeat 1–4 and 6. On iPhone the `…` corner is always visible (no hover) —
confirm it is legible over a photo and that the context menu (long-press) still opens.

**VoiceOver** (iPhone: triple-click side button; Mac: `⌘F5`). Swipe to a photo card that
fills its tile. It must speak: *"Image. <name>. [Waiting for iCloud… if pending]. Large.
2 of 5"* — the same words a glyph card speaks. **Failure case to look for:** it says only
the name, or says "image" twice, or the photo is announced as an unlabelled image element.
The rotor's Actions must still list Reattach / Move Earlier / Move Later / Make Card
Small…/ Remove Material.

**Dynamic Type.** Settings → Accessibility → Display & Text Size → Larger Text, pushed to
the top. The photo card's name and footer must still sit on the dark band — the band grows
with them. **Failure case:** the name is on the photo with no dark behind it.

**Voice launch (Task 2).** Shortcuts app → run the "Record a Note to Work" action.
- From the **Chat** tab with the app already open: the app switches to Work AND the voice
  capture sheet opens. **Failure case:** it switches to Work but no recorder appears (the
  route was consumed while the pane was hidden), or a recorder appears over Chat.
- From a **cold** launch (swipe the app away first): same result once the desk mounts.
- Run it **twice in a row**: the second run must open the recorder again, and at no point
  should two recorders stack.
- Cancel the sheet, then switch to Chat and back to Work: **no** recorder may reappear —
  the request is spent.
- On the **Mac** with the window closed: the window opens on Work with the recorder up.

## Open questions

1. **The image-forward availability glyph sits top-LEADING at both footprints.** In the text
   layout it is top-leading at `.standard` (after the artwork) but top-TRAILING at `.large`
   (before the 26pt menu gap). Neither position survives literally once the artwork column
   and the text column are gone, and one consistent corner across both photo footprints
   beats mirroring two different ones. Founder call at QA step 6/7 — moving it to trailing
   is a two-line change.
2. **The image-forward caption drops the kind line and the preview text that the
   `.large` TEXT card carries.** A large glyph card draws name → "Image" → `detail` →
   footer; the photo card draws name → footer only. On a picture the kind line is noise
   (the tile IS the answer) and `detail` is empty for nearly every captured image, so both
   would spend scrim height on nothing. VoiceOver still hears both — the spoken summary is
   unchanged. Founder call at QA step 2 if the large photo card wants more caption.
3. **`width`/`height` are still nil on captured images** (f4's open question). The
   full-bleed tile therefore crops to the slot rather than honouring the source aspect
   ratio, which is what "image-forward" wants anyway — but if the founder ever asks for
   aspect-ratio-preserving photo cards, that is the field it needs.
4. **Nothing open on this slice's own verification.** Both builds are 0-error and all three
   suites that assert this slice pass. The only red is `WorkboardCopyTruthGuardTests`, whose
   8 failures are slice D's un-catalogued keys and slice A3's orphaned rows — the copy agent
   closes both.
