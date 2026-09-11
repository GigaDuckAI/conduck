# share-ios — plan §A share-picker removal, iOS appex. DONE. iOS build green.

Slug `desk-share-ios`, cleaned (`removed: desk-share-ios`). No commits/pushes/stash/checkout. `Identity-Override.xcconfig` untouched. Nothing under `docs/qa/desk-cloudkit/` touched. Only the three files I own are modified — `git status --short -- Conduck/ConduckShareExtension/` is exactly:

```
 M Conduck/ConduckShareExtension/Localizable.xcstrings
 M Conduck/ConduckShareExtension/ShareView.swift
 M Conduck/ConduckShareExtension/ShareViewController.swift
```

**Mirrors untouched.** `ConduckShareExtension/WorkCaptureEnvelope.swift` and `ShareTargetsSnapshot.swift` are NOT modified — the `targetWorkItemID` field and the `RecentWorkItem` type both stay in the contract exactly as they were. `ShareTargetsSnapshotWriter`, the snapshot mirrors and every test file: untouched.

---

## 1. What changed (file + symbol)

### `Conduck/ConduckShareExtension/ShareView.swift`

| Symbol | Change |
|---|---|
| `private enum WorkDestination` (`.new` / `.existing(UUID)`) | **DELETED** |
| `@State private var workSelection: WorkDestination` | **DELETED** |
| `private var recentWorkItems: [ShareTargetsSnapshot.RecentWorkItem]` | **DELETED** (the snapshot field itself survives; nothing in this appex reads it now) |
| `private var selectedWorkItemID: UUID?` | **DELETED** |
| `private var workDestination: some View` (scroll list: "Destination" section + "Recent Work" section + lock footer) | **REPLACED** by `private var workSummary: some View` |
| `let onAddToWorkboard: (String, Bool, UUID?) -> Void` | now `(String, Bool) -> Void`; doc comment rewritten to "on the one desk … names no destination" |
| `addToWorkboard()` | `onAddToWorkboard(caption, includePageText)` — the third argument is gone |
| `body` | `if disposition == .work { workSummary }` (was `workDestination`); nothing else in `body` changed |
| file header, "Capture / send boundary" block | states the new constraint: Work has ONE desk, so that mode offers no destination and stays a single tap; the Send-now paragraph is unchanged |
| `Strings.{sectionDestination, sectionRecentWork, newWork, newWorkDetail, untitledWork}` | **DELETED** (the 5 picker keys) |
| `Strings.deskDetail` | **NEW** — `share.work.desk.detail` |

### `Conduck/ConduckShareExtension/ShareViewController.swift`

| Symbol | Change |
|---|---|
| `viewDidLoad`'s `onAddToWorkboard:` closure | two parameters; forwards `commitToWork(note:includePageText:)` |
| `commitToWork(note:includePageText:targetWorkItemID:)` | → `commitToWork(note:includePageText:)`; doc comment now says it names no destination and the drainer resolves the one desk |
| `writeWorkCaptureEnvelope(id:note:providers:capture:includePageText:targetWorkItemID:)` | → same minus `targetWorkItemID:` |
| envelope construction (`:775`) | `targetWorkItemID: nil` with a two-line constraint comment ("Targetless by contract: Work is one desk, so the drainer resolves the destination. The envelope keeps the field for the mirrored contract.") |

`loadShareTargetsSnapshot()` is untouched and still runs — the snapshot still feeds the **Send now** gateway/recent-chat picker.

### `Conduck/ConduckShareExtension/Localizable.xcstrings`
5 keys removed, 1 added, 47 → **43** keys. Nothing else in the file differs (verified key-by-key against the pre-edit parse).

---

## 2. What the share UI shows now

Layout is unchanged above and below the middle region; only the middle region in **Work** mode changed.

- Nav bar: `Cancel` + title `Add to Work` (Work mode) / `Send to` (Send mode) — unchanged.
- Pinned: shared-item header → the Work/Send-now segmented picker → the Safari page-text toggle row (Safari shares only) → divider. All unchanged.
- **Work mode middle region (`workSummary`)**: no list, nothing scrolls. Centered `rectangle.stack.badge.plus` glyph (amber, `accessibilityHidden`), one line of copy — "Everything you share is added to your Work desk." — and the existing teal `lock.fill` "Nothing is sent to AI" label under it. Vertically centered between two `Spacer`s.
- **Send mode middle region**: the gateway / recent-chats picker, the conditional search field, the fallback row and the empty-search state — **all completely unchanged**.
- Bottom composer: caption field + one primary amber button, `Add to Work` / `Adding to Work…` in Work mode, `Send now` / `Sending…` in Send mode, ⌘-Return unchanged. **"Add to Work" is now literally one tap** — pick the mode (it is the default), tap the button.
- The failure alert (`WorkboardCommitFailure`, retryable vs deterministic) is unchanged, so `ErrorSurfaceDriftGuardTests`'s `ConduckShareExtension/ShareView.swift` `.notErrorDriven` row stays accurate.

---

## 3. Decisions + deviations (with why)

1. **Kept the Work/Send-now disposition picker.** The task removes the *Work destination* picker, not the mode switch; the Send-to-Chat path had to stay untouched, and it is reached only through that segment.
2. **Work mode still renders something, not nothing.** Deleting the list outright would leave a blank slab between the pinned header and the composer. One glyph + one line + the existing inert-privacy label keeps the mode legible and keeps `share.work.inert` (the strongest privacy claim in this appex) on screen, where it already lived.
3. **Deleted the `targetWorkItemID` parameter chain rather than threading a permanent `nil`.** The plan keeps the envelope FIELD (mirror rule, honoured), but a parameter that is always nil through three functions is dead weight and would read as if a destination could still arrive. The constraint is now stated once, at the envelope construction site. **This deliberately breaks one source-grep assertion — see §5.**
4. **Catalog edited by line-exact raw-text surgery in Python, not `json.dump`.** Deviation from the brief's literal "python json load → modify → dump": this file is Xcode-formatted (`"key" : {`, 2-space indent, space before the colon) and `json.dump` cannot reproduce that, so a re-dump would rewrite all 560 lines and diverge from the untouched macOS twin. Same precedent integrate-a set for the main catalog. The script parsed the file with `json.load` first, deleted the five key blocks by their exact line ranges, inserted the new block at its alphabetical position (`share.work.desk.detail` sorts before `share.work.error.empty`), re-fixed the last block's trailing comma (`share.work.untitled` was the file's final key), then re-parsed and asserted: exactly those 5 keys gone, exactly 1 added, **every other key's value byte-identical**, key order still sorted, `version`/`sourceLanguage` unchanged, no trailing newline added. `git diff --stat` on the catalog: 72 lines (60 deleted, 12 inserted).
5. **No Codex consult** — nothing here was a hard call.

---

## 4. Verification — exactly what I ran

- **iOS build**, sim `6C3FB33E-D89F-4D1E-9F0D-3FAC0C089228`, no `-configuration`, derivedData `~/Library/Caches/gigaduck-builds/desk-share-ios/DerivedData`, log `ios-build-1.log`:
  - `grep -c ': error: '` → **`0`**
  - `grep -nE '\*\* BUILD SUCCEEDED \*\*|\*\* BUILD FAILED \*\*'` → **`24869:** BUILD SUCCEEDED **`**
  - appex present: `DerivedData/Build/Products/*/Conduck.app/PlugIns/ConduckShareExtension.appex`
  - `grep -n 'ConduckShareExtension/Share.*warning:'` → no hits (no new warnings in my files)
- **Removed-key grep** over my catalog and `ShareView.swift` for `share.work.new|share.work.section.destination|share.work.section.recent|share.work.untitled` → **`0`** in both files (`grep -c`).
- **`python3 json.load`** on `ConduckShareExtension/Localizable.xcstrings` → OK, **43 keys**; `share.work.desk.detail` value reads back as `Everything you share is added to your Work desk.`
- `git diff --check` → clean, exit 0.
- **Tests: NOT RUN.** My brief scopes me to the iOS build; I own no test file and the two impacted assertions below are the share-contract agent's next wave. I did not weaken, skip or delete any assertion anywhere.
- The slug dir (and its log) was removed by `clean-build-cache.sh desk-share-ios` — re-run the build if you need the log.

---

## 5. Expected test impact (I edited NO test file)

Both live in `Conduck/ConduckTests/WorkCaptureInboxTests.swift`. The **macOS** halves of each still pass until the mac agent lands the twin change; only the `ConduckShareExtension/…` paths fail.

1. **`testShareSurfacesUseDistinctWorkVocabularyAndAdaptivePrimaryActions`** (`:311`). Its `expectedWorkKeys` array contains all five keys I removed — `share.work.new`, `share.work.new.detail`, `share.work.section.destination`, `share.work.section.recent`, `share.work.untitled` — and it asserts each one in **both** `ConduckShareExtension/ShareView.swift` **and** `ConduckShareExtension/Localizable.xcstrings`. **10 assertion failures expected on the iOS paths** (5 keys × 2 files). Fix: drop those five rows from `expectedWorkKeys`, and add `share.work.desk.detail` if you want the new key guarded the same way.
   Everything else in that test still holds, verified by grep in the post-edit file: `defaultValue: "Add to Work"` ✓, `defaultValue: "Adding to Work…"` ✓, no `"Add to Workboard"` ✓, `.frame(minHeight:` ✓ (bottom composer), `.accessibilityAddTraits(isSelected ? .isSelected : [])` ✓ and `.accessibilityAddTraits(.isHeader)` ✓ (both survive in `targetRow` / `sectionHeader`, which the Send picker still uses), no `share.addToWorkboard` / `share.workboard.` ✓.
2. **`testShareWritersValidateAndRollbackBeforeAtomicPublication`** (`:286`). Its final assertion is
   `XCTAssertTrue(source.contains("targetWorkItemID: targetWorkItemID"), "\(relativePath) must carry the optional inert Work destination into the envelope")`
   — my file now reads `targetWorkItemID: nil`. **1 assertion failure expected** on `ConduckShareExtension/ShareViewController.swift`. That assertion's *intent* is the behaviour this task removes, so it should become the opposite guard: assert `targetWorkItemID: nil` (i.e. the appex can never name a destination). The other three assertions in that loop — validate-before-publish ordering, `if !didPublish`, `try? fm.removeItem(at: tmp)` — are untouched and still pass.

No other test references the iOS `ShareView`/`ShareViewController` sources. `ErrorSurfaceDriftGuardTests:433` (`ConduckShareExtension/ShareView.swift` → `.notErrorDriven`) still describes the file correctly — the retry alert is unchanged. `ShareTargetsSnapshotTests`'s `recentWorkItems` cases are about the snapshot wire format, which I did not touch.

---

## Catalog

Sole owner of `Conduck/ConduckShareExtension/Localizable.xcstrings` this wave; edits are already **applied** there (not deferred).

**ADDED (1)** — key = defaultValue, copied from the source declaration:

| Key | en value |
|---|---|
| `share.work.desk.detail` | `Everything you share is added to your Work desk.` |

comment: `Explains where a Work capture lands, in place of a destination picker`

**REMOVED / DEAD (5)** — deleted from source AND from this catalog in the same edit:

| Key | former en value |
|---|---|
| `share.work.new` | `New Work` |
| `share.work.new.detail` | `Start a new draft` |
| `share.work.section.destination` | `Destination` |
| `share.work.section.recent` | `Recent Work` |
| `share.work.untitled` | `Untitled Work` |

**Untouched in this catalog:** `share.work.title`, `share.work.inert`, all six `share.work.error.*`, and every `share.*` Send-mode key. **No other `.xcstrings` file was opened** — the macOS twin still carries all five picker keys, by design.

---

## Requests

1. **macOS share agent — the twin is still on the old shape.** `ConduckShareExtensionMac/{ShareView.swift, ShareViewController.swift, Localizable.xcstrings}` still carry the Work destination picker and the five keys. Until it lands, `testShareSurfacesUseDistinctWorkVocabularyAndAdaptivePrimaryActions` passes on the mac paths and fails on mine, which is expected, not drift. Mirror my shape if you want the two appexes to stay legible as twins: delete `WorkDestination` / `workSelection` / `recentWorkItems` / `selectedWorkItemID`, replace the destination list with the same glyph + one-line + inert-lock summary, narrow `onAddToWorkboard` to `(String, Bool)`, drop the `targetWorkItemID` parameter chain, and construct the envelope with `targetWorkItemID: nil`. **You own your catalog** — the key to add there is `share.work.desk.detail` with the identical value above (the two appex catalogs currently differ by 1 key: 47 mac vs 43 iOS).
2. **Share-contract / test agent (next wave) — two assertion sets, spelled out in §5.** (a) remove the five picker keys from `WorkCaptureInboxTests.expectedWorkKeys` (`:314`); (b) flip `testShareWritersValidateAndRollbackBeforeAtomicPublication`'s `targetWorkItemID: targetWorkItemID` assertion (`:305`) to guard `targetWorkItemID: nil` instead — the appex must now be *incapable* of naming a destination, which is worth a positive guard rather than a deletion. Do (a)/(b) for the mac path only once the mac twin has landed, or the mac half goes red early.
3. **Drainer / desk agent — nothing is owed to me, one fact for the record.** Every iOS share capture now arrives with `targetWorkItemID == nil`, so the drainer's desk-resolve path is the ONLY path a share capture can take; the `.done`-target and target-unavailable branches can never be reached from this appex again.
4. **Snapshot-writer agent — `recentWorkItems` now has zero readers in the iOS appex.** purge-core already publishes it empty. Once the mac twin drops its picker too, the field is dead end-to-end at the app level; the wire field must still stay in the three `ShareTargetsSnapshot.swift` mirrors (byte-identity rule) and `ShareTargetsSnapshotTests` still guards it, so this is a note, not a deletion request. `makeRecentWorkItems` / `maximumRecentWorkItems` / `WorkItemSummary` remain callerless (purge-core §Requests 4).

## Call-site touches

None. I edited only the three files I own; I needed no compatibility edit in any file belonging to another agent.
