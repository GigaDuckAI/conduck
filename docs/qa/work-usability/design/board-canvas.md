# Work board — canvas and arrangement

Lens: what the board looks like, and how moving things feels. macOS first.

## 1. Diagnosis

**The mosaic's expressiveness is dead weight.** The founder's board is a uniform four-column grid of
equal squares — no wide cards, no small ones, no ragged bands, no holes. Every material is created
`.standard`, nothing auto-assigns a size, and the only route to a wide card is a per-card menu item
nobody has used. The app pays for a mixed-span engine and the cascade it implies, and renders a plain
lattice.

**Card weight is backwards, and the text is duplicated.** A note titled "hi" shows body "hi." An
audio card titled "Just some code. Nothing else" repeats that sentence underneath. Three
share-extension cards read "Share note" on the identity line with the real content below. The
identity line goes to a generated prefix or a channel label, the tile sits about 85% empty, and
image footers spend prominent space on "5,5 MB · 3 days ago."

**The window is mostly margin.** macOS collapses the sidebar to give Work the window, then Work
re-narrows to a 920pt cap: four cards per row in an 1860pt window.

**Dragging fails three ways.** Nothing moves, so the capsule is a promise the person must simulate,
where Home Screen and Photos move the content itself. The commit is a post-hoc round trip that answers
a direct-manipulation gesture with a modal whenever a concurrent arrival bumps the desk revision. And
there is no lift language: long press with no haptic on iOS, no cursor change on macOS, one whole-board
target resolved by geometry alone.

**The header row is debugging UI.** "Drag to reorder" captions a gesture instead of doing anything, and
the Tiles/List picker beside it renders in system blue under a brand-amber Chats/Work control: two
competing segmented controls in two accents, where Finder and Photos use the toolbar Conduck has.

## 2. Options

**A — Uniform ordered gallery.** Keep the sequence and enforce what the board already is: one
footprint, fixed slot geometry, live reflow, and the tile's area spent on content. Precedent:
Photos, Finder icon view, Notes gallery.

**B — Keep mixed footprints, make Feature discoverable.** The knob may be buried rather than unwanted.
*Cost:* every packing cost stays — cascade, hysteresis, holes — bought on a hypothesis, and today's
cramped duplicated card is a bad baseline for judging whether more area helps.

**C — Free-form canvas.** Cards at (x, y), pan and zoom, so persistent position becomes information a
sequence cannot hold. *Cost:* a 390pt phone shows about one and a half cards, scattered coordinates
leave unrepairable noise where a lost reorder still leaves a sensible list, and every outside-board
capture needs a landing spot, which is a packing algorithm.

**D — Lanes, or a stream.** Lanes suit grouping as an overlay, not a base; a stream denies arrangement.

## 3. Recommendation

**Take A.** Preferring an ordered desk to a canvas is a product decision, not a proof: sequence is
load-bearing across List view, VoiceOver and Move Earlier/Later. It is the one call the founder might
reasonably overrule, and whether spatial arrangement belongs *inside* a group is the grouping
designer's hypothesis.

**Wave 1 — anatomy, header, width. No layout change.**

| Kind | Card face |
|---|---|
| Note, transcript | One continuous excerpt. Suppress a heading that equals the body *or repeats its generated leading prefix*, since equality alone misses longer notes, but keep an independently meaningful title and never delete the body's opening sentence. A transcript must not imply playable audio. |
| Image | Full bleed, identifying name always visible, size and age demoted to macOS hover in reserved space so the caption never moves. Availability glyph and companion band unconditional. |
| Link | Title primary, host always kept, a path excerpt only where it distinguishes. No network fetch at render; a muted glyph where no icon bytes exist. |
| File | Filename is the identity: two lines, middle truncation, extension protected. Type and size beneath. Existing PDF thumbnails only, never generated at render. |
| Audio | No duration — not on the record, known only after decoding. Transcript carries the weight; with no words, a name plus capture time. |

That is a shared presentation policy, and the accessibility builders must use it too, since both
currently append name and body separately. Two fixes are upstream: the drainer writes the literal
"Share note" as the title of every non-empty share-sheet note, so new captures should derive a title
from content, while legacy generic titles are suppressed at display rather than rewritten.

Delete "Drag to reorder." Move Tiles/List into a macOS window-toolbar view menu declared *before* the
trailing section-control host, gated by Work activity, sharing one layout binding with the board
rather than duplicating its private state; that also removes the two-accent clash without repainting
anything, and iOS gets the same menu in the navigation bar. Raise the actual grid to 1440pt (1472
outer, since the cap sits outside the 16pt padding) for six cards per row. The 1860pt ceiling buys no
extra column, only 30% bigger cards.

**Wave 2 — enforce one footprint, then fix the feel.** Render every card `standard` and retire the
Card Size control, keeping the stored column readable and rewriting nobody's rows: an incoming `small`
or `large` renders standard. Enforcement must be total — if any path still draws a wide card, the
mixed engine and its tests all stay and the gesture cannot assume fixed slots.

Uniformity is what makes the drag cheap. Slot rectangles become fixed for a given width and card count,
so **target the slots, not the animated card frames**, and the accepted-slot rule is just "hold this slot
until the pointer crosses the next slot's boundary." That deletes the packing-dependent hysteresis. What
survives: source identity, cancellation, edge autoscroll under a still pointer, commit handoff, and
rebase-or-cancel rules for a source deleted mid-drag, a fold, a column-count change or a remote reorder.
One trap remains — the planner already subtracts one when the source precedes the gap, so a
source-removed index double-adjusts.

Keep the hand-rolled `NSItemProvider` and the single board `DropDelegate`. The `Transferable` migration
is not the fix: `ownProcess` does not gate a same-process handler, the advertised content type does, and
`onDropSessionUpdated` is macOS-only. Legacy `.onDrag(_:preview:)` already gives a custom lift preview,
so add that plus `.sensoryFeedback(.impact)` on iOS and `pointerStyle` grab cursors on macOS.

**Fix the rollback as a rebase, not a superset test.** Send the baseline canonical order beside the
proposed one and accept when the current canonical order equals that baseline plus new ids appended; a
bare superset check silently erases a concurrent reorder. The baseline must be canonical, not
expanded-displayed order, since a fold can display `other, picture` over stored `recording, other,
picture`. Real conflicts land the store's order behind a transient inline note, never an alert.

**Room reserved for the siblings.** Build selection in Wave 2 — `Set<UUID>` plus an anchor, click /
⌘-click / ⇧-click on macOS, a Select mode on iOS, Esc to clear. Tap stays "open," so selection is a mode
on iOS and a modifier on macOS. Grouping plugs in as a selection-scoped action, and a group card is a
stacked-edge tile with a count — what the folded pair already is, so grouping generalizes the fold. Dispatch
belongs on the group object and its own surface, so `WorkboardCaptureCanvas` keeps its literal "no
transport dependency."

**Top three risks.** (1) Uniformity is reversible only on evidence, so keep the mixed engine behind the
enforcement rather than deleting it. (2) Uniformity removes packing amplification, not movement: cards
between source and destination still shift, and absolute position still does not survive a reorder.
(3) Copy-truth rule 4 fails on orphan catalog rows, and `MacWorkbenchShellDriftGuardTests` pins
section-control placement.

## 4. Codex debate log

- **Killed my central claim.** Retiring `small` makes every band two units tall but does not stabilise
  reflow: `S,F,S` and `S,S,F` on four columns give equal band heights and different board heights. It
  also caught two ordering bugs — the planner already subtracts one for a preceding source, and a
  superset append test passes on "reorder, then append" and erases the reorder.
- **Killed my security reasoning.** `ownProcess` cannot gate another handler in the *same* process; the
  advertised content type separates reorder from import. Wave 2 collapsed from an API migration into
  "change what you draw."
- **Where I pushed and it held.** I offered a cheaper destination ghost instead of live reflow. It
  refused well: a ghost draws one object from the *future* arrangement over objects from the *current*
  one, so it lands on an occupied card and reads as replacement.
- **Where the screenshot reversed us both.** Codex had insisted a wide Feature earns its keep as a
  landmark, and I had agreed. Shown that the real board is all-standard and nothing auto-assigns a size,
  it withdrew Feature outright: the observed defects are wasted width, repeated text and bad dragging,
  none of which mixed packing explains. That also made the gesture cheaper, since enforced uniformity
  gives fixed slots — on condition enforcement is total, as one reachable wide card reinstates every
  assumption.
- **Its caveats I kept.** All-standard today does not prove nobody ever resized, since `standard` is also
  the absence a reset produces, and the buried-menu theory is only a discoverability hypothesis.
- **Split one bug into two, and the rest.** Title/body duplication is presentational, fixed by a shared
  suppression policy the accessibility text must share; "Share note" is an upstream drainer literal. It
  conceded the ordered desk as defensible but correctly called my "outside-board captures dominate"
  argument a dodge. Four cards in an 1860pt window matches the 920pt cap, so 1440 stands.
