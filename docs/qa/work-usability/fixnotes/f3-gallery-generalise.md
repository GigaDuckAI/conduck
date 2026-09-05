# f3-gallery-generalise — A3 (preview), model-free image gallery

## What changed

**`Conduck/Conduck/Views/Conversation/AttachmentFullScreenView.swift`** (rewritten around a model-free core)
- `struct AttachmentGalleryPage: Identifiable, Sendable { id; thumbnailData; accessibilityLabel }` — the gallery's only page model.
- `AttachmentGalleryPage.pages(forImageAttachments:)` — Chat's `AttachmentRecord` → page mapping, pulled out as a `nonisolated` pure function so it is testable without building a view. Numbers pages 1-based through the EXISTING key `attachment.image.accessibility`.
- `enum AttachmentGalleryResidency.residentIndices(current:count:radius:)` — pure window arithmetic (clamps `current`, clamps both ends, radius 0 = current page only, empty gallery = empty set).
- `AttachmentFullScreenView` primary init is model-free (`pages:startIndex:loadFullBytes:fullDecodeMaxPixel:`); the convenience init `(imageAttachments:messageID:startIndex:)` is unchanged in shape, so `ConversationThreadView:~1767` compiles untouched (verified: that file was not edited and the iOS + macOS builds are clean).
- Per-page laziness + residency: each `ZoomableImagePage` asks the loader when it becomes RESIDENT (`.task(id: FullLoadKey(isResident:attempt:))`). Leaving the window cancels the in-flight load and drops the decoded full image; the thumbnail stays so a swipe back is never black. Full BYTES are never stored in view state — they are decoded and released inside the task.
- Memory warning (iOS): `.onReceive(UIApplication.didReceiveMemoryWarningNotification)` sets `residencyRadius = 0`, which releases both neighbours. It stays 0 for the life of the presentation.
- `ZoomableImagePage` failure state: `didFail` (loader threw, or bytes did not decode) renders a message + Retry when nothing is on screen, and a bare Retry button in the spinner's place when the thumbnail rendered but the original did not. Retry clears `didFail` and bumps `attempt`.
- `private actor MessageAttachmentBytesLoader` — Chat's loader. Resolves bytes by ATTACHMENT ID via `ConversationStore.loadLocalAttachmentPayloads(for:)`, single-flight, retains nothing after a load resolves.
- Unchanged on purpose: pinch 1–6x, pan gated to `scale > 1`, double-tap reset, `TabView(.page)` + `ForEach(..., id: \.offset)` + `.tag(index)`, black ground, the Done button, and the macOS sheet frame (which lives at `AttachmentImageGrid.fullScreenCoverCompat` — that file was NOT edited).

**`Conduck/Conduck/Utilities/Extensions.swift`** (addition only, inside the existing `extension Image`, directly after `decoded(from:maxPixel:)`)
- `Image.decodedStrictlyBounded(from:maxPixel:)` — `@concurrent nonisolated`, ImageIO-only through `ImageProcessor.displayCGImage`, returns `nil` on failure with NO `platformImage` fallback.

**NEW `Conduck/ConduckTests/AttachmentGalleryPageTests.swift`.**

## New API

```swift
struct AttachmentGalleryPage: Identifiable, Sendable {
    let id: UUID
    let thumbnailData: Data?
    let accessibilityLabel: String
}

extension AttachmentGalleryPage {
    nonisolated static func pages(forImageAttachments attachments: [AttachmentRecord]) -> [AttachmentGalleryPage]
}

enum AttachmentGalleryResidency {
    nonisolated static func residentIndices(current: Int, count: Int, radius: Int) -> Set<Int>
}

// Primary (Work uses this one)
AttachmentFullScreenView(
    pages: [AttachmentGalleryPage],
    startIndex: Int,
    loadFullBytes: @escaping @Sendable (UUID) async throws -> Data,
    fullDecodeMaxPixel: Int? = nil     // Work passes 4096; Chat passes nil
)

// Convenience (Chat's call site, signature unchanged)
AttachmentFullScreenView(imageAttachments: [AttachmentRecord], messageID: UUID, startIndex: Int)

extension Image {
    @concurrent nonisolated static func decodedStrictlyBounded(from data: Data, maxPixel: Int) async -> Image?
}
```

`loadFullBytes` is called at most once per page per residency entry and must THROW when the bytes are unavailable — the page turns that into the Retry state.

## New strings

```
attachment.gallery.loadFailed | This image couldn't be opened. | Shown in the full-screen image gallery when a picture's full bytes cannot be loaded or decoded.
attachment.gallery.retry | Retry | Button in the full-screen image gallery that re-attempts loading the current picture.
```

The existing `workboard.material.preview.unavailable.title` / `.message` pair was NOT reused: it is a card-level "No Preview" pair, while these two are a per-page failure line and a button label. No other key changed; `attachment.image.accessibility` and `attachment.fullscreen.done` are reused as-is.

## Tests

`ConduckTests/AttachmentGalleryPageTests.swift` — page mapping (order, id, thumbnail passthrough, 1-based label, empty list), residency arithmetic (neighbours, both ends clamped, radius 0, out-of-range current, empty gallery, radius wider than the gallery), strict decode (nil on non-image bytes, nil on empty bytes, non-nil on a generated JPEG) and the bound itself (512×256 at `maxPixel: 128` → 128×64; nil bound → 512×256).

Measured: `AttachmentGalleryPageTests` **Executed 14 tests, with 0 failures**; ran alongside `AttachmentWatchDisplayClassTests` (**17 tests, 0 failures**) — the only existing class covering attachment rendering symbols; grep found no existing test class naming `AttachmentFullScreenView` or `AttachmentImageGrid`.

Builds: iOS `build-for-testing` 0 errors, 0 new warnings in the three touched files; macOS `build` (`CODE_SIGNING_ALLOWED=NO`) 0 errors — the platform-conditional edits compile on both.

## Requests (files I do not own)

1. **Work router agent** (`PersonalWorkbenchRouter` / `PersonalWorkbenchView`): build the gallery with the PRIMARY init —
   `AttachmentFullScreenView(pages: pages, startIndex: i, loadFullBytes: { id in try await ConversationStore.shared.loadWorkMaterialPayload(id: id) }, fullDecodeMaxPixel: 4096)`.
   The loader must throw (not return empty `Data`) when a card's bytes are unreadable, so the page shows Retry instead of a broken image. Build `pages` with `AttachmentGalleryPage(id: card.id, thumbnailData: <card thumbnail>, accessibilityLabel: <card name>)` — the label is read by VoiceOver verbatim, so pass the material's name, not a numbered string.
2. **Copy agent**: add the two `attachment.gallery.*` keys above.
3. Nobody needs to edit `ConversationThreadView.swift` or `AttachmentImageGrid.swift` for this slice — both were left untouched and still compile.

## Nobody undo

- **The strict decoder has no fallback.** `decodedStrictlyBounded` returning nil where `decoded` would return an unbounded `UIImage`/`NSImage` is the entire point: the fallback in `decoded` is unbounded, so "just call `decoded`" on Work's originals re-opens the memory hazard the 4096 bound exists to close.
- **Residency releases the full image, not the thumbnail.** Dropping the thumbnail too would make a swipe-back go black; keeping the full image would make the window meaningless.
- **`residencyRadius` stays 0 after a memory warning.** Re-widening it re-runs the allocation the system just complained about.
- **Chat's loader is keyed by attachment ID, not by index.** `loadAttachmentData(for:)` drops rows whose image bytes are empty, so the old index-aligned map could show the wrong picture on every page after such a row. Do not "simplify" back to an index lookup.
- **The loader keeps no bytes after a load resolves** — only the in-flight Task is shared. A cache there would silently pin every page's full bytes.
- **`didFail` is terminal until Retry** and the load task early-returns on it; without that the `.task` re-arms and spins a failing load forever.
- **`Task.isCancelled` is checked before `didFail = true`** — a cancelled load is the residency window working, not an error.
- **`.simultaneousGesture(drag, including: scale > 1 ? .all : .none)`** still gates paging; an always-on drag recognizer breaks TabView swiping.

## Open questions

- Zoom state is deliberately NOT reset when a page leaves the residency window (today's behaviour preserved). A page released at 6x briefly shows a magnified thumbnail before the original re-decodes. Founder QA call: reset on release, or leave it.
- The bound is measured through `ImageProcessor.displayCGImage` (the whole of `decodedStrictlyBounded`'s decode) because a SwiftUI `Image` exposes no pixel size to assert on.
