# Work board — grouping, Brief, dispatch and Mac selection: implementation plan

One wave: the group object, the Brief that dispatches it, and the Mac click model ship together,
because each is the other two's substrate. The founder decisions in `board-grouping-dispatch.md`
bind. Paths are relative to `Conduck/Conduck/`.

## 1. Phases and file ownership

A phase owns its files exclusively. Two phases naming one file are sequential.

| # | Phase | Owns | After | Publishes |
|---|---|---|---|---|
| P1 | Model + store | `Conversations 18.xcdatamodel/` (new) + `.xccurrentversion`, `WorkboardRecords.swift`, `ConversationStore+Workboard.swift` | — | `groupID`, `WorkItemRole`, five mutations |
| P2 | Partition + group card | `WorkboardLiveRepository`, `WorkboardViewModel`, `WorkboardGroupCardView` (new), `WorkboardCaptureCanvas` | P1 | `WorkboardCardSnapshot`, `onOpenGroup` |
| P3 | Selection, Mac package, iOS Select | P2's shared files, plus `WorkboardSelection` (new), `WorkboardAudioCardView`, `WorkboardMaterialListRow`, `WorkboardComponents`, `WorkboardArrangement` | **P2 — shared files** | `WorkboardInteractionMode` |
| P4 | Brief surface | `Views/WorkBrief/` (new), `Services/WorkBrief/PreparedTurnMaterials` (new), `WorkboardView` | P1 | `PreparedTurnMaterials`, `WorkBriefPacket` |
| P5 | Send seam + dispatch | `ConversationDetailViewModel`, `ConversationStore`, `WorkBriefPreparer` + `WorkBriefDispatcher` (new) | P4's contract file | — |
| P6 | Guards, copy, spec | `WorkboardCopyTruthGuardTests`, new drift guards, `Localizable.xcstrings`, `spec.md`, `project-structure.md` | P1–P5 | — |

P4 and P5 run in parallel with P2/P3. **`PreparedTurnMaterials` is declared once, by P4, in its
own file**; P5 consumes and never stubs it. The new folders need a `project-structure.md` map line
in P6 or `check-folder-map.sh` fails. The Brief lives outside `Views/Workboard/` and
`Services/Workboard/` so the spec's transport-free boundary over those folders survives verbatim.

## 2. Model 18

Additive, optional, default-free, relationship-free — the shape `WorkboardModelMigrationTests`
enforces for v14–v17.

| Entity | New | Meaning |
|---|---|---|
| `WorkMaterial` | `groupID: UUID?` | The sibling `WorkItem` holding this card's brief. Never the desk id. |
| `WorkItem` | `role: String?` | `nil` = the desk or a legacy item; `"group"` = a brief container. |

`WorkDispatch` is resumed with no new column: `workItemID` names the group item, which is what the
entity was shaped for, and its snapshot, gateway, conversation, message and attempt columns fill as
the run proceeds. `reviewAcknowledgedAt` stays untouched — it acknowledged a *returned result*, so
reusing it as consent would rewrite old rows as approvals. `currentDispatchID` and `boardOrder`
stay unwritten: a pointer and the row it names arrive from CloudKit independently, so the footer
reads the newest **dispatched** row instead.

The group item writes `title` (name) and `objective` (prompt), bounded by
`WorkItemContentLimits.maximumFieldCharacters` for free. `preferredGatewayRef` stays unwritten in
v1: the highlight comes from the app default as the share sheet's does, and a second stored
highlight authority is a second thing that can disagree.

**`groupID` joins `WorkMaterialCanonicalOrder`** as an orderable `groupKey`, beside `attachedToKey`
and ahead of the device-local `rowKey` — the precedent for a synced link column, and what makes two
devices holding duplicate rows agree about a group's contents. Every group write addresses **every
physical row** of each material, as `setWorkMaterialCardSize` does.

## 3. Store API

Five mutations, each one transaction under one compare-and-swap on the desk revision, returning
the refreshed `WorkItemRecord`: `createWorkMaterialGroup(memberIDs:name:)`,
`renameWorkMaterialGroup`, `dissolveWorkMaterialGroup`, `setWorkMaterialGroupMembership`, and
`setWorkGroupContent(_:title:objective:)`. All take `expectedOwnerRevision`.

Dissolve clears `groupID` on every member's every row and deletes the group item; dispatch rows are
history, never swept here — the conversation-delete fetches tombstone them. `setWorkGroupContent`
is new rather than a reuse, because the existing content writer is private and its arbitrary-item
constructor test-only; the Brief autosaves through it on dismiss, and a refusal keeps the text in
the sheet and says the board moved.

**Grouping is a reorder.** All five rewrite the whole permutation through
`rewriteWorkMaterialSequence`, which demands every logical id exactly once — so a group operation
and a drag refuse each other on the same token with the same recovery. Members become contiguous
in that rewrite; a group gets no rank space of its own.

Contiguity is a *display* rule, not a storable invariant: two devices can group different sets
offline and CloudKit merges `sequence` per row. The board draws a group at `min(sequence)` among its
arrived members, in stored order, contiguous or not; the next reorder re-normalises. Drawing a group
above a lower-ranked non-member is the licence the fold takes when a recording published before its
picture draws at the picture's rank.

An **unknown `groupID`** — the group item has not arrived — leaves its materials visible as ordinary
cards and unlinks nothing. A partially arrived group degrades to loose cards, never to a wrong one.

Removing a selection needs `removeWorkMaterials(ids:expectedOwnerRevision:)`, one CAS over the set.
Sequential `removeMaterial` calls cannot stand in — the first advances the revision the second
holds, which is why `removeMaterialGroup` exists for the fold's pair.

## 4. Seam (b): ONE partition of materials into cards

`WorkboardCompanionFold` generalises into `WorkboardBoardPartition`, one pure pass producing
`(displayed: [WorkboardCardSnapshot], hiddenChildIDs, childByParent, memberIDsByGroup)`. A card is
either a material card, which may carry a companion, or a group card with a name, members and a
count.

**The fold runs first, inside the group.** A folded recording goes wherever its picture goes and is
never independently a member — capture identity is a fact, grouping is an arrangement. Membership is
written on the picture and expanded onto the pair by the machinery that expands a reorder. A
recording that later unfolds, its picture deleted, keeps its `groupID` and becomes its own member
card: legal, no repair.

Every stored material appears exactly once — card, companion, or group member. `expandedOrder` gains
one layer: a group expands to its member run, each member to `[picture, recording]`. **The group is
one entry in the displayed array**, so contiguity holds by construction rather than by a repair
pass, and dragging a group moves its whole run.

The footer counts **cards** ("Landing page copy · 4 items") and shows no byte total — deliberately
unlike the memo's mock, because sending size is route-dependent and audio contributes transcript
bytes, so a board number would disagree with the Brief's for reasons the board cannot explain.
Bytes appear only where a gateway is named. `groupID` is single-valued, so no card is in two groups.

## 5. Seam (a): selection versus play and drag

One `WorkboardInteractionMode { browse, select }` on the view model, plus `WorkboardSelection`
(`ids`, `anchor`, pure ops over *displayed* order). The mode is consulted **before**
`WorkboardCardActionPolicy`, which is unchanged: the policy answers "what do these bytes permit",
the mode answers "does this gesture mean selection".

While `.select`, in **both layouts**: the tile's and the list row's primary Button toggles selection
instead of running `primaryAction`; every playback entry point is suppressed — the standalone audio
tile's button, the folded card's companion band, the list row's own play badge — each deactivating
its player on entry, copying the `workbenchDestinationIsActive` teardown; and `.onDrag` returns a
bare `NSItemProvider()` through the guard that already refuses during an import. A `.syncPending`
card IS selectable — grouping reads no bytes — which also answers "a click can do nothing" for the
one genuinely silent state. It is not includable in a Brief (§7).

**macOS has no Select mode**; selection is ambient and ships whole:

| Gesture | Result |
|---|---|
| Click | Select exactly that card |
| ⌘-click / ⇧-click | Toggle / extend from the anchor over displayed order |
| Drag from empty space | Rubber band over **the active layout's** frames — the mosaic engine's placed `Result` in Tiles, the measured `WorkboardRowFramesKey` frames in List. Cards own `.onDrag`, empty space owns the band, so neither can fire twice |
| Double-click | Open **the card under the pointer**, never "the selection", so a first click collapsing the selection is harmless |
| Space | Preview the anchor by the route Open takes for that kind — gallery for images, sheet for notes and links, Quick Look for files and recordings. Not a new file-materialising path, so it adds no macOS temp-copy retention |
| ⌘A / ⌫ / Esc / ⌘G / ⇧⌘G | Select all · remove selection, one confirmation naming the count · clear · group · dissolve |

The audio tile stops being the play button on macOS: the transport gains its own visible play
control nested in the now-selectable tile, legal because the tile is no longer a Button — resolving
the memo's open question by removing the collision rather than arbitrating it. iOS is unchanged in
`.browse`.

**Batch reorder.** `WorkMaterialDragPayload` gains `materialIDs: [UUID]?` (Codable, tolerant on
decode, displayed order); the one board `DropDelegate` still takes the first provider, and
`WorkboardMaterialOrdering.order(moving: [UUID], toInsertionIndex:in:)` moves the run to one slot.
The planner's "subtract one when the source precedes the gap" becomes "subtract the moved ids
preceding it" — the single-id path is n=1 of the same arithmetic, which keeps the bug the canvas
memo names fixed.

**iOS Select mode**: a Select control in the board header beside the Board view picker; the bottom
safe-area inset *swaps* from the capture composer to a Group / Remove / Done bar rather than
stacking. The composer's draft lives on the view model, so Done restores it intact. Arrow-key
navigation is out of scope — the mosaic has no focus engine.

## 6. The Brief

Host-owned: it mounts on `WorkboardPresentationModifier`, the persistent chain that exists so hiding
or unmounting Work's column cannot re-anchor a sheet. The board card raises `onOpenGroup(UUID)`, a
routing closure of exactly `openMaterial`'s shape, carrying no transport.

Contents: name, one prompt field, the reviewed material list, the gateway roster, one button. The
roster comes from `configuredRemoteAgentRefs()` + `RemoteAgentRefMetadata` +
`RemoteAgentBadgePalette`, the three the share snapshot writer resolves, with the app default
highlighted and nothing chosen. A highlight is not a decision.

**Routing is a Brief classifier over the STORED kind and availability**, never the board snapshot,
whose projection rewrites `.unknown` into `.file` or `.note` and would hide the case:

| Family | Route |
|---|---|
| Text-bearing — note, transcript, link; readable from metadata alone | Extracted UTF-8 through `AttachmentDeliveryPlanner.plan(…)`. Inline works with no file server, so these never read "can't go" |
| Image | Inline vision, converted **from the frozen copy**: `WorkMaterialImagePolicy` leaves animated, undecodable and pre-rule images at their original bytes, so no card may be assumed to hold a bounded JPEG. One that will not decode is frozen excluded with that reason; a server copy of the original still rides when a lane is ready |
| File, audio payload, `.unknown` with readable bytes | Server-required. The only family that can read "can't go", and only when no lane is ready |
| Metadata-only and not text-bearing; `.unknown` without bytes | Frozen excluded — the projection already reports these unavailable |

**Two sizes; the list shows the sending one.** A card's stored `byteSize` describes its payload —
zero for an ordinary note, and conversion or extraction changes it. The row shows the *sending*
size: UTF-8 bytes for text, the converted JPEG's for an image, upload bytes for a file — computed
locally, marked an estimate until the packet is prepared, the total their sum. The route badge sits
beside it and recomputes when the highlight changes.

Rows are deselectable, and the Brief may reference materials from outside its group, which is how
one PDF serves two asks. On a gateway with `fileTransferSupported == false` unroutable rows dim
*before* the ask and the button reads "Ask OpenRouter without 3 files"; otherwise "Ask OpenClaw".
Never a bare Send.

Audio contributes **transcript only**. A recording with none reads "No transcript — not included ·
Audio stays in Work" and cannot be selected. Sizes are transcript bytes, never recording bytes.

**Nothing leaves before Ask.** The Brief instantiates no `ComposerAttachmentCoordinator`, mints no
stored key and opens no session at open.

## 7. Seam (c) and the prepared-send seam

`WorkBriefPacket`, encoded into `briefSnapshotData`: group id, name, prompt, gateway ref and name,
the reserved conversation and dispatch ids, the desk revision, `approvedAt`, and per listed row its
material id, stored kind, sending size, planned route, content revision, and an explicit
**`included` flag with an exclusion reason**. Approval lives here and nowhere else. Validation and
preparation touch included rows only, so "the reviewed five" is a claim about the included set and
can never quietly become four.

Ask, in order, all after the press:

1. **Claim.** `isDispatching` is set synchronously before the first await, the shape
   `ComposerAttachmentCoordinator.dispatchInProgress` uses. Two presses cannot mint two packets,
   two conversations or two hops — the conversation view model's in-flight guard cannot help,
   because each Ask would create a *different* conversation.
2. **Freeze** the packet, reserving one conversation id and one dispatch id, and insert the
   `WorkDispatch` row with `userMessageID` and `dispatchedAt` still empty.
3. **Copy, then revalidate.** Materialise an immutable local copy of every included material —
   bytes for payload cards, a text/URL snapshot for text-bearing ones — then re-read each through
   `WorkboardLiveRepository.currentMaterialSnapshot` and compare revisions **after the copies
   exist and before the first upload**: the two-gate shape `WorkMaterialShareCoordinator` uses,
   because a metadata check alone leaves a window in which a replacement's bytes are the ones
   copied. Any mismatch or unreadable row refuses the whole Ask before a turn exists, naming the
   rows. Only those copies are converted and transmitted, so a replacement after this gate cannot
   substitute its bytes.
4. **Convert and upload.** Any conversion or upload failure fails the whole Ask — unlike the
   composer, whose user watches a strip they staged item by item; the Brief's user approved a list.
5. **Dispatch.** `createConversation(id:backend:)` with the reserved id — the id the dispatch row,
   the upload key namespace and the deletion tombstone all use — then the turn.

v1 always opens a **new** conversation: "Ask OpenClaw" names a gateway, not a thread.

The seam in `ConversationDetailViewModel.sendUserTurn` is one parameter,
`prepared: PreparedTurnMaterials? = nil`, with a precondition that `attachments` is empty when it is
present. The one line at the `.pending` processing site becomes a choice between
`Self.processAttachments(attachments)` and `ProcessedAttachments(prepared:)`. **That initialiser
sets no `droppedCount` — the branch cannot express a drop.** `expectedRef` and `expectedFileLaneID`
ride exactly as the composer passes them, so a stale roster cannot reroute stored keys, and the turn
is written durably before the hop as everywhere else.

**The receipt is carried, not inferred.** `onLocalAcceptance` returns only a Bool and the appended
message id never leaves the method, so `PreparedTurnMaterials` carries the dispatch id,
`sendUserTurn` forwards it at its append call as `linkingDispatch:`, and the store stamps
`userMessageID`, `dispatchedAt` and the `deliveryAttemptID` the append mints **in the same
`context.perform` save that writes the turn**. A crash between freeze and append leaves a dispatch
row with no `dispatchedAt`, and the footer reads dispatched rows only — so a frozen-but-unsent
packet never claims the group was asked. Re-ask is a new dispatch id and a new packet, never a
mutation. **The Brief has no Retry**: once a turn exists the conversation is the only recovery
surface, which is what makes at-most-once dispatch safe. The group keeps an "Asked OpenClaw · 2h"
footer drawn by a `WorkBriefStatusFooter` the Brief subsystem owns, honouring the existing
`conversationRemovedAt` tombstone.

Partial sync: the Brief lists what is **locally present** and never claims completeness. A member
that is `syncPending` or `unavailableOnThisDevice` is listed, frozen excluded, with the reason —
omitting it is exactly the N−1 failure. A group with nothing includable disables the button.

## 8. Spec and copy-guard rewrites (P6)

The spec heading becomes **"## Work is one desk, and only an Ask makes a turn"**, opening: *"Work
is one desk per person, made by the first capture and never deleted. Every capture surface lands
on it. Only an explicit Ask naming the gateway authorises transmission of the frozen, reviewed
prompt and material representations to that gateway and its file server; capture and grouping
never dispatch."* A short paragraph adds the group — the fold generalised, a sibling item holding
the brief, one group per card, no nesting — and the rejected alternatives: repointing
`workItemID`, membership-only, drop-on-card, a link graph, Ask on every card. No source file cites
the old heading by name, so `check-spec-cites.sh` stays green.

Copy guard: rule 1 keeps its mechanism, gains **ask/asked** to `retiredWords`, and its rationale
becomes *"VOCABULARY. Work captures, groups, opens, keeps and removes; none of those authorises
transmission to a gateway or file server. That belongs to the Brief, where an explicit Ask naming
the gateway commits the frozen packet the person reviewed."* `"workBrief."` joins `catalogPrefixes`
so rule 4 scans it both ways. New **rule 8**: a `workBrief.*` key may say ask or send; it may be
referenced only from files under `WorkBrief/`, which is why the board's status footer is a
Brief-owned view rather than a Work string saying "asked"; and the Ask button's row must carry a
`%@`, so no button reads a bare Send. New catalog rows are spliced by hand, sorted,
`indent=2, ensure_ascii=False`.

New guard `WorkBriefBoundaryDriftGuardTests`: no file under `Views/Workboard/`,
`Services/Workboard/` or `WorkboardViewModel.swift` names `RemoteAgentRef`, `sendUserTurn`,
`ConversationDetailViewModel`, `uploadServerFile` or `ComposerAttachmentCoordinator`; no file
under `WorkBrief/` names `ComposerAttachmentCoordinator`. `WorkBriefStatusFooter` is allowlisted.

## 9. Tests that pin each invariant

| Invariant | Test |
|---|---|
| v18 adds two optional columns, mutates no shipped entity, and a real v17 store opens under it | `WorkboardModelMigrationTests` (new pair) |
| Each mutation advances the desk revision under one CAS and refuses a stale token | `WorkboardGroupStoreTests` (new) |
| Every write addresses every physical row; duplicates differing in `groupID` resolve canonically; a refused prompt save keeps the text | `WorkboardGroupStoreTests` |
| Every stored material appears exactly once — card, companion, member | `WorkboardBoardPartitionTests` (new) |
| A group holding a folded pair still hands the store every logical id exactly once | `WorkboardBoardPartitionTests` |
| The fold wins inside a group; a companion is never an independent member | `WorkboardCompanionFoldTests` (extended) |
| An unknown `groupID` leaves materials visible and unlinks nothing | `WorkboardBoardPartitionTests` |
| Interleaved ranks draw one group card; the next reorder writes a contiguous run | `WorkboardOrderingTests` (extended) |
| Batch move: n moved ids preceding the gap subtract n | `WorkboardMaterialOrderingTests` |
| In `.select`, play, preview and reorder are suppressed in Tiles and List, folded play badge included | `WorkboardSelectionModeTests` (new) |
| Range selection follows displayed, not stored, order | `WorkboardSelectionTests` (new) |
| Every `WorkMaterialKind` classifies — `.unknown` with and without bytes; animated, legacy, undecodable images | `WorkBriefRouteTests` (new) |
| Sending size is computed, not read off the card: multibyte note, link, extracted document, converted image | `WorkBriefRouteTests` |
| An excluded row stays excluded; the included count never silently drops | `WorkBriefPreparerTests` (new) |
| A replacement during the copy uploads nothing and writes no turn; one after the final gate never substitutes its bytes | `WorkBriefPreparerTests` |
| Two Ask presses mint one packet, one conversation, one hop; the reserved id reaches creation, the dispatch row and the tombstone | `WorkBriefDispatcherTests` (new) |
| Through `sendUserTurn`, the append itself persists `userMessageID`, `deliveryAttemptID`, `dispatchedAt` | `WorkBriefDispatcherTests` |
| A dispatch row with no `dispatchedAt` never shows an "Asked" footer | `WorkDispatchRecordTests` (new) |
| The prepared branch cannot carry a dropped count | `PreparedTurnMaterialsTests` (new) |
| No byte leaves before Ask — no upload, no stored key at open | `WorkBriefPreparerTests` + drift guard |
| Vocabulary, `workBrief.*` scope, named-gateway button | `WorkboardCopyTruthGuardTests` 1, 4, 8 |

## 10. Acceptance checks (founder QA script)

1. **Mac, browse.** Click selects, nothing opens; double-click opens. ⇧-click three cards away
   selects four in reading order. Rubber-band from empty space works in **both** Tiles and List.
   Esc clears, ⌘A selects all. The recording tile has a visible play control and clicking the tile
   selects; Space previews it, Space on a note opens the note sheet, on an image the gallery.
2. **Group.** Select four, ⌘G, name it. One stacked card, member strip, "4 items"; the four are
   contiguous and drag together. Relaunch — the group survives.
3. **iPhone.** Select → tap four → Group. The composer is replaced by the Select bar while
   selecting and returns with its draft intact. Tapping a group opens the Brief.
4. **Brief.** Every row shows a sending size and a route badge. Switch the highlight to a gateway
   with no file server: binary rows read "can't go" and the button reads "…without N files", while
   notes and links stay inline. A GIF or undecodable image, and a recording with no transcript, are
   listed excluded with their reason. Type a prompt, dismiss, reopen, relaunch — it survives.
   Nothing uploads while the Brief is merely open.
5. **Ask.** One press opens one new conversation on the named gateway carrying exactly the included
   rows; the group keeps "Asked … · just now". Press twice fast: one conversation, one turn.
6. **Failure cases.** Delete a member on a second device with the Brief open, then Ask — refused
   whole, naming the row, no conversation created. Replace a card's file *while the copies are being
   made* — nothing uploads, no turn; replace it *after* validation — the turn carries the approved
   bytes. Wi-Fi off with a file row included — the Ask fails whole, no partial turn. Ask, then
   delete the conversation — the footer respects the tombstone.
7. **Partial sync.** Where a member is still syncing, the Brief lists it excluded with "Waiting for
   iCloud" and sends the rest without claiming the group was complete.

## Appendix — review resolutions

Two Codex rounds against the code. Fourteen findings, all with file:line evidence, **all accepted
and folded in**; none refuted.

| # | Finding | Landed |
|---|---|---|
| r1-1 | Metadata-only revalidation leaves a window where a replacement's bytes are the ones copied | §7.3 |
| r1-2 | The packet could not tell an excluded row from an approved one | §7 `included` flag |
| r1-3 | The text planner classifies no images or binaries and has no "can't go" | §6 families |
| r1-4 | `createConversation(backend:)` mints its own UUID | §7.5 reserved id |
| r1-5 | The receipt could not come back, and separate stamping leaves a crash window | §7 `linkingDispatch` |
| r1-6 | Two Ask presses create two conversations | §7.1 claim |
| r1-7 | The prompt had a home but no write API | §3 `setWorkGroupContent` |
| r1-8 | Selection ignored the List renderer's own Button, play badge and frames | §5, P3 |
| r1-9 | Space cannot Quick Look notes, links or images | §5 preview by kind |
| r1-10 | Stored `byteSize` is zero for a note and describes payload, not what is sent | §6 sending size |
| r2-1 | The dispatch id had no path *through* `sendUserTurn` | §7 receipt paragraph |
| r2-2 | `.unknown` was undefined, and the projection rewrites it, hiding the gap | §6 classifier input |
| r2-3 | `WorkMaterialImagePolicy` leaves animated, undecodable and legacy images unconverted | §6 image family |
| r2-4 | The QA line promised rejecting a replacement "anywhere mid-Ask", which no gate delivers | §10.7 split |
