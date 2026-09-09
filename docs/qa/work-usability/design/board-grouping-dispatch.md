# Work board — grouping and dispatch to a gateway

## 1. Diagnosis

**The board shows no trace of either verb.** Twelve uniform tiles fill four columns and
nothing on any of them says "these belong together" or "this could go somewhere". There is
no selection affordance to inherit, and a note tile reading "hi" spends most of its square
on nothing, so the density a group would relieve is already on screen.

**No noun a prompt can attach to.** The desk is a flat bag on a dense integer rank, and the
prompt-shaped fields (`objective`, `context`, `desiredOutcome`, `constraints`,
`preferredGatewayRef`) hang off the one desk item nothing writes. Adjacency is the poor
man's group: dragging cards together records position, not meaning.

**The one grouping primitive refuses to generalise.** The recording-names-picture fold is
two members, kind-constrained, capture-derived, with a no-chain rule stated in the companion
type (`WorkboardViewModel.swift:132-135`). No selection exists, so every plural verb is
blocked; reading order is a hard layout invariant, so a group cannot be a region or lane.

**The buried lede: the schema exists, mothballed.** A dormant `WorkDispatch` entity
(`Conversations 17.xcdatamodel:89`) carries `briefSnapshotData`, `promptSnapshot`,
`titleSnapshot`, `gatewayRef`, `conversationID`, `userMessageID`, `deliveryAttemptID`,
`dispatchedAt` and `workItemID`. Two fetches tombstone it on conversation delete
(`ConversationStore.swift:2552,2609`); nothing else touches it. This is a resumed feature.

## 2. Options for the group object

- **A — group is a `WorkItem`, members repoint `workItemID`.** Schema-native, clearly the
  original intent. **Rejected on evidence:** publication validates a foreign owner against
  legacy capture provenance (`ConversationStore+Workboard.swift:1004,2212`), which a named
  group fails, so grouping does not survive a recapture.
- **B — membership only, nothing collapses** (a `groupID`, a colour chip, a filter). Touches
  no invariant, but twelve cards stay twelve; it does not answer the density complaint.
- **C — drag one card onto another.** Drop-on-card needs a second semantic on a single
  geometry-resolved drop target (dwell = merge, edge = insert), the exact ambiguity that
  design avoided, and iPhone `.onDrag` has no lift preview. Additive later.
- **D — recommended: generalise the fold, own the brief in a sibling item.** Materials keep
  `workItemID` = desk, so replay, idempotency and the rank space are untouched. A nullable
  `groupID` names a sibling `WorkItem` with a role marker, used only as the brief container —
  what `WorkDispatch.workItemID` already expects. Leave `boardOrder` unused.

## 3. The group

A group is the existing fold with N members, a person-authored link and a name — and the
fold already ships the visual vocabulary. A folded pair draws today as a host card with a
small dark pill docked inside it carrying the companion's play control and title. A stack
extends that pill into a member strip rather than inventing chrome, footer reading "Landing
page copy · 4 items · 6.1 MB".

**Grouping IS a reorder.** I first claimed membership could be written without renumbering,
the stack drawn at `min(sequence)`. False: every reorder expands *all* folds and rewrites the
whole permutation, so grouping A and D then dragging E drags D beside A anyway. Group
creation makes members contiguous in one transaction advancing the desk revision — the same
compare-and-swap and refusal people already meet on a drag.

**Making one: Select mode**, both platforms, with a home already. The board header carries a
"Drag to reorder" caption and a "Board view" control, so Select belongs beside them, not in
the titlebar. Mac gets click, shift-click range, command-click toggle, rubber-band from
empty space only, and ⌘G; iPhone gets a Select button and a bottom-bar Group, the Photos
pattern. **The hazard is one gesture both selecting a card and firing its preview or inline
audio transport** — several cards on the board carry a live play control. Minimum fix: one
shared interaction mode decided *before* `WorkboardCardActionPolicy`, with play, preview and
reorder drags suppressed while selecting.

**No nesting, one board group per card.** The companion type already forbids chaining, a card
in two groups cannot fold into both without appearing twice, and the reorder planner demands
every logical id exactly once. Source reuse is solved on the dispatch side instead. Companion
folding and human grouping must yield ONE partition of materials into displayed cards.

## 4. Dispatch

**The prompt is never typed in the desk composer**, whose destination is a private
single-case enum written to stop a second destination creeping back in
(`WorkboardCaptureCanvas.swift:19-44`). There is a second, visual reason. That composer
already submits with a grey up-arrow circle, the same affordance Chat uses to reach a
gateway. Once dispatch exists anywhere in the app, a prompt field sitting above that arrow
makes "commit to my desk" and "send to an AI" look like one button.

**Tapping a stack opens a Brief**, owned by the persistent host rather than the sheet, since
macOS unmounts the desk column. Title, one prompt field, the reviewed material list, the
gateway roster with the app default highlighted, copied from the share sheet whose header
says it best: *a highlight is not a decision*. One button names where it goes: "Ask
OpenClaw", never a bare Send.

**The list is the privacy surface**: every material with byte size, a running total, and a
route badge — inline, uploads to your file server, or can't go. Rows are deselectable, and
the Brief may pull in materials from *outside* its group as dispatch references, which is how
one shared PDF serves two asks. On OpenRouter (`fileTransferSupported == false`) unroutable
items are dimmed *before* the ask and the button reads "Ask OpenRouter without 3 files".

**Dispatch is reachable only from a group in v1** — a group of one is two taps. Ask on every
card turns a desk where things rest into an outbox with sixty send buttons, the exact
property the founder valued. Codex conceded this after pushback.

**Audio is transcript-only**, so the voice sheet's shipped promise stays literally true. A
recording with no transcript reads "No transcript — not included · Audio stays in Work" and
cannot be selected. Count transcript bytes, never recording bytes.

**Zero gateway, speech-provider or file-server traffic before Ask.** A real blocker:
`ComposerAttachmentCoordinator` uploads originals at *stage* time (`:433,560`), so a Brief
staging through it leaks bytes before a gateway is chosen. The Brief owns a local preparer
and never instantiates that coordinator. The smallest correct send seam is a
`.prepared(PreparedTurnMaterials)` branch beside today's `.pending` processing at
`ConversationDetailViewModel.swift:4150`. That branch may **not** carry a dropped count:
today's path can send a surviving subset when conversion fails, and a reviewed five must
never silently become four.

**After dispatch** a `WorkDispatch` row records the run; the group stays on the desk with an
"Asked OpenClaw · 2h" footer respecting the existing tombstone. Re-ask is a new run id and a
new frozen packet. Do **not** reuse `reviewAcknowledgedAt` as sending permission — it
acknowledged a returned result *after* dispatch. Approval goes in `briefSnapshotData`.

## 5. The boundary

The invariant moves off the group and onto the packet:

> Only an explicit Ask naming the gateway authorises transmission of the frozen, reviewed
> prompt and material representations to that gateway and its file server. Capture and
> grouping never dispatch.

**Keep copy-guard rule 1; rewrite its rationale honestly** — moving strings to a
`workBrief.*` prefix preserves the test mechanically while the claim underneath goes false.
Proposed: *"VOCABULARY. Work captures, groups, opens, keeps and removes; none of those
authorises transmission to a gateway or file server. That belongs to the Brief, where an
explicit Ask naming the gateway commits the frozen packet the person reviewed."* Keep the
send/dispatch/brief/draft families banned on `workboard.*` and **add ask/asked**, not banned
today. Add `workBrief.*` to the bidirectional catalog scan, enforce where those keys may be
*used*, and make the new rule behavioural: the named Ask submits the packet the review
described.

## 6. "Connect the ideas"

Grouping, plus **an editable `caption`** — the column exists on every material and is never
written after capture, so one line of "why this is here" is the annotation half at no schema
cost. **Reject a Freeform-style link graph:** a second ordering system on a board whose
reading order is a hard invariant, and the brief consumes a set, not a graph.

## 7. Top risks

1. **Partial group sync.** Records arrive independently and a group carries no membership
   manifest, so a device cannot tell a complete one-member group from a partially arrived
   three-member one. Dispatch must act on the *reviewed local selection* and never claim
   completeness. An unknown `groupID` must leave its material visible, never unlink it.
2. **`groupID` meets duplicate reconciliation.** One logical material can have several
   physical rows; membership must participate in canonical selection and address every
   duplicate, or two devices disagree about the group's contents.
3. **The guard changes character** from structural to procedural. Add a source drift guard
   naming the Brief as the sole exception, as the desk already guards its sole load owner.

*Cheap to get wrong:* the migration is additive only, so retiring the dormant brief columns
means retiring their API and UI ownership, never deleting production CloudKit fields.

## 8. Codex debate log

- **Killed my best-sounding claim:** membership-only writes cannot preserve positions, since
  every reorder expands all folds and rewrites the permutation.
- **Found `WorkDispatch`**, which I missed entirely — reframing the work from designing a
  brief to resuming one, and supplying the identity model I was about to reinvent.
- **Killed Option A on evidence, not taste.** I rejected repointing `workItemID` on vague sync
  grounds; Codex traced the replay chain. Better reason, same verdict.
- **Caught the eager upload:** my Brief would have leaked bytes at open, before a gateway was
  chosen, contradicting the very precedent I was quoting.
- **Caught the audio boundary** and **the partial-send hole**, where conversion failure can
  silently drop a reviewed item. It also stopped me misusing `reviewAcknowledgedAt`, a
  post-dispatch result acknowledgement whose reuse would rewrite old records as consent.
- **Where it pushed and I held.** Codex wanted single-card Ask for source reuse; I argued
  legibility and offered outside-material references instead, and it endorsed group-only for
  v1. I kept one dense sequence as the single ordering authority rather than reviving
  `boardOrder`, and it agreed reusing the schema does not make every dormant field useful.
- **Unresolved, flagged not hidden:** the companion-fold × human-group partition.
