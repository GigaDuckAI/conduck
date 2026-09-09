# Opening a card: preview, and the card interaction model

## 1. Diagnosis

**Work's preview is not custom, and that is the problem.** It is Chat's
`AttachmentFullScreenView` — one component, two call sites
(`ConversationThreadView.swift:1767`, `PersonalWorkbenchView.swift:1303`) — and files and
recordings already reach Quick Look through the same `FilePreviewCoordinator` type.

**On macOS the shared component renders a malformed control.** `.tabViewStyle(.page)` is
unavailable on native macOS, so it is applied only inside `#if os(iOS)`
(`AttachmentFullScreenView.swift:245`). The Mac falls through to the default tab-bar style,
and because no page sets a `.tabItem`, every page becomes an *unlabeled tab*. Codex
compiled a probe against the macOS 26.5 SDK on a 26.6 runtime: 12 pages produced a
12-segment `NSSegmentedControl` with nil labels, above the content. The screenshot matches
— a dark capsule holding one blue square with grey dots either side, floating clear of the
sheet's own top edge. That is not a page indicator Conduck drew. It is an unlabeled
segmented control escaping its container. Work amplifies it by paging the *whole desk*
(`gallerySelection`, `:575-600`) where Chat pages one message.

So the founder's question has a precise answer: there is no custom preview. There is the
standard one, drawing a broken container on the Mac.

The rest is wrapper: a bare Share glyph opposite the X with no toolbar between them, a
share-progress banner, and a 900x640 sheet against Chat's 600x500 (both are sheets on macOS;
the cover-versus-sheet split I assumed does not exist). The sheet carries **no filename,
size, date or zoom control** — nothing naming what you are looking at.

Two more inconsistencies, neither of them Work-versus-Chat:

- **Four kinds, four unrelated screens.** Image → black pager. File/audio → Quick Look.
  Note → a nav-bar sheet of frozen text. Link → an empty-state view whose whole content is
  the URL plus an Open Link button.
- **A click can do nothing.** For `.syncPending`, `primaryAction` is nil and the tile is
  deliberately not a Button (`WorkboardCaptureCanvas.swift:2046-2052`). A 12pt glyph is the
  only explanation; the sentence exists in VoiceOver only.

**And the tile already says everything twice.** A note's title is its first non-empty line
(`WorkboardWorkspaceCaptureLogic.title`) while its preview body is the *whole* text, so the
one-line note in the screenshot reads "hi" over "hi", and a voice note repeats its transcript
the same way. That is why those tiles look 85% empty while their sheets add nothing.

## 2. Options

**A. Strip Work's wrapper to Chat's.** Cheap, and it makes them identical — identically
broken on the Mac. Reject.

**B. Quick Look everything, images included.** My first objection — that `QLPreviewItem` is
synchronous over a file URL and so forces pre-materializing the desk — is wrong: an item may
return a nil `previewItemURL`, prepare its file off the callback, then call
`refreshCurrentPreviewItem()`. The costs are elsewhere. Images that never touch disk gain a
file-backed lifecycle, and `FilePreviewReclaimPolicy` on macOS reclaims on a *launch*
age-sweep with no cap, so a long-running Mac accumulates copies for weeks — Chat's
`AgentDownloadScratch` sweeps on every adoption for exactly this reason and Work bypasses
that protection. Thumbnail-first rendering is lost, and Markup would edit a disposable copy
with no write-back. Reject as the default.

**C. Fix the container, keep the component.** One component, one cursor, two platform
containers: iOS keeps the `TabView` pager, macOS renders the current page directly with
Previous/Next, arrow keys and a counter — how Preview and Photos navigate.

**D. Mac interaction model.** Click selects, double-click opens, Space Quick Looks.
Finder's contract, and the substrate multi-select needs. A package, not a shortcut.

**On "why not just make it Quick Look on the Mac?"** — fair, since a black sheet with two
floating glyphs looks nothing like the system panel. But the founder asked for *"the standard
preview we also have in chat"*, a Work-versus-Chat comparison. Fixing the container and adding
a header buys most of the system feel at none of B's cost. "Open with" is the one affordance
that needs a real file, so offer it on demand.

## 3. Recommendation: C first, in this order

**1. Fix the Mac pager.** Render the current page directly on macOS with `.id(page.id)` so
image, zoom and loading state reset on navigation; Previous/Next plus arrow keys; a counter
that *explains* the collection instead of implying one. Keep `AttachmentGallerySelection` as
the single cursor so Share follows the visible page. Branch the container inside the shared
component — separate galleries would drift. **Chat takes the same fix.**

**2. Never let a click be silent.** `.syncPending` is the silent state; an unavailable card
already routes to Reattach. Give syncing a visible "Waiting for iCloud" at standard and large,
not only in VoiceOver. `.localOnly` is not an error and should stop looking like one.

**3. Links open in the browser on click.** Delete the placeholder sheet; show host as title
and path as preview. **No fetched title or favicon** — that is the desk making an outbound
request on its own. Separately: a Safari page shared to Work lands as a markdown document
while a bare URL lands as a bare link. Same intent, two card types.

**4. Name what you are looking at, and say it once.** Give the Mac sheet a real header —
filename, counter, Share, close — which is most of what Quick Look's titlebar carries and
what this sheet has none of. Chat gets the same header and the Share it lacks. Pair it with
the duplication fix: when the preview body starts with the title, show the remainder, or
nothing when there is none.

**5. The Mac selection package.** Click selects, Cmd-click toggles, Shift-click ranges
(the mosaic guarantees reading order). Double-click opens. Space Quick Looks one card.
Cmd-A, Delete, Escape. iOS keeps tap-to-open plus a Select mode, because that is what both
platforms' own apps do. Verified costs: the standalone audio tile *is* the play button today
(`WorkboardAudioCardView`, `Button(action: toggle)`), and the drag payload holds one id while
the drop delegate takes the first provider, so moving a selection needs a batch operation.

**6. Note editing, last, because it is the only item that can lose words.** A `TextEditor`
sheet with a durable draft keyed by material id. There is a precedent to copy:
`WorkVoiceCaptureCoordinator` writes a transcript onto its card as "a content edit, not a
repair", advancing both revisions. Do not re-derive the title from the first line —
chat-captured notes are titled "Chat response", and the record does not store *why* a title
exists.

**7. The folded card opens as one sheet** — picture in the gallery, the recording's
transport along its bottom.

**Boundary note.** Nothing here adds an outbound path, so the desk's "nothing leaves
without an explicit act" claim survives intact — but selection is the substrate
grouping-then-dispatch will ride on. The live temptation is the link card: opening a URL is
the person's own click; fetching its title is the desk phoning out unasked.

**Top three risks.** (1) Note editing can silently destroy a sentence. The compare-and-swap
is a *local* Core Data check on `updatedAt`, not a CloudKit server token, and materials sync
independently — two offline devices can both edit one note, both pass their check, both
report success, and mirroring resolves last-writer-wins. (2) Click-to-select rewrites the
desk's interaction contract on day one and changes what an audio tile means; ship it whole or
not at all. (3) Quick Look temp copies already accumulate on the Mac with no cap, so making
Space a habit turns an existing leak load-bearing.

## 4. Codex debate log

- **It reproduced the Mac defect I only hypothesised**, compiling a probe against the macOS
  26.5 SDK on a 26.6 runtime: an unlabeled segmented control, one segment per page. That
  turned a wrapper critique into a bug report and reordered the memo.
- **It refuted my Quick Look objection on the API**, so I kept the rejection and rewrote its
  grounds: retention, thumbnail-first, and Markup with nowhere to write back.
- **It killed my selection-scoped paging.** Opening one screenshot would leave you unable to
  reach the next without entering Select mode, and the first click of a double-click can
  collapse the selection before Open reads it.
- **It corrected four claims of mine**: Chat is a sheet on macOS too, the audio tile is
  itself the play button, chat-captured notes carry assigned provenance titles, and the copy
  guard fails the test suite rather than compilation. It also found the sharpest note-editing
  failure — two *successful* saves.
- **I pushed back on its ranking and it changed.** It had links above availability; I argued
  a silent click on a common card beats an extra click on a rare one. It agreed, adding that
  only `.syncPending` is genuinely silent. I also rejected a full Mac gallery fork: one
  component with a branched container keeps the cursor contract.
- **Unresolved:** whether Space on a selected *audio* card should Quick Look or play. I chose
  Quick Look for consistency and named the collision rather than hiding it.
