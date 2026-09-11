# fix-r1-watch-work-destination — Codex findings on the Watch Work destination

Source: `docs/qa/work-usability/verify/codex-r1-watch-work-destination.md` (3 findings).
Design: `docs/qa/work-usability/design/watch-work-destination.md`.

| ID | Verdict |
|---|---|
| W-R1-1 (P2) | **FIXED** — `WatchGatewayLabel` in `WatchNoteView.swift`, used by the chooser rows and the capture overlay's destination caption |
| W-R1-2 (P2) | **FIXED** — the four doc sites the design lists, plus the chooser's founder-QA cases (`handoff.md` 66a–66m) |
| W-R1-3 (P2) | **PARTLY FIXED** — two new fixtures establish a real conversation pin before the Work start; the reachable-in-production `.idle`-with-pin state has no public seam and is named as such |

Files touched: `Conduck/ConduckWatch Watch App/Views/WatchNoteView.swift`,
`Conduck/ConduckWatch Watch App/Views/WatchConversationThreadView.swift`,
`Conduck/ConduckWatchTests/ConduckWatchSmokeTests.swift`,
`Conduck/ConduckWatchTests/WatchCaptureGuardTests.swift`,
`Conduck/ConduckTests/ErrorSurfaceDriftGuardTests.swift` (one exemption entry, below),
`docs/qa/work-usability/handoff.md`, `docs/qa/work-usability/fixnotes/c3-watch-ui.md`,
`README.md`, `docs/ai-context/project-structure.md`. **No catalog rows.**

---

## W-R1-1 — two gateways, one label · **FIXED**

`RemoteAgentRefMetadata.shortDisplayName` is a head cut at 16 characters, so two customs
whose names agree over their first fifteen ("Frankfurt production alpha" / "…beta") render
one identical row, and the chooser stops being a choice. The recording caption
(`threadBackendName`) carried the same string, so the mis-tap cue decision 7 exists for named
a destination the person could not check either.

**Fix:** `WatchGatewayLabel` — the wrist's own label policy, beside `WatchAskDestinationRows`
in the view that owns it. `visible(for:customs:)` returns the shared short form unless
another gateway in the roster shortens to the same string, in which case the name is shown
from where it diverges, behind a leading ellipsis ("…alpha" / "…beta"): names collide this
way only when their heads match, so the head is the half that carries no information for the
decision. `spoken(for:customs:)` is the untruncated name, attached as the accessibility label
on both the chooser rows and the caption. **The shared shortening policy is untouched** —
every other surface, and the error-sentence budget it was derived from, keep it exactly.

`ErrorSurfaceDriftGuardTests.testNarrowAndSpokenSurfacesUseTheShortNameForm` fails on a full
name rendered by a narrow surface and names its own escape for text with no width. One
`fullNameExemptions` entry was added for `spoken`, the second on that list beside
`WatchGatewayBadge.resolved`, which was exempted for the same reason.

Pinned by `WatchGatewayLabelTests` (5 cases, `ConduckWatchSmokeTests.swift`), including the
control that the shared shortener genuinely collapses the fixture's two names. **Mutation-run
measured:** with the divergence branch short-circuited to the shared form, the colliding-pair
and three-name cases fail (`Executed 5 tests, with 4 failures`); restored, `284 tests, 0
failures`.

## W-R1-2 — the docs still describe two buttons · **FIXED**

Applied the design's Docs list: `handoff.md` decision 1, the Watch paragraph, U-17 reworded
and U-18 closed, QA steps 52–56, 59, 61, 62, 65 and the two cross-surface steps (80, 81)
rewritten around Ask → **Where to?** → **Add to Work**; `c3-watch-ui.md`'s first "Nobody
undo" bullet marked superseded (the surviving rule is *no sticky destination*, not *two
buttons*); `README.md`'s wrist clause; `project-structure.md`'s Views row.

The negative controls the design assigns to founder QA are steps **66a–66m**, added as
lettered steps so the CarPlay/Share/Capture sections keep their numbers: chooser cancellation
with 0/1/N rosters (no capture, no push, no hint), the single-gateway sheet, the empty-roster
sheet, the destination caption's legibility, two gateways named alike under VoiceOver, the
maximum roster at 41 mm and largest text, 41 mm recorder clearance through "1 min left",
switch-off / Action Button / unavailable-default refusal / notification tap / busy under an
open sheet, and the "Saving to Work…" launchpad caption. They are marked unrun, and no agent
may run them.

Codex also notes the row-builder tests would pass if the one-gateway bypass returned. That is
design decision 14 — the wiring is two lines of view code, pinned by founder QA (step 66b)
rather than by a source-text guard, which round 1 of the design review rejected as brittle.

## W-R1-3 — the pin half of the transition test was a tautology · **PARTLY FIXED**

Real: `testAWorkPickAfterAnAbandonedGatewayDraftInheritsNothing` starts from an idle machine,
where `inFlightConversationID` is already nil, so its pin assertions could not fail. That
case now says what it owns (the stale hint, and that a Work start mints nothing), and two new
cases establish a genuine pin first and assert the precondition:

- `testAWorkPickAfterADeniedBoundCaptureInheritsNoConversationPin` — `startCapture(boundTo:
  .existing(id))` with the microphone refused leaves `.error` holding that conversation;
  asserted before the Work start.
- `testAWorkPickAfterAMintedDraftInheritsNoConversationPin` — the Ask-hint arm mints and pins
  a conversation, then the hop stops at the config gate; the Work start must leave that
  conversation exactly where it is (`captureMintCount` unchanged, one row, same id).

**Named limit, not a claim:** both paths enter Work from `.error`, where `startWorkCapture`
runs `dismissError()` first — so the clear these cases exercise is `dismissError`'s, and
`startWorkCapture`'s own pin clears are a backstop that only an `.idle` machine still holding
a pin can exercise. That state is reachable in production (`handleBackgroundReply` clears the
in-flight marker by conversation match, so an older turn's reply landing against a newer
turn's marker returns to `.idle` with the pin intact) but no public seam on the service can
arrange it: every other route back to `.idle` clears the pins on the way, and the properties
are `private`. The tests say so where they stand.

## Measured

| Run | Result |
|---|---|
| `xcodebuild test -scheme ConduckWatchTests` (watchOS sim `28AC563B…`) | **Executed 284 tests, 0 failures**, exit 0, `grep -c ': error: '` = 0, no warning in any file this round touched |
| `xcodebuild test -scheme Conduck -only-testing:ConduckTests/ErrorSurfaceDriftGuardTests -only-testing:ConduckTests/WorkboardCopyTruthGuardTests` (iOS sim `04DEF…`) | **17 tests, 0 failures**, exit 0 |
| `scripts/check-folder-map.sh` · `scripts/check-spec-cites.sh` · `scripts/add-spdx-headers.sh --check` · `git diff --check` | exit 0 each |

No `-configuration` flag; caches under `~/Library/Caches/gigaduck-builds/watch-fix{,-ios}`,
both cleaned with `clean-build-cache.sh`.

## Nobody undo

- **`WatchGatewayLabel` is the wrist's label site, and it is LOCAL.** Do not push the
  divergence rule down into `RemoteAgentRefMetadata`: the shared budget exists for the
  in-thread error banner and CarPlay's spoken copy, where a leading ellipsis buys nothing and
  the sentence frame owns the width.
- **The accessibility labels carry the full name on purpose.** They are the reason the
  `fullNameExemptions` entry exists; deleting either without the other leaves a blind user
  choosing between two rows that sound identical, or a red drift guard.
- **`threadBackendName` names the thread bar, the thinking line AND the capture caption.**
  One string for one gateway on one device — a second naming path would let the caption and
  the title disagree for exactly the names this round made distinguishable.
- **The precondition assertions in the two pin cases are the point.** A fixture that stops
  establishing a real pin must fail loudly rather than silently returning the tests to the
  tautology this round removed.
