# U-34 — Share on the Work desk

Share is now on every Work card (source card, audio card) and on the image
gallery, on iOS/iPadOS and macOS. One tap: the card's bytes are copied out of
the vault asynchronously behind a visible "Preparing…" banner, and the system's
share UI opens by itself once the copy lands. There is no second tap.

## What ships

**`WorkMaterialShareCoordinator` (`Conduck/Conduck/Views/Workboard/WorkMaterialShareCoordinator.swift`)**
Owned by `PersonalWorkbenchRouter` alongside `filePreview`, so it survives the
platform shells remounting the desk. Entry point is `share(materialID:)` — by
ID, not by snapshot, so the availability gate answers for the card that exists
rather than the one the menu closed over.

Flow: mint a monotonic token → resolve the card on the live desk → refuse unless
`WorkboardCardActionPolicy.allows(.open, …)` → prepare off the actor → on
completion re-check the token AND re-check the desk → present.

`PreparedWorkShare` is `.text(String)` (notes; an empty note falls back to its
title so the sheet is never opened on an empty string), `.link(URL)` (links) and
`.file(WorkMaterialExportSnapshot)` (image, file, recording — the ORIGINAL
bytes, never a thumbnail).

`acceptsPreparedShare(requested:desk:)` is the staleness rule, pure and static:
refuses a removed card, a changed `revision`, a changed `kind`, and bytes that
stopped being readable here. A card-size change is revision-neutral by contract
and does NOT refuse.

**Presentation** — `WorkMaterialSharePresenter`, behind the `WorkSharePresenting`
protocol so every decision above is testable without a window.
- iOS: `UIActivityViewController` presented from the TOPMOST view controller (the
  gallery is a sheet, so the root is often not the presenter), with
  `popoverPresentationController.sourceView`/`sourceRect` set unconditionally and
  `permittedArrowDirections = []`. That is the iPad trap `ServerFileExportPicker`'s
  header warns about.
- macOS: `NSSharingServicePicker(items:)` RETAINED on the presenter and shown with
  `show(relativeTo:of:preferredEdge:)`.

**`SharePresentationAnchor` (`Conduck/Conduck/Views/Components/SharePresentationAnchor.swift`)**
A registry of platform views, newest-attached-wins, installed with
`.sharePresentationAnchor(_:)`. Two surfaces register: the workbench shell and
the gallery sheet, so a share fired inside the gallery pops out of the gallery
rather than out of the desk it covers. `presentationView` skips any view with no
window, which is what makes a torn-down sheet fall back to the desk underneath.

**`WorkMaterialExportSnapshot` (`Conduck/Conduck/Services/Workboard/WorkMaterialExportSnapshot.swift`)**
The disposable-copy logic, extracted out of `PersonalWorkbenchView` and now used
by BOTH Quick Look and Share. Two lanes (vault copy, payload write) that share
one filename rule, one type rule and one reclaim rule.

Filename-parity defect FIXED. The vault lane used to ask only "is there any
extension?", so `Meeting v1.2` was read as having extension `.2` and its bytes
travelled with their type unstated, while the payload lane named it correctly.
One rule now, consulted in decreasing order of what each source knows about
content: a RECOGNISED extension already in the title → the stored MIME type →
the vault leaf's own extension (taken verbatim; it came off the original file).
`contentType` resolves from the finished filename, then the MIME, with `.data`
only as the unknown fallback.

Quick Look behaviour is unchanged: the router maps
`WorkMaterialExportError.bytesUnavailable` back to `WorkbenchPreviewError.unavailable`
so the preview lane keeps its own sentence, and only that case is remapped — a
file-system refusal still reaches the person as what it was.

**Reclaim / sweep.** A copy that failed, lost its token, lost the desk check, or
could not be presented is removed immediately. A copy that WAS handed to the
share UI is retained on both platforms, because nothing reports back from
another process.

Sweeper defect FIXED. Each copy is now its OWN top-level directory,
`Conduck-Workboard-Preview-<UUID>/`, directly under the shared temporary
directory. `TempScratchSweeper.sweep()` ages top-level entries by creation date,
so the sweep is now per-copy; previously every copy lived inside one
`Conduck-Workboard-Preview/` folder that was aged by ITS creation date, so a
copy made a second ago inside a day-old folder was deleted out from under a live
share. The owned prefix string is unchanged, so legacy folders still get swept.

**Menu + accessibility.** Share added to `cardMenuContent` in
`WorkboardCaptureCanvas.swift` and `WorkboardAudioCardView.swift`, gated on the
same `.open` permission Open uses, plus to `cardAccessibilityActions` in both —
the ellipsis menu is `accessibilityHidden`, so VoiceOver reaches Share there or
not at all. Plumbed `viewModel.shareMaterial` → `Dependencies.shareMaterial` →
`WorkboardLiveRepository`, mirroring `openMaterial`.

**Gallery.** `AttachmentFullScreenView` gained a `pageActions: (UUID) -> PageActions`
view-builder slot, handed the CURRENT selection's page id (so a swipe changes
what Share acts on). Chat is untouched: a constrained
`extension … where PageActions == EmptyView` carries both no-actions
initialisers. `AttachmentGalleryPage` stays plain `Sendable` data with no UI
closures on it.

**Failure surface.** Refusals go to the desk's existing `WorkboardNotice`
(`kind: .error`) rather than a second presenter racing the preview alert, and are
announced to VoiceOver. `WorkMaterialShareCoordinator.message(for:)` uses
`AppError.descriptionWithRecovery()` for typed errors and the system's own
sentence otherwise. No control is labelled "Retry" or "Try again", so
`ErrorSurfaceDriftGuardTests`' registry is untouched.

## New catalog keys

`workboard.material.share`, `.share.preparing`, `.share.failed.title`,
`.share.unavailable`, `.share.syncPending`, `.share.stale`, `.share.noAnchor`.
The retired `common.share` was NOT reused and is still absent.

## Files

Created:
- `Conduck/Conduck/Services/Workboard/WorkMaterialExportSnapshot.swift`
- `Conduck/Conduck/Views/Workboard/WorkMaterialShareCoordinator.swift`
- `Conduck/Conduck/Views/Components/SharePresentationAnchor.swift`
- `Conduck/ConduckTests/WorkMaterialShareTests.swift`

Changed:
- `Conduck/Conduck/Views/Workboard/PersonalWorkbenchView.swift`
- `Conduck/Conduck/Views/Workboard/WorkboardCaptureCanvas.swift`
- `Conduck/Conduck/Views/Workboard/WorkboardAudioCardView.swift`
- `Conduck/Conduck/Views/Conversation/AttachmentFullScreenView.swift`
- `Conduck/Conduck/ViewModels/WorkboardViewModel.swift`
- `Conduck/Conduck/Services/Workboard/WorkboardLiveRepository.swift`
- `Conduck/Conduck/Services/AgentDownloadScratch.swift` (prefix comment only)
- `Conduck/Conduck/Localizable.xcstrings`
- `Conduck/ConduckTests/WorkboardOpenPathTests.swift` (filename test now drives
  the extracted symbol)

## Tests

`WorkMaterialShareTests` (20 tests) covers preparation per kind, every
availability state, byte-identical export on both lanes, filename parity
including `Meeting v1.2`, content-type resolution, stale-desk rejection,
supersession, presentation failure, per-copy reclaim, the per-copy sweep, the
reclaim guard, the gallery slot's current-selection contract, Chat's `EmptyView`
default, and the catalog rows.

Targeted run (all 16 suites' "started" lines present):

```
Test Suite 'AttachmentGalleryPageTests' passed          — Executed 15 tests, with 0 failures (0 unexpected)
Test Suite 'ErrorSurfaceDriftGuardTests' passed         — Executed 7 tests, with 0 failures (0 unexpected)
Test Suite 'FilePreviewCoordinatorTests' passed         — Executed 11 tests, with 0 failures (0 unexpected)
Test Suite 'TempScratchSweeperTests' passed             — Executed 11 tests, with 0 failures (0 unexpected)
Test Suite 'WorkMaterialShareTests' passed              — Executed 20 tests, with 0 failures (0 unexpected)
Test Suite 'WorkboardAvailabilityTests' passed          — Executed 11 tests, with 0 failures (0 unexpected)
Test Suite 'WorkboardBoardProjectionTests' passed       — Executed 4 tests, with 0 failures (0 unexpected)
Test Suite 'WorkboardCopyTruthGuardTests' passed        — Executed 10 tests, with 0 failures (0 unexpected)
Test Suite 'WorkboardDeskPresentationTests' passed      — Executed 6 tests, with 0 failures (0 unexpected)
Test Suite 'WorkboardDeskViewModelTests' passed         — Executed 5 tests, with 0 failures (0 unexpected)
Test Suite 'WorkboardGalleryPagesTests' passed          — Executed 8 tests, with 0 failures (0 unexpected)
Test Suite 'WorkboardLiveRepositorySupportTests' passed — Executed 6 tests, with 0 failures (0 unexpected)
Test Suite 'WorkboardMaterialBoardActionsTests' passed  — Executed 12 tests, with 0 failures (0 unexpected)
Test Suite 'WorkboardOpenPathTests' passed              — Executed 9 tests, with 0 failures (0 unexpected)
Test Suite 'WorkboardSyncedRowRepairTests' passed       — Executed 4 tests, with 0 failures (0 unexpected)
Test Suite 'WorkboardWorkspaceCaptureTests' passed      — Executed 5 tests, with 0 failures (0 unexpected)
Executed 144 tests, with 0 failures (0 unexpected) in 16.981 (17.019) seconds
```

Whole target:

```
Test Suite 'ConduckTests.xctest' passed
	 Executed 5359 tests, with 1 test skipped and 0 failures (0 unexpected) in 84.264 (85.813) seconds
```

The one skip is pre-existing and unrelated:
`GatewayAdapterBriefTests.testClipboardBriefRevisionPinMatchesPublishedContract`
skips because there is no `website/` checkout beside this worktree.

`TempScratchLeafDriftGuardTests` caught a real regression on the first full run:
`makeContainer()` built its leaf from `containerPrefix + UUID()`, and the guard
reads source, so a non-literal leaf reads as unclaimable. The write site now
spells the prefix as a literal with the id interpolated; the constant and the
literal are held together by `testEachCopyOwnsItsOwnSweepableContainer`.

## Builds

```
xcodebuild build-for-testing … -destination 'platform=iOS Simulator,id=04DEF4F5-…'  → ** TEST BUILD SUCCEEDED **, 0 ": error:" lines
xcodebuild build … -destination 'platform=macOS'                                    → ** BUILD SUCCEEDED **, 0 ": error:" lines
```

## Not done / notes

- `plutil -lint` cannot validate `Localizable.xcstrings` on this machine: it
  rejects the file at `HEAD` too, and rejects a trivial `{"a":1}` JSON file, so
  it is not acting as a JSON linter here. The catalog was validated instead with
  `plutil -convert xml1 -o /dev/null Conduck/Conduck/Localizable.xcstrings`
  (exit 0, so plutil does parse it) and `python3 -m json.tool`.
  `WorkboardCopyTruthGuardTests` is green, which is the check that actually
  matters — it reads the shipped rows in both directions.
- Share cancellation is silent by design: no completion handler is attached on
  either platform, so a cancelled sheet leaves no trace and the copy is left to
  the age sweep exactly as a completed one is.
- The founder still has to QA this on a device/simulator. Suggested script is in
  the handoff back to the orchestrator.

---

# Round 4 fixes

Five findings from the Codex verification, all fixed.

## MAJOR 1 — the gates read the board, not the store

`WorkboardViewModel.desk` reloads behind a 180 ms debounce, so both share checks
were answering from a board that still drew a card the store had already
replaced or deleted. Because the byte read resolves the id against the store
independently, replacement bytes could leave the device under the OLD
revision's filename and MIME type.

The coordinator no longer reads the board at all. `deskMaterials` is gone,
replaced by an injected `currentMaterial: (UUID) async throws -> WorkboardMaterialSnapshot?`
wired to `WorkboardLiveRepository.currentMaterialSnapshot(id:)`, which projects
`ConversationStore.fetchWorkMaterial(id:)` through the SAME mapping the board
uses. `fetchWorkMaterial` went from private to internal to allow that; it reads
metadata only, no payload, so running it twice per share stays cheap whatever
the card's size.

The run is now: mint token → GATE 1 (store) → refuse or bind the export to THIS
revision's metadata → prepare → GATE 2 (store) → present. `acceptsPreparedShare`
took `desk:` and now takes `current:`, and refuses on a deleted card, a changed
revision, a changed kind, or bytes that stopped being readable. Card size stays
revision-neutral and does not refuse. Every `await` re-checks the token; a copy
that loses any check is reclaimed before the function returns.

Because any metadata change bumps `updatedAt` and therefore the revision, "bytes
exported under metadata of a different revision" is unreachable rather than
unlikely.

## MAJOR 2 — presentation was assumed, never measured

A note or a link is ready in the same runloop turn as the tap, so the request
landed on a context menu still dismissing. The iOS presenter followed even a
dismissing `presentedViewController`, called `present`, and returned `true`
regardless — so a refusal counted as a hand-off: nothing on screen, no failure
shown, and the copy kept alive.

`WorkSharePresenting` now has two members.
`awaitPresentationReadiness(from:)` polls until the topmost controller is not
`isBeingDismissed`/`isBeingPresented`, has no `transitionCoordinator`, presents
nothing, and is in a window — bounded at 2 s, after which it reports failure
rather than hanging a share forever. `present(_:from:)` re-checks that settled
state, presents, and returns `host.presentedViewController === controller`.
UIKit links the two controllers synchronously when it accepts and leaves them
unlinked when it refuses, so that is a measurement. It is deliberately the cheap
check rather than "did the view reach a window": a false negative would reclaim
bytes a live share sheet is reading.

The wait sits BETWEEN the two store gates, because the wait itself is long
enough for the desk to change again.

macOS: `show(relativeTo:of:preferredEdge:)` has no did-show callback, so what is
confirmed is everything AppKit requires — an anchor view inside a VISIBLE window
— and showing on an anchor outside a window, the one way it silently does
nothing, is refused. The picker also became a delegate so the retain is dropped
on `sharingServicePicker(_:didChoose:)`, bounding its lifetime to its own
presentation instead of to the next share.

## MAJOR 3 — the anchor registry was newest-UPDATED-wins

Both representables removed and re-appended their view on every SwiftUI update,
so any redraw of the workbench underneath promoted it above the still-attached
gallery and the next share popped out of the wrong surface.

`register(_:)` is now idempotent membership only, never a promotion. Reordering
happens in one place, `viewDidMoveToWindow(_:)`, called from a new
`SharePresentationAnchorPlatformView` subclass that overrides
`didMoveToWindow` / `viewDidMoveToWindow`. Attachment promotes; detachment
leaves the entry in place but stops it being eligible, so the surface underneath
wins again without re-registering.

## MAJOR 4 — "Preparing…" was invisible behind the gallery

The gallery sheet is opaque, so a slow export of a camera original showed
nothing, and a refusal landed on an alert the person could not see.

The banner was extracted into `WorkShareStatusBanner`, drawn by BOTH the shell
and the gallery sheet from the SAME coordinator — one piece of state, two
renderers. The coordinator's failure sink was replaced by an observable
`failure` property with `clearFailure()`. The gallery renders refusals inline
(tap to dismiss); the shell forwards them to the desk's existing
`WorkboardNotice` alert only when the frontmost sheet does not draw them itself,
which `MaterialPresentation.rendersShareFailure` decides. `closeMaterial()`
clears a failure the gallery already showed, so the same sentence is never read
twice. One new key: `workboard.material.share.dismissFailure`.

## MINOR — the gallery-slot test proved nothing about the wiring

It only exercised the index-to-id helper, so wiring the slot to `startIndex`
would have left it green. `AttachmentFullScreenView` gained
`pageActionID(forSelection:)`, which the body calls with `selection`, and two
tests now drive a selection change THROUGH the real slot: one asserts the ids
the caller's closure receives across a swipe, the other runs Work's own closure
into the coordinator and asserts the exported copy is named for page 2.

## Files changed in round 4

- `Conduck/Conduck/Views/Workboard/WorkMaterialShareCoordinator.swift` (rewritten run + presenter)
- `Conduck/Conduck/Views/Components/SharePresentationAnchor.swift` (attachment ordering)
- `Conduck/Conduck/Views/Workboard/PersonalWorkbenchView.swift` (store wiring, failure routing, gallery banner)
- `Conduck/Conduck/Views/Conversation/AttachmentFullScreenView.swift` (`pageActionID(forSelection:)`)
- `Conduck/Conduck/Services/Workboard/WorkboardLiveRepository.swift` (`currentMaterialSnapshot`)
- `Conduck/Conduck/Services/ConversationStore+Workboard.swift` (`fetchWorkMaterial` internal)
- `Conduck/Conduck/Localizable.xcstrings` (one key)
- `Conduck/ConduckTests/WorkMaterialShareTests.swift` (20 → 28 tests)

## Round 4 measurements

Required suites, all six "started" lines present:

```
Test Suite 'ErrorSurfaceDriftGuardTests' passed  — Executed 7 tests, with 0 failures (0 unexpected) in 2.925 (2.927) seconds
Test Suite 'FilePreviewCoordinatorTests' passed  — Executed 11 tests, with 0 failures (0 unexpected) in 0.009 (0.011) seconds
Test Suite 'TempScratchSweeperTests' passed      — Executed 11 tests, with 0 failures (0 unexpected) in 0.381 (0.383) seconds
Test Suite 'WorkMaterialShareTests' passed       — Executed 28 tests, with 0 failures (0 unexpected) in 0.052 (0.057) seconds
Test Suite 'WorkboardCopyTruthGuardTests' passed — Executed 10 tests, with 0 failures (0 unexpected) in 13.197 (13.199) seconds
Test Suite 'WorkboardOpenPathTests' passed       — Executed 9 tests, with 0 failures (0 unexpected) in 0.006 (0.008) seconds
Executed 76 tests, with 0 failures (0 unexpected) in 16.570 (16.588) seconds
```

Whole target:

```
Test Suite 'ConduckTests.xctest' passed
	 Executed 5367 tests, with 1 test skipped and 0 failures (0 unexpected) in 84.743 (86.254) seconds
```

The one skip is the same pre-existing, unrelated
`GatewayAdapterBriefTests.testClipboardBriefRevisionPinMatchesPublishedContract`,
which needs a `website/` checkout beside this worktree.

Builds:

```
xcodebuild build-for-testing … -destination 'platform=iOS Simulator,id=04DEF4F5-…'  → ** TEST BUILD SUCCEEDED **, 0 ": error:" lines
xcodebuild build … -destination 'platform=macOS'                                    → ** BUILD SUCCEEDED **, 0 ": error:" lines
```

---

# Round 5 fixes

Four findings from Codex round 5, all fixed.

## MAJOR A — the rollback restored the revision, so a bytes swap was invisible

`restoreReplacedPayload` put `prior.updatedAt` back along with the payload
columns. Since the material revision IS `updatedAt`, a card read at revision A,
replaced with B, then rolled back, read as A again. A share prepared against A
resolves BYTES by id independently, so it could pick up B's bytes mid-flight and
then pass the revision check against a restored A.

`updatedAt` is now stamped FRESH on rollback — one `Date()` for every physical
row of the material, so the newest-wins ordering in `workMaterialRow` breaks its
tie on `createdAt` rather than on stamps that disagree. Every other restored
column is untouched, so the spec's guarantee holds exactly: a refused reattach
returns the previous payload and the metadata describing it. Only the revision
moves.

Checked the other `updatedAt` readers before changing it. The board's material
sort is `(sequence, createdAt, id)`, not `updatedAt`. The `updatedAt` sort
descriptor at `ConversationStore+Workboard.swift:1575` is on `WorkMaterialBlob`,
a different entity. Owner-revision optimistic concurrency reads the WorkItem
row, which the replace already stamped and which this path does not touch. The
thumbnail backfill's stamp-nothing rule is a separate write and is untouched.

Verified as a negative control rather than by inspection: with the old line
restored, `testARolledBackReattachMintsAFreshRevisionAndKeepsTheBytes` fails
with

```
XCTAssertGreaterThan failed: ("4740080601458411586") is not greater than ("4740080601458411586")
XCTAssertFalse failed - which is the whole point: the share gate refuses it
```

so the test reproduces the exact accept-a-stale-copy defect, and the fix was put
straight back.

## MAJOR B — a throwing final store read leaked the copy

Gate 2 can throw after preparation succeeded. The outer `catch` reported the
failure but could not see `prepared`, so the copy's directory survived until the
next launch sweep — up to a day of the person's bytes in a temporary directory
for a share that never happened.

The reclaim is now a `defer` installed immediately after preparation, disarmed
by a single `handedOff = true` after `present` returns true. Every exit — a
superseded token, an unsettled surface, a stale card, a refused presentation,
and the throw — leaves through it. `settleUnpresented` became `refuse`, which
only says why; the bytes are the defer's job.

## MINOR C — the slot tests still passed a selection value in by hand

They called a parameterised helper, so wiring `currentPageID` to `startIndex`
would have left them green.

The gallery's cursor is now a real object, `AttachmentGallerySelection`, that
the view owns and the pager binds to (`pagerSelection`), and that the residency
window and the actions slot both read. The tests hold that same object, move
`index` exactly as a swipe does, and build `currentPageActions` — the member the
chrome itself draws — so the caller's closure runs with whatever the cursor now
names. One test asserts the ids received across a swipe; the other runs Work's
own closure into the coordinator and asserts the exported copy is named
`Page 2.jpeg`.

This is not a rendered-pager test: SwiftUI gives no way to drive a `TabView`
swipe from XCTest here. It is the smallest unit that owns the whole
selection to id to action chain, and it is the SAME state the pager writes, so
wiring the slot to `startIndex` fails it on the second invocation.

## MINOR D — the gallery failure path never announced

The routing `onChange` returned before `AccessibilityAnnouncer.announce` on the
gallery arm, and the inline banner neither announced nor took focus.

The announcement moved into the coordinator's `report(_:)`, the one place a
refusal is published, so it happens the moment the failure exists and no routing
arm can skip it. The view's `onChange` is now routing only. The inline banner
gained `@AccessibilityFocusState` and takes focus when it appears, so the
refusal can be found again — and its dismiss control reached — without hunting a
black full-screen gallery.

## Files changed in round 5

- `Conduck/Conduck/Services/ConversationStore+Workboard.swift` (fresh revision on rollback)
- `Conduck/Conduck/Views/Workboard/WorkMaterialShareCoordinator.swift` (deferred reclaim, single announcing failure sink)
- `Conduck/Conduck/Views/Conversation/AttachmentFullScreenView.swift` (`AttachmentGallerySelection`, `currentPageActions`)
- `Conduck/Conduck/Views/Workboard/PersonalWorkbenchView.swift` (routing-only onChange, banner focus)
- `Conduck/Conduck/Services/Workboard/WorkboardLiveRepository.swift` (`presentationSnapshotForTesting`)
- `Conduck/ConduckTests/WorkMaterialShareTests.swift` (28 → 32 tests)

## Round 5 measurements

Required suites plus every class touching the workboard store rollback
(`grep -rln "rollback\|replaceWorkMaterialPayload" Conduck/ConduckTests`), all
thirteen "started" lines present:

```
Test Suite 'ErrorSurfaceDriftGuardTests' passed      — Executed 7 tests, with 0 failures (0 unexpected) in 2.914 (2.916) seconds
Test Suite 'FilePreviewCoordinatorTests' passed      — Executed 11 tests, with 0 failures (0 unexpected) in 0.006 (0.008) seconds
Test Suite 'TempScratchSweeperTests' passed          — Executed 11 tests, with 0 failures (0 unexpected) in 0.390 (0.392) seconds
Test Suite 'WorkCaptureDrainerTakeoverTests' passed  — Executed 1 test, with 0 failures (0 unexpected) in 0.491 (0.492) seconds
Test Suite 'WorkCaptureInboxLeaseTests' passed       — Executed 17 tests, with 0 failures (0 unexpected) in 0.065 (0.068) seconds
Test Suite 'WorkCaptureSharePublisherTests' passed   — Executed 7 tests, with 0 failures (0 unexpected) in 0.013 (0.014) seconds
Test Suite 'WorkMaterialShareTests' passed           — Executed 32 tests, with 0 failures (0 unexpected) in 0.093 (0.099) seconds
Test Suite 'WorkboardBlobPublicationTests' passed    — Executed 22 tests, with 0 failures (0 unexpected) in 0.667 (0.672) seconds
Test Suite 'WorkboardCopyTruthGuardTests' passed     — Executed 10 tests, with 0 failures (0 unexpected) in 13.694 (13.696) seconds
Test Suite 'WorkboardDeskUpsertTests' passed         — Executed 16 tests, with 0 failures (0 unexpected) in 0.125 (0.128) seconds
Test Suite 'WorkboardOpenPathTests' passed           — Executed 9 tests, with 0 failures (0 unexpected) in 0.007 (0.009) seconds
Test Suite 'WorkboardPublicationLockTests' passed    — Executed 2 tests, with 0 failures (0 unexpected) in 0.907 (0.908) seconds
Test Suite 'WorkboardThumbnailTests' passed          — Executed 8 tests, with 0 failures (0 unexpected) in 0.348 (0.350) seconds
Executed 153 tests, with 0 failures (0 unexpected) in 19.722 (19.755) seconds
```

Whole target:

```
Test Suite 'ConduckTests.xctest' passed
	 Executed 5371 tests, with 1 test skipped and 0 failures (0 unexpected) in 85.243 (86.758) seconds
```

Same pre-existing, unrelated skip:
`GatewayAdapterBriefTests.testClipboardBriefRevisionPinMatchesPublishedContract`,
which needs a `website/` checkout beside this worktree.

Builds:

```
xcodebuild build-for-testing … -destination 'platform=iOS Simulator,id=04DEF4F5-…'  → ** TEST BUILD SUCCEEDED **, 0 ": error:" lines
xcodebuild build … -destination 'platform=macOS'                                    → ** BUILD SUCCEEDED **, 0 ": error:" lines
```

---

# Round 6 fix

One item: the round 5 rollback gave every restored row the SAME fresh timestamp.

## What was wrong

`updatedAt` is not only the revision — it is also the FIRST key deciding which
physical row of a CloudKit-duplicated material is canonical, in both
`deduplicatedWorkMaterials` and the single-row read. Two duplicates can
legitimately name different blobs, because two offline devices can publish
different bytes under one material id. Collapsing that key to one shared value
hands the decision to `createdAt`/`title`, which a merge can leave identical, so
the row that won before the rollback could lose afterwards and the card would
serve the OTHER payload. That contradicts the guarantee the rollback exists for:
a refused reattach returns the previous payload.

## What changed

`restoreReplacedPayload` now stamps rows from `ConversationStore.restoredRevisionStamps(count:after:now:step:)`,
a pure static that returns one stamp per row with two properties:

- **Strictly decreasing** across `priorRows` in its own order, which is
  canonical order (`workMaterialRows` returns newest-wins first, and
  `WorkMaterialReattachSwap.priorRows` preserves it). Distinct stamps settle the
  order on the first sort key alone, so `createdAt`/`title` are never consulted
  and the row that won before the replace wins after the rollback.
- **Strictly newer than every prior stamp.** The base clears the highest prior
  stamp by the full spread plus one step, so even the last row restored is above
  it — including when a peer's clock put a prior stamp ahead of `Date()`. Every
  row's revision therefore differs from the one it had.

Payload and metadata columns are still restored verbatim; only the revision
moves. The ordering contract is now documented on `WorkMaterialReattachSwap.priorRows`,
because the array's ORDER is the only carrier of canonicality — the snapshot
copies no `createdAt` or `title`, so the restore cannot re-derive it, and a
caller that re-sorted it would silently change which duplicate a rolled-back
card serves.

## Tests

Two new, and the round 5 single-row test kept (rewritten onto the desk
publication route with an empty replacement file, which reaches the same vault
publication proof without allocating 30 MB).

`testRestoredRevisionStampsPreserveOrderAndClearEveryPriorStamp` drives the pure
rule: descending order, all stamps distinct, all above the ceiling, including
the case where `now` is BEHIND the rows being replaced.

`testARolledBackReattachKeepsTheSameCanonicalRowAmongDuplicates` builds the real
two-row state through the store's own seams — a synced card, a second blob, and
`_duplicateWorkMaterialRowForTesting` naming that blob with a newer stamp so the
DUPLICATE is canonical and the card serves its bytes. It then forces a reattach
whose publication cannot be proved and asserts both halves: the restored stamps
are distinct, the previously canonical row is still the newest, the card still
serves the same 36 bytes, every restored stamp is above the highest prior stamp,
the canonical revision moved, and the share gate refuses a copy prepared before
the replace.

Verified as a negative control rather than by inspection. With the stamps made
uniform again, the duplicate test fails with:

```
XCTAssertEqual failed: ("1") is not equal to ("2") - one shared stamp collapses the first sort key and lets the other duplicate win
XCTAssertGreaterThan failed: ("2026-09-05 15:08:44 +0000") is not greater than ("2026-09-05 15:08:44 +0000") - the row that was canonical before the replace is canonical after the rollback
XCTAssertEqual failed: ("Optional(31 bytes)") is not equal to ("Optional(36 bytes)") - a refused reattach returns the PREVIOUS payload — the one the card was actually on
```

That is the reported defect exactly: the card served the other row's payload.
The fix was put straight back.

## Files changed in round 6

- `Conduck/Conduck/Services/ConversationStore+Workboard.swift` (`restoredRevisionStamps`, the ordering contract on `priorRows`)
- `Conduck/ConduckTests/WorkMaterialShareTests.swift` (32 → 34 tests)

## Round 6 measurements

The named suites plus every class grepping `restoreReplacedPayload`, `dedup` or
`_duplicateWorkMaterialRowForTesting`, all fourteen "started" lines present:

```
Test Suite 'ConversationStoreDedupeTests' passed              — Executed 5 tests, with 0 failures (0 unexpected) in 0.067 (0.068) seconds
Test Suite 'ConversationStoreDistinctBackendsTests' passed    — Executed 5 tests, with 0 failures (0 unexpected) in 0.020 (0.021) seconds
Test Suite 'ConversationStoreReconcileOutputScanTests' passed — Executed 15 tests, with 0 failures (0 unexpected) in 0.074 (0.077) seconds
Test Suite 'ServerFileRenderDedupeTests' passed               — Executed 7 tests, with 0 failures (0 unexpected) in 0.003 (0.004) seconds
Test Suite 'SharedInboxDrainerTests' passed                   — Executed 31 tests, with 0 failures (0 unexpected) in 1.999 (2.005) seconds
Test Suite 'SharedInboxManifestTests' passed                  — Executed 18 tests, with 0 failures (0 unexpected) in 0.010 (0.013) seconds
Test Suite 'WorkMaterialShareTests' passed                    — Executed 34 tests, with 0 failures (0 unexpected) in 0.094 (0.099) seconds
Test Suite 'WorkboardAudioCaptureTests' passed                — Executed 20 tests, with 0 failures (0 unexpected) in 0.164 (0.167) seconds
Test Suite 'WorkboardBlobPublicationTests' passed             — Executed 22 tests, with 0 failures (0 unexpected) in 0.588 (0.592) seconds
Test Suite 'WorkboardDeskUpsertTests' passed                  — Executed 16 tests, with 0 failures (0 unexpected) in 0.129 (0.132) seconds
Test Suite 'WorkboardGalleryPagesTests' passed                — Executed 8 tests, with 0 failures (0 unexpected) in 0.003 (0.005) seconds
Test Suite 'WorkboardPersistenceTests' passed                 — Executed 7 tests, with 0 failures (0 unexpected) in 0.038 (0.043) seconds
Test Suite 'WorkboardSyncedRowRepairTests' passed             — Executed 4 tests, with 0 failures (0 unexpected) in 0.027 (0.028) seconds
Test Suite 'WorkboardThumbnailTests' passed                   — Executed 8 tests, with 0 failures (0 unexpected) in 0.345 (0.346) seconds
Executed 200 tests, with 0 failures (0 unexpected) in 3.559 (3.604) seconds
```

Whole target:

```
Test Suite 'ConduckTests.xctest' passed
	 Executed 5373 tests, with 1 test skipped and 0 failures (0 unexpected) in 84.749 (86.254) seconds
```

Same pre-existing, unrelated skip
(`GatewayAdapterBriefTests.testClipboardBriefRevisionPinMatchesPublishedContract`,
which needs a `website/` checkout beside this worktree).

Builds:

```
xcodebuild build-for-testing … -destination 'platform=iOS Simulator,id=04DEF4F5-…'  → ** TEST BUILD SUCCEEDED **, 0 ": error:" lines
xcodebuild build … -destination 'platform=macOS'                                    → ** BUILD SUCCEEDED **, 0 ": error:" lines
```

---

# Round 7 fix

One regression from round 6: `restoredRevisionStamps` lifted EVERY row above the
global prior maximum, which promoted losing duplicates and suppressed a later
legitimate update of the winner.

## What was wrong

With prior stamps A=90 (loser) and B=160 (winner), the shared-ceiling rule wrote
A≈160.001 and B≈160.002. A peer whose clock had since corrected then imports a
legitimate update of its own row only, B=101 — and the promoted A now outranks
it, so the card serves bytes nobody wrote last. Restoring A=90/B=160 followed by
that same import selected B correctly, so round 6 traded one stale-read defect
for another.

## What changed

The rule is now per row: `stamp_i = prior_i + step`, one millisecond, and
nothing is measured against any other row.

```swift
nonisolated static func restoredRevisionStamps(
    advancing priorStamps: [Date?],
    step: TimeInterval = 0.001
) -> [Date?] {
    priorStamps.map { $0?.addingTimeInterval(step) }
}
```

Three properties, all documented on the function and on
`WorkMaterialReattachSwap.priorRows`:

- **(a) The canonical winner is unchanged.** Adding one step to every stamp is
  monotone, so rows that differed still differ the same way. Rows that were
  EQUAL stay equal, which is also correct: that tie was already settled by
  `createdAt`/`title` and those are untouched.
- **(b) Every row that had a revision gets a different one**, which is what a
  reader holding the pre-replace revision needs. A row whose column was empty
  stays empty — there is no revision to advance, and inventing one would promote
  a row that had nothing to say.
- **(c) A later legitimate update of the winner still wins.** Each loser sits
  one step above where it already was, so a subsequent write to the winning row
  outranks every loser, including a peer's ordinary `Date()` landing far below
  the winner's own prior stamp.

Two things are stated in the doc comment rather than left implicit. First, the
residual on (c): when two priors were EQUAL both rise together, so an update
landing inside that one step is outranked. The window is one millisecond wide,
it needs a write within a millisecond of the previous one, and the next write to
either row clears it. Second, why `step` is a millisecond and not the smallest
representable increment: property (b) is the one whose failure is silent, since
it re-opens the stale-share defect, and a millisecond survives any date rounding
a CloudKit round trip could apply where a single-ULP bump might not.

The `priorRows` contract improved as a side effect. Canonical order is now
carried by the VALUES rather than by the array's order, so re-sorting it changes
nothing and no row can be promoted past where it stood. That is strictly more
robust than the round-6 position-based contract, which was unprovable from the
snapshot's own data because it copies no `createdAt` or `title`.

One new test seam, `_setWorkMaterialRowUpdatedAtForTesting(id:contentHash:updatedAt:)`,
in-memory gated like every other. A peer updating its own mirrored row is the
ordinary way `updatedAt` moves on one duplicate and not the others, and no
public API can produce it because every local write deliberately touches every
physical row.

## Tests

`testRestoredRevisionStampsAdvanceEachRowPastItsOwnPriorStamp` replaces the
round-6 pure test and pins all three properties on Codex's own numbers, plus the
equal-priors tie, the prior-ahead-of-now case, the nil column and the empty
input.

`testARolledBackCardStillLetsALaterUpdateOfTheWinnerWin` is the new store-level
sibling: a peer row stamped an hour ahead is canonical, a reattach is refused,
the peer then republishes with a corrected clock through the new seam, and the
card must serve the peer's bytes.

One round-6 assertion in `testARolledBackReattachKeepsTheSameCanonicalRowAmongDuplicates`
encoded the old rule (every stamp above the global maximum) and was replaced
with the per-row invariant, keyed by each row's own payload hash, plus an
explicit check that the loser is NOT lifted to the winner's level.

Verified as a negative control. With the round-6 shared-ceiling rule reinstalled,
the new tests fail with:

```
XCTAssertLessThan failed: ("2026-09-05 16:39:31 +0000") is not less than ("2026-09-05 15:39:31 +0000") - the rollback advanced our row past its OWN stamp, not up to the peer's
XCTAssertEqual failed: ("Optional(31 bytes)") is not equal to ("Optional(36 bytes)") - the peer's corrected update is the newest write, so its bytes are the card's
XCTAssertEqual failed: ("Optional(2026-09-05 16:39:32 +0000)") is not equal to ("Optional(2001-01-01 00:01:30 +0000)") - a skewed sibling does not drag this row up
```

That is the reported regression exactly: the card served our stale 31 bytes
instead of the peer's 36. The fix was put straight back.

## Files changed in round 7

- `Conduck/Conduck/Services/ConversationStore+Workboard.swift` (per-row rule, both doc comments, one new test seam)
- `Conduck/ConduckTests/WorkMaterialShareTests.swift` (34 → 35 tests)

## Round 7 measurements

The five named suites, all "started" lines present:

```
Test Suite 'ConversationStoreDedupeTests' passed  — Executed 5 tests, with 0 failures (0 unexpected) in 0.062 (0.064) seconds
Test Suite 'WorkMaterialShareTests' passed        — Executed 35 tests, with 0 failures (0 unexpected) in 0.122 (0.128) seconds
Test Suite 'WorkboardBlobPublicationTests' passed — Executed 22 tests, with 0 failures (0 unexpected) in 0.640 (0.645) seconds
Test Suite 'WorkboardDeskUpsertTests' passed      — Executed 16 tests, with 0 failures (0 unexpected) in 0.129 (0.131) seconds
Test Suite 'WorkboardThumbnailTests' passed       — Executed 8 tests, with 0 failures (0 unexpected) in 0.340 (0.342) seconds
Executed 86 tests, with 0 failures (0 unexpected) in 1.293 (1.311) seconds
```

Whole target:

```
Test Suite 'ConduckTests.xctest' passed
	 Executed 5374 tests, with 1 test skipped and 0 failures (0 unexpected) in 85.260 (86.756) seconds
```

Same pre-existing, unrelated skip
(`GatewayAdapterBriefTests.testClipboardBriefRevisionPinMatchesPublishedContract`,
which needs a `website/` checkout beside this worktree).

Builds:

```
xcodebuild build-for-testing … -destination 'platform=iOS Simulator,id=04DEF4F5-…'  → ** TEST BUILD SUCCEEDED **, 0 ": error:" lines
xcodebuild build … -destination 'platform=macOS'                                    → ** BUILD SUCCEEDED **, 0 ": error:" lines
```

---

# Round 8 fixes

Two items, plus one thing they uncovered that had to be fixed with them.

## OPEN 1 — an undated row is not revisionless

`updatedAt` is nullable, and every projection substitutes `createdAt` for a row
that carries none. The round-7 rule advanced the raw COLUMN and left a nil
alone, so an undated singleton read the SAME revision before and after a
rollback and a copy taken mid-swap passed the share gate's equality check.

I took the option Codex named first: advance the EFFECTIVE revision. The
substitution chain is now one shared definition,
`ConversationStore.materialRevisionDate(updatedAt:createdAt:)`, used by the
projection readers consume and by the rollback that has to move it. The row
snapshot carries `createdAt` for that purpose only and never writes it back, and
`restoredRevisionStamps` takes effective revisions, so an undated row leaves a
rollback with `updatedAt = createdAt + step`.

I did not take the alternative (excluding undated rows from eligibility) because
it changes what a card IS on a device that has one, rather than fixing the
bookkeeping, and it would strand such a card behind a repair that nothing
schedules.

## The thing that fell out of it

The mixed case does not work without a third change, and shipping OPEN 1 alone
would have moved the defect rather than fixed it.

There were two comparison spaces. The board's `deduplicatedWorkMaterials`
compares the SUBSTITUTED revision, while `workMaterialRow` sorted on the raw
column, where SQL puts NULL last. So an undated duplicate the board read as
canonical was the one row the single-row read could never return: the desk
described one duplicate while the payload, the vault URL and the share gate
answered from the other. That is pre-existing, and `workMaterialRow`'s own
doc comment already CLAIMED the two agreed.

Advancing the effective revision without closing that would have flipped which
row the payload reader serves across a refused reattach, which is precisely the
guarantee this work exists to hold. So `workMaterialRow` now applies the rule
in memory over the same rows, comparing the same
`(effective revision, createdAt, title)` tuple the projection compares, with
ties keeping the first row exactly as the projection's strict-greater
replacement does. My own test caught this: its precondition failed because the
undated duplicate did not win the payload read.

## OPEN 2 — the peer test could not see a no-op

It swallowed the reattach error and would have passed even if the restamp did
nothing, because the hour-ahead peer row wins either way.

`failAReattachOn` now asserts THE refusal, `WorkboardStoreError.materialPayloadUnavailable`,
which the store raises only once the rollback succeeded — so both store tests
now prove they exercised the restore rather than failing earlier and reading an
untouched card. The peer test reads both rows' stamps before and after the
rollback and asserts both moved, asserts our row advanced past its own stamp
rather than up to the peer's, and asserts the peer row's final stamp is the
corrected one and its bytes are what the card serves.

## Tests

Four added, one strengthened, 35 to 39.

- `testAnUndatedRowIsNotRevisionless` pins the substitution chain.
- `testAdvancingMixedDatedAndUndatedRowsKeepsTheSameWinner` pins the mixed
  ordering in substituted space.
- `testARolledBackUndatedRowStillChangesItsRevision` is the store-level
  singleton: the payload goes back verbatim, the revision moves, and the share
  gate refuses a copy taken mid-swap.
- `testARollbackKeepsTheWinnerWhenOneDuplicateIsUndated` is the store-level
  mixed case: the undated duplicate serves the card before and after.
- `testARolledBackCardStillLetsALaterUpdateOfTheWinnerWin` gained the
  measurements above.

One new seam parameter: `_setWorkMaterialRowUpdatedAtForTesting` accepts nil to
CLEAR the column, which is the other state no public API reaches.

Both fixes were verified as negative controls rather than by inspection.
Leaving undated rows alone (the round-7 behaviour) fails with:

```
XCTAssertGreaterThan failed: ("4740080638054969886") is not greater than ("4740080638054969886") - an undated row is not revisionless, so its revision has to move too
XCTAssertFalse failed - so a copy taken mid-swap is refused rather than passing on an unchanged revision
```

Making the restamp a no-op fails the strengthened peer test with:

```
XCTAssertGreaterThan failed: ("2026-09-05 15:58:51 +0000") is not greater than ("2026-09-05 15:58:51 +0000") - our row's revision moved
XCTAssertGreaterThan failed: ("2026-09-05 16:58:51 +0000") is not greater than ("2026-09-05 16:58:51 +0000") - and so did the peer row's
```

Both fixes went straight back.

## Files changed in round 8

- `Conduck/Conduck/Services/ConversationStore+Workboard.swift` (shared substitution definition, effective-revision advance, aligned single-row read, seam accepts nil)
- `Conduck/ConduckTests/WorkMaterialShareTests.swift` (35 → 39 tests)

## Round 8 measurements

The five named suites, all "started" lines present:

```
Test Suite 'ConversationStoreDedupeTests' passed  — Executed 5 tests, with 0 failures (0 unexpected) in 0.061 (0.063) seconds
Test Suite 'WorkMaterialShareTests' passed        — Executed 39 tests, with 0 failures (0 unexpected) in 0.132 (0.139) seconds
Test Suite 'WorkboardBlobPublicationTests' passed — Executed 22 tests, with 0 failures (0 unexpected) in 0.636 (0.641) seconds
Test Suite 'WorkboardDeskUpsertTests' passed      — Executed 16 tests, with 0 failures (0 unexpected) in 0.131 (0.134) seconds
Test Suite 'WorkboardThumbnailTests' passed       — Executed 8 tests, with 0 failures (0 unexpected) in 0.342 (0.343) seconds
Executed 90 tests, with 0 failures (0 unexpected) in 1.302 (1.321) seconds
```

Whole target:

```
Test Suite 'ConduckTests.xctest' passed
	 Executed 5378 tests, with 1 test skipped and 0 failures (0 unexpected) in 85.292 (86.775) seconds
```

Same pre-existing, unrelated skip
(`GatewayAdapterBriefTests.testClipboardBriefRevisionPinMatchesPublishedContract`,
which needs a `website/` checkout beside this worktree).

Builds:

```
xcodebuild build-for-testing … -destination 'platform=iOS Simulator,id=04DEF4F5-…'  → ** TEST BUILD SUCCEEDED **, 0 ": error:" lines
xcodebuild build … -destination 'platform=macOS'                                    → ** BUILD SUCCEEDED **, 0 ": error:" lines
```

## For the next review round

`workMaterialRow` is a canonical read used by the payload load, the vault URL
and the share gate, and this round changed how it picks among duplicates. It is
the piece worth a fresh pair of eyes: the change is small and it repairs the
function against its own documented contract, but it is the widest-reaching edit
in this whole feature.

---

# Round 9 fix

One item: complete ties still let the two selectors pick different physical rows.

## What was wrong

Both compared the same three keys, but neither key set could break a full tie,
so each fell through to "keep whichever arrived first" — and their candidate
lists are ordered differently. The board sorts materials by
`(sequence, createdAt)`; the single-row read starts from a timestamp-ordered
fetch. Same rule, same rows, different answer. A fully tied fetch was not stable
against itself either.

## What changed

There is now ONE total ordering, `WorkMaterialCanonicalOrder`, declared beside
`materialRevisionDate`, and both selectors reduce to `max` over it.

```swift
(lhs.revision, lhs.createdAt, lhs.title, lhs.contentHash, lhs.rowKey)
    < (rhs.revision, rhs.createdAt, rhs.title, rhs.contentHash, rhs.rowKey)
```

The first three keys are the human-meaningful ones and are unchanged, so a desk
without duplicates and every already-decided case behave exactly as before. The
last two exist only to make ties impossible: the bytes the row names, then the
row itself as `objectID.uriRepresentation().absoluteString`, which is unique by
construction. `contentHash` comes first of the two so that rows carrying the
same bytes rank by something meaningful rather than by storage identity, which
also keeps the answer stable when one of them is re-imported.

`deduplicatedWorkMaterials` now compares `canonicalOrder`, and `workMaterialRow`
is a single `max` over `canonicalOrder(of:)`. Neither has a "first of the
equals" rule any more, because there are no equals. `StoredWorkMaterial` carries
`rowKey` for that purpose only; nothing displays or persists it.

`sequence` deliberately does NOT enter the ordering. All it ever did was permute
one selector's candidate list, and order-independence is what makes that
irrelevant.

## Tests

Two added, 39 to 41.

`testBothSelectorsAgreeOnEveryCandidateSetInEitherOrder` feeds each candidate
set to the selector in original and REVERSED order and asserts the same winner:
dated against dated, dated against substituted, substituted against substituted,
Codex's counterexample (same owner, id, title and createdAt, one stamped and one
substituted to the same instant, different bytes, ranks that differ), and a full
tie on every human-meaningful key. It also asserts totality directly — for any
two distinct rows exactly one outranks the other — which is what removes the
fallback rule rather than merely making it agree today.

`testTheBoardAndThePayloadReadNameTheSameBytesOnATiedCard` is the end-to-end
half: a card whose two duplicates tie on revision, title and rank while naming
different bytes, asserting the board's `contentHash` and the hash of what
`loadWorkMaterialPayload` serves are the same. That is the pair of readers that
could previously describe one duplicate on the desk and open the other.

Verified as a negative control. With the comparator cut back to the three-key
tuple, the parity test fails on every tied case, the winner flipping with the
candidate order:

```
XCTAssertEqual failed: … rowKey: "a" … is not equal to … rowKey: "b" … - two substituted rows
XCTAssertEqual failed: … contentHash: "aaa" … is not equal to … contentHash: "bbb" … - rows differing only in the bytes they name
XCTAssertEqual failed: … rowKey: "row-1" … is not equal to … rowKey: "row-2" … - a full tie on every human-meaningful key
XCTAssertTrue failed - exactly one of any two distinct rows outranks the other
```

The fix was put straight back.

## Files changed in round 9

- `Conduck/Conduck/Services/ConversationStore+Workboard.swift` (the ordering type, both selectors, `rowKey` on the projection)
- `Conduck/ConduckTests/WorkMaterialShareTests.swift` (39 → 41 tests)

## Round 9 measurements

The six named suites, all "started" lines present:

```
Test Suite 'ConversationStoreDedupeTests' passed  — Executed 5 tests, with 0 failures (0 unexpected) in 0.060 (0.062) seconds
Test Suite 'WorkMaterialShareTests' passed        — Executed 41 tests, with 0 failures (0 unexpected) in 0.143 (0.151) seconds
Test Suite 'WorkboardBlobPublicationTests' passed — Executed 22 tests, with 0 failures (0 unexpected) in 0.636 (0.641) seconds
Test Suite 'WorkboardDeskUpsertTests' passed      — Executed 16 tests, with 0 failures (0 unexpected) in 0.128 (0.131) seconds
Test Suite 'WorkboardOpenPathTests' passed        — Executed 9 tests, with 0 failures (0 unexpected) in 0.007 (0.016) seconds
Test Suite 'WorkboardThumbnailTests' passed       — Executed 8 tests, with 0 failures (0 unexpected) in 0.341 (0.343) seconds
Executed 101 tests, with 0 failures (0 unexpected) in 1.316 (1.345) seconds
```

Whole target:

```
Test Suite 'ConduckTests.xctest' passed
	 Executed 5380 tests, with 1 test skipped and 0 failures (0 unexpected) in 85.344 (86.858) seconds
```

Same pre-existing, unrelated skip
(`GatewayAdapterBriefTests.testClipboardBriefRevisionPinMatchesPublishedContract`,
which needs a `website/` checkout beside this worktree).

Builds:

```
xcodebuild build-for-testing … -destination 'platform=iOS Simulator,id=04DEF4F5-…'  → ** TEST BUILD SUCCEEDED **, 0 ": error:" lines
xcodebuild build … -destination 'platform=macOS'                                    → ** BUILD SUCCEEDED **, 0 ": error:" lines
```

## One judgement call worth a look

`rowKey` is `objectID.uriRepresentation().absoluteString`. It is stable for every
row these selectors see, because both start from a fetch and a fetched row's id
is never the temporary kind. It is also LOCAL: two devices can rank a fully tied
pair differently. That is acceptable and, I think, unavoidable — a tie on every
synced column has no synced answer — and `contentHash` sitting ahead of it means
the disagreement can only be about which of two rows naming the SAME bytes wins,
which no reader can tell apart. Worth a second opinion if that reasoning is
wrong.

---

# Round 10 fixes

Three items.

## 1 — tied rows were not indistinguishable

`WorkMaterialCanonicalOrder` now carries every column two physical rows can
genuinely differ on, between `contentHash` and `rowKey`:

```
revision, createdAt, title, contentHash,
localVaultKey, storageMode, byteSize, kind,
textContent, urlString, filename, thumbnailDigest,
rowKey
```

The first four keys and their order are unchanged, so every already-decided card
resolves exactly as before. The vault case is the one that mattered most: a
device-local row names no blob, so `contentHash` is nil on both while the leaves
they hold are different bytes, and `localVaultKey` is what separates them. The
thumbnail key is presence plus a SHA-256 of the bytes, so two different previews
of the same size rank deterministically.

Absence sorts BELOW every present value in each optional key, encoded so that
"no column at all" cannot collide with an empty string. Comparison is grouped
into identity, payload and presentation tuples because Swift tuples top out
at six elements.

The doc comment now says which keys are synced and which is not: every key
except `rowKey` is a mirrored column, so two devices compute the same value and
agree without talking, and `rowKey` is last precisely because it is the only
device-local one.

I also collapsed the two construction paths into one. `StoredWorkMaterial` no
longer rebuilds an ordering from its own fields; it stores what
`ConversationStore.canonicalOrder(of:)` returns for the row it was projected
from, which is the same call the single-row read makes. The raw columns are read
rather than the parsed enums, because an enum that maps an unrecognised lane or
kind onto a default would erase the difference this ordering is trying to see.

## 2 — the objectID comment was wrong

Fetches can return pending inserts, so "a fetched row's id is never temporary"
was not the reason. The comment now states the true one: every row these
selectors compare comes from a fetch on a fresh context, and the one caller that
inserts selects before inserting, so no temporary id reaches a comparison. That
is a claim about the callers rather than about fetches, which is why it is now
also an `assert(!row.objectID.isTemporaryID, …)` in the ordering constructor
rather than prose alone.

## 3 — the parity test never touched a selector

It called `max()` on constructed values. `testBothRealSelectorsPickTheSameRowInEitherOrder`
now builds real rows in the in-memory store and goes through both real
selectors, via a new seam that hands the SAME candidate list to each forward and
reversed and reports four row keys that must all match. Six cases: dated against
dated, dated against undated, undated against undated, rows the two devices
ranked differently, two vault rows naming different leaves, and a perfect twin.
The duplicate seam gained `localVaultKey` and `sequence` parameters to build the
last three.

**Something that test taught me, and the reason there is a fourth test.** With
only `rowKey` as a tiebreak the parity test still passes: one device's two
selectors agree, because `rowKey` alone already makes the order total. Parity is
not what the new keys buy. What they buy is agreement BETWEEN devices, and that
needed its own assertion. `testEverySyncedKeyOutranksTheDeviceLocalRowKey` gives
the row that must win the SMALLER row key for each synced key in turn, so a
comparator falling through to the local id fails it. That is the test the
negative control moves.

## Negative controls

Cutting the comparator back to the round-9 keys leaves the parity test green —
which is the finding above — and fails the synced-key test on the vault case:

```
XCTAssertEqual failed: … localVaultKey: Optional("leaf-a") … rowKey: "row-b" … is not equal to … localVaultKey: Optional("leaf-b") … rowKey: "row-a" … - two vault rows naming different leaves: a synced column has to decide this, not the row's local id
XCTAssertEqual failed: … localVaultKey: nil … is not equal to … localVaultKey: Optional("leaf") … - a vault row against one naming no leaf at all
```

Both restored.

## Files changed in round 10

- `Conduck/Conduck/Services/ConversationStore+Workboard.swift` (the ordering's keys and doc, one construction path, the objectID assertion, the parity seam, two duplicate-seam parameters)
- `Conduck/ConduckTests/WorkMaterialShareTests.swift` (41 → 43 tests)

## Round 10 measurements

The six named suites, all "started" lines present:

```
Test Suite 'ConversationStoreDedupeTests' passed  — Executed 5 tests, with 0 failures (0 unexpected) in 0.062 (0.063) seconds
Test Suite 'WorkMaterialShareTests' passed        — Executed 43 tests, with 0 failures (0 unexpected) in 0.202 (0.210) seconds
Test Suite 'WorkboardBlobPublicationTests' passed — Executed 22 tests, with 0 failures (0 unexpected) in 0.608 (0.612) seconds
Test Suite 'WorkboardDeskUpsertTests' passed      — Executed 16 tests, with 0 failures (0 unexpected) in 0.125 (0.128) seconds
Test Suite 'WorkboardOpenPathTests' passed        — Executed 9 tests, with 0 failures (0 unexpected) in 0.007 (0.008) seconds
Test Suite 'WorkboardThumbnailTests' passed       — Executed 8 tests, with 0 failures (0 unexpected) in 0.341 (0.343) seconds
Executed 103 tests, with 0 failures (0 unexpected) in 1.344 (1.366) seconds
```

Whole target:

```
Test Suite 'ConduckTests.xctest' passed
	 Executed 5382 tests, with 1 test skipped and 0 failures (0 unexpected) in 85.152 (86.649) seconds
```

Same pre-existing, unrelated skip
(`GatewayAdapterBriefTests.testClipboardBriefRevisionPinMatchesPublishedContract`,
which needs a `website/` checkout beside this worktree).

Builds:

```
xcodebuild build-for-testing … -destination 'platform=iOS Simulator,id=04DEF4F5-…'  → ** TEST BUILD SUCCEEDED **, 0 ": error:" lines
xcodebuild build … -destination 'platform=macOS'                                    → ** BUILD SUCCEEDED **, 0 ": error:" lines
```

## One cost worth knowing

`StoredWorkMaterial.init` now builds the ordering eagerly, which digests the
thumbnail bytes of every material on every board load. I chose that over a lazy
computed property because the lazy version would have had to rebuild the key
from the projection's own parsed fields, and that is the drift this round exists
to remove. Previews are small tile images and the whole-suite timing did not
move, but it is a real addition to the board's read path and worth a look if
board loads are ever measured.

---

# Round 11 fixes

Four items of final polish on the ordering.

## 1 — completeness

`mimeType`, `caption` and `cardSize` join the ordering after `filename` and
before the preview, with the same absence encoding. The full key sequence is now

```
revision, createdAt, title, contentHash,
localVaultKey, storageMode, byteSize, kind,
textContent, urlString, filename, mimeType, caption, cardSize,
thumbnailDigest,
rowKey
```

`testEverySyncedKeyOutranksTheDeviceLocalRowKey` now varies every one of them,
including the first four it never touched.

## 2 — absence encoding, and NaN

Every WorkMaterial column is optional in the model — I checked the current
version rather than assuming — so there was no "document it instead" escape.
`createdAt`, `title` and `byteSize` now carry presence like the strings do, and
the comparison runs through one `decide(_:_:)` helper that puts absence below
every present value for any `Comparable`. An empty title and a zero byte size
are values now, not absences, and the test asserts both.

`revision` is the one deliberate exception and the doc says why: it IS the
substituted value every reader compares, so giving it presence here would order
rows differently from the projection that reports them.

The preview digest no longer collapses nil and empty. A present-but-empty column
hashes like any other value, so nil sorts below empty sorts below non-empty.

Dates are sanitised at construction. `Date` comparison is `Double` comparison
and NaN is ordered against nothing, so one NaN stamp would make the whole
ordering intransitive and hand "canonical" back to comparison order. A NaN is
now treated as ABSENT, which is a position the ordering defines, behind an
`assertionFailure`. It cannot come out of Core Data; it is guarded because the
failure would be silent and the check is free.

## 3 — the digest is lazy again

`WorkMaterialThumbnailDigest` is a small locked box holding the raw bytes and
computing the SHA-256 on first ask, cached. The ordering value captures the box,
so building one costs nothing, and the digest is the LAST synced key — every
cheap key is asked first, so two rows differing in anything at all never reach
it. `==` is derived from `<` rather than synthesised, which keeps equality lazy
too and stops the two operators drifting as keys are added.

That undoes the cost I flagged at the end of round 10 while keeping the one
construction path: the ordering is still built from the raw columns by
`canonicalOrder(of:)`, and `StoredWorkMaterial` still stores what that returns.

## 4 — the two test gaps

The rank fixture assigned rank 0 to a card already at rank 0. It uses 1 now and
asserts the two ranks actually differ, since the whole point of that case is
handing the two selectors different candidate orders.

`testASingletonDeskLoadHashesNoPreviews` loads a desk of three cards that all
carry previews and asserts the digest counter did not move.
`testTheKeysBeforeThePreviewAreAnsweredWithoutHashingIt` is the unit-level
half: comparing two rows that differ in the title leaves both boxes untouched,
and comparing two that tie all the way down does reach it.

## Files changed in round 11

- `Conduck/Conduck/Services/ConversationStore+Workboard.swift` (three more keys, presence encoding, NaN guard, lazy digest box, derived `==`, a test-only digest counter)
- `Conduck/ConduckTests/WorkMaterialShareTests.swift` (43 → 45 tests)

## Round 11 measurements

The six named suites, all "started" lines present:

```
Test Suite 'ConversationStoreDedupeTests' passed  — Executed 5 tests, with 0 failures (0 unexpected) in 0.061 (0.062) seconds
Test Suite 'WorkMaterialShareTests' passed        — Executed 45 tests, with 0 failures (0 unexpected) in 0.182 (0.191) seconds
Test Suite 'WorkboardBlobPublicationTests' passed — Executed 22 tests, with 0 failures (0 unexpected) in 0.607 (0.611) seconds
Test Suite 'WorkboardDeskUpsertTests' passed      — Executed 16 tests, with 0 failures (0 unexpected) in 0.129 (0.132) seconds
Test Suite 'WorkboardOpenPathTests' passed        — Executed 9 tests, with 0 failures (0 unexpected) in 0.007 (0.009) seconds
Test Suite 'WorkboardThumbnailTests' passed       — Executed 8 tests, with 0 failures (0 unexpected) in 0.342 (0.344) seconds
Executed 105 tests, with 0 failures (0 unexpected) in 1.328 (1.350) seconds
```

Whole target:

```
Test Suite 'ConduckTests.xctest' passed
	 Executed 5384 tests, with 1 test skipped and 0 failures (0 unexpected) in 85.339 (86.835) seconds
```

Same pre-existing, unrelated skip
(`GatewayAdapterBriefTests.testClipboardBriefRevisionPinMatchesPublishedContract`,
which needs a `website/` checkout beside this worktree).

Builds:

```
xcodebuild build-for-testing … -destination 'platform=iOS Simulator,id=04DEF4F5-…'  → ** TEST BUILD SUCCEEDED **, 0 ": error:" lines
xcodebuild build … -destination 'platform=macOS'                                    → ** BUILD SUCCEEDED **, 0 ": error:" lines
```

## What I did not do

I ran no negative control this round. The four items are additive — more keys,
more presence, a lazy box, better fixtures — and each new assertion fails
trivially against the previous code by construction, so a control would only
have restated the diff. Every earlier round's control still holds.

---

# Round 12 fix

One defect: the preview key ranked by digest alone.

## What was wrong

A digest is a hex string and orders lexicographically. The hash of empty data is
`e3b0c442…`, which sorts above plenty of real ones — `"one"` hashes to `7692…`
— so an otherwise tied EMPTY preview beat a NON-EMPTY one. That is the exact
opposite of the nil < empty < non-empty the round-11 doc claimed.

## What changed

Emptiness is now a TIER, asked before the digest, and the digest is compared
only between two rows that both carry real bytes.

```swift
if let decided = decide(lhs.previewPresence, rhs.previewPresence) { return decided }
if lhs.previewPresence == WorkMaterialCanonicalOrder.previewPresent,
   let decided = decide(lhs.thumbnailDigest, rhs.thumbnailDigest) {
    return decided
}
return lhs.rowKey < rhs.rowKey
```

`previewPresence` reads 0 for no column, 1 for a column that is present but
empty, 2 for one with bytes, straight off the immutable `Data?` the box already
holds. It needs no lock and no hash, so the digest stays lazy and gets strictly
lazier: two rows differing only in whether they have a preview at all now settle
without hashing either one.

An empty column still HAS a digest — it is a real state of a row — the ordering
just never compares it against a non-empty one.

## Test

`testEverySyncedKeyOutranksTheDeviceLocalRowKey` gained the tier case, in both
operand orders like every other case there. It uses `"one"` deliberately and
asserts up front that its digest sorts BELOW the empty one's, so the case is
only meaningful while the trap it was written for is still there.

Verified as a negative control. With the tier removed and the digest comparing
alone, the new case fails both ways round:

```
XCTAssertEqual failed: … rowKey: "row-b" … is not equal to … rowKey: "row-a" … - real preview bytes against an EMPTY column, whatever their digests say: a synced column has to decide this, not the row's local id
XCTAssertEqual failed: … - real preview bytes against an EMPTY column, whatever their digests say: in either order
```

Restored.

## Files changed in round 12

- `Conduck/Conduck/Services/ConversationStore+Workboard.swift` (the presence tier, the gated digest comparison, both doc comments)
- `Conduck/ConduckTests/WorkMaterialShareTests.swift` (one case added to an existing test; still 45)

## Round 12 measurements

The four named suites, all "started" lines present:

```
Test Suite 'ConversationStoreDedupeTests' passed — Executed 5 tests, with 0 failures (0 unexpected) in 0.061 (0.062) seconds
Test Suite 'WorkMaterialShareTests' passed      — Executed 45 tests, with 0 failures (0 unexpected) in 0.185 (0.193) seconds
Test Suite 'WorkboardDeskUpsertTests' passed    — Executed 16 tests, with 0 failures (0 unexpected) in 0.159 (0.162) seconds
Test Suite 'WorkboardThumbnailTests' passed     — Executed 8 tests, with 0 failures (0 unexpected) in 0.340 (0.342) seconds
Executed 74 tests, with 0 failures (0 unexpected) in 0.745 (0.760) seconds
```

Whole target:

```
Test Suite 'ConduckTests.xctest' passed
	 Executed 5384 tests, with 1 test skipped and 0 failures (0 unexpected) in 85.742 (87.258) seconds
```

Same pre-existing, unrelated skip
(`GatewayAdapterBriefTests.testClipboardBriefRevisionPinMatchesPublishedContract`,
which needs a `website/` checkout beside this worktree).

Builds:

```
xcodebuild build-for-testing … -destination 'platform=iOS Simulator,id=04DEF4F5-…'  → ** TEST BUILD SUCCEEDED **, 0 ": error:" lines
xcodebuild build … -destination 'platform=macOS'                                    → ** BUILD SUCCEEDED **, 0 ": error:" lines
```
