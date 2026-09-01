# store-descriptions — plan §C two-store store descriptions. DONE. iOS + macOS + watch green; 20 targeted tests / 0 failures; watch suite 231 / 0.

Parallel phase. No commits/pushes/stash/checkout. `Identity-Override.xcconfig` untouched. Nothing under `docs/qa/desk-cloudkit/` touched. **No `.xcstrings` file opened** (I added zero user-facing strings). I edited exactly TWO files: `Conduck/Conduck/Services/ConversationStore.swift` and the new `Conduck/ConduckTests/WorkboardTwoStoreLoadTests.swift`. `WorkboardModelMigrationTests.swift` needed nothing — **untouched**; no shared helper had to move.

Spike recipe §2 replicated exactly. `performLoad()`'s multi-store resolution logic untouched (only the post-load topology assertion the task requires was appended after the continuation).

---

## 1. Exact description setup (`ConversationStore.swift`)

**One builder, three callers.** `private static func storeDescriptions(core:blobStoreURL:cloudKit:) -> [NSPersistentStoreDescription]` is the only place a description array is assembled, so the production store, the QA screenshot store and the test seam cannot drift.

```swift
core.configuration = coreConfigurationName            // "Core"
configureSyncOptions(on: core, cloudKit: cloudKit)
#if os(watchOS)
return [core]                                          // the omission IS the exclusion
#else
guard let blobStoreURL else { return [core] }
let blobs = NSPersistentStoreDescription(url: blobStoreURL)
blobs.type = core.type                                 // in-memory seam stays in memory
blobs.configuration = blobsConfigurationName           // "Blobs"
configureSyncOptions(on: blobs, cloudKit: cloudKit)
return [core, blobs]
#endif
```

New private statics beside `container`: `coreStoreFilename = "Conversations.sqlite"` · `blobStoreFilename = "ConversationBlobs.sqlite"` · `coreConfigurationName = "Core"` · `blobsConfigurationName = "Blobs"`.

| Init | Core URL | Blobs URL | cloudKit |
|---|---|---|---|
| `private init()` production | `groupURL/Conversations.sqlite` (**unchanged shipped file**) | `groupURL/ConversationBlobs.sqlite`, off the **SAME `groupURL` local** — no second `containerURL(forSecurityApplicationGroupIdentifier:)` call, so `check-storage-seam.sh` needs no change | `cloudKitUsable` on **BOTH** |
| `private init()` App-Group-nil fallback | Core Data default location | `siblingBlobStoreURL(besideCore:)` | same |
| `private init()` QA screenshot | `/dev/null`, `NSInMemoryStoreType` | `/dev/null-Blobs`, in-memory (type copied from core) | false on both |
| `init(inMemory:storeURL:)` | `/dev/null` (in-memory) or `storeURL` | `siblingBlobStoreURL(besideCore: core.url)` | false on both |

`siblingBlobStoreURL(besideCore:)` = the Core file's own name with `-Blobs` appended, same directory, extension preserved. `/dev/null` → `/dev/null-Blobs`; `/tmp/x.sqlite` → `/tmp/x-Blobs.sqlite`. It is derived from the Core URL precisely so no new App Group query appears anywhere.

`configureSyncOptions` itself is **unchanged** — both descriptions run through it identically, so history tracking + remote-change posting + (when `cloudKit`) `cloudKitContainerOptions` are attached the same way to both. Simulator / unentitled: `cloudKitUsable == false` reaches BOTH stores, so neither attaches CloudKit. There is no per-store special-casing anywhere.

## 2. The load assertion (spike pitfall 1)

In `performLoad()`, immediately after the `loadPersistentStores` continuation resolves and **before** the `store.load ms=` milestone:

```swift
let expectedStores = descriptions.map(Self.storeIdentity(of:)).sorted()
let mountedStores = container.persistentStoreCoordinator.persistentStores
    .map(Self.storeIdentity(of:)).sorted()
guard expectedStores == mountedStores else {
    throw StoreTopologyMismatch(expected: expectedStores, mounted: mountedStores)
}
```

- `storeIdentity` = `"<configuration>@<url.lastPathComponent>"`. **File NAME only, deliberately**: Core Data hands back a resolved `/private/var/…` path for a URL handed in as `/var/…`, so comparing whole URLs would fail on any temp directory rather than on a real mismatch. A nil `description.configuration` maps to `PF_DEFAULT_CONFIGURATION_NAME`, which is what `NSPersistentStore.configurationName` reports for it, so the comparison stays honest if anyone ever mounts a default-configuration store again.
- Sorted set comparison covers **both** the count and the pairing in one guard.
- **New error type `ConversationStore.StoreTopologyMismatch: Error, CustomStringConvertible`**, deliberately NOT a `StoreError` case: `landAgentTurn`'s `catch let verdict as StoreError` switches over that enum exhaustively (`ConversationStore.swift`, the `.conversationNotFound / .userMessageNotFound / .attemptAlreadyTerminal` switch), and a topology failure has no business in a turn-landing decision. Same precedent as `DebugInjectedSaveFailure`.
- It fails through the **existing** load-error path: `performLoad` throws → the single-flight `loadTask` is sticky → every `ensureLoaded()` caller rethrows forever, which is the behaviour `ConversationStoreLoadAndDebounceTests.testLoadFailureThrowsOnFirstAndEverySubsequentTouch` already pins.

`WorkboardTwoStoreLoadTests.testAMisPointedConfigurationCouldNotHaveMountedUnnoticed` proves the assertion is not decorative: it opens the CORE file under `configuration = "Blobs"` and asserts `loadError == nil`. Core Data really does mount it silently.

## 3. In-memory seam decision (documented, as asked)

**Both in-memory seams mount BOTH stores.** `init(inMemory: true)` and the QA screenshot store each get a Core in-memory store plus a Blobs in-memory store at `/dev/null-Blobs` (distinct URL so the coordinator can tell them apart; `blobs.type = core.type` keeps the sibling in memory rather than leaving a stray sqlite behind an in-memory Core).

Why, given the spike says a missing/fresh Blobs store is harmless:
- Harmless ≠ equivalent. A one-store seam exercises a topology the app never runs, and any test or seeder that inserts a `WorkMaterialBlob` would fail on a store nothing mounted — a failure mode the byte-io agent would meet as an unexplained test error rather than a design fact.
- Evidence it is safe: the FULL iOS suite (4,730 executed) runs almost entirely on `ConversationStore(inMemory: true)`, and every non-share-extension test passed with two in-memory stores mounted. Two in-memory stores on one coordinator with named configurations work.
- The QA screenshot store keeps the production shape for the same reason: once byte sync lands, a seeded card whose bytes ride the payload store has somewhere to put them.

## 4. Memory at the ceiling — how I measured, and the number

`WorkboardTwoStoreLoadTests.testACeilingSizedPayloadStaysBoundedInPeakMemory`.

- **Instrument**: `task_info(TASK_VM_INFO)` → `phys_footprint`, polled every 2 ms from a detached thread (`FootprintSampler` at the bottom of the test file), max over the window. I deliberately did **not** use `ledger_phys_footprint_peak`: it is a PROCESS-lifetime high-water mark, so in a suite that already peaked higher it reports zero growth and the bound passes vacuously.
- **Window**: baseline sampled, then `Data(repeating: 0xC7, count: Int(Constants.workboardSyncCeilingBytes))` allocated, handed to the seam, assigned to `WorkMaterialBlob.payload`, and `context.save()`d. Peak sampled at the end of the window.
- **Result (two runs, temporarily asserting `< 0` to print the numbers, then restored):**
  - `baseline=35326208 peak=67209520 growth=31883312 ceiling=31457280` → **1.0135×**
  - `baseline=35195160 peak=67062088 growth=31866928 ceiling=31457280` → **1.0130×**
- **Reading**: peak growth is the test's own copy of the payload plus ~410 KB. External binary storage adds **no second copy** of a 30 MiB payload. (A third run died in simulator preflight before any case started — `** TEST EXECUTE FAILED **`, no measurement; the two that ran agree to 0.05 %.)
- **Shipped bound**: `XCTAssertLessThan(growth, Int64(ceiling) * 3)` — ~3× headroom over measured, set to catch a build that buffers the payload several times over, not to pin allocator behaviour.

## 5. TN3164 record (as asked): the multi-container-instance warning does not apply here

Verified in this tree, not assumed:
- Project targets are `Conduck`, `ConduckWatch Watch App`, `ConduckWatchExtension`, `ConduckTests`, `ConduckShareExtension`, `ConduckShareExtensionMac`, `ConduckWatchTests`. **There is no App Intents extension target.** `Intents/CaptureWorkboardIntent.swift` is app-target source, so intents run in the app process.
- The built app's `PlugIns/` holds `ConduckShareExtension.appex` and `ConduckTests.xctest` and nothing else.
- Neither share extension opens Core Data: `grep -rln 'NSPersistentContainer|NSPersistentCloudKitContainer|ConversationStore'` over both extension directories hits only `SharedInboxManifest.swift`, and only in doc comments. They write App-Group **envelope files**; the app's drainer persists them.

So the TN3164 case ("your app and extension both use `NSPersistentCloudKitContainer` to manage a shared store, even though they are different processes") has no instance in this codebase, and **no process gating of `cloudKitContainerOptions` was added.** Both stores attach CloudKit wherever the app does. Gate 2 steps 14–16 still have to measure 134410 on a signed device — this is a static-topology argument, not a runtime measurement, and a system-spawned second instance of the app process is exactly what a headless intent run can look like.

## 6. What blob-io may rely on

1. **Two stores are mounted or the load threw.** After a successful `ensureLoaded()` you may assume a `Blobs` store exists on every non-watchOS platform, including the in-memory test seam. No defensive "is the blob store there?" check is needed at write time.
2. **No `context.assign(_:to:)`, ever.** Proven on the real model through the real seam: `testAMaterialAndItsBlobCommitInOneSaveIntoDifferentPhysicalStores` inserts both rows in ONE `context.save()` with no assignment and asserts `objectID.persistentStore?.url` for each. Core Data routes by configuration membership.
3. **The watch compiles `ConversationStore.swift` with the Blobs description compiled out** (`#if os(watchOS)` returns `[core]`). Watch app BUILD and the watch suite are green. So on watchOS the `WorkMaterialBlob` entity is in the model but in NO mounted store: **any watch code path that inserts or fetches a blob row must be `#if !os(watchOS)`.** A fetch returns empty rather than throwing, but an insert has no store to land in.
4. **Losing the payload store is survivable and silent** — proven: Core rows keep `storageMode == "syncedPayload"` with zero blob rows, and the container reloads with the Blobs store recreated empty. That state is exactly `.syncedPending`; the availability projection is what makes it non-corrupting. Do not add a sweep.
5. **Blob externals live in their own `_SUPPORT` directory** beside `ConversationBlobs.sqlite` (`.ConversationBlobs_SUPPORT/_EXTERNAL_DATA`). Anything that copies, backs up or wipes the store handles TWO `_SUPPORT` directories. My test helper `removeStoreFiles(at:)` takes `.sqlite` / `-wal` / `-shm` / `_SUPPORT` per store and is called for both.
6. **A ceiling-sized payload costs ~1× in peak memory** (§4). You do not need to stream a 30 MiB blob into the attribute.
7. **Five test seams exist under `#if CONDUCK_TESTING`** at the end of `ConversationStore.swift`, all gated on the new `isIsolatedTestStore` flag (true only for `init(inMemory:storeURL:)`, so a signed suite run can never reach the founder's App Group data): `_mountedStoresForTesting()`, `_writeMaterialAndBlobForTesting(materialID:title:payload:)`, `_materialAndBlobForTesting(materialID:includingPayload:)`, `_unloadForTesting()`, plus the `MountedStoreForTesting` / `MaterialBlobStoresForTesting` / `MaterialBlobSnapshotForTesting` snapshots. **`_writeMaterialAndBlobForTesting` writes raw rows and is NOT a production write path** — it exists only to prove routing; when you land the real blob writer, do not route anything through it, and feel free to have the fixture hash string (`"test-fixture-hash"`) follow whatever `contentHash` convention you pick.

## 7. Tests added — `Conduck/ConduckTests/WorkboardTwoStoreLoadTests.swift` (7 cases)

| Case | Holds |
|---|---|
| `testTheTestSeamMountsCoreAndThePayloadStoreWithTheExpectedPairing` | 2 stores; `Core`→the handed file, `Blobs`→the `-Blobs` sibling |
| `testAMisPointedConfigurationCouldNotHaveMountedUnnoticed` | opening the Core file as `Blobs` returns **no error** — the load assertion's justification |
| `testAMaterialAndItsBlobCommitInOneSaveIntoDifferentPhysicalStores` | one save, no assign, `objectID.persistentStore?.url` differs and matches each file |
| `testBothStoresSurviveCloseAndReopen` | unload → fresh store → 2 stores, title + storageMode + byteSize intact, 256 KB payload byte-identical |
| `testDeletingThePayloadStoreLeavesCoreIntactAndRecreatesBlobsEmpty` | blob sqlite set deleted while closed → reopen mounts 2, Core row intact, `blobRowCount == 0` |
| `testTheWatchShapeOpensTheSameCoreFileCleanlyWithNoPayloadStore` | raw container, `[Core]` only, against the app's CURRENT model: 1 store, material readable, `WorkMaterialBlob` count 0 |
| `testACeilingSizedPayloadStaysBoundedInPeakMemory` | §4 |

## 8. Gates run (exact lines)

Slug `desk-store-desc`, derivedData `~/Library/Caches/gigaduck-builds/desk-store-desc/{DerivedData,DerivedDataWatch,DerivedDataMac}`, every log written there and grepped. No `-configuration` passed to any test/build-for-testing invocation.

- iOS `build-for-testing`, sim `1DCDF41E-D223-48B4-AA8E-147B0A9E2CE1` → `ios-bft-3.log`: `grep -c ': error: '` = **0**, `** TEST BUILD SUCCEEDED **`.
- iOS `test-without-building`, three quoted `-only-testing:` flags → `ios-test-2.log`, `** TEST EXECUTE SUCCEEDED **`:
  - `Executed 7 tests, with 0 failures (0 unexpected) in 0.004 (0.006) seconds` — `WorkMaterialStoragePolicyTests`
  - `Executed 6 tests, with 0 failures (0 unexpected) in 1.010 (1.011) seconds` — `WorkboardModelMigrationTests`
  - `Executed 7 tests, with 0 failures (0 unexpected) in 0.318 (0.319) seconds` — `WorkboardTwoStoreLoadTests`
  - total `Executed 20 tests, with 0 failures (0 unexpected) in 1.331 (1.337) seconds`
- **watch app BUILD**, `-scheme 'ConduckWatch Watch App'`, `-destination 'platform=watchOS Simulator,id=28AC563B-42C1-4E66-940D-77E63B07918B'` → `watch-build-1.log`: 0 `error:` lines, `** BUILD SUCCEEDED **`.
- **watch SUITE** (extra, not in my brief — the wrist mounting a single `Core` store is the riskiest part of my change): `-scheme ConduckWatchTests`, same sim → `watch-test-1.log`, `** TEST SUCCEEDED **`, `Executed 231 tests, with 0 failures (0 unexpected) in 9.537 (9.619) seconds`. That also answers integrate-a §Requests 7 (231 was the predicted count).
- **macOS** `build -destination 'platform=macOS'` (extra insurance — this file compiles for macOS and has a macOS-only entitlement probe) → `mac-build-1.log`: 0 `error:` lines, `** BUILD SUCCEEDED **`. Signed through the identity override; **no `CODE_SIGNING_ALLOWED=NO` fallback needed**.
- `bash scripts/check-storage-seam.sh` → `✓ storage seam intact — 768 Swift files scanned…`, exit 0.
- `git diff --check` → clean, exit 0.
- `Conversations 16.mom` present in the built `Conduck.app/Conversations.momd/` — registration re-proven in my own build.
- Build caches removed with `/Users/peterkruck/repos/GigaDuck/.claude/scripts/clean-build-cache.sh desk-store-desc` (the script lives in the MAIN repo `.claude/`, not in this worktree). The logs no longer exist; re-run if you need them.

### FULL iOS suite — 22 failures, ALL in another agent's in-flight files

`ios-full-1.log`, `** TEST EXECUTE FAILED **`:

```
Executed 4730 tests, with 1 test skipped and 22 failures (0 unexpected) in 65.114 (66.484) seconds
```

I ran it because I changed the store init every test uses. Every one of the 22 failures is in **`ConduckTests.WorkCaptureInboxTests`**, and every one is a source/catalog drift-guard assertion about the two SHARE EXTENSIONS, which the parallel share-extension agent is mid-rewrite of (`git status` shows `ConduckShareExtension{,Mac}/{ShareView.swift,ShareViewController.swift,Localizable.xcstrings}` modified; `git diff` shows the five `share.work.*` keys deleted from `ShareView.swift`). Exact failing assertions, deduplicated:

```
-[ConduckTests.WorkCaptureInboxTests testShareSurfacesUseDistinctWorkVocabularyAndAdaptivePrimaryActions] : XCTAssertTrue failed - ConduckShareExtension/Localizable.xcstrings must carry the exact source key share.work.new
  … same for share.work.new.detail, share.work.section.destination, share.work.section.recent, share.work.untitled
  … same five for ConduckShareExtension/ShareView.swift ("must use the exact catalog key")
  … same five for ConduckShareExtensionMac/Localizable.xcstrings and five for ConduckShareExtensionMac/ShareView.swift
-[ConduckTests.WorkCaptureInboxTests testShareWritersValidateAndRollbackBeforeAtomicPublication] : XCTAssertTrue failed - ConduckShareExtension/ShareViewController.swift must carry the optional inert Work destination into the envelope
-[ConduckTests.WorkCaptureInboxTests testShareWritersValidateAndRollbackBeforeAtomicPublication] : XCTAssertTrue failed - ConduckShareExtensionMac/ShareViewController.swift must carry the optional inert Work destination into the envelope
```

Per the parallel-phase rule I waited (≈6 min, spent on the watch build) and retried once with a fresh `build-for-testing` → `ios-inbox-retry.log`: `Executed 30 tests, with 22 failures (0 unexpected) in 0.413 (0.423) seconds`. Still failing; the share agent has not yet updated `WorkCaptureInboxTests`. **I did not touch any of those files** and I did not weaken or delete any assertion. Nothing in the failure set concerns Core Data, store descriptions, configurations or loading. The other 4,708 tests passed with my change in.

Note: the executed count is 4,730 vs integrate-a's 4,723 — +7 is exactly `WorkboardTwoStoreLoadTests`.

---

## Call-site touches

**NONE.** No file outside the two I own was opened for editing.

---

## Catalog

**Keys I ADDED in source: NONE.** Nothing I wrote produces user-facing copy; no `.xcstrings` file was opened.

**Keys I found DEAD: NONE.** I deleted no code that referenced a key.

---

## Requests

1. **blob-io / byte-sync agent — read §6 before writing the first blob.** In particular: no `context.assign`, both stores are guaranteed mounted after `ensureLoaded()`, and every blob touch on the watch needs `#if !os(watchOS)` because the entity exists in the model there but in no mounted store.
2. **Share-extension agent (or the serial integrator) — `ConduckTests/WorkCaptureInboxTests` is 22 failures behind your `ShareView.swift` / `ShareViewController.swift` / extension-catalog edits.** Exact assertions quoted in §8. It is not my file and not my breakage; naming it here so it is not attributed to the store change.
3. **Orchestrator — the iOS baseline moves to 4,730 executed** (integrate-a's 4,723 + my 7), 1 skip unchanged.
4. **Orchestrator — Gate 2's founder checklist is unchanged by my work but two of its steps are now cheap to phrase precisely.** Step 1 should say the App Group container must hold `Conversations.sqlite` **and** `ConversationBlobs.sqlite`, each with its own `_SUPPORT` directory — those are the exact production filenames now in source. Steps 14–16 (134410) remain genuinely open: §5 shows the TN3164 *extension* case does not exist in this project, but a headless intent run is still a second process image of the app and only a signed device can settle it.
5. **Anyone adding a store description later** — go through `ConversationStore.storeDescriptions(core:blobStoreURL:cloudKit:)`. `performLoad` compares the mount against `container.persistentStoreDescriptions`, so a description built anywhere else still has to satisfy the same `configuration@filename` pairing or the load throws `StoreTopologyMismatch`.
6. **Docs agent** — `spec.md`'s storage section will need the two-file truth: the app opens two SQLite stores from the App Group container (`Conversations.sqlite` under configuration `Core`, `ConversationBlobs.sqlite` under `Blobs`), and watchOS mounts only the first. Present tense; that IS the architecture now, not a delta.
