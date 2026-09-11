# U-71 — One card for a screenshot captured with a voice note

One press of Capture to Work publishes TWO materials — an `.image` at
`WorkVoiceScreenshotCoordinator.materialID(forCapture:)` and an `.audio` at the
capture id — and the recording carries the picture's id. The desk draws that
pair as ONE card: the screenshot, with the recording inside it. Nothing about
the two artifacts changed; what changed is what the board makes of them.

The design is `~/.claude/plans/binary-painting-leaf.md` (decisions 1–12, settled
before a line was written) and the two design reviews are
`verify/codex-design-companion-r1.md` and `-r2.md`. Four implementation rounds
read the finished diff: `verify/codex-r1-companion-card.md` … `-r3.md`, and then
`verify/codex-r4-companion-card-spotcheck.md`, scoped to round 3's own fixes.

---

## The column, and what writes it

**Model 17** (`Conversations 17.xcdatamodel`; model 16 byte-identical and still a
live upgrade path) adds one attribute:
`WorkMaterial.attachedToMaterialID: UUID?` — optional, Core configuration only,
no relationship, nothing in Blobs. It is the entire schema cost of the feature.
A composite kind was refused in the earlier design (`design/mac-work-destination.md:44`)
and refused again here: it costs a new model, a gallery page, a Quick Look case
and a blob field, and it breaks `WorkMaterialBlobRecord.id == materialID`.

**It is written on the recording draft only** — never on an image row, never on
the fallback note — with the value
`WorkVoiceScreenshotCoordinator.materialID(forCapture: originalCaptureID)`
whenever the capture carries a picture at recording-publish time: the menu bar
asks `capture.screenshot != nil || capture.screenshotQueued`, `ConverseIntent`
asks `pendingWorkImageData != nil`, and the retry surfaces read it from retry
metadata. It travels as its own parameter (`publishRecording(… attachedTo:)`,
`recover(… attachedTo:)`) rather than being derived at the write door, because
the escape republish calls `publishRecording(captureID: escapedID)` — deriving
from that parameter would name the escape of the escape.

**The link is a promise about identity, not existence.** It is written even when
the picture's own publication failed, so a retry landing the picture a day later
needs no repair: the next board build folds the pair and the desk's card count
drops by one. `PendingRetryMetadata.workAttachedToMaterialID` carries it through
every retry hop, persisted independently of `workImageData` — those bytes are
dropped once the picture is queued, the link is not — and the legacy
filename-only reconstruction leaves it nil. The watch relay passes nil
explicitly: the wrist names no picture.

**The canonical-row selector** includes the link in its presentation-field
ordering, so duplicate rows differing only in it converge to the same winner on
every device.

## The fold — board side

`WorkboardCompanionFold` runs inside the live repository's board build
(`WorkboardLiveRepository.snapshot(for:localThumbnails:)`). Every stored material
is projected to a `WorkboardMaterialSnapshot` FIRST, and the fold runs over the
projections — so a recording drawn inside its picture is the same value it would
be standing alone, and the board never holds a second, thinner description of a
companion. The result is `Folded = (displayed, hiddenChildIDs, childByParent)`:
`displayed` is what the desk renders, and the other two are what a caller that
must address every STORED id expands the pair with.

Resolution, for a child C carrying link L: candidates
`[L, WorkMaterialCollisionEscape.materialID(forCapture: L)]`, in that order,
first one satisfying ALL of — on this desk, `kind == .image`, carrying no link of
its own, and not C itself. C must be `.audio`. Where several recordings name one
picture the lowest `uuidString` folds and every other renders standalone.
Nothing is ever discarded: every material handed to the fold comes back, as a
card or as exactly one picture's companion.

The companion is a `WorkboardCompanionSnapshot` — a lossless mirror of the
child's own card, since a `WorkboardMaterialSnapshot` that can hold a
`WorkboardMaterialSnapshot` is a recursive value type — plus
`companion.material`, which hands the child back as the card that Open, Share
and Reattach are given.

The board's rule and `ConversationStore.eligibleCompanionPictureID` are the same
conditions in the same order, deliberately: the board must not fold a pair the
group delete would refuse as `.invalidMaterialCompanion`.

## Board plumbing

**Delete — one card, one Delete, two materials.** `WorkboardMaterialBoard.remove(_:)`
branches on `material.companion`: present → `WorkboardViewModel.removeGroupFromBoard`
→ `Dependencies.removeMaterialGroup` → `WorkboardLiveRepository.removeMaterialGroup`
→ `ConversationStore.deleteWorkMaterialGroup(parentID:childID:workItemID:expectedOwnerRevision:)`.
Absent → the unchanged single-material path. The store validates the named pair,
compares the owner revision once, deletes all physical rows of both plus both
blob lanes, collects EVERY distinct vault key (a `Set`, not a `.first`), advances
the desk timestamp once, saves once, then removes the vault files and posts one
notification. Two single deletes are not a substitute: the first advances the
very revision the second is holding, so the recording would survive its picture.
The confirmation names both members
(`workboard.material.remove.confirm.message.pair`), because the person is looking
at one card and would otherwise read a promise about the screenshot alone.

**Reorder — displayed order in, stored order out.** A drag is planned over the
cards a person can see; `WorkboardDeskMember.expandedOrder` grows that
permutation into the stored one, each folded card becoming `[picture, recording]`
adjacent, immediately before `reorderWorkMaterials`, which rewrites dense ranks
from a permutation that must contain every logical id exactly once.
`applyMaterialOrder` writes those same expanded ranks onto the optimistic board —
the card takes its rank and hands the next one to its companion — while the
rendered array stays displayed-only. Mosaic geometry, drag payloads and
accessibility position counts are computed from the displayed array and are
unchanged. A refused reorder whose corrective read also fails calls
`restoreMaterialOrder(_:)`, which copies the SAVED sequence back onto the current
card and its companion by id rather than reindexing displayed positions.

**Open / Share / Reattach — one member each.** `WorkboardCompanionRouting.actions`
binds the board's three already-gated seams (`openMaterial`, `shareMaterial`,
`beginReattachment`) to `companion.material` and hands them to whichever card
family is drawn, so each route validates only its own member: a screenshot
readable on this device says nothing about whether the recording's bytes arrived.
Resolution of a single id searches companions as well as cards
(`WorkboardDeskMember.find`), which is what keeps `currentDeskCard` and
`reattachMaterial` working after a fold — `currentDeskCard` keeps its absent-card
fallback to the tapped snapshot (`fix-r1-desk.md`) underneath that search.

## The card

The tile is the gallery's button, as it always was; the recording is a band
across the bottom of that tile with its own play control, the transcript's lead
line, as much of the transcript as the footprint carries, and the clip's
progress once it has decoded. The picture's footer — size and date — is
unchanged.

`WorkboardCompanionBand.placement(for:footprint:)` asks
`WorkboardCardArtworkMode.resolve` the same question the tile asks: an
image-forward tile puts the band on the scrim (white on the gradient's dark end);
both inline variants — the small footprint, and a standard/large card whose
picture produced no thumbnail — put it in the text column on a recessed strip;
the smallest footprint takes a third, `.compact` placement — the transport
alone over a one-row thumbnail-and-name body. That tile is ONE grid unit, and the
unit is not one number: the four-column grid hands out 81 points at board width
360, 71 at 320 and 64 at 292, the last width before it drops to two columns. So
the four sizes (a 26-point transport in 4 points of padding, a 24-point thumbnail
inside 9-point insets — 76 points at the reference unit) are a CEILING, and
`WorkboardCompanionBand.compactMetrics(forTileHeight:)` scales all four by
`min(1, tile / 81)`: the sum is then `76/81` of whatever tile the grid granted at
any width and any type size, and nothing grows on a wide board. The card reads
that tile from `WorkboardMosaicEngine.unitSize(forWidth:)` — the same unit `place`
frames every card with, handed down as `grantedUnitHeight`. There is no "no band"
branch: any card carrying a companion draws one.

The band is a SIBLING of the tile, not content inside it: `cardSurface` is
`ZStack(alignment: .bottom) { tileControl; companionBand }` under one clip,
because a control nested in a `Button`'s label never receives the tap. The tile
reserves the band's MEASURED height (`onGeometryChange` → `bandHeight`): the
image-forward caption adds it inside its own bottom padding, so the scrim grows
over the band and the words never land on bare photograph; the inline tile adds
it as bottom padding on `cardBody`. Everything in the band except the transport
is `allowsHitTesting(false)`, its own background included.

One recording, one player. `WorkboardAudioTransport` and
`WorkboardAudioProgressTrack` are extracted from `WorkboardAudioCardView` (which
now draws through them, with no visual change) and own nothing; the card holds
one `WorkboardAudioCardPlayer()`, so `WorkboardAudioExclusivity.shared` still has
a single holder. Bytes are read on first activation — no `.task`, no
`.onAppear` — so a desk of twenty recordings loads nothing, and the clock appears
only once a clip has decoded. Every companion row asks the RECORDING's
availability: play, Open Recording, Share Recording and Reattach Recording. The
picture's own Share row reads "Share Screenshot", so a card holding two files
never offers an unqualified verb.

VoiceOver hears one card: "Screenshot with voice note. <picture name>.
<transcript>", then the recording's state (from the one shared
`WorkboardAudioTransport.statusLabel(for:)`), availability, footprint and
position; the band's transport is hidden from it exactly as the ellipsis
affordance is, and playback reaches the person as the custom actions Play/Pause
Recording beside Open Recording, Share Recording, Reattach Recording and Share
Screenshot.

**The list row** draws the same pair as one row: thumbnail with a play badge over
it, the recording's words as the row text, the picture's kind, size and date
underneath. It plays through the row's existing single player
(`material.companion?.id ?? material.id`), and its tap still opens the picture —
a folded row never carries `.startsMediaSession`.

## Findings by round

| # | Sev | Finding | Verdict |
|---|---|---|---|
| r1-f1 | P2 | A recording naming ITSELF folded through the escape of its own id, and `eligibleCompanionPictureID` had no child exclusion at all — so the group delete validated that pair and destroyed both materials | **Fixed.** Both resolvers reject `link == child` before any candidate is examined. Pinned by `testASelfNamingRecordingDoesNotFoldThroughTheEscapeOfItsOwnID` and `testGroupDeleteRefusesASelfNamingRecordingEvenWithAPictureAtItsOwnEscape`, each carrying a negative control in which an honest recording naming that same picture still folds and still deletes as a pair |
| r2-f1 | P3 | The tip's optimistic-reorder rollback reindexed `.sequence` from displayed positions instead of restoring saved ranks, so after a refused reorder AND a failed corrective read the hidden companion's rank diverged from persistence | **Fixed.** `restoreMaterialOrder(_:)` copies the saved sequence back onto the current card and its companion by id; the dense rewrite stays on the optimistic path, which is the order the store is about to write. Pinned by `testARefusedReorderRestoresTheSavedRanksRatherThanReindexingThem` (fails `[0, 1]` / companion `2` against the pre-fix code) |
| r3-f1 | P3 | A folded tile omitted the recording's state from VoiceOver, so a `.failed` or `.blocked` recording re-offered "Play Recording" with no explanation | **Fixed.** `WorkboardCompanionBand.accessibilityValue(for:phase:elapsed:duration:)` is spoken as the card's accessibility value on BOTH tile branches, and one `WorkboardAudioTransport.statusLabel(for:)` serves the folded tile and the list row, while the standalone audio card speaks its own switch (`WorkboardAudioCardView.swift`) over the same keys and the same words. Pinned by `testTheSpokenCardStatesWhyTheRecordingRefusedToPlay` and `testBothFormsOfTheTileSayWhatTheRecordingIsDoing` |
| r3-f2 | P3 | `spec.md`'s release gate still read "Deploy model 16 to production CloudKit before release." — a maintainer following it would verify the wrong model and ship the column undeployed | **Fixed in the docs pass** (the lane owns no permanent doc). `spec.md` and release gate 1 of `handoff.md` both name model 17; U-77 records it |
| r3-f3 | P3 | The smallest folded tile exceeded its grid unit: a 48-point strip band over a ~68-point stacked body inside 81 points, and because the band is drawn ON the tile the overflow HID the picture's name and availability glyph rather than merely clipping them | **Fixed.** The `.compact` placement above, sized from the unit the mosaic granted rather than from the compact board's 81 points — the grid hands out 71 at width 320 and 64 at 292. Pinned by `testAFoldedSmallCardFitsEveryGridUnitTheMosaicCanGrantIt` (every width from 240 to 1,400 at every dynamic type size), `testTheCompactDrawingShrinksWithTheTileAndNeverGrowsPastIt` and the source guard `testTheCompactBandIsDrawnFromTheUnitTheMosaicGranted` |
| r4-f1 | P3 | The compact budget was one number — 76 points against a grid unit assumed to be 81 — but the four-column grid grants 71 at board width 320 and 64 at 292, so the band and the row under it overflowed on every board narrower than 360 and the overflow hid the picture's name behind the band | **Fixed.** `compactMetrics(forTileHeight:)` scales all four sizes by `min(1, tile / 81)` from the unit `WorkboardMosaicEngine.unitSize(forWidth:)` granted, handed to the card as `grantedUnitHeight`. Pinned by `testAFoldedSmallCardFitsEveryGridUnitTheMosaicCanGrantIt` — every width from 240 to 1,400 at every `DynamicTypeSize`, asked through the placement the card draws — plus `testTheCompactDrawingShrinksWithTheTileAndNeverGrowsPastIt` and the source guard `testTheCompactBandIsDrawnFromTheUnitTheMosaicGranted`. Negative controls: resolving `isCompact` to a constant fails the guard; taking `.small` out of the compact placement fails the budget at every width |
| r4-f2 | P3 | `handoff.md` step 139 asked the Small band for the recording's NAME, which the compact band deliberately does not draw — the one visible name there is the screenshot's | **Fixed in the docs pass.** Step 139 asks for the transport alone, the screenshot's own name whole beside it, and the same card again at the grid's tightest width |
| r4-f3 | P3 | `handoff.md` step 143 triggered the VoiceOver refusal by playing a second recording, which takes the audio and stops the first clip rather than refusing — `.blocked` needs a LIVE capture, so the step could not reach the value it was checking | **Fixed in the docs pass.** The step leaves a ⌃⌘W press recording (the popover pins itself open, so the desk stays reachable) and then activates Play Recording; the second-recording behaviour stays where it belongs, in step 136 |
| r4-f4 | P3 | This note claimed `statusLabel(for:)` serves the audio card too; the audio card speaks its own switch | **Fixed in the docs pass.** r3-f1 above and `handoff.md` both name the two surfaces it serves and say the audio card matches it in wording rather than in code |

Design rounds r1 and r2 settled the rules the implementation then had to hold —
first ELIGIBLE candidate rather than first existing, lowest child id rather than a
rank, a parent carrying no link of its own — and are recorded in
`verify/codex-design-companion-r1.md` / `-r2.md` rather than as findings.

## Nobody undo

1. **FIRST ELIGIBLE, NEVER FIRST EXISTING.** A row of another kind standing at
   the named id is precisely WHY the picture escaped; stopping the search there
   makes every collision-escaped pair permanently two cards. The list is two long
   and no longer — there is exactly one escape.
   *Pinned by* `testAPictureUnderItsCollisionEscapeStillTakesItsRecording`,
   `testAWrongKindRowAtTheNamedIdWithNothingBehindItLeavesTheRecordingStanding`,
   `testGroupDeleteResolvesThroughTheCollisionEscapeAndRefusesTheOccupiedID`.
2. **A link naming the child itself is rejected before any candidate is
   examined**, in BOTH resolvers. Skipping only the self-referential candidate
   lets the escape of C fold C into a picture nobody paired it with, and the
   store then accepts that pair and deletes two materials.
   *Pinned by* `testACardThatNamesItselfIsNotItsOwnCompanion`,
   `testASelfNamingRecordingDoesNotFoldThroughTheEscapeOfItsOwnID`,
   `testGroupDeleteRefusesASelfNamingRecordingEvenWithAPictureAtItsOwnEscape`.
3. **The winner among several claimants is the lowest child UUID, never a rank.**
   Rank moves with the arrangement, so picking by it lets a drag on an unrelated
   card silently hand a screenshot a different recording.
   *Pinned by* `testOnlyTheLowestRecordingIdFoldsAndTheArrangementCannotChangeThat`
   and `testMovingAnUnrelatedCardCannotChangeWhichRecordingIsFolded`.
4. **The parent must carry no link of its own, and the child must be `.audio`.** A
   chain is not a fold: following one draws a recording two hops from where it
   belongs and makes the group delete remove a card nobody pointed at. A folded
   note would lose the full-text and copy route its own card has, which is why
   text mode is two cards by decision (U-71 in `handoff.md`). The fold's cheap
   exit ("no `.audio` row carries a link") also enforces the kind test, so a test
   for it must put a LINKED recording on the desk or the exit hides the break.
   *Pinned by* `testAPictureThatItselfNamesAPictureIsNotAParent`,
   `testOnlyARecordingFoldsAndATypedNoteKeepsItsOwnCard`,
   `testADeskWithNoLinkedRecordingIsReturnedUnchanged`.
5. **An orphaned recording rendering standalone is CORRECT, not a defect, and
   nothing is ever discarded.** The link is a promise about identity, not
   existence — it is written even when the picture's publication failed — so a
   retry that lands the picture later needs no repair pass. `displayed` ∪
   companions == the input, and every hidden id is exactly one card's companion;
   that equality is what makes the reorder expansion complete.
   *Pinned by* `testARecordingWhosePictureIsNotOnTheDeskKeepsItsOwnCard`,
   `testTheLinkIsWrittenEvenWhenThePicturesOwnPublicationFailed`,
   `testExpandedOrderNamesEveryStoredMaterialExactlyOnceWithThePairAdjacent`.
6. **The board's rule and the store's `eligibleCompanionPictureID` are the same
   conditions in the same order, and they move together.** Diverge, and the board
   folds a pair the group delete refuses as `.invalidMaterialCompanion` — a
   Delete that fails on a card the person is looking at.
   *Pinned by* `testGroupDeleteRefusesEveryPairThatIsNotAFoldAndDeletesNothing`
   beside the fold's own truth table.
7. **The reorder request is expanded; the rendered array is not.** Displayed ids
   alone are refused by the store as an incomplete permutation; a companion
   inserted into `desk.materials` puts a hidden recording under a drag, a mosaic
   frame and an accessibility position. `applyMaterialOrder` assigns EXPANDED
   ranks and DISPLAYED positions separately — reusing the displayed index as
   `.sequence` makes the optimistic board disagree with what the store writes.
   *Pinned by* `testAReorderRequestExpandsAFoldedCardIntoItsTwoStoredMaterials`
   and `testARefusedReorderRestoresTheSavedRanksRatherThanReindexingThem`.
8. **The displayed `childID` travels to the store unchanged, and a folded Delete
   has no optimistic update.** Re-resolving the fold at confirmation time would
   delete a recording the person never saw on that card; re-checking the child
   against the current companion would silently no-op a destructive confirmation
   when a sync lands mid-dialog. The card leaves when the store says both members
   are gone, so a refusal has nothing to roll back, and
   `Dependencies.removeMaterialGroup` defaults to a THROW rather than a no-op so
   an unwired board fails where the person can see it.
   *Pinned by* `testTheDeleteCarriesTheCompanionTheBoardDrewRatherThanTheCurrentOne`,
   `testAFoldedCardsDeleteRemovesBothMembersUnderOneRevision`,
   `testAGroupDeleteForAPictureTheBoardNoLongerHoldsReachesNoStore`.
9. **The group delete collects EVERY distinct vault key across both members and
   all their physical rows** — a `Set`, never `.first`. Duplicate rows for one
   material can name different vault leaves, and a leaf left behind has no card
   to reclaim it ever again. (The single-material path still takes `.first`; that
   pre-existing leak is U-75, not this lane's to widen.)
   *Pinned by* `testGroupDeleteCollectsEveryVaultKeyAcrossBothMaterialsAndEveryRow`.
10. **The band is drawn OUTSIDE the tile's button, and everything in it except
    the transport refuses hits — its own background included.** A band inside
    `tileControl` is a play control that silently opens the gallery; a strip that
    consumes hits turns the bottom of every folded card into a dead zone.
    *Pinned by* `testTheBandIsDrawnOutsideTheTilesButton`.
11. **The reservation is the MEASURED band height, claimed inside the caption's
    own padding on the image-forward tile.** A constant pushes the picture's
    footer under the clip at accessibility type sizes; claiming it outside the
    caption's background leaves the recording's words on bare photograph. The
    smallest footprint is `.compact` BEFORE the artwork mode is consulted, and it
    draws no progress track — which is what keeps its height fixed once a clip
    decodes. Its four sizes come from the GRANTED unit, never from the reference
    81: a band drawn at the reference inside a 64-point tile hides the picture's
    name behind itself.
    *Pinned by* `testAFoldedSmallCardFitsEveryGridUnitTheMosaicCanGrantIt`,
    `testTheCompactBandIsDrawnFromTheUnitTheMosaicGranted` and
    `testTheGrantedFootprintDecidesTheBandJustAsItDecidesTheTile`.
12. **One default-constructed `WorkboardAudioCardPlayer()` per surface, no surface
    constructs a `WorkboardAudioExclusivity`, and the transport has no `.task` or
    `.onAppear`.** A player per transport, or a registry of its own, is two cards
    playing at once; an eager read is every recording on the board decoded to
    show a number nobody asked for.
    *Pinned by* `testEverySurfaceDrawingARecordingSharesTheProcessWideRegistry`,
    `testTheTransportReadsNoBytesUntilItIsActivated`,
    `testTheSpokenCardCarriesTheClockOnlyOnceAClipHasLoaded`.
13. **Playability and every companion row ask `companion.availability`; the
    picture's Share row says which file leaves.** Asking the picture offers a
    transport over bytes that have not arrived, and an unqualified "Share" on a
    card holding two files names neither.
    *Pinned by* `testTheRecordingsOwnAvailabilityDecidesItsRows`,
    `testAMissingRecordingKeepsItsOwnRepairRoute`,
    `testTheShareRowSaysWhichOfTheTwoFilesLeaves`.
14. **The accessibility value lives on the TILE, in both of its forms, and the
    band stays `accessibilityHidden`.** A card still waiting for its bytes is not
    wrapped in a button and still holds a recording that can fail; adding the
    value to the button branch alone leaves that card silent.
    *Pinned by* `testBothFormsOfTheTileSayWhatTheRecordingIsDoing` and
    `testTheSpokenCardNamesTheScreenshotAndCarriesTheWords`.
15. **`attachedToMaterialID` on the record and the snapshot is RAW.** The store
    validates nothing about it — the named material may not exist, may be the
    wrong kind, may be on another desk — because a single-card read outside a
    board build has no desk to resolve it against. The fold is the only resolver,
    and the group delete is the only validator.
    *Pinned by* `testV17AddsOnlyTheMaterialCompanionLinkColumn` and
    `testTwoDuplicateRowsDifferingOnlyInTheCompanionLinkConvergeOnOneRow`.
16. **The link is derived from the ORIGINAL capture id and travels as its own
    parameter**, and the retry lane keeps it after the picture's bytes are
    dropped. Deriving it at the write door names the escape of the escape on a
    republish; reconstructing it from remaining image bytes loses it exactly when
    a retry needs it most. The fallback note carries no link at all.
    *Pinned by* `testTheRecordingNamesThePictureThatWasCapturedWithIt`,
    `testTheParkedRecordKeepsTheLinkAfterItsPictureBytesAreDropped`,
    `testARecordEncodedWithoutTheLinkStillDecodesAndNamesNothing`,
    `testTheFallbackNoteCarriesNoLinkEvenForACaptureThatTookAPicture`,
    `testTheShortcutsLaneDecidesTheLinkBeforeItArmsAndKeepsItThroughStamped`.
17. **Reworded copy takes a NEW key.** All eight new rows are referenced in
    app-target source, which `WorkboardCopyTruthGuardTests` rule (4) checks in
    both directions; nothing was retired, because every removed literal still has
    a live reference elsewhere.
    *Pinned by* `WorkboardCopyTruthGuardTests` and
    `testEveryCompanionRowIsNamedDistinctly`.

## Deliberately not here

- **Text mode stays two cards** (U-71 in `handoff.md`) — founder call, and one
  widened kind test away if it is wanted.
- **No backfill** (U-73): pairs captured before the column existed carry no link
  and stay two cards. Inferring the pairing from timestamps is exactly the guess
  the column exists to avoid.
- **The 1,568 px `ImageProcessor` cap** (U-72) is pre-existing and untouched.
- **`deleteWorkMaterial`'s single-material `.first` vault key** (U-75) is
  pre-existing; the group path takes the `Set` this lane needed and does not
  reach into the other.
- **The 16 → 17 migration rides the framework defaults** (U-74). It is covered by
  a real SQLite test that opens a v16 store under the v17 model; what is not
  pinned anywhere is the intent, so a future change setting either option false
  would make this an unmigrated store silently.
