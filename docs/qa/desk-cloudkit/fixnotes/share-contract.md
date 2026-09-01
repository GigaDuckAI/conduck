# share-contract — the share data contract after the picker died. DONE. iOS TEST BUILD SUCCEEDED; all 3 owned classes green (46 tests, 0 failures).

Parallel phase. No commits/pushes/stash/checkout. `Identity-Override.xcconfig` untouched. Nothing under `docs/qa/desk-cloudkit/` touched. No `.xcstrings` file opened. Slug `desk-share-contract` cleaned (`removed: desk-share-contract`).

Files I edited — three, all mine:
- `Conduck/Conduck/Services/ShareTargetsSnapshotWriter.swift`
- `Conduck/ConduckTests/ShareTargetsSnapshotWriterColorTests.swift`
- `Conduck/ConduckTests/WorkCaptureInboxTests.swift`

**Mirrors NOT touched.** `git status --short -- '*ShareTargetsSnapshot.swift' '*WorkCaptureEnvelope.swift'` is EMPTY.

---

## 1. THE DECISION (plan §A preference, taken)

**Keep the `recentWorkItems` field and the `RecentWorkItem` type in the contract; publish an empty array; do NOT touch the three mirrors.**

Why: plan §A states the preference outright, and both appex agents independently asked for it (share-ios §Requests 4, share-mac §Requests 2). Dropping the field would be a three-file byte-identical edit plus a re-verify of both appexes, for zero behavioural gain — the appexes already read nothing, so an empty array and an absent field are indistinguishable on device. Keeping it also keeps `ShareTargetsSnapshotTests.testAppexMirrorIsByteIdenticalToCanonicalBelowHeader` and the pinned-wire test meaningful without edits.

Verified after my edits (bodies from the first `import Foundation` onward, `awk` + `cmp`):
```
iOS mirror body identical
mac mirror body identical
```

## 2. What changed (file + symbol)

### `ShareTargetsSnapshotWriter.swift`

| Symbol | Change |
|---|---|
| `nonisolated static let maximumRecentWorkItems = 8` | **DELETED** (with its doc comment) |
| `nonisolated static func makeRecentWorkItems(_:limit:)` | **DELETED** whole — the recent-Work projection. Its only caller was the store read purge-core already deleted (`fetchRecentWorkItemSummaries`); its only remaining references were the two tests below |
| `buildSnapshot()` | unchanged code. `let recentWorkItems: [ShareTargetsSnapshot.RecentWorkItem] = []` (purge-core's line) and its one-desk comment KEPT verbatim — it is what my new drift guard greps for |
| `buildSnapshot()` doc bullet | `recentWorkItems` bullet rewritten: always empty, the store is never read for it |
| file header | added a `WORK TARGETS: none.` paragraph (one desk → no destination → empty array; the field stays because the three copies must stay byte-identical); the opening line now says "Send to" picker, since that is the only picker the snapshot still fills |

`filterRecents`, `hexString`, `clampChannel`, the atomic write, the coalescing loop and the watchOS no-op are all untouched.

`WorkItemSummary` (`Conduck/Conduck/Models/WorkboardRecords.swift:123`) is now referenced by **nothing** — declaration only. Not my file → §Requests 1.

### `ShareTargetsSnapshotWriterColorTests.swift` (8 → 7 cases)

| Case | Change |
|---|---|
| `testRecentWorkProjectionSortsByModifiedDateAndBoundsPayload` | **DELETED** (scout-purge §6, `:77`) — it exercised `makeRecentWorkItems` |
| `testRecentWorkProjectionWithNonPositiveLimitIsEmpty` | **DELETED** (scout-purge §6, `:92`) |
| `private func workItem(title:modifiedAt:) -> WorkItemSummary` | **DELETED** — helper for the two above |
| `testTheWriterPublishesNoWorkTargets` | **NEW** — reads `Conduck/Services/ShareTargetsSnapshotWriter.swift` off disk (anchored on `#filePath`, the idiom this file's sibling tests already use) and asserts (a) the writer contains `let recentWorkItems: [ShareTargetsSnapshot.RecentWorkItem] = []`, (b) it contains no `makeRecentWorkItems` |
| file header | broadened: the file covers the writer's pure seams — hex helper, dead-gateway recents filter, and the one-desk no-Work-targets rule |

The 4 color cases and the 2 `#if os(iOS)` filter cases are untouched.

**Why a source guard and not a behavioural one:** `buildSnapshot()` is `private` and actor-isolated, and `regenerate()` writes into the real App-Group container. There is no seam that returns the built snapshot to a test. The invariant that matters is "the writer never asks the board for targets", which is a source fact — so I guarded it as one, honestly, rather than inventing a seam this wave.

### `WorkCaptureInboxTests.swift` (30 cases, unchanged count)

| Case | Change |
|---|---|
| `testShareWritersValidateAndRollbackBeforeAtomicPublication` (`:286`) | the final assertion **FLIPPED**: `source.contains("targetWorkItemID: targetWorkItemID")` → `source.contains("targetWorkItemID: nil")`, message rewritten to "must publish a targetless envelope — Work is one desk, so an appex can never name a destination". This is share-ios §Requests 2(b) and share-mac §Requests 1, both filed as BLOCKING. The other three assertions in that loop (validate-before-publish ordering, `if !didPublish`, `try? fm.removeItem(at: tmp)`) are untouched |
| `testShareSurfacesUseDistinctWorkVocabularyAndAdaptivePrimaryActions` (`:311`) | `expectedWorkKeys`: the 5 picker keys removed, `share.work.desk.detail` added (13 → 9 entries). NEW `retiredWorkKeys` array with the 5 removed keys, asserted **absent** from both `ShareView.swift` files AND both extension catalogs — a positive guard rather than a silent deletion, as share-mac asked. NEW `XCTAssertFalse(source.contains("snapshot.recentWorkItems"))` per appex. The `defaultValue: "Add to Work"` / `"Adding to Work…"` / not-`"Add to Workboard"`, `.frame(minHeight:`, `.accessibilityAddTraits(isSelected ? .isSelected : [])`, `.accessibilityAddTraits(.isHeader)` and the two `share.addToWorkboard`/`share.workboard.` negatives are all untouched and all still pass |

Pre-flight grep confirmed each surviving assertion before I ran anything: `.isHeader` at iOS `:678` / mac `:719`, `isSelected` at `:725` / `:766`, `.frame(minHeight:` at `:807` / `:856`, `share.work.desk.detail` declared at `:924` / `:969`, `snapshot.recentWorkItems` count 0 in both, retired keys count 0 in both catalogs.

## 3. Deviations from scout-purge §6, with why

scout §6 predicted **−5** cases "if the share-sheet Work-destination picker also goes": `WorkCaptureInboxTests:173`, `WorkboardPersistenceTests:126`, `ShareTargetsSnapshotWriterColorTests:77,92`, `ShareTargetsSnapshotTests:130`. I delivered **−2 net in my files** (−2 deleted, +1 added). The three I did not take:

1. **`ShareTargetsSnapshotTests:130` `testTolerantRecentWorkDecodeDefaultsRenderFields` — KEPT.** The scout's row assumed `RecentWorkItem` leaves the contract. Plan §A says keep the field, and I did; the type is still encoded, still decoded, still mirrored three ways. A tolerant-decode guard on a type that is still on the wire is live coverage, not residue — deleting it would be a real loss with no offsetting truth. **`ShareTargetsSnapshotTests.swift` is therefore unmodified** (`git status` confirms), and its populated-`recentWorkItems` cases (`:56`, `:185`, `:240`) stay: they test the CONTRACT's ability to carry a Work target, which is exactly what the mirror rule preserves, not a claim that the writer ever publishes one. That claim now has its own guard (§2, `testTheWriterPublishesNoWorkTargets`).
2. **`WorkCaptureInboxTests:173` `testOlderEnvelopeWithoutWorkDestinationDecodesAsNewWork` — KEPT, untouched.** Same reason: `WorkCaptureEnvelope.targetWorkItemID` survives by the mirror rule, and the test asserts a legacy envelope decodes with `targetWorkItemID == nil` — which is now not merely tolerated but the *only* shape any appex writes. Its NAME ("…AsNewWork") is mildly stale vocabulary; renaming it is envelope/drainer territory, not mine, so I left it. Flagged in §Requests 3.
3. **`WorkboardPersistenceTests:126` — not mine, and already resolved.** `fetchRecentWorkItemSummaries` has **zero** occurrences left in any `.swift` file (only a stale doc-comment mention, which I removed with the test that carried it). Whoever did the test-compile pass already took it.

No assertion anywhere was weakened, skipped or deleted to get green.

## 4. Exactly what I ran, and the exact result lines

derivedData `~/Library/Caches/gigaduck-builds/desk-share-contract/DerivedData`, logs in that slug dir, no `-configuration` passed.

**iOS `build-for-testing`**, sim `5C851D88-959C-445E-ACC8-A4C6ADB2876C`, `ios-bft-1.log`:
- `grep -c ': error: '` → **0**
- `** TEST BUILD SUCCEEDED **` (line 27383)

**Targeted tests**, `test-without-building`, same sim, `ios-test-1.log` → `** TEST EXECUTE SUCCEEDED **`:
```
Test Suite 'ShareTargetsSnapshotTests' passed
	 Executed 9 tests, with 0 failures (0 unexpected) in 0.014 (0.018) seconds
Test Suite 'ShareTargetsSnapshotWriterColorTests' passed
	 Executed 7 tests, with 0 failures (0 unexpected) in 0.007 (0.008) seconds
Test Suite 'WorkCaptureInboxTests' passed
	 Executed 30 tests, with 0 failures (0 unexpected) in 0.167 (0.174) seconds
	 Executed 46 tests, with 0 failures (0 unexpected) in 0.188 (0.201) seconds
```
No simulator flake, no retry needed.

**Mirror cmp** (bodies from `import Foundation` onward): `iOS mirror body identical`, `mac mirror body identical`. `git status --short -- '*ShareTargetsSnapshot.swift' '*WorkCaptureEnvelope.swift'` → empty.

**`git diff --check`** → clean, exit 0.

**Counts.** `ShareTargetsSnapshotWriterColorTests` 8 → **7** (−2 deleted, +1 added). Every other class unchanged. **Net iOS suite delta from me: −1 executed test.** Against integrate-a's measured baseline of 4723, the suite should now read **4722** — but note that share-ios/share-mac landed AFTER integrate-a's full run, so 4723 was measured on a tree whose `WorkCaptureInboxTests` assertions were about to go red; my two flips are what make it green again, at 30 cases either way.

**NOT run, plainly:** the full iOS suite (my brief scopes me to the owned classes; nothing I touched can reach another class — the two deleted tests' only shared symbol was `WorkItemSummary`, and the writer symbols I deleted had no other reference in the repo, verified by a repo-wide grep). macOS build: not run — I changed no macOS-only code and no appex source; the writer compiles identically on both platforms and the last macOS gate (share-mac) is newer than my edits in every file except mine. Watch suite: not run, no watch sim assigned, no watch code touched. `check-storage-seam.sh`: not run — I added no store access (`ShareTargetsSnapshotWriter` is already on the allowlisted seam and I removed a read rather than adding one).

## 5. What the next agent must know

- **The snapshot's `recentWorkItems` is now empty BY CONSTRUCTION and guarded.** `ShareTargetsSnapshotWriterColorTests.testTheWriterPublishesNoWorkTargets` fails if anyone re-adds a projection or changes that literal line. If a future feature genuinely needs Work targets again, that test is the deliberate speed bump — update it consciously.
- **The 5 picker keys are now guarded ABSENT**, not merely unlisted. `retiredWorkKeys` in `WorkCaptureInboxTests` asserts they are gone from both `ShareView.swift` files and both extension catalogs. The strings phase must not "restore" them, and must never treat `share.work.desk.detail` as a dead candidate — it is now a *required* key in both extension catalogs.
- **Both appexes are now asserted incapable of naming a Work destination** (`targetWorkItemID: nil` positive guard). The drainer's desk-resolve path is the only path a share capture can take, and a test says so.
- **The three `ShareTargetsSnapshot.swift` copies and the three `WorkCaptureEnvelope.swift` copies are untouched by this whole wave** (share-ios, share-mac, me). Any future edit to either is still a byte-identical triplet edit.

## Catalog

**Keys I ADDED in source: NONE.** I opened no `.xcstrings` file and declared no new `String(localized:)`.

**Keys I found DEAD: NONE new.** The 5 retired picker keys were already deleted from source AND from both extension catalogs by share-ios / share-mac in this same wave; my change only makes their absence enforced. `share.work.desk.detail` is LIVE in both appex sources and both catalogs — do not delete it.

## Call-site touches

None. My minimal-touch rights this wave were `none`, and I used none — every edit is inside the three files I own.

## Requests

1. **Whoever next opens `Conduck/Conduck/Models/WorkboardRecords.swift` (store/records cleanup):** `WorkItemSummary` (`:123`) now has **zero** references repo-wide — declaration only. Its own doc comment describes a job that no longer exists ("the cross-process share-targets snapshot … must never pay for the whole board to publish a handful of picker rows"). Delete the struct and its comment; nothing else in the repo will notice (verified by `grep -rn --include='*.swift' WorkItemSummary .` → one hit, the declaration).
2. **Docs agent:** if `spec.md` or any header describes the share sheet publishing a bounded list of recent Work items, or the snapshot carrying Work targets, that is false on both platforms. The truth: the snapshot fills only the **Send to** gateway/recent-chat picker; `recentWorkItems` is published empty and the field survives solely because the three source copies must stay byte-identical.
3. **Envelope/drainer owner (low priority, vocabulary only):** `WorkCaptureInboxTests.testOlderEnvelopeWithoutWorkDestinationDecodesAsNewWork` (`:173`) is correct and green, but its name says "…AsNewWork" — a phrase from the dead picker. If someone is already in that file's envelope section, "…DecodesWithNoDestination" would be truer. I did not rename it: it is not in my ownership and the assertion is sound as-is.
4. **Orchestrator — baseline arithmetic.** My net delta is **−1 executed iOS test**. scout §6's "−5 if the picker goes" is superseded for the three rows in §3 above; the two I kept guard contract surfaces plan §A deliberately preserved.
