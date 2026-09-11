# Work board — wave A handoff

## 1. Status

**Built. Verified by Codex. Awaiting your QA. Nothing is committed.** Everything sits in the working
tree of `.claude/worktrees/work-board`, branch `feature/work-board`. Your main checkout is untouched
apart from the `Conduck` submodule modification that predates this session. Changed files:

**Modified (19 sources + 12 test files):** `Localizable.xcstrings`, `Models/WorkboardRecords`,
`Services/ConversationStore+Workboard`, `Services/Workboard/WorkCaptureDrainer`,
`Services/Workboard/WorkboardLiveRepository`, `ViewModels/WorkboardViewModel`,
`Views/Conversation/AttachmentFullScreenView`, `Views/Conversation/AttachmentImageGrid`,
and in `Views/Workboard/`: `PersonalWorkbenchView`, `WorkboardArrangement`, `WorkboardAudioCardView`,
`WorkboardCaptureCanvas`, `WorkboardCardActionPolicy`, `WorkboardComponents`, `WorkboardDetailView`,
`WorkboardMaterialListRow`, `WorkboardMosaicLayout`, `WorkboardTutorialView`, `WorkboardView`.

**New:** `AttachmentGalleryShareLink`, `WorkboardCardFace`, `WorkboardDragResolution`; four test
files (`WorkboardCardFacePolicyTests`, `WorkboardDragArrangementTests`,
`WorkboardDragResolutionTests`, `WorkboardReorderRebaseTests`); five design memos under
`docs/qa/work-usability/design/`. No changes to `spec.md` or `project-structure.md` — nothing here
changes a documented decision.

## 2. What changed, in user terms

**Card faces (lane F).** A card now says its thing once. A one-line note no longer shows its text as
both title and body; a voice note leads with its transcript instead of repeating it. Share-sheet notes
get a title derived from their content rather than three identical "Share note" rows — and older cards
hide the generic line at display time, so nothing in your data was rewritten. Image cards keep the
name always visible and demote size and age to a Mac hover, in reserved space, so the name never
jumps. A card still receiving bytes says "Waiting for iCloud…" in words, not just a glyph; a
local-only card reads as informational, never as an error. Every card is the same size now, and the
per-card **Card Size** menu is gone.

**Preview and opening (lane P).** The Mac preview no longer draws that stray strip of unlabeled dots
— an AppKit control escaping its container. It renders one page at a time with a real header: name,
counter, Previous/Next, arrow keys, Share. Chat's gallery gets the identical header and the Share it
never had. Share exports a proper JPEG with a real filename, so Photos, Messages and Mail accept it.
Links open in the browser on click instead of a placeholder sheet. A folded card (a recording that
named a picture) opens as one sheet.

**Dragging (lane D).** Dragging a card now moves the board. The card leaves its place, a dashed
placeholder stands where it will land, and neighbours slide only when the destination changes. iPhone
gets a bump on lift and a lighter one at each new destination; the Mac gets an open-hand cursor over a
card, closed while dragging. On release the card lands where the placeholder was, with no flash of the
old order. If a capture arrives mid-drag, Tiles rebases quietly; List gives up and moves nothing
rather than guessing, because a list's positions are measured, not calculated. Reordering no longer
answers a direct gesture with a modal alert.

**Ordering correctness (lane L).** Two real data bugs Codex found and we fixed: a reorder could
promote a losing duplicate row ahead of the local clock, and a rebase could accept a synced-in picture
that folded away a recording. Also, the board's usable width rose, so a wide Mac window now shows six
cards per row instead of four.

## 3. Gates

| Gate | Result |
|---|---|
| iOS suite | **Executed 5832 tests, 1 skipped, 0 failures (0 unexpected)** in 101.335s — `** TEST SUCCEEDED **`, scheme Conduck, iPhone 17 Pro sim (booted + `bootstatus -b` first). The one skip is the known baseline environment skip (`GatewayAdapterBriefTests.testClipboardBriefRevisionPinMatchesPublishedContract`). 5830 → 5832 is exactly the two regression tests added this pass, both passing by name. `WorkboardCopyTruthGuardTests` and `WorkboardDragResolutionTests` passed. Log: `scratchpad/test-ios-2.log` |
| Watch suite | **Executed 302 tests, 0 failures** in 9.802s — `** TEST SUCCEEDED **`, Apple Watch Series 11 46mm. Exactly the 302 / 0 baseline; the watch sim stayed shut down for the whole iOS run. Log: `scratchpad/test-watch-2.log` |
| macOS | `** BUILD SUCCEEDED **` and `** TEST BUILD SUCCEEDED **` (`platform=macOS`, no signing). The macOS test bundle was **not** run, per standing instruction — `WorkboardAudioCaptureTests` hangs on the host. iOS compile before the suite: `** TEST BUILD SUCCEEDED **`. Logs: `scratchpad/build-mac-2.log`, `build-mac-test-2.log`, `build-ios-2.log` |
| Repo scripts | All six exit 0: `check-storage-seam`, `check-folder-map`, `check-spec-cites`, `check-legal-copies`, `check-spec-size`, `add-spdx-headers --check`. `git diff --check` clean; no trailing whitespace in new files. Build cache removed via the sanctioned script; other sessions untouched |
| String catalog | Parses clean with a duplicate-key detector: 2,354 rows, zero duplicates, byte-untouched this pass. Every `workboard.*` / `attachment.*` literal cross-checked — zero missing, zero orphans |

## 4. Codex verification

Codex reviewed each lane's diff and then the whole integrated diff.

| Lane | Raised | Fixed | Refutation accepted | Still open |
|---|---|---|---|---|
| P (preview) | 2 | 6 | 0 | 1 — opening a folded card while its recording plays leaves playback with the board, so the sheet shows Play while audio continues |
| F (card faces) | 5 | 5 | 0 | 1 — folded recordings bypass the shared dedupe policy and can repeat their transcript's opening line |
| L (ordering) | 3 | 6 | 0 | 1 — the "one switch restores mixed card sizes" reversal is incomplete (below) |
| D (dragging) | 3 | 5 | 0 | 0 |
| Whole diff | 3 | 7 | 1 | 1 — now fixed, below |

Three findings were **refuted, and the refutation accepted**: link cards do keep explicit ports; the
gallery does distinguish "Not on this device" from "Waiting for iCloud…"; and Chat's Share uses a
single static JPEG representation plus a per-item filename, the only shape the API allows. One low
caveat on that last: QA-mode seeded drafts persist real PNG bytes, so "every page is JPEG" holds for
real capture paths but not QA seeds.

**The one finding fixed after the last integration.** A drop resolver built a doubly-wrapped optional,
so a board merely *holding* an abandoned drag session refused an incoming cross-window drop before it
was even decoded. I verified the premise rather than taking it, confirmed a cancelled local drag does
leave that stale session behind, and fixed it — with the list's deliberate refusal preserved, since
the fallback is reached only at the moment the board is drawing nothing lifted. That exposed a second
bug in the same lines (a stale session could open a hole at the wrong card), fixed in the same edit.
Two regression tests pin both, each with a control that fails if the old spelling returns.

**Deliberately left open.** Flipping the mixed-card-size switch back on would restore mixed geometry
without the matching card drawing. Not a live defect today, and the cheap fix would silence the
tripwire while leaving the real gap; a guard test fails by name the day anyone flips it. Also open:
the header caption and picker have no owner yet (below), and one policy helper stays test-only until
the grouping wave's preview router calls it.

## 5. QA script

**macOS first.**

1. Work → open a picture. The header shows name, counter, Previous/Next and Share. **No strip of
   dots.** Arrow keys work on the very first press, without clicking first, and Share always acts on
   the page you can see. *Fail:* dots reappear; arrows dead until you click; Share sends the wrong page.
2. Chat → open an image from a message. Same header, Share present. Share it to Photos, Messages and
   Mail. *Fail:* a destination refuses it, or the file arrives unnamed.
3. Board: a one-line note shows its text **once**; a long note shows one continuous excerpt with no
   repeated first line; three share-sheet notes carry three different titles, not three "Share note".
4. A syncing card says **"Waiting for iCloud…"** in words, on the tile and in the list row. A
   local-only card is teal/informational, never warning-coloured.
5. A link card clicks through to the browser. A folded card opens as **one** sheet.
6. Every card is the same size; the ellipsis and context menus have **no Card Size**. Move
   Earlier/Later, Open, Share, Reattach and Remove all still work.
7. Widen the window: **six cards per row**.
8. Drag a card. It leaves the board; a dashed placeholder marks the landing slot; the cursor is an
   open hand over a card, closed while dragging; neighbours slide only when the target changes.
   Release: **no flash of the old order**. *Fail:* an alert on a conflicting drop.
9. Drag off the board and back without releasing — the placeholder disappears, then returns. Release
   outside: nothing moves. Drop past the last card: it appends.
10. In **List**, repeat 8–9; the placeholder is a row of the dragged row's height.
11. **New this pass:** with two Work windows open, cancel a drag in one by releasing off the board,
    then drag a card in from the *other* window. It must still reorder.

**Then iPhone.** Repeat 3–6 and 8–10, plus a bump on the long-press lift and a lighter one at each
new destination. Reduce Motion on — everything works, nothing animates. VoiceOver reaches
Previous/Next, and Move Earlier/Later announce the new position.

**Two things nobody could test from here.** Whether the board actually *starts* scrolling when a drag
reaches the edge (that scroll view was nobody's lane; the re-resolution half is built and tested), and
whether it is acceptable that lifting a playing card stops its playback — a deliberate trade, but a
behaviour change you should see.

## 6. Deferred / out of scope

- **Header chrome** — deleting the "Drag to reorder" caption and moving the Tiles/List picker into a
  toolbar menu belongs to the **ui-design worktree session**. The caption is now merely redundant, not
  wrong, so no copy was deleted on integrator authority.
- **Note editing** and **Mac click-to-select** ship with the grouping wave, by your earlier decision.
- **Grouping plan** — written and Codex-reviewed twice (14 findings, all accepted, none refuted) at
  `design/grouping-implementation-plan.md`. Six phases, exclusive file ownership, and a model that
  makes grouping a reorder rather than a new invariant. It runs **after** this wave merges: its phases
  claim the same canvas files. Two flags: it is 3,588 words against a 3,000 cap (further cuts would
  have removed the reason behind each rule), and it deviates from the mock by showing a card count but
  no byte total on a group card, because a board number would disagree with the Brief's. Yours to
  overrule.

## 7. Commit plan

Nothing is committed. My suggestion:

1. In the worktree (which *is* the Conduck app repo), commit **one per lane** — card faces,
   preview/gallery, dragging, ordering correctness, docs — so a bisect finds a regression by feel
   rather than by file. One squash is fine if you prefer a single entry.
2. Merge `feature/work-board` into `main` inside `Conduck/`, push to `GigaDuckAI/conduck`.
3. In the monorepo, commit the submodule pointer bump.
4. Then the ui-design header session, then the grouping wave, in that order.
