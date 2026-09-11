# foundation — plan §C.1–5 (model 16, constants, policy, records, migration tests). DONE, gates green.

Sync GO path taken. Spike recipe replicated verbatim; no deviations from it.

## What changed (file:line)

**1. Model `Conversations 16`** — `Conduck/Conduck/Models/Conversations.xcdatamodeld/Conversations 16.xcdatamodel/contents` (new; byte-identical copy of 15 + the spike's XML block, `diff` against `spike-harness/Conversations-16-contents.xml` = 0). `Conversations 15.xcdatamodel` UNTOUCHED (git status proves only `.xccurrentversion` changed in that dir). `.xccurrentversion` → `Conversations 16.xcdatamodel`.
- `WorkMaterialBlob`: `materialID` UUID · `payload` Binary + `allowsExternalBinaryDataStorage` · `byteSize` Integer 64 `usesScalarValueType="NO"` **no defaultValueString** · `contentHash` String · `createdAt`/`updatedAt` Date. All optional, no defaults, no relationships, no uniqueness constraints.
- Configurations `Core` (the 7 pre-existing entities) + `Blobs` (blob only), each `usedWithCloudKit="YES"`.
- **REGISTRATION PROVEN, no pbxproj edit** — from the compiled bundle:
  `…/Debug-Testing-iphonesimulator/Conduck.app/Conversations.momd/` lists `Conversations 16.mom` (+ `.omo`), and its `VersionInfo.plist` has `NSManagedObjectModel_CurrentVersionName = "Conversations 16"`. Same momd present in **both** watch bundles. `project.pbxproj` NOT touched.

**2. `Conduck/Conduck/Utilities/Constants.swift:2089-2113`** — `workboardDeskItemID` = `DE5C0000-0000-4000-A000-000000000001` and `workboardSyncCeilingBytes: Int64 = 30 * 1024 * 1024`, both `nonisolated static let`, with the ceiling's "below the archived 50 MB figure, raise only on device evidence" comment.

**3. `Conduck/Conduck/Services/Workboard/WorkMaterialStoragePolicy.swift`** (new) — `mode(kind:byteSize:) -> WorkMaterialStorageMode`; `.syncedPayload` iff `0 < byteSize <= ceiling`, else `.localVault`. Never returns `.metadataOnly` (that is decided at the draft). Kind is accepted but deliberately not consulted.

**4. `Conduck/Conduck/Models/WorkboardRecords.swift`** — ADDITIONS ONLY, nothing deleted:
- `:351-356` `WorkMaterialKind.audio` (decode is free: `init(stored:)` + `RawRepresentable` Codable already total).
- `:416-420` `WorkMaterialAvailability.syncedPending`.
- `:564-604` `WorkMaterialBlobRecord` — `id == materialID`, `byteSize`, `contentHash`, `createdAt`, `updatedAt`, plus `var isComplete: Bool { byteSize > 0 && !contentHash.isEmpty }`. **No payload field by design** — the availability fetch must never project bytes.

**5. Tests** — `Conduck/ConduckTests/WorkMaterialStoragePolicyTests.swift` (new, 7 tests: inclusive ceiling, ceiling+1, 0/-1/.min, 256 MB/.max, every `WorkMaterialKind` gets the same answer, never `.metadataOnly`, ceiling < 50 MB). `Conduck/ConduckTests/WorkboardModelMigrationTests.swift` +2 tests + helpers `loadCoreAndBlobStores`, `unload`, `removeStoreFiles` (cleans `.sqlite`/`-wal`/`-shm`/`_SUPPORT` for BOTH stores; `setUp` now mints a sibling `blobStoreURL`).
- `testV16AddsOnlyTheBlobEntityAndTwoCloudKitConfigurations`: added-entity set == `["WorkMaterialBlob"]`, nothing dropped, no shipped column/relationship mutated, **identical `versionHash` 15→16 for all 7 entities**, v15 declares no named configurations, v16 declares exactly Core+Blobs with the right membership, external-storage + optional/no-default + no-uniqueness assertions on the blob.
- `testV15SQLiteReopensAsCoreInV16BesideAWritableBlobStore`: real v15 default-config SQLite (WorkItem + WorkMaterial with `cardSize` and a 400 KB external `thumbnailData`) → reopened under two v16 descriptions; asserts `persistentStores.count == 2` with the right (configurationName, filename) pairs, rows/timestamps intact, blob table empty, then writes a 5 MB blob + flips the material to `syncedPayload` **in one `save()` with no `context.assign`**, asserts each row's `objectID.persistentStore.url`, closes, reopens, payload byte-identical, material `payload` column nil, and the `.dictionaryResultType` projection returns metadata with **no `payload` key**.

**6. Compile fallout I had to fix (exhaustive switches over the two enums I extended)** — minimal, no behavior invented:
- `WorkboardDispatchCoordinator.swift:294-296` — `case .file, .audio:` (a voice note travels as its recording).
- `WorkboardLiveRepository.swift:395-398` — `.syncedPending` joins `.unavailableOnThisDevice` in `presentationAvailability` → **fails closed**; `:404` adds `.audio` to the metadata-only-without-bytes group.
- `WorkboardLiveRepository.swift:440-445` — `.syncedPending` detail line, NEW STRING key **`workboard.material.syncPending` = "Waiting for iCloud…"**, added to `Conduck/Conduck/Localizable.xcstrings` (extracted_with_value/new, alphabetical slot before `workboard.material.unavailableHere`; catalog JSON re-parsed clean, 2398 keys).
- `WorkBriefPromptBuilder.swift:103` — `case .file, .audio: return .file`. **Purge agent: this file dies; nothing of mine depends on it surviving.**

## Binding for the agents after me
- **`.syncedPending` PROJECTION LANDS AT `ConversationStore+Workboard.swift:2202-2237`** — `MaterialRow.record(availableLocalKeys:)`, the `case .syncedPayload: availability = .synced` branch. It must become "complete blob row exists for this materialID → `.synced`, else `.syncedPending`", fed by ONE batch `.dictionaryResultType` fetch (materialID/byteSize/contentHash/updatedAt, never payload) alongside the existing `availableLocalKeys` set. `hasPayload` at `:2227` keys off `availability == .synced || .availableLocally`, so it follows for free. Use `WorkMaterialBlobRecord.isComplete` as the completeness rule — do not re-derive it.
- **Chip copy: REUSE `workboard.material.syncPending`.** Do not mint a second "Waiting for iCloud…" key.
- **ByteSync agent**: `ConversationStore.swift` store descriptions are UNTOUCHED by me — that is yours (spike §2: two descriptions off the existing `groupURL` local, Blobs wrapped in `#if !os(watchOS)`, both through `configureSyncOptions`, `performLoad()` unchanged, second description for `init(inMemory:storeURL:)`). Assert at load that exactly 2 stores mounted with the expected url/configuration pairing (spike pitfall 1: a mis-pointed configuration mounts silently).
- **Capture agent**: `Constants.workboardDeskItemID` is live; the Watch literal mirror + drift-guard test are NOT done (not my slice).
- `WorkMaterialStoragePolicy` currently has no call sites — wiring the five duplicated `.localVault` decisions to it is the ByteSync/capture slice.
- I deleted NOTHING. `WorkBriefPromptBuilder`/`WorkboardDispatchCoordinator` edits are one-line case additions the purge can drop wholesale.

## Gates run
- iOS `build-for-testing` (iPhone 17 Pro `04DEF4F5…`, no `-configuration`): **BUILD SUCCEEDED**.
- macOS `build` (`platform=macOS`): **BUILD SUCCEEDED** (extra insurance — my two enum extensions touch macOS-gated view code paths).
- Targeted tests: `WorkMaterialStoragePolicyTests` 7/7 · `WorkboardModelMigrationTests` 6/6 (4 pre-existing + 2 new) → **13 executed, 0 failures**.
- `scripts/check-storage-seam.sh` ✓ (774 files, no raw store access). `git diff --check` clean. Catalog JSON parses.
- derivedData `~/Library/Caches/gigaduck-builds/desk-foundation` removed via `/Users/peterkruck/repos/GigaDuck/.claude/scripts/clean-build-cache.sh desk-foundation` (note: the script lives in the MAIN repo `.claude/`, not in this worktree).
- No commits, no pushes, no stash. Identity-Override symlink untouched.
