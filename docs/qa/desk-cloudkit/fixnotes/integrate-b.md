# integrate-b — part 2a close-out. PASS. iOS 4758 / 1 skip / 0 failures · watch 231 / 0 · both builds green.

Serial phase, alone in the tree. No commits/pushes/stash/checkout. `Identity-Override.xcconfig` untouched. Nothing under `docs/qa/desk-cloudkit/` touched. Slug `desk-integrate-b` cleaned at the end.

**Headline: part 2a had already landed compatibly and green — test-surgery left the suite at 4758/0. Nothing was broken across slices, so there was no breakage to fix.** My work was the two `## Requests` nobody in a parallel wave could take, the catalog verification, and the gate: full iOS suite, the WATCH suite (unrun by every agent since desk-intents added its two cases), and the signed macOS build (unrun since before the byte-sync and availability slices).

---

## 1. Catalog — nothing to apply to the main catalog, verified rather than assumed

**Every 2a agent's `## Catalog` says "keys I ADDED in source: NONE"** — availability, blob-io, share-contract, store-descriptions and test-surgery all declared zero. The only two ADDED keys in the wave were `share.work.desk.detail` in each appex catalog, and share-ios / share-mac each own their catalog and had already applied theirs. **So I inserted no key and edited no `.xcstrings` file at all.**

I did not take that on trust. Source-vs-catalog sweep of all four targets (regex over `String(localized: "…")` / `LocalizedStringResource("…")`, tolerant of the line-split form, differenced against each catalog's key set):

| Catalog | keys | source keys in that target | missing from catalog | `python3 json.load` |
|---|---|---|---|---|
| `Conduck/Conduck/Localizable.xcstrings` | 2402 | 1849 | **0** | OK |
| `Conduck/ConduckShareExtension/Localizable.xcstrings` | 43 | 42 | **0** | OK |
| `Conduck/ConduckShareExtensionMac/Localizable.xcstrings` | 42 | 41 | **0** | OK |
| `Conduck/ConduckWatch Watch App/Localizable.xcstrings` | 299 | 60 | **0** | OK |

**The 5 picker keys are gone from BOTH extension catalogs** — `share.work.new`, `share.work.new.detail`, `share.work.section.destination`, `share.work.section.recent`, `share.work.untitled` return `[]` from a membership check on each catalog's key set. Their only remaining occurrence anywhere in the repo is `WorkCaptureInboxTests.swift:329-333`, where share-contract turned them into a **positive `retiredWorkKeys` guard** (`XCTAssertFalse(source.contains(...))` per appex) — that is the reverse of a leak and must stay.

`share.work.desk.detail` is present in both appex catalogs with the byte-identical value `Everything you share is added to your Work desk.`

Each appex catalog's one "catalog-only" entry is the empty-string key `""` (pre-existing in both) — `share.summary.more` is NOT an orphan, it is the split-across-lines declaration share-mac warned about, and the tolerant regex resolves it. **I deleted no main-catalog key**; the ~164 dead candidates from the earlier waves are all still there for the strings phase, as my brief requires.

## 2. The two Requests I resolved

### (a) availability §Requests 1 / test-surgery §Requests 4 — `.syncedPending` gets its own presentation state

This was the wave's one live UI contradiction: a card whose bytes are still arriving rendered the "Waiting for iCloud…" detail line AND the reattach paperclip in `AppColors.warning`, said "Reattach" to VoiceOver, offered Reattach in its menu, and opened the file importer on tap — the person told two different things about one card. availability wrote the exact three-file fix and could not take it (not its files); desk-vm's wave was over. It is plan §C's letter (`.syncedPending` → chip, non-available for opening/playback) finished properly, so I took it.

| File | Symbol | Change |
|---|---|---|
| `Conduck/Conduck/ViewModels/WorkboardViewModel.swift` | `WorkboardMaterialAvailability` | `+ case syncPending`; `isAvailable` rewritten from `self != .unavailableOnThisDevice` to `self == .available \|\| self == .localOnly`, so the new case cannot fail OPEN by omission. Doc comment widened to state why waiting and damage are different states. |
| `Conduck/Conduck/Services/Workboard/WorkboardLiveRepository.swift` | `presentationAvailability(_:)` | `.syncedPending` split out of the shared `.unavailableOnThisDevice` arm → returns `.syncPending`. Both arms carry their own reason. |
| `Conduck/Conduck/Views/Workboard/WorkboardCaptureCanvas.swift` | `WorkboardSourceCard.availabilityGlyph` / `availabilityLabel` | Two binary ternaries became three-way switches: `availabilityGlyphName` (`internaldrive` / `icloud.and.arrow.down` / `paperclip.badge.ellipsis`) + `availabilityGlyphTint` (`brandTeal` / `textTertiary` / `warning`), and `availabilityLabel` reusing the EXISTING key `workboard.material.syncPending` = `Waiting for iCloud…`. **No new key.** |
| `Conduck/ConduckTests/WorkboardAvailabilityTests.swift` | `testACardClaimingSyncedBytesWithNoBlobIsPendingAndCannotBeOpened` | the one line availability named: `presented == .unavailableOnThisDevice` → `== .syncPending`, **plus** a new `XCTAssertNotEqual(presented, .unavailableOnThisDevice)` and the fail-closed claim kept verbatim as the message on `XCTAssertFalse(presented.isAvailable)`. Strictly more is asserted than before; nothing was weakened. |

Why nothing else moved: `openMaterial` (`:314`) and the card menu's `onReattach` (`:1092`) already gate on the literal `== .unavailableOnThisDevice`, so a pending card is excluded from opening and from the Reattach affordance **for free**. `isAvailable` had exactly ONE caller repo-wide (that test), so redefining it moves nothing else. There is no exhaustive `switch` over `WorkboardMaterialAvailability` anywhere outside the two I wrote. The enum's `Codable` conformance is not used for persistence (`WorkboardMaterialSnapshot` is not `Codable`), so no stored value gains a case.

### (b) share-contract §Requests 1 — dead `WorkItemSummary` deleted

`Conduck/Conduck/Models/WorkboardRecords.swift`: deleted `nonisolated struct WorkItemSummary` and its doc comment, which described the picker job that died with the share picker. Re-verified before deleting: `grep -rn --include='*.swift' WorkItemSummary` over the whole repo returned exactly one hit, the declaration. Nothing else in the repo notices, and both platforms build.

## 3. Requests I deliberately did NOT take (each with its reason)

1. **test-surgery §Requests 1 / integrate-a §Requests 4a — `createWorkItemWithInitialMaterial` + `WorkMaterialOwnerPolicy.createNew` + its branch inside `publishWorkMaterial` + the 3 `ConversationStoreAtomicWorkCaptureTests` cases.** Production-dead, verified twice already. **Still deferred, now by three integrators.** It is not a function deletion: it cuts a branch out of `publishWorkMaterial`, the ONE write path every desk capture takes (owner resolution, identifier-collision guards, `createdOwner`), and authorises deleting a whole test class. Plan §A requires the *routing* subsumed, which it is. Doing it at the closing gate would put a re-cut of the single write path into a diff nobody re-reviews. Suite delta when it happens: **−3 → 4755**. See §Requests 1.
2. **blob-io §Requests 4 (the reattach comment) and §Requests 5 (`WorkAssetVault.swift` header) are ALREADY CLOSED** — availability rewrote both while it owned those files. I read them: the reattach comment at `WorkboardLiveRepository.swift:544` now says the arriving bytes get their lane picked afresh, "within the ceiling they ride private CloudKit as a blob, above it they stay in the device-local vault"; the vault header now states the one-lane-of-two truth and the ceiling's reason. Nobody owes these. (Plan §C / Codex #12 is satisfied for the header; §E's `spec.md` lines are still the docs agent's.)
3. **Every copy rewrite** — availability §Requests 2 (`sync.icloud.banner.*` say "your conversations" and the desk renders them verbatim; the banner's internal `.padding` insets it ~16pt from the cards), test-surgery §Requests 3, plus integrate-a §2.6's whole list. Strings/copy phase owns source+catalog lockstep; my brief scopes me to ADDED keys.
4. **integrate-a §Requests 3** (`WorkboardSurface` / `WorkboardMaterialActions.Presentation.row` / `WorkboardMaterialRoute` / `WorkboardMetrics.cardCornerRadius`) — unchanged and still owed. `WorkboardSurface` still needs the founder-visible adopt-or-delete call, since plan §B names it the desk container and the shipped desk draws none.
5. **All docs / founder-QA / orchestrator-ledger requests** — not mine, listed forward in §Requests.

## 4. The gate — exactly what I ran, quoted

Slug `~/Library/Caches/gigaduck-builds/desk-integrate-b/`, every log written there and grepped (never judged from tail or exit code). No `-configuration` passed anywhere. `xcrun simctl shutdown all` first.

**iOS `build-for-testing`**, sim `04DEF4F5-C144-4936-AEC3-A971B4FA9CDC` (`ios-bft-1.log`):
```
** TEST BUILD SUCCEEDED **
```
`grep -c ': error: '` → **0**.

**macOS `build`, `-destination 'platform=macOS'`, SIGNED** (`mac-build-1.log`):
```
** BUILD SUCCEEDED **
Signing Identity:     "Apple Development: Peter Krueck (Z4PNDLZK98)"
```
`grep -c ': error: '` → **0**. **No `CODE_SIGNING_ALLOWED=NO` fallback was needed** — this is the macOS evidence test-surgery §Requests 5 called load-bearing, and it now post-dates the byte-sync, share and availability slices.

**FULL iOS suite** (`ios-full-3.log`, `test-without-building`, no `-only-testing`):
```
** TEST EXECUTE SUCCEEDED **
Executed 4758 tests, with 1 test skipped and 0 failures (0 unexpected) in 62.663 (64.109) seconds
```
`grep -cE '\.swift:[0-9]+: error:'` → **0**. The STALL RULE never fired: no `Dispatch Thread Hard Limit`, no chunking, one run start to finish in ~64s.

The one skip is `GatewayAdapterBriefTests.testClipboardBriefRevisionPinMatchesPublishedContract`, quoted from the log:
```
GatewayAdapterBriefTests.swift:263: … Test skipped - No website source at …/.codex/worktrees/website/src/lib/adapter-contracts.ts
```

**Delta vs the `651a859` baseline (4750 executed / 0 failures / 2 skips): +8 executed, −1 skip, failures unchanged at 0.** The lost skip is not a loss of coverage: it lived in `WorkBriefAssistantTests.swift`, which purge-core deleted whole (integrate-a §5 verified that file was the only deleted one containing an `XCTSkip`). The +8 is the whole wave's net: the purge removed a large block of brief/dispatch/picker cases and the 2a slices added `WorkboardTwoStoreLoadTests` (7), `WorkboardBlobPublicationTests` (12), `WorkboardBlobGCTests` (6), `WorkboardAvailabilityTests` (9), `WorkCaptureInboxLeaseTests` (9) and the rest. **My own edits changed the count by 0** — I added no case and deleted none.

Byte-sync / share classes inside that run, from the same log:

| Class | Result | Class | Result |
|---|---|---|---|
| `WorkboardAvailabilityTests` | Executed 9, 0 failures | `WorkboardTwoStoreLoadTests` | Executed 7, 0 failures |
| `WorkboardBlobGCTests` | Executed 6, 0 failures | `WorkboardDeskUpsertTests` | Executed 10, 0 failures |
| `WorkboardBlobPublicationTests` | Executed 12, 0 failures | `WorkCaptureInboxTests` | Executed 30, 0 failures |

**WATCH suite**, scheme `ConduckWatchTests`, sim `28AC563B-42C1-4E66-940D-77E63B07918B` (`watch-1.log`, `xcodebuild test`, no `-configuration`):
```
** TEST SUCCEEDED **
Executed 231 tests, with 0 failures (0 unexpected) in 9.540 (9.622) seconds
```
`grep -c ': error: '` → **0**. **231 is exactly the predicted number** (baseline 229 + desk-intents' 2 Workboard cases in the existing `ConduckWatchSmokeTests.swift`). This closes integrate-a §Requests 7 and test-surgery §Requests 5's watch item — it had been unverified by every agent since desk-intents wrote it.

**One infrastructure incident, reported for honesty, no result taken from it.** My first full-suite attempt was launched with `nohup … &` inside a backgrounded shell; the harness reported it complete while the `xcodebuild` process was in fact still alive, so a second attempt ran **concurrently against the same simulator and the same DerivedData**. I detected it from `ps` (two `xcodebuild test-without-building` pids, 02:30 and 02:08 elapsed), killed both, `xcrun simctl shutdown all`, and re-ran ONCE cleanly — `ios-full-3.log` above is that single clean run. `ios-full-1.log` (25 lines, package resolution only) and `ios-full-2.log` (interleaved, no summary) are discarded and no number in this fixnote comes from either.

## 5. Hygiene

- `bash scripts/check-storage-seam.sh` → `✓ storage seam intact — 771 Swift files scanned, no raw store or live-adapter access outside Conduck/Conduck/Services/Storage/LiveStorage.swift`, exit **0**.
- `git diff --check` → clean, exit **0**.
- **All four catalogs `python3 json.load` clean** (counts in §1). `plutil` deliberately not used.
- **Mirror triplets — both correct, neither modified.** `git status --short -- '*WorkCaptureEnvelope.swift' '*ShareTargetsSnapshot.swift'` is **empty**. `cmp` on the whole files reports DIFFER for all six pairs, which is the standing convention and not drift: each copy carries its own target-specific header. Below `import Foundation` every copy of each file hashes identically — `WorkCaptureEnvelope` → `45a26a6658c92401` ×3, `ShareTargetsSnapshot` → `a72a7d13d6f1e9ec` ×3. That is the contract `ShareTargetsSnapshotTests.testAppexMirrorIsByteIdenticalToCanonicalBelowHeader` and `WorkCaptureInboxTests` enforce, and both are green.
- **`git status --short` sweep — nothing outside the expected surface, and no `.pbxproj`, no `.xcstrings` in the main app, no mirror, no `Identity-Override.xcconfig`.** 21 modified + 4 untracked. Everything matches test-surgery's hand-off list plus exactly my four files: `Conduck/Conduck/Models/WorkboardRecords.swift` and `Conduck/Conduck/ViewModels/WorkboardViewModel.swift` (both newly appearing, both mine), and my additions inside the already-modified `WorkboardLiveRepository.swift`, `WorkboardCaptureCanvas.swift` and the untracked `WorkboardAvailabilityTests.swift`. The four untracked files are the 2a test files (`WorkboardAvailabilityTests`, `WorkboardBlobGCTests`, `WorkboardBlobPublicationTests`, `WorkboardTwoStoreLoadTests`), all in the synchronized `ConduckTests` group, all compiled and run with no pbxproj edit.

## 6. Deviations from my brief, with reasons

1. **I took availability §Requests 1 (a three-production-file UI change), not only "cross-slice breakage".** My brief's step 2 is "resolve open Requests coherent with the plan", and this one was written as an exact patch by the agent that could not apply it, is plan §C's own behaviour, and left a user-visible contradiction on the desk. It is bounded: one enum case, one switch arm, two view accessors, one test line, and `isAvailable` was rewritten to fail closed by construction rather than by omission.
2. **I ran the full iOS suite even though test-surgery had it at 4758/0 an hour earlier.** My edits touch the projection→presentation seam every card reads, so a targeted run would not have been evidence.
3. **No Codex consult.** The one debatable call was §6.1's scope question, which is a process judgement, not a technical one.
4. **Slug cleaned at the end, so the logs no longer exist** — every line quoted above was taken from them before deletion.

---

## Catalog

**Keys I ADDED in source: NONE.** The `syncPending` label reuses the existing `workboard.material.syncPending` = `Waiting for iCloud…` (foundation.md's key, already declared by `WorkboardLiveRepository.materialDetail` and already in the main catalog with that exact en value — I compared them character for character, ellipsis included).

**Keys I found DEAD: NONE new.** Deleting `WorkItemSummary` retired no key — the struct carried no copy. The `WorkboardMaterialAvailability` change retired none either: `workboard.material.reattach.short` and `workboard.material.localOnly` both keep their arms, and `workboard.material.syncPending` gained a second reader.

**No `.xcstrings` file was opened for editing by me, in any target.**

**For the strings phase — three traps in this wave's keys, all still live:**
- `workboard.material.{syncPending,localOnly,reattach.short,unavailableHere}` are ALL live and now each have two readers (repository + canvas). None is a dead candidate.
- The five `share.work.*` picker keys are already gone from both appex catalogs; their remaining source occurrences are the negative guard in `WorkCaptureInboxTests` and must NOT be read as live references.
- integrate-a §Requests 2's trap is unchanged: `workboard.material.add*` are live in grep and dead in behaviour, and `Add ${thought} to Work` is macro-composed with zero grep hits BY DESIGN — never delete it.

---

## Requests

1. **Store owner (whoever next opens `ConversationStore+Workboard.swift`) — the ONE piece of dead production code left in this wave, deferred by three integrators now.** `createWorkItemWithInitialMaterial` + `WorkMaterialOwnerPolicy.createNew` + its branch inside `publishWorkMaterial`, and with them all THREE `ConversationStoreAtomicWorkCaptureTests` cases (they are that function's only coverage — do not delete the tests first). Verified production-dead by integrate-a and re-verified green by test-surgery. Suite delta **−3 → 4755**. integrate-a §Requests 4b (`addWorkMaterial`/`addWorkMaterialFile`/`insertWorkMaterial`/`createWorkItem`) is **CLOSED**: blob-io kept them as the test-only non-desk owner mint and said so at both declarations, and test-surgery rewrote the matching test message.
2. **View/cleanup phase — integrate-a §Requests 3 is untouched and still needs a founder-visible decision on `WorkboardSurface`** (zero consumers; plan §B calls it the desk container, the shipped desk draws no container). The other three in that sweep (`WorkboardMaterialActions.Presentation.row` + `rowRoutes` + `action(for:)` + `label(for:)`, `WorkboardMaterialRoute`, `WorkboardMetrics.cardCornerRadius`) are verified dead and go together with the `workboard.material.add*` keys.
3. **Strings/copy phase — the most user-visible debt left is the desk banner's copy.** `sync.icloud.banner.{noAccount,restricted,quotaExceeded}` all say "your conversations", and `WorkboardCaptureCanvas.deskSyncBanner` renders them verbatim on the Work desk. Either widen the three, or give the desk its own three keys. Second, cosmetic: `ICloudUnavailableBanner` bakes in `.padding(.horizontal)` + `.padding(.top, 8)`, so on the desk it sits ~16pt inset from the cards — intended or a two-line fix, founder's call.
4. **Docs agent — four spec facts are now settled by code, not by plan.** (a) plan §E's two: `spec.md:430` (Work file bytes device-local) and `:503` (audio not retained). (b) the app opens **`Conversations 16`** and `ConversationsModelMigrationTests.testTheCurrentModelVersionIsV16` is the guard (integrate-a §Requests 5). (c) two SQLite stores in the App Group container — `Conversations.sqlite` under configuration `Core`, `ConversationBlobs.sqlite` under `Blobs`; watchOS mounts only the first (store-descriptions §Requests 6). (d) a card's availability is decided by whether a COMPLETE blob row exists, never by what `storageMode` claims; a card claiming synced bytes with no blob is `.syncedPending` — **and as of this slice it is its own presentation state**: visible, un-openable, showing "Waiting for iCloud…" with a sync glyph and NO reattach affordance. Also: the share sheet offers no Work destination and no "Recent Work" list on either platform (share-mac §Requests 5), and the snapshot's `recentWorkItems` is published empty and survives only for mirror byte-identity (share-contract §Requests 2).
5. **Founder QA / Gate 2 — one item to add and three to sharpen.** ADD: on a device where a card's bytes have not arrived, the card must show "Waiting for iCloud…" with the `icloud.and.arrow.down` glyph and must NOT offer Reattach anywhere (tap, menu, VoiceOver) — that is this slice's user-visible change and only a real two-device run proves it. SHARPEN: spike checklist steps 6, 10 and 18 per availability §Requests 7; step 1 per store-descriptions §Requests 4 (the container must hold BOTH `Conversations.sqlite` and `ConversationBlobs.sqlite`, each with its own `_SUPPORT` directory); and the macOS share-panel item per share-mac §Requests 4.
6. **Orchestrator — the gate numbers to record.** iOS **4758 executed / 1 skipped / 0 failures** (plan §F's "~4664" and "2 skips" are both superseded — the second skip died with `WorkBriefAssistantTests`). Watch **231 / 0**. Signed macOS `** BUILD SUCCEEDED **` post-dating every 2a slice. Plan §G item 1 (deploy model 16 to CloudKit Production) is now enforced by the suite, not just the plan.
7. **Nobody collapse `syncPending` back into `unavailableOnThisDevice`, and nobody rewrite `isAvailable` as `!= something`.** The enum now names the READABLE cases on purpose: a fourth unreadable state added later must fail closed by default, and the surface's whole safety claim ("nothing may be opened, played or sent from bytes this device cannot read") rests on that one line. `WorkboardAvailabilityTests.testACardClaimingSyncedBytesWithNoBlobIsPendingAndCannotBeOpened` asserts both halves — the state IS `.syncPending`, and it is NOT available.
8. **Anyone running a long xcodebuild from an agent harness: do not wrap it in `nohup … &`.** The harness reports the wrapper's exit as the command's, the real `xcodebuild` survives, and a second attempt then interleaves with it on the same simulator and DerivedData. §4 has the detection (`ps -Ao pid,etime,command`) and the recovery.
