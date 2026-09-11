# share-mac — plan §A share-picker removal, macOS appex. DONE. macOS signed BUILD SUCCEEDED + iOS BUILD SUCCEEDED.

Parallel phase. No commits/pushes/stash/checkout. `Identity-Override.xcconfig` untouched. Nothing under `docs/qa/desk-cloudkit/` touched. No test file touched. No mirror file touched. Slug `desk-share-mac` cleaned at the end.

Files I edited — exactly the three I own, nothing else:
- `Conduck/ConduckShareExtensionMac/ShareView.swift`
- `Conduck/ConduckShareExtensionMac/ShareViewController.swift`
- `Conduck/ConduckShareExtensionMac/Localizable.xcstrings`

`git status --short -- Conduck/ConduckShareExtensionMac/` shows those three and nothing more.

---

## 1. What changed (file + symbol)

### `ShareView.swift`

| Symbol | Change |
|---|---|
| `private enum WorkDestination` (`.new` / `.existing(UUID)`) | **DELETED** — the whole type. Only the picker read it. |
| `@State private var workSelection: WorkDestination` | **DELETED**. |
| `private var recentWorkItems: [ShareTargetsSnapshot.RecentWorkItem]` | **DELETED** — the appex no longer reads `snapshot.recentWorkItems`. The snapshot FIELD is untouched (mirror). |
| `private var selectedWorkItemID: UUID?` | **DELETED**. |
| `let onAddToWorkboard: (String, Bool, UUID?) -> Void` | → `(String, Bool) -> Void`. Doc comment rewritten to the one-desk constraint. |
| `addToWorkboard()` | `onAddToWorkboard(caption, includePageText, selectedWorkItemID)` → `onAddToWorkboard(caption, includePageText)`. |
| `private var workDestination: some View` | **REPLACED** by `private var workSummary: some View` (name mirrors iOS). No `ScrollView`, no `LazyVStack`, no `Section`, no `targetRow`/`sectionHeader` calls. Centered lockup: amber `rectangle.stack.badge.plus` glyph (`.accessibilityHidden(true)`) + `Strings.deskDetail` + the surviving `Strings.nothingSent` lock label. |
| body `Group { if disposition == .work { … } }` | mounts `workSummary`. |
| `Strings.sectionDestination` / `.sectionRecentWork` / `.newWork` / `.newWorkDetail` / `.untitledWork` | **DELETED** (the 5 picker keys). |
| `Strings.deskDetail` | **ADDED**, `share.work.desk.detail` (see §Catalog). |
| File header, `── Capture / send boundary ──` | rewritten: Add to Work is always targetless, Work has no destination; Send now keeps its picker, which is why the scroll region still exists. |

`targetRow`, `sectionHeader`, `badge(monogram:fill:)`, `monogram(for:)`, `Self.relativeFormatter`, `ShareTargetFilter`, `showSearch`, `isFallback`, `defaultSelection` all SURVIVE — Send mode still uses every one of them.

### `ShareViewController.swift`

| Symbol | Change |
|---|---|
| `viewDidLoad`, the `onAddToWorkboard:` closure literal | `{ note, includePageText, targetWorkItemID in … }` → `{ note, includePageText in self?.commitToWork(note:includePageText:) }`. |
| `commitToWork(note:includePageText:targetWorkItemID:)` | → `commitToWork(note:includePageText:)`. Doc comment rewritten. |
| `writeWorkCaptureEnvelope(id:note:providers:capture:includePageText:targetWorkItemID:)` | → `…(id:note:providers:capture:includePageText:)`. |
| `WorkCaptureEnvelope(...)` construction | `targetWorkItemID: targetWorkItemID` → `targetWorkItemID: nil`, with a constraint comment naming the one desk and saying the FIELD stays because the three copies are mirrored. |

Nothing else in the file moved. The validate-before-publish order, the `if !didPublish` / `try? fm.removeItem(at: tmp)` rollback, the atomic `try fm.moveItem(at: tmp, to: published)` and the macOS `file://` divergence are all untouched.

## 2. Decisions

1. **Removed the param rather than passing a dead `nil` through three frames.** The alternative — keep `commitToWork`/`writeWorkCaptureEnvelope` taking `targetWorkItemID: UUID?` and hand them `nil` — would have kept `WorkCaptureInboxTests.testShareWritersValidateAndRollbackBeforeAtomicPublication`'s `source.contains("targetWorkItemID: targetWorkItemID")` assertion green for free, but it leaves a parameter nothing can ever populate. The plan says "always a targetless envelope"; a plumbed-but-unfillable parameter is a lie in the signature. I took the clean cut and filed the test impact as a Request (§Requests 1). **share-ios independently made the identical cut** — verified below.
2. **The envelope FIELD stays, the mirrors stay untouched.** `git status --short -- '*WorkCaptureEnvelope.swift' '*ShareTargetsSnapshot.swift'` is EMPTY. `ShareTargetsSnapshot.RecentWorkItem` and `snapshot.recentWorkItems` still exist in all three snapshot copies; the mac appex simply stops reading the array. That is deliberate: it keeps `ShareTargetsSnapshotTests.testAppexMirrorIsByteIdenticalToCanonicalBelowHeader` green and leaves the writer decision entirely to share-contract.
3. **I mirrored share-ios's copy and layout verbatim, including a NEW string.** share-ios's side landed in the tree mid-wave. They removed the same five keys, cut the same closure to `(String, Bool)`, wrote `targetWorkItemID: nil`, named the replacement region `workSummary`, and ADDED `share.work.desk.detail` = `Everything you share is added to your Work desk.` I adopted all of it — same key, same `defaultValue:`, same `comment:`, same visual lockup (glyph 34pt `.light` amber → callout detail text → teal lock label, `Spacer(minLength: 0)` top and bottom). Reason: `testShareSurfacesUseDistinctWorkVocabularyAndAdaptivePrimaryActions` loops ONE expected-key list over BOTH `ShareView.swift` files and BOTH catalogs, so a key present on one side only is a guaranteed failure once share-contract updates the list. The two catalogs' `share.work.desk.detail` entries are byte-identical (verified by dict comparison, §5).
4. **macOS-specific deviation from the iOS layout, deliberate and small:** the mac pane carries an explicit `.padding(.vertical, 16)` and no `.scrollDismissesKeyboard` (iOS-only modifier, and there is no scroll region left anyway). The macOS panel is a FIXED `480×600` `preferredContentSize` set once in `viewDidLoad`; it cannot shrink when the disposition flips to `.work`, so the region MUST fill the space the Send picker occupies rather than leave a void. That constraint is stated at `workSummary`'s doc comment — it is the reason the region is a centered lockup and not a bare caption.
5. **`share.work.inert` ("Nothing is sent to AI") reused, not re-minted.** It is the only surviving Work-mode string besides the new one.
6. **`share.work.title` is iOS-only and stays iOS-only.** The mac appex has no navigation title; it never carried that key and still doesn't.

## 3. Deviations from my brief

- My brief said the 5 picker keys "leave THIS catalog" and said nothing about adding one. I ADDED `share.work.desk.detail`. Reason in §2.3: matching share-ios is what "mirror the iOS intent EXACTLY" means here, and the lockstep test makes divergence a hard failure. Net catalog change is identical to iOS: **12 insertions, 60 deletions**.
- No other deviation.

## 4. What the next agent must know

- **The mac appex can no longer produce a targeted Work envelope.** Any future "share into a specific Work item" feature has to re-add the parameter in both appexes together; the envelope field is still there waiting.
- **`snapshot.recentWorkItems` now has ZERO readers in the mac appex** (and, per their diff, zero in the iOS appex). Whatever share-contract decides for `ShareTargetsSnapshotWriter` — write an empty array vs. drop the field — no appex code will notice. Prefer the empty array; it keeps the three-way snapshot mirrors byte-identical.
- **`WorkCaptureInboxTests` has TWO tests that read my file, not one.** The known one (`testShareSurfacesUseDistinctWorkVocabularyAndAdaptivePrimaryActions`, the picker keys) and `testShareWritersValidateAndRollbackBeforeAtomicPublication`, whose `targetWorkItemID: targetWorkItemID` assertion I have broken on purpose in BOTH appexes. See §Requests 1.
- **`workSummary` is a plain non-scrolling stack.** The assertions `.frame(minHeight:`, `.accessibilityAddTraits(isSelected ? .isSelected : [])` and `.accessibilityAddTraits(.isHeader)` that the lockstep test greps are still present in the file — they live in `targetRow`/`sectionHeader`, which Send mode keeps. Those three assertions do NOT need to change.
- **Founder QA script item:** open the macOS Share panel from Finder (a PDF) and from Safari (a page). Work mode should show the amber stack glyph, "Everything you share is added to your Work desk.", the teal "Nothing is sent to AI" line, and the note field + **Add to Work** on the panel floor — no "Destination" / "Recent Work" list anywhere. Flipping to **Send now** must still show NEW CONVERSATION / RECENT CHATS with search once there are >8 targets. Safari's page-text toggle row must still appear above the divider in both modes.

## 5. Exactly what I ran, and the exact result lines

derivedData `~/Library/Caches/gigaduck-builds/desk-share-mac/DerivedData`, every log kept in that slug dir until the cleanup. No `-configuration` passed anywhere.

**macOS, signed through the identity override (no `CODE_SIGNING_ALLOWED=NO` needed):**
`xcodebuild -project …/Conduck.xcodeproj -scheme Conduck -destination 'platform=macOS' … build`
- `mac-build-1.log` (before the iOS mirroring pass) → `** BUILD SUCCEEDED **`
- `mac-build-2.log` (final) → `** BUILD SUCCEEDED **`, `grep -cE '\.swift:[0-9]+:[0-9]+: error:'` = **0**

  (A bare `grep -c 'error:'` returns 6 on that log; all six are source echoes such as `func urlSession(… didCompleteWithError error: Error?)`. The anchored compiler-diagnostic grep above is the real count.)

**ConduckShareExtensionMac built AND embedded AND signed** — from `mac-build-2` products:
```
…/Debug/Conduck.app/Contents/PlugIns/ConduckShareExtensionMac.appex
Identifier=ai.gigaduck.AgentRelay.ConduckShareExtensionMac
Authority=Apple Development: Peter Krueck (Z4PNDLZK98)
TeamIdentifier=J2ANN674AF
```

**iOS cross-check**, sim `5C851D88-959C-445E-ACC8-A4C6ADB2876C`:
- `ios-build-1.log` → `** BUILD SUCCEEDED **`
- `ios-build-2.log` (final) → `** BUILD SUCCEEDED **`, anchored `error:` count **0**

**Catalog gates:**
- `python3 json.load` on `ConduckShareExtensionMac/Localizable.xcstrings`: OK, **42 keys** (46 before → 41 after the 5 deletions → 42 after the 1 addition).
- `git diff --stat` on my catalog: **12 insertions, 60 deletions** — identical to iOS's.
- Source↔catalog sweep over `Conduck/ConduckShareExtensionMac/*.swift`: **41 source keys, 0 missing from the catalog, 0 catalog keys unused by source.**
- Cross-catalog compare iOS vs mac: iOS-only `share.title`, `share.work.title`; mac-only `share.error.tooManyItems` — all three PRE-EXISTING platform differences, none mine. Shared-key value drift is the pre-existing tap/click-style set (`share.cancel`, `share.capture.*`, `share.work.error.unavailable`). **`share.work.desk.detail` is NOT in the drift list — the two entries are byte-identical.**
- `git diff --check`: clean, exit 0.
- Mirror triplets: `git status --short -- '*WorkCaptureEnvelope.swift' '*ShareTargetsSnapshot.swift'` → **empty**. Untouched, as instructed.

**Editing method for the catalog:** line surgery, not `json.dump`. The file is Xcode-formatted (`"key" : {`, 2-space indent, alphabetical) and a re-dump would rewrite all ~500 lines and drop the space before every colon. Deletions removed each key's exact block and fixed the trailing comma when the last entry went; the addition copied the iOS entry's 12 lines verbatim into the alphabetical slot before `share.work.error.empty`. Re-validated with `python3 json.load` after every write.

**NOT run, and why:** no tests. My brief forbids test-file edits (share-contract owns them) and the two tests that cover this surface are string-assertion tests I have deliberately invalidated — running them now would report a failure that is share-contract's to resolve, not evidence of anything. I did not run the watch suite (no watch sim assigned, no watch code touched) or `check-storage-seam.sh` (no store access in an appex; nothing I changed can affect it).

**Not verified — stated plainly:** I have not seen the new macOS Work pane render. Share extensions cannot be exercised headlessly, so the visual balance of the centered lockup inside the fixed 480×600 panel is a build-verified layout, not an observed one. It is in the founder QA script above.

## Catalog

`Conduck/ConduckShareExtensionMac/Localizable.xcstrings` — I own it this wave and edited it directly (per my brief), so these are already applied, not requests.

**ADDED (1)** — key = `defaultValue`, copied from the `String(localized:defaultValue:)` in my source and byte-identical to the iOS appex's entry:

| Key | en value | Declared in |
|---|---|---|
| `share.work.desk.detail` | `Everything you share is added to your Work desk.` | `ConduckShareExtensionMac/ShareView.swift`, `Strings.deskDetail` |

**DELETED — the 5 picker keys (already removed from this catalog AND from source):**

| Key | en value it carried |
|---|---|
| `share.work.section.destination` | `Destination` |
| `share.work.section.recent` | `Recent Work` |
| `share.work.new` | `New Work` |
| `share.work.new.detail` | `Start a new draft` |
| `share.work.untitled` | `Untitled Work` |

**Found DEAD elsewhere: none.** The mac appex catalog has no orphans left (`catalog-only: []`). `share.summary.more` looks orphaned to a naive one-line grep because its `String(` / `localized:` pair is split across two source lines — it is LIVE at `ShareView.swift`'s summary builder. **Do not delete it.**

## Call-site touches

None. My minimal-touch rights this wave were `none`, and I used none — every edit is inside the three files I own.

## Requests

1. **share-contract (BLOCKING for the gate) — `Conduck/ConduckTests/WorkCaptureInboxTests.swift`, two tests, both now failing by design in BOTH appexes:**
   - `testShareWritersValidateAndRollbackBeforeAtomicPublication` (~`:285`) asserts `source.contains("targetWorkItemID: targetWorkItemID")` for both `ShareViewController.swift` files. Both now read `targetWorkItemID: nil`. The invariant worth keeping is the *inverse*: assert `source.contains("targetWorkItemID: nil")` so nobody quietly re-introduces a targeted share. Every other assertion in that test (validate-before-publish ordering, `if !didPublish`, `try? fm.removeItem(at: tmp)`) is still true — do not touch them.
   - `testShareSurfacesUseDistinctWorkVocabularyAndAdaptivePrimaryActions` (~`:311`): drop `share.work.new`, `share.work.new.detail`, `share.work.section.destination`, `share.work.section.recent`, `share.work.untitled` from `expectedWorkKeys` and **add `share.work.desk.detail`** — it is now in both `ShareView.swift` files and both catalogs. Keep `share.addToWork`, `share.addToWork.progress` and all six `share.work.error.*`. The `.frame(minHeight:` / `.accessibilityAddTraits(isSelected ? .isSelected : [])` / `.accessibilityAddTraits(.isHeader)` assertions still pass unchanged (Send mode keeps `targetRow`/`sectionHeader`) — leave them. Consider adding the negative guard `XCTAssertFalse(source.contains("share.work.section."))` in both files.
2. **share-contract — `ShareTargetsSnapshotWriter.swift`:** zero appex readers of `recentWorkItems` remain on either platform. Write an EMPTY array rather than removing the field, so the three `ShareTargetsSnapshot.swift` copies stay byte-identical and `ShareTargetsSnapshotTests.testAppexMirrorIsByteIdenticalToCanonicalBelowHeader` needs no edit. If you do drop the field, it is a three-file lockstep edit and both appexes must be re-verified.
3. **Strings/copy phase — do NOT re-audit the two extension catalogs for the picker keys.** They are already gone from `ConduckShareExtensionMac/Localizable.xcstrings` (me) and `ConduckShareExtension/Localizable.xcstrings` (share-ios). Deleting them again is a no-op at best. `share.work.desk.detail` is NEW and LIVE in both — never treat it as a dead candidate.
4. **Whoever writes the founder QA script** — fold in the macOS share-panel item from §4.
5. **Docs agent** — if any doc describes the share sheet offering a Work destination or a "Recent Work" list, that is now false on both platforms: the share is one press, always onto the single desk.
