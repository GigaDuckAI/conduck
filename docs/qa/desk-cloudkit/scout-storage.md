# Workboard storage / CloudKit sync seam — scout report

Worktree: `/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard`
Branch `feature/agent-workboard` @ 651a859. All paths below are relative to that worktree root unless absolute.

**Headline:** the byte-sync lane already exists in the model and on the read side. `WorkMaterial.payload` is an external-storage Binary attribute in model 14/15, and `WorkMaterialStorageMode` already has a `.syncedPayload` case that every reader handles — but **no writer ever produces it**. This is a switch that was built and left off, not a greenfield feature. Also: models 14 and 15 exist only on this branch (`origin/main` tops out at 13), so nothing shipped depends on them and they can still be edited in place.

---

## 1. VAULT — `WorkAssetVault`

`Conduck/Conduck/Services/Workboard/WorkAssetVault.swift` — `actor`, wrapped in `#if !os(watchOS)` (:16, :347). **Not compiled for the Watch target.**

### API surface (all actor-isolated unless noted)

| Member | Line | Notes |
|---|---|---|
| `static let shared` / `init(baseURL:fileManager:)` | :20, :48 | injected temp dir in tests |
| `nonisolated static var productionBaseURL` | :53 | App Group `…/Application Support/WorkboardAssets/`; `preconditionFailure` if no durable container (:70) |
| `store(_ data:id:suggestedExtension:) -> String` | :77 | in-memory write; iOS `.completeFileProtectionUntilFirstUserAuthentication` |
| `storeFile(at:id:suggestedExtension:) -> String` | :99 | `copyItem`, brackets the security scope |
| `storeFileStreaming(at:id:suggestedExtension:expectedByteCount:onProgress:) -> StoredFile` | :131 | 1 MiB chunks, cancellable, byte count verified (:170) |
| `data(for:) -> Data` | :192 | `.mappedIfSafe` |
| `url(for:) -> URL` | :200 | app-internal only; never hand to an external opener |
| `urls(for: [String]) -> [String: URL]` | :210 | batch resolver — **exists but has no caller** |
| `snapshotFile(for:id:) -> URL` | :224 | per-dispatch temp copy |
| `copy(key:id:) -> StoredFile` | :250 | disk-level card duplication |
| `contains(_:) -> Bool` | :274 | |
| `remove(_:)` | :279 | |
| `markReferenced(_:)` | :289 | clears the staged-key guard after the DB save commits |
| `reclaimUnreferenced(keeping:) -> Int` | :295 | GC against the DB's authoritative key set |
| `nonisolated static makeKey / isSafeKey` | :314, :319 | leaf = `<uuid>.<safeext>` |

### File layout on disk

Flat directory, no nesting: `<AppGroup>/Application Support/WorkboardAssets/<uuid-lowercased>.<ext>`. Extension is sanitized through `WorkCaptureEnvelope.safePathExtension`. Source/display filenames never become filesystem paths (`makeKey` :314-317). `isSafeKey` (:319-326) rejects anything that is not `lastPathComponent`, contains a separator, has a non-UUID stem, or whose extension does not round-trip through the sanitizer.

### Retention / budget

There is **no size budget, no quota, no LRU, no TTL**. Retention is purely referential:
- `stagedKeys` (:41) covers the write→commit publication gap so a just-picked file is not mistaken for a crash orphan; process death clears it.
- `reconcileWorkAssetVault` (`ConversationStore+Workboard.swift:1736-1752`) fetches every `localVaultKey` via a dictionary-result-type request (:1741-1750) and hands the set to `reclaimUnreferenced`. A failed fetch deletes nothing.
- Eager deletion paths: `deleteWorkItem` :693, `insertWorkMaterial` rollback :930-936, `replaceWorkMaterialPayloadFile` :1000-1004, `deleteWorkMaterial` :1047.

### Callers

Only `ConversationStore` (`ConversationStore.swift:1087` stored property; :1349 test-seam init constructs an isolated temp vault) plus the reconcile trigger at `Conduck/Conduck/Views/Workboard/PersonalWorkbenchView.swift:959`. Every vault touch is behind the store actor. Tests: `WorkAssetVaultTests.swift`, `WorkboardPersistenceTests.swift`, `WorkboardLiveRepositorySupportTests.swift`, `ConversationStoreAtomicWorkCaptureTests.swift`.

### `WorkMaterialStorageMode` — what it controls

`Conduck/Conduck/Models/WorkboardRecords.swift:362-373`. **Three cases, not two:**

```swift
case metadataOnly    // text/link/no binary payload
case syncedPayload   // external-binary Core Data asset mirrored in private CloudKit
case localVault      // App-Group vault on the source device; only metadata + opaque key sync
```

- **Write:** `ConversationStore.apply(_:workItemID:storageMode:…)` at `ConversationStore+Workboard.swift:1929` writes `payload` **only** when `.syncedPayload`; :1932-1935 does the same for `thumbnailData`. `workboardSyncedTextContent` (:1955-1964) nils `textContent` for `.localVault` and for file/image kinds, so a file extract never enters the mirrored row.
- **Read:** `loadWorkMaterialPayload` :1190-1209 switches on mode → column (`payload`) vs vault (`data(for: key)`). `localURLForWorkMaterial` :1214-1219 returns nil unless `.localVault`.
- **Availability projection:** `StoredWorkMaterial.record(availableLocalKeys:)` :2202-2212 maps `.metadataOnly → .metadataOnly`, `.syncedPayload → .synced`, `.localVault → .availableLocally | .unavailableOnThisDevice`.
- **UI consumers:** badge + reattach gate `Views/Workboard/WorkboardCaptureCanvas.swift:317-318, 1167-1168, 1511-1516, 1569-1575, 1684`; dispatch block `Views/Workboard/WorkboardDispatchSheet.swift:264-267, 571-574`; `ViewModels/WorkboardViewModel.swift:51-57` (`WorkboardMaterialAvailability.isAvailable`) and :406 (gates selection/dispatch); copy at `PersonalWorkbenchView.swift:583`.

### ★ Load-bearing finding

**`.syncedPayload` is fully implemented on the read/capture/duplicate side and produced by NO writer.** Every ingest forces `.localVault` when bytes exist:

- `+Workboard.swift:739` — streaming file branch, hardcoded `.localVault`
- `:743` — `storageMode = draft.payload == nil ? draft.storageMode : .localVault`
- `:829-830` — same expression in `addWorkMaterial`
- `:879` — `addWorkMaterialFile` hardcodes `.localVault`
- `:982` — `replaceWorkMaterialPayloadFile` hardcodes `.localVault` and nils `payload`

The only `.syncedPayload` rows reachable today are (a) a duplicate of an already-synced row (`duplicateWorkItem` :621-632) and (b) a test fixture (`ConduckTests/WorkboardPersistenceTests.swift:262`), deliberately payload-less to simulate "bytes never arrived from CloudKit".

Also note the `WorkMaterialDraft` default (`WorkboardRecords.swift:473`): `storageMode ?? (payload == nil ? .metadataOnly : .localVault)`.

---

## 2. CORE DATA MODEL — `Conversations 15`

`Conduck/Conduck/Models/Conversations.xcdatamodeld/Conversations 15.xcdatamodel/contents`.
Model root: `usedWithCloudKit="YES"`. `.xccurrentversion` → `_XCCurrentVersionName = Conversations 15.xcdatamodel`.

### `WorkMaterial` full attribute list (:123-145)

All optional, all nil-default, no relationships, no uniqueness constraints:

`byteSize` Integer 64 · `caption` String · `cardSize` String · `createdAt` Date · `filename` String · `height` Integer 32 · `id` UUID · `kind` String · `localVaultKey` String · `mimeType` String · **`payload` Binary `allowsExternalBinaryDataStorage="YES"` (:134)** · `sequence` Integer 32 · `sourceDevice` String · `storageMode` String · `textContent` String · **`thumbnailData` Binary `allowsExternalBinaryDataStorage="YES"` (:139)** · `title` String · `updatedAt` Date · `urlString` String · `width` Integer 32 · `workItemID` UUID.

### External-storage binaries already in the model

- `Attachment.data` (:6) — external
- `Attachment.previewData` (:12) — external
- `Attachment.thumbnailData` (:16) — Binary, **not** external
- `WorkDispatch.briefSnapshotData` (:90) — external
- `WorkMaterial.payload` (:134) — external
- `WorkMaterial.thumbnailData` (:139) — external

Model 14 → 15 diff is exactly one line: `WorkMaterial.cardSize`. Model 13 → 14 adds the three Workboard entities wholesale (including `payload` already external).

### Container setup — `Conduck/Conduck/Services/ConversationStore.swift`

- `init()` :1291-1327 — `cloudKitUsable = !simulator && Constants.hasICloudContainerEntitlement`; picks `NSPersistentCloudKitContainer(name:"Conversations")` (:1298) or plain `NSPersistentContainer`. Store URL = App Group container `Conversations.sqlite` (:1307-1310), load-bearing because the headless App Intent process shares it.
- `configureSyncOptions(on:cloudKit:)` :1378-1393 — **one store description, and no `configurations:` argument appears anywhere in the codebase.** The single default configuration therefore carries every entity, so `WorkItem`/`WorkMaterial`/`WorkDispatch` all mirror. Attaches `NSPersistentCloudKitContainerOptions(containerIdentifier: Constants.iCloudCloudKitContainerID)` (:1383-1385); `NSPersistentHistoryTrackingKey` + `NSPersistentStoreRemoteChangeNotificationPostOptionKey` always on (:1388-1392).
- Test/QA seams use plain `NSPersistentContainer` with CloudKit off (:1266-1275 screenshot mode; :1347-1370 `init(inMemory:storeURL:)`). Comment at :1338-1346 explains why: `NSPersistentCloudKitContainer` rejects `NSInMemoryStoreType` with NSCocoaError 134060 and reaches `CKContainer.default()` (fatal-asserting on an unentitled host) for the on-disk variant.
- `hasICloudContainerEntitlement` (`Conduck/Conduck/Utilities/Constants.swift:76-98`) is `#if os(macOS)`-probed via `SecTaskCopyValueForEntitlement`, and a constant `true` on every other platform → **the watchOS app attaches CloudKit mirroring on device and mirrors `WorkMaterial`.**
- `viewContext` is deliberately unconfigured and unused (:1474-1482). Every read and write runs on a fresh `newBackgroundContext()` inside `perform`. `newWriteContext()` :1593-1597 sets `NSMergeByPropertyObjectTrumpMergePolicy`; `newReadContext()` :1605-1607 sets none (read-only contexts never save).
- Remote-change fan-in: `.NSPersistentStoreRemoteChange` observer :1505-1521 → `RemoteChangeDebouncer` → `.conversationsDidChange` (coalesced, ≤1/s under a storm).

### Does Chat sync attachment bytes today? Yes — this is the reuse precedent

`Attachment.data` is external-binary on a mirrored entity, written at `ConversationStore.swift:3246` (`attachment.setValue(draft.data, forKey: "data")`). It works because the bytes are **bounded before they reach Core Data**:

- Images are re-encoded through `ImageProcessor` at `defaultMaxPixel = 1568` (`Conduck/Conduck/Services/ImageProcessor.swift:81`; call sites `ConversationDetailViewModel.swift:4439-4454`, `ComposerAttachmentCoordinator.swift:496`).
- Text files ride inline only under `textInlineMaxBytes` (32 KB); `Constants.textProbeMaxBytes = 10 MB` bounds even the text-vs-binary probe.
- Genuinely large files never enter Core Data at all: they become `isServerReference` rows with a `storedKey` pointing at the user's own gateway file server (`Conduck/Conduck/Models/AttachmentRecord.swift:51-59`; `ConversationStore.swift:1985-2015` handles the lane-less clone case).

So the precedent proves external-binary → CKAsset mirroring works in this app. It does **not** prove ~100 MB works — nothing Chat stores in Core Data is anywhere near that.

---

## 3. MIGRATION HARNESS

`Conduck/ConduckTests/WorkboardModelMigrationTests.swift` (264 lines). **Programmatic — no fixture stores checked in.**

Two test shapes per version pair:

1. **Schema contract.** `requiredModel(named: "Conversations 15.mom")` (:236-246) loads the compiled `.mom` out of `Conversations.momd` in `Bundle.main` or the test bundle, then asserts set-differences over `entitiesByName` / `attributesByName`.
   - v13→v14 (:37-83): added entity set must equal exactly `{WorkItem, WorkMaterial, WorkDispatch}`; every pre-existing entity's attribute and relationship key sets unchanged; every new attribute `isOptional` with `defaultValue == nil`; `relationshipsByName.isEmpty`; `uniquenessConstraints.isEmpty`. Explicit `allowsExternalBinaryDataStorage` assertions for `WorkMaterial.payload` (:70), `WorkMaterial.thumbnailData` (:71), `WorkDispatch.briefSnapshotData` (:72-76).
   - v14→v15 (:147-179): entity sets equal; added attribute set must equal `["cardSize"]` on `WorkMaterial` and `[]` on everything else; no shipped column dropped.

2. **Real SQLite round trip.** `loadStore(model:)` (:248-263) builds an `NSPersistentContainer` with an explicit `NSManagedObjectModel` over a per-test temp `storeURL`, with `shouldMigrateStoreAutomatically = true` and `shouldInferMappingModelAutomatically = true`. Pattern: write rows with model vN → `persistentStoreCoordinator.remove(store)` → reload the same file with vN+1 → assert old values intact, new column nil, and that a write to the new column succeeds (:85-145, :181-234). `tearDown` removes the `.sqlite`, `-wal`, `-shm` (:26-35).

### What adding `Conversations 16` requires

1. Copy `Conversations 15.xcdatamodel/` to `Conversations 16.xcdatamodel/`, edit its `contents`.
2. Add the new `.xcdatamodel` to the `.xcdatamodeld` group in `Conduck/Conduck.xcodeproj` (the momd compile phase compiles what is in the group — a directory that is not referenced silently never becomes a `.mom`, and `requiredModel` would then fail).
3. Flip `.xccurrentversion`'s `_XCCurrentVersionName` string to `Conversations 16.xcdatamodel`.
4. Add two tests mirroring :147 (schema delta) and :181 (SQLite round trip).

Lightweight inference covers a new optional attribute **or** a new relationship-free entity — no mapping model needed.

**Invariants the new version must satisfy or existing tests fail:** every attribute optional; every `defaultValue` nil; no relationships on Workboard entities (:57-58); no uniqueness constraints (:59-60, :176-178).

### ★ Nothing shipped depends on model 15

`git ls-tree origin/main` on the `Conduck` submodule shows model versions only up to `Conversations 13`. Models 14 and 15 exist **only** on `feature/agent-workboard`. Model 13 is the Production-deployed CloudKit schema. Consequence: 14 and 15 can still be **edited in place** rather than superseded by a 16, and reshaping them breaks no installed base. A CloudKit Production schema deploy is still required before any build carrying the Workboard entities reaches users — including the entities as they stand today.

---

## 4. STORAGE SEAM — `scripts/check-storage-seam.sh`

206 lines. Guards three things, **none of which is Core Data**:

1. **Raw store APIs** (:67-75) — `UserDefaults(suiteName:)` / `.init(suiteName:)`, `NSUbiquitousKeyValueStore.default|.init(|()`, `SecItemCopyMatching|Add|Update|Delete`, `.ubiquityIdentityToken` — allowed only in `Conduck/Conduck/Services/Storage/LiveStorage.swift`.
2. **Adapter boundary** (:83-90) — `LiveDefaultsStore(`, `LiveUbiquitousStore(`, `LiveSecretStore(`, `LiveCloudAvailability(`, `LiveKVSChangeSource(`, `SettingsDependencies.live(` — same restriction, with one allowlisted consumer (`MascotCatalog.swift`).
3. **App-Group container directory** (:100-120) — `containerURL(forSecurityApplicationGroupIdentifier:)` must be on a by-file allowlist. `WorkAssetVault.swift` is already on it (:109) with a reason, as is `WorkboardUploadJournal.swift` (:112), `WorkCaptureInbox.swift` (:106), `ConversationStore.swift` (:114), both share extensions (:118-119).

Matching is whole-file `perl -0777` with comments and string literals blanked out (:131-146), so line-wrapped call sites and doc-comment mentions behave correctly. It asserts ≥100 Swift files were scanned (:54-58) so a moved source root fails rather than passing vacuously.

**Implication for byte sync:** a path that goes through Core Data touches nothing this script checks and passes trivially. It only bites if new code opens the App Group container directly — e.g. a separate blob-cache directory outside `WorkAssetVault` — which would need a new `CONTAINER_ALLOWLIST` entry with a stated reason.

---

## 5. SYNC / ACCOUNT STATE

`Conduck/Conduck/Services/CloudSyncMonitor.swift` (346 lines) — `@MainActor @Observable`, `static let shared`. This already exists and is the natural architectural hang point.

- **Event observation:** `NSPersistentCloudKitContainer.eventChangedNotification` (:164-176), completed events only (`event.endDate != nil`). Plus `.CKAccountChanged` (:179-185) → `refreshAccountStatus()`.
- **Suspended-window catch-up:** `ConversationStore.recentSyncEventSummaries(limit:)` (`ConversationStore.swift:1532-1545`) runs an `NSPersistentCloudKitContainerEventRequest.fetchEvents(after: .distantPast)` on a fresh background context and returns only `Sendable` snapshots. Returns `[]` when the container is not a CloudKit container. Log-only — historical events never promote UI (:265-271).
- **`SyncEventSummary`** (`ConversationStore.swift:76-118`) lives in `ConversationStore.swift` so it compiles for watchOS too. Carries kind / succeeded / dates / errorDomain / errorCode / storeID and **already carries `isQuotaExceeded`** — `nsError.domain == CKErrorDomain && nsError.code == CKError.Code.quotaExceeded.rawValue` (:109-110). Never carries `localizedDescription`.
- **Published state:** `iCloudUnavailable: Bool`, `unavailableReason: Reason?` where `Reason ∈ {noAccount, restricted, quotaExceeded}` (:49-95), plus a sticky-per-episode `bannerDismissed` persisted to the App-Group flag. `showsBanner` (:107). Localized banner + Settings copy for all three reasons already exist (:55-94).
- **Classification:** `static func actionableReason(for: CKAccountStatus) -> Reason?` (:233-240) is pure and unit-tested; `.available`, `.couldNotDetermine`, `.temporarilyUnavailable` all return nil so transient states never alarm. Quota is promoted on a **live failed** event only (:260-262).
- **Inert paths:** no container entitlement → logs once and wires nothing (:154-157); Simulator → `#if !targetEnvironment(simulator)` guards; `-ConduckQAForceICloudUnavailable` QA override (:140-144, :195).
- **No force-sync exists** (:22-25) — `NSPersistentCloudKitContainer` exposes no public force-fetch/force-export; the monitor surfaces state and never commands sync.
- Redacted ring buffer of the last 50 events in App-Group defaults, coalesced ~1 s off the main thread (:282-324), readable by Diagnostics.

**Where a "waiting for iCloud" / "device only" indicator hangs:** `CloudSyncMonitor.shared` is `@MainActor @Observable`, so a Workboard card badge or board-level banner can read `iCloudUnavailable` / `unavailableReason` directly. The per-material "bytes have not arrived yet" state is precisely `storageMode == .syncedPayload && payload == nil` — a condition `captureWorkDispatch` already treats as a hard failure (`+Workboard.swift:1317-1320` → `WorkboardStoreError.materialPayloadUnavailable`) and which `duplicateWorkItem` (:621-624) refuses on. The two systems meet cleanly; nothing new is needed at the account layer.

---

## 6. SIZE ACCOUNTING + EVERY BYTE-INGEST ENTRY POINT

### How byte size is tracked

`WorkMaterial.byteSize` (Integer 64, mirrored) is the single authority. Written once in `apply(...)` at `+Workboard.swift:1938`. Sources, in order of preference at each call site:

- the streamed copy's **verified** byte count from `storeFileStreaming` (`+Workboard.swift:738`, `:880`, `:985`) — `storeFileStreaming` throws unless `copied == expectedByteCount` (`WorkAssetVault.swift:170-172`);
- `draft.byteSize` (caller-supplied, e.g. `resourceValues(forKeys:[.fileSizeKey])`);
- `payload.count` (:742, :828).

`WorkAssetVault.copy` re-stats the destination from disk (:264-265). There is **no aggregate accounting** anywhere — nothing sums material bytes per board or per account.

### Every byte-ingest entry point

| # | Surface | Path | Bytes arrive as |
|---|---|---|---|
| 1 | Canvas drop / file picker / photo picker / camera / screenshot | `Views/Workboard/WorkboardCaptureCanvas.swift:1870-1930` (`WorkboardImportMapping.imports`) → `WorkboardMaterialImport` → `Services/Workboard/WorkboardLiveRepository.swift:658-777` (`importMaterial`) | in-memory `data:` for Transferable images (:1878-1885) **or** `fileURL:` (:1886-1908) |
| 1a | ↳ first material on a provisional card | `store.createWorkItemWithInitialMaterial` `+Workboard.swift:709-809` | `sourceFileURL` → `storeFileStreaming` (:730); else `payload` → `vault.store` (:746) |
| 1b | ↳ subsequent material | `addWorkMaterialFile` :854-884 / `addWorkMaterial` :814-849 | |
| 2 | Reattach / replace on an unavailable card | `WorkboardCaptureCanvas.swift:754-772` → `WorkboardLiveRepository.replaceMaterial` :838-879 → `replaceWorkMaterialPayloadFile` :948-1007 | `fileURL`, streaming |
| 3 | Share extension (iOS + macOS), menu-bar capture, GigaAction, Shortcuts | `WorkCaptureInbox` App-Group envelope → `Services/Workboard/WorkCaptureDrainer.swift:111-173` (`persist`) → `addWorkMaterialFile` :159 | file URL already inside the App Group; **never held in appex memory** (`ConduckShareExtension/ShareViewController.swift:883` is a pure `copyItem`) |
| 4 | Chat turn → Work capture | `+Workboard.swift:344-415` — `loadLocalAttachmentPayloads` then `addWorkMaterial` :415 | in-memory `payload:` (:382), already-bounded chat bytes; server references become `.metadataOnly` notes (:353-374) |
| 5 | Card duplication | `duplicateWorkItem` :611-650 | `vault.copy` (:640) for `.localVault`; payload re-insert (:622-632) for `.syncedPayload` |
| 6 | Watch | `ConduckWatch Watch App/WorkboardCaptureIntent.swift` | **text only** — 16 000-char cap, no byte lane, `WorkAssetVault` not compiled for watchOS |

Text-only lanes (no bytes): `WorkboardTextMaterialSheet.swift:136, 148`; `WorkboardViewModel.swift:1399` (`addWorkspaceThought`); drainer note/url branches (`WorkCaptureDrainer.swift:339-365`).

### Existing ceilings in the codebase

- `WorkCaptureEnvelope.maximumFileBytes = 256 MB`, `maximumEnvelopeBytes = 512 MB` (`Conduck/Conduck/Models/WorkCaptureEnvelope.swift:29-30`), enforced in the share extension at `ShareViewController.swift:723-727`.
- `Constants.fileTransferSoftConfirmBytes = 100 MB` (`Constants.swift:1728-1732`) — already drives a "this is a large file" confirmation in the Workboard import path (`WorkboardCaptureCanvas.swift:1844-1846`, `hasLargeFiles` :1850).
- `Constants.textProbeMaxBytes = 10 MB`, `webPageCaptureMaxBytes = 128 KB`, `maxAudioSize = 15 MB`.

### Where a ≤ceiling policy check belongs

The storage-mode decision is currently duplicated at five sites (`:739`, `:743`, `:829-830`, `:879`, `:982`). Collapse them into one `WorkMaterialStoragePolicy.mode(kind:byteSize:)` helper and the ceiling is enforced everywhere by construction — including lane 3 (share/drainer), which has no UI to warn from and is the lane most likely to carry a 200 MB file.

Note the interaction: a 100 MB sync ceiling sits **below** the 256 MB share cap, so lane 3 will routinely still produce local-vault-only materials. The `.localVault` + reattach path stays first-class, not a legacy branch.

---

## 7. DESIGN OPTIONS

### Shape A — flip the existing `.syncedPayload` lane on

Writers choose `.syncedPayload` under the ceiling; `apply` already writes `payload`; `loadWorkMaterialPayload`, `captureWorkDispatch`, `duplicateWorkItem` and the availability projection already handle it. The vault becomes a read-through cache, or is skipped entirely for synced rows. Cost: near-zero new code, no model change, no migration.

### Shape B — `WorkMaterialBlob`, 1:1 with `WorkMaterial` by UUID foreign key

Big binary lives on its own entity and therefore its own CKRecord; `WorkMaterial` keeps only metadata. Suggested columns: `materialID` UUID, `payload` Binary (external), `byteSize`, a content hash, `createdAt`/`updatedAt`.

### Do current fetches fault bytes in? Yes — this is the deciding fact

`fetchWorkItems` does `context.fetch(materialRequest).map(StoredWorkMaterial.init)` (`+Workboard.swift:1605-1611`), and `StoredWorkMaterial.init` reads `thumbnailData` (:2187) for **every** material on **every** board load. Core Data faulting is object-level: once any property is touched the row is realized, and `allowsExternalBinaryDataStorage` only relocates the bytes on disk — it does not make an unread attribute free. Under A, a board holding twenty 80 MB materials realizes twenty payloads on a refresh.

### Recommendation: **B**

Codex (gpt-5.6, independent read-only pass over this repo) reached the same conclusion unprompted, and added two points worth keeping:

- **One managed object = one CKRecord.** Under A, a caption edit and a 100 MB asset share an export and a last-writer-wins conflict domain. Apple does not document whether `NSPersistentCloudKitContainer` avoids restaging an unchanged asset — so do not claim every caption edit re-uploads 100 MB, but B makes the question moot.
- **~100 MB is not a documented native CKAsset ceiling.** Apple publishes no current maximum for native CKAsset; the archived Web Services limit is 50 MB. Treat 100 MB as unproven: make the ceiling a conservative, production-tested, founder-tunable constant with `.localVault` fallback above it.

B also fits the house pattern exactly — relationship-free UUID foreign keys, newest-wins dedup, explicit orphan sweep (the blob table gets the same `reclaimUnreferenced` treatment the vault already has).

**What B does NOT buy:** lazy cloud download or quota savings. Mirroring imports the blob record and its asset on every device, and private-database storage counts against the user's iCloud quota.

**A is acceptable only if** the board path first switches to an explicit `propertiesToFetch` dictionary projection excluding `payload` — merely not reading the property is insufficient. That is a larger and riskier edit to the hot path than adding an entity.

---

## 8. RISKS

1. **Object-level faulting on the hot path.** `StoredWorkMaterial` touching `thumbnailData` (`+Workboard.swift:2187`) realizes the whole row for every material on every board load. Strongest argument against shape A, and a standing hazard whatever shape lands — `thumbnailData` is itself external-binary.

2. **512-thread deadlock precedent.** `fetchRecentForPicker` (`ConversationStore.swift:2419`) produced a libdispatch deadlock under agent load. The board fetch is the same species: a wide `perform` plus a **per-key actor hop loop** at `+Workboard.swift:1648-1651` — `await workAssetVault.contains(key)` once per material — even though the batch resolver `WorkAssetVault.urls(for:)` (:210) exists and is unused. Adding a second per-material availability probe (blob present? asset downloaded?) without batching walks straight back into it. Same shape at the single-row read `:1575-1578`.

3. **CloudKit dedup / merge.** No uniqueness constraints are permitted (asserted `WorkboardModelMigrationTests.swift:59-60, 176-178`). One logical UUID can import as several physical rows; `deduplicatedWorkItems` / `deduplicatedWorkMaterials` (`+Workboard.swift:1690-1729`) project newest-wins without deleting either CloudKit record, and `rewriteWorkMaterialSequence` (:1799-1810) deliberately writes **every** matching row. A 1:1 blob entity inherits all of this: it can arrive before or after its material, arrive twice, or arrive orphaned — the reader must tolerate all three, and the orphan sweep must handle a blob whose material never arrives. `NSMergeByPropertyObjectTrumpMergePolicy` (`ConversationStore.swift:1595`) is per-property, so a local metadata edit racing an imported blob is fine, but two devices attaching different bytes to the same material id is genuinely last-writer-wins with no user-visible conflict surface.

4. **watchOS.** The Watch attaches CloudKit mirroring on device (`Constants.swift:96-97` returns a constant `true` off macOS) and compiles the shared store, so it mirrors `WorkMaterial` — and would mirror a blob entity in the same configuration. `WorkAssetVault` is `#if !os(watchOS)`, so the wrist has no fallback store and no eviction path. Options: exclude the blob entity via a second store configuration (which means a second `NSPersistentStoreDescription`; note `NSPersistentCloudKitContainer` validates **every** description — see the 134060 note at `ConversationStore.swift:1340-1346`), or accept CKAssets landing on the watch. This deserves an explicit decision, not a default.

5. **Share-extension memory is currently fine — don't regress it.** The appex is ~120 MB-capped (`ShareViewController.swift:14, 52, 272`) and today never materializes payload bytes (pure `copyItem`, :883; ImageIO thumbnails only, :388-390). Any "hash it / thumbnail it before choosing the lane" logic must live in the app-side drainer, not the extension.

6. **Model-15 / Production interaction.** Nothing shipped depends on models 14 or 15 — `origin/main` is at 13, and 13 is the Production-deployed CloudKit schema. Editing 14/15 in place is still free. But no build carrying the Workboard entities (with or without byte sync) can reach users until the schema is deployed to CloudKit Production, and adding a blob entity changes what gets deployed.

7. **The 100 MB number is unproven** (see §7), and the share lane already admits 256 MB, so users will hit the ceiling regularly. Make it tunable and make the `.localVault` + reattach experience good.

8. **No aggregate byte accounting.** Nothing sums material bytes per board or per account, so "you are about to fill your iCloud" cannot be surfaced proactively today. `quotaExceeded` is only learned reactively, from a failed export event (`CloudSyncMonitor.swift:260-262`).
