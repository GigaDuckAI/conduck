# spike — Gate 1 (plan §C). VERDICT: **FEASIBLE**

Repo untouched (`git status --porcelain` empty in worktree AND in `Conduck/`). All harness code lived under `~/Library/Caches/gigaduck-builds/desk-spike/`, cleaned at end. No build was warranted (zero repo lines changed); the two harnesses compiled with `swiftc` and ran green.

---

## (a) PROOF — headless, two harnesses, 90 assertions, 0 failures

### Harness 1 — synthetic mini-model (`spike.swift`, 57 pass / 0 fail)
Programmatic `NSManagedObjectModel`s mimicking the real shape (all-optional attributes, nil defaults, no relationships, no uniqueness constraints, `allowsExternalBinaryDataStorage` on payload/thumbnail).

### Harness 2 — the **REAL** compiled models (`realmodel.swift`, 33 pass / 0 fail) ← this is the load-bearing one
- `out15.mom` = `Conversations 15.xcdatamodel` **verbatim**, compiled with `xcrun momc`.
- `out16.mom` = that same XML + entity `WorkMaterialBlob` + two `<configuration>` elements, compiled with `xcrun momc`.

**Proven with the real models:**
1. Model 15 declares **no** named configurations (`configurations == []`) — the shipped store is a default-configuration store.
2. Model 16 declares exactly `["Blobs", "Core"]`; `Core` == the exact 7 model-15 entities (`Attachment, Conversation, GatewayAttempt, Message, WorkDispatch, WorkItem, WorkMaterial`); `Blobs` == `["WorkMaterialBlob"]`.
3. **Every one of the 7 pre-existing entities keeps an IDENTICAL `versionHash` 15→16.** Adding an entity + configurations does not perturb them, so the `Core` store opens with a *no-op* migration.
4. A real v15 SQLite store created under the **default** configuration (rows in `Conversation`/`WorkItem`/`WorkMaterial`/`WorkDispatch`, including external-binary `thumbnailData` and the model-15-only `cardSize` column) **reopens under `description.configuration = "Core"` in v16 with zero errors and every value intact.**
5. Two-SQLite topology (`Conversations.sqlite` = Core, `ConversationBlobs.sqlite` = Blobs) on ONE `NSPersistentContainer`/one coordinator: both stores mount; blob and material both save **from the same context in one save**, with **no `context.assign(_:to:)` needed** (Core Data routes by configuration membership); `objectID.persistentStore` confirms each row landed in the right physical file; 5 MB external payload round-trips; close → reopen → all intact; a second v16 load is a clean no-op re-migration.
6. Availability projection works: `NSFetchRequest<NSDictionary>` with `resultType = .dictionaryResultType` and `propertiesToFetch = ["materialID","byteSize","contentHash","updatedAt"]` returns metadata and **no `payload` key** — plan §C's "ONE batch fetch that never projects payload" is directly implementable.
7. Paired cross-store delete (material + its blobs) commits in one `save()`.

**Also proven in harness 1:** genuine lightweight migration of `Core` (adding an optional column changes `WorkMaterial`'s version hash, old rows survive, new column nil, writes succeed); 30 MB external payload saves and reads back whole; blob external files land in `.ConversationBlobs_SUPPORT/_EXTERNAL_DATA` **beside the Blobs sqlite**, not the Core one; deleting the Blobs sqlite while Core survives → container reloads fine, Core rows untouched, Blobs recreated empty (materials degrade to `.syncedPending`, exactly the plan's protocol); two independent coordinators over the same file pair see each other's writes.

### `momc` CloudKit validation is LIVE and per-configuration (non-vacuous control)
Making one blob attribute non-optional produced:
`WorkMaterialBlob.contentHash: error: WorkMaterialBlob.contentHash must have a default value [8]`
So model 16 compiling clean is real evidence that `Blobs` is a valid CloudKit configuration.

---

## THE RECIPE (Foundation + ByteSync agents: replicate exactly)

### 1. `Conversations 16.xcdatamodel/contents` — append BEFORE `</model>`
`momc` accepts `<configuration>` elements verbatim; entity XML stays where it is (alphabetical among entities), configurations go last.

```xml
    <entity name="WorkMaterialBlob" representedClassName="WorkMaterialBlob" syncable="YES" codeGenerationType="class">
        <attribute name="byteSize" optional="YES" attributeType="Integer 64" usesScalarValueType="NO"/>
        <attribute name="contentHash" optional="YES" attributeType="String"/>
        <attribute name="createdAt" optional="YES" attributeType="Date" usesScalarValueType="NO"/>
        <attribute name="materialID" optional="YES" attributeType="UUID" usesScalarValueType="NO"/>
        <attribute name="payload" optional="YES" attributeType="Binary" allowsExternalBinaryDataStorage="YES"/>
        <attribute name="updatedAt" optional="YES" attributeType="Date" usesScalarValueType="NO"/>
    </entity>
    <configuration name="Core" usedWithCloudKit="YES">
        <memberEntity name="Attachment"/>
        <memberEntity name="Conversation"/>
        <memberEntity name="GatewayAttempt"/>
        <memberEntity name="Message"/>
        <memberEntity name="WorkDispatch"/>
        <memberEntity name="WorkItem"/>
        <memberEntity name="WorkMaterial"/>
    </configuration>
    <configuration name="Blobs" usedWithCloudKit="YES">
        <memberEntity name="WorkMaterialBlob"/>
    </configuration>
```

★ **`byteSize` must be `usesScalarValueType="NO"` with NO `defaultValueString`.** My first attempt copied `Attachment.byteSize`'s `defaultValueString="0" usesScalarValueType="YES"` and got `defaultValue == Optional(0)`, which would fail the codebase's own convention — `WorkboardModelMigrationTests.swift:63-64` asserts every new attribute `isOptional` **and** `XCTAssertNil(attribute.defaultValue)`. `WorkMaterial`'s own Integer columns already follow the `usesScalarValueType="NO"`/no-default form; match those, not `Attachment`'s.
★ `usedWithCloudKit="YES"` stays on `<model>` AND goes on each `<configuration>`. Both survive `momc`.
★ Also flip `.xccurrentversion`'s `_XCCurrentVersionName` to `Conversations 16.xcdatamodel`.

### 2. `ConversationStore.init()` — store descriptions
`container.persistentStoreDescriptions.first` is no longer enough; build the array explicitly.

- Core description: **same URL as today** (`groupURL/Conversations.sqlite` — do NOT rename, it is the shipped file), `configuration = "Core"`.
- Blobs description: `groupURL/ConversationBlobs.sqlite`, `configuration = "Blobs"`, **wrapped in `#if !os(watchOS)`** — that omission IS the watch exclusion (the watch compiles the same `ConversationStore.swift`).
- Run BOTH through the existing `configureSyncOptions(on:cloudKit:)` so history tracking + remote-change posting + `cloudKitContainerOptions` are attached identically. Set `container.persistentStoreDescriptions = [core, blobs]`.
- `performLoad()` already counts descriptions and resolves only after the LAST one lands (`:1437-1465`) — **no change needed there.** It is already multi-store correct.
- The `init(inMemory:storeURL:)` test seam needs the same two-description treatment for the on-disk case (in-memory: `/dev/null` for both won't work — give the blob store its own `/dev/null`-equivalent or a sibling temp URL; harness 1 shows a missing/fresh Blobs file is harmless).

`ConversationBlobs.sqlite` is my suggested filename, not a binding one — pick whatever you like, but it must differ from `Conversations.sqlite` (see pitfall 1). **`scripts/check-storage-seam.sh` needs no change**: derive the second URL from the SAME `groupURL` local that already exists, so no new `containerURL(forSecurityApplicationGroupIdentifier:)` call appears, and `ConversationStore.swift` is already on the App-Group allowlist.

### 3. Writes need NO `context.assign(_:to:)`
Because `WorkMaterialBlob` is a member of exactly one configuration, Core Data routes inserts automatically (proven, R2). Use `affectedStores` only if a fetch must be scoped for performance.

### 4. Proving model 16 registration from the compiled `.momd` (plan §C / Codex #11)
**Evidence gathered, and it supports "no pbxproj edit":** the project uses `PBXFileSystemSynchronizedRootGroup` (8 of them) with no per-file build-phase entries. `Models/Conversations.xcdatamodeld` and `Services/ConversationStore.swift` each appear **exactly once** in `project.pbxproj`, both inside `PBXFileSystemSynchronizedBuildFileExceptionSet` *"Exceptions for \"Conduck\" folder in \"ConduckWatch Watch App\" target"* (`project.pbxproj:219`, `:233`). Two consequences:
- The entry names the **`.xcdatamodeld` directory**, not individual `.xcdatamodel` versions — so adding `Conversations 16.xcdatamodel` inside it needs **no pbxproj edit for the app OR the watch**.
- It also confirms the watch target compiles `ConversationStore.swift` and embeds the model, which is why `#if !os(watchOS)` around the Blobs description is the correct exclusion lever (the file already carries seven such guards).

Still prove it rather than assume — after an iOS build:
```
find ~/Library/Caches/gigaduck-builds/<slug> -name 'Conversations.momd' -exec ls {} \;
```
`Conversations 16.mom` must be listed. `WorkboardModelMigrationTests.requiredModel(named:)` (`:236-246`) loads out of that same `.momd`, so if it isn't there the new v15→v16 tests fail loudly — that test IS the proof gate.

---

## Documented pitfalls found (bind the implementers)

1. **A mis-pointed configuration does NOT error.** Opening the Core sqlite with `configuration = "Blobs"` succeeded silently (0 errors) and presented an empty blob table. Core Data validates only the entities the configuration names. Consequence: a typo'd URL silently forks the topology and starts writing blob rows into `Conversations.sqlite`. Mitigation: distinct filenames (done), and assert at load time that `persistentStoreCoordinator.persistentStores.count == 2` with the expected `url.lastPathComponent`/`configurationName` pairing.
2. **No cross-configuration relationships, ever.** Documented Core Data rule; the plan's UUID foreign key already complies. Do not "improve" it into a relationship.
3. **Two stores never commit atomically.** Proven only that both save in one `save()` call — that is one coordinator transaction per store, not a distributed one. Plan §C's crash-repairable publication protocol (blob durable → material → ack) is required, not optional.
4. **External files are per-store.** Blob externals live in `.ConversationBlobs_SUPPORT/_EXTERNAL_DATA`. Anything that copies/backs up/wipes the store must handle the second `_SUPPORT` directory too. Same for the existing `tearDown`-style cleanups (`.sqlite`, `-wal`, `-shm` × 2, plus 2 `_SUPPORT` dirs).
5. **`CloudSyncMonitor` needs no structural change, but doubles its event rate.** `SyncEventSummary` already carries `storeID` (`ConversationStore.swift:90`) and `NSPersistentCloudKitContainerEventRequest.fetchEvents` returns events for every mirrored store, so the plumbing is store-aware today. Two consequences: the `cloudSyncEventLog` ring buffer now holds ~2× the events per unit time (consider its capacity), and the desk banner must stay driven by account-level state (`noAccount`/`restricted`/`quotaExceeded` — all account-wide, so unaffected) rather than by "the last event failed", which could now be a Blobs-store event about a material the user isn't looking at.
6. **Losing the Blobs sqlite is survivable but silent** — Core rows keep `storageMode == "syncedPayload"` with no blob. The `.syncedPending` availability path is what makes this non-corrupting; do not add an orphan/consistency sweep (plan §C forbids it).

---

## (b) RESEARCH — CloudKit, two mirrored stores, one container

### DOCUMENTED
| Fact | Source |
|---|---|
| Multiple stores via model configurations is an officially supported `NSPersistentCloudKitContainer` pattern; you add configurations in the model editor, tick "Used with CloudKit" per configuration, and set each store description's `configuration` + `cloudKitContainerOptions`. **"Repeat for each configuration that you want to sync."** | [Setting Up Core Data with CloudKit → "Manage multiple stores"](https://developer.apple.com/documentation/coredata/setting-up-core-data-with-cloudkit) |
| The exact motivating use case is ours, in Apple's words: *"If you need to synchronize part of a large data set to iCloud, your app can organize the data in two stores to mirror one to CloudKit and keep the other on the local device."* Apple ships a working two-store / two-configuration / one-`NSPersistentContainer` sample with the same `description.configuration = …` recipe I proved. | [Linking Data Between Two Core Data Stores](https://developer.apple.com/documentation/coredata/linking-data-between-two-core-data-stores) |
| `initializeCloudKitSchema` **"Creates the CloudKit schema for all stores in the container that manage a CloudKit database"** — it is multi-store aware and validates each store's model. | [initializeCloudKitSchema(options:)](https://developer.apple.com/documentation/coredata/nspersistentcloudkitcontainer/initializecloudkitschema(options:)) |
| Two stores CAN share one `containerIdentifier`: Apple's sharing sample runs `.private` and `.shared` stores against `gCloudKitContainerIdentifier`, one identifier, two `NSPersistentCloudKitContainerOptions`. | [Sharing Core Data objects between iCloud users](https://developer.apple.com/documentation/coredata/sharing-core-data-objects-between-icloud-users) |
| Two stores CAN each mirror to CloudKit — WWDC19's example runs `local` + `cloud` + `shared`, the two mirrored ones carrying **different** container identifiers (`iCloud.com.wwdc.demo`, `iCloud.com.wwdc.shared`). | [WWDC19-202 Using Core Data With CloudKit](https://developer.apple.com/videos/play/wwdc2019/202/) |
| Core Data mirrors the private database into a **specific custom zone**, named `com.apple.coredata.cloudkit.zone` in every Apple log sample. | [WWDC19-202](https://developer.apple.com/videos/play/wwdc2019/202/); zone name appears throughout [Reading CloudKit Records for Core Data](https://developer.apple.com/documentation/coredata/reading-cloudkit-records-for-core-data) and TN3164 |
| Large binary attributes are auto-promoted to `CKAsset` (`CD_payload` → `CD_payload_ckAsset`) once a field exceeds roughly 750 KB or the record would breach CloudKit's 1 MB record limit. This is the mechanism byte sync rides on. | [WWDC19-202](https://developer.apple.com/videos/play/wwdc2019/202/) |
| **"The size of a record is limited 1MB. (Record fields of the `CKAsset` type are excluded to this limit.)"** — CKAsset fields do NOT count against the 1 MB record cap. Combined with the auto-promotion above, this is the documented basis for a 30 MB blob riding CloudKit at all. | [TN3164 → "Avoid hitting a CloudKit limit"](https://developer.apple.com/documentation/technotes/tn3164-debugging-the-synchronization-of-nspersistentcloudkitcontainer) |
| A CloudKit container is limited to **1000 record zones**; a record type to 256 fields. | [TN3164 → "Avoid hitting a CloudKit limit"](https://developer.apple.com/documentation/technotes/tn3164-debugging-the-synchronization-of-nspersistentcloudkitcontainer) |
| A debug build that syncs while TestFlight/App Store does not means the **schema was not deployed to production** — this is the single most common shipping failure. (Already plan §G.1.) | [TN3164](https://developer.apple.com/documentation/technotes/tn3164-debugging-the-synchronization-of-nspersistentcloudkitcontainer) |
| Core Data with CloudKit requires an **SQLite** store and a CloudKit-compatible model: **no unique constraints, no undefined attributes, no required relationships.** (`WorkMaterialBlob` satisfies all three.) | [Mirroring a Core Data Store with CloudKit](https://developer.apple.com/documentation/coredata/mirroring-a-core-data-store-with-cloudkit) |

### ★ NOT DOCUMENTED — the one genuine open question for Gate 2
**Two mirrored stores with the SAME `containerIdentifier` AND the SAME `.private` database scope.** Every Apple example differentiates the two stores by *something*: different container identifier (WWDC19) or different `databaseScope` (sharing sample). I could not find the same-container-same-scope case documented anywhere, nor a statement of whether each mirrored store gets its own record zone or both target the single fixed `com.apple.coredata.cloudkit.zone`.

**Weak evidence pointing at ONE shared zone (INFERENCE — treat as a reason to measure, not a conclusion):** TN3164's partial-error dictionaries are keyed `<UUID>:(com.apple.coredata.cloudkit.zone:__defaultOwner__)`, and TN3163 states that the UUID in these logs is the **Core Data store UUID**. So Apple's own error keying is (store, zone) with the zone name a **constant**, not a per-store derivative. That is a single-store sample and proves nothing about the two-store case, but it is the opposite of what you would expect if each store minted its own zone name.

**Why it matters beyond tidiness (INFERENCE, and it is the crux of watch exclusion):** the watch excludes blobs by never mounting the Blobs store. If each store gets its **own** zone, the watch's Core store fetches only its own zone and blob records never reach the wrist — clean exclusion. If both stores share **one** zone, the watch's Core store fetches zone changes that include `CD_WorkMaterialBlob` records, and whether it also pulls their `CKAsset` files before discarding them as unknown record types is unverifiable headlessly. **A shared zone would not break correctness, but it could defeat the entire point of the two-store design.** Gate 2 must measure this directly.

**Contingency if Gate 2 shows a shared zone / leakage (INFERENCE, high confidence):** give the Blobs store its **own** CloudKit container identifier (e.g. `iCloud.ai.gigaduck.conduck.blobs`). That is the exactly-documented WWDC19 pattern, guarantees a separate zone in a separate container, and keeps every privacy claim intact (still the user's own private iCloud, still no backend, still "Data Not Collected"). Cost: a second container provisioned in the Developer portal, added to **both** `Conduck-Community.entitlements` and `Conduck-Official.entitlements`, and a second Production schema deploy. This is a config change, not a redesign — so it does not threaten Gate 1's verdict.

### TN3164 — multiple container instances on one store (VERBATIM, plan §C's TN3164 concern)
Section **"Avoid synchronizing a store with multiple persistent containers"**:

> When using `NSPersistentCloudKitContainer` to load a Core Data store that is already loaded by another `NSPersistentCloudKitContainer` instance, you might see an error like the following example: … `Error Domain=NSCocoaErrorDomain Code=134410 "CloudKit setup failed because there is another instance of this persistent store actively syncing with CloudKit in this process."` … `NSUnderlyingException=Illegal attempt to register a second handler for activity identifier com.apple.coredata.cloudkit.activity.setup.…`
>
> This can happen when your app and extension both use `NSPersistentCloudKitContainer` to manage a shared Core Data store (**even though they are different processes**). When working with an extension, you don't control its lifecycle. It is perfectly possible that your extension is launched when your app is running, or vice versa, and both of them try to load the shared store.
>
> **To avoid the conflict, consider having the app in charge of the synchronization.** An extension that has the capability to present UI can remind users to launch the app to synchronize with CloudKit, if that is an appropriate user experience.
>
> The app and extension can avoid presenting stale data by observing `.NSPersistentStoreRemoteChange` and consuming the persistent history…
>
> The error can also happen when your app unintentionally has multiple `NSPersistentCloudKitContainer` instances that manage the same store. For example, when you set a variable that holds an `NSPersistentCloudKitContainer` instance to a new value, the instance won't be released if a Core Data object tied to the container still exists. To avoid the situation, release all the objects before releasing the `NSPersistentCloudKitContainer` instance.

**Apple's prescribed mitigation, in order:**
1. **One process owns synchronization — the app.** Every other process (App Intent, share extension) loads the store **without** `cloudKitContainerOptions`, i.e. as a plain mirror-less store, and lets the app export later.
2. Non-owning processes stay fresh by observing `.NSPersistentStoreRemoteChange` and consuming persistent history — **already wired in this app** (`ConversationStore.swift:1505-1521` → `RemoteChangeDebouncer` → `.conversationsDidChange`).
3. Never hold two live container instances over one store in one process; release managed objects before releasing a container.

**What this means for Conduck (INFERENCE from the documented text):** the headless `CaptureWorkboardIntent` process shares the App Group sqlite, so it is *already* exposed to 134410 today — the second store doubles the surface but does not create it. The right move is #1: gate `cloudKitContainerOptions` so **only the main app process attaches CloudKit**, and the intent/extension processes load both stores mirror-less (they still write rows; the app exports them on next launch, which is exactly what the inbox/drainer design already assumes). This is a plan-adjacent hardening — flag it to the orchestrator; it is not Gate-1 blocking and it is not in the plan's §C text.
**Do NOT skip step 3 of the publication protocol on the strength of this**: a mirror-less write still needs the blob-then-material ordering.

---

## (c) GATE 2 — founder signed-device checklist (DRAFT; plan §G.2, release-blocking)

Two signed devices on one iCloud account (iPhone + Mac), plus the Watch. Run in order; each step names what you should see.

**Setup**
- [ ] 0. Deploy model 16 to CloudKit **Production** before the release build (plan §G.1, supersedes the model-15 cardSize gate). In the CloudKit Console confirm record type **`CD_WorkMaterialBlob`** exists with fields `CD_materialID`, `CD_byteSize`, `CD_contentHash`, `CD_createdAt`, `CD_updatedAt`, and `CD_payload` **and/or** `CD_payload_ckAsset`.
- [ ] 1. Both stores exist on device: in the App Group container, `Conversations.sqlite` **and** `ConversationBlobs.sqlite`, each with its own `.…_SUPPORT/_EXTERNAL_DATA` directory.

**Export**
- [ ] 2. Device A: record a voice note and drop a large image + a ~25 MB file on the desk. All three cards appear immediately (audio playable before transcript — plan §D).
- [ ] 3. Xcode console, filter subsystem `com.apple.coredata`, message `Observed`: **two distinct store UUIDs** appear, one export activity per store. Neither store logs **134410** ("another instance of this persistent store actively syncing").
- [ ] 4. Export completes with no `134060` ("CloudKit integration is only supported for SQLite stores") and no partial errors.

**★ 5. ZONE CHECK — the load-bearing step.** CloudKit Console → Private Database → Zones. Record what you see:
- [ ] **Two zones** (Core + Blobs distinct) → the design works as intended; watch exclusion is structural. Proceed.
- [ ] **One zone** (`com.apple.coredata.cloudkit.zone` holding both `CD_WorkMaterial` and `CD_WorkMaterialBlob`) → **STOP and report.** Go to step 11 and measure watch leakage before shipping; the fallback is a second CloudKit container identifier for the Blobs store (see §(b)).

**Import**
- [ ] 6. Device B (second Mac/iPhone, same iCloud): the desk arrives. Metadata cards appear FIRST; blobs land after. Before bytes arrive, cards show the **"Waiting for iCloud…"** `.syncedPending` chip and are **not openable/playable** — then flip to available without a relaunch.
- [ ] 7. Play the voice note on device B — the audio is byte-identical (it plays through, not truncated).
- [ ] 8. Delete one material on device A. On device B **both** the card and its blob disappear (paired delete crossed the wire). No orphan blob is left in the Console.

**Delete / reinstall**
- [ ] 9. Delete the app from device B, reinstall, sign in. The desk and **all** blobs reimport. Confirm both sqlite files are recreated and repopulated.
- [ ] 10. Partial-loss drill: with the app closed, delete ONLY `ConversationBlobs.sqlite` (+ `-wal`/`-shm`/`_SUPPORT`). Relaunch — the app must NOT crash; cards return as `.syncedPending`, then refill from CloudKit.

**★ Watch exclusion**
- [ ] 11. On the Watch (signed, same account), after the desk has synced: confirm **no `ConversationBlobs.sqlite`** exists and no blob bytes are on-device. Check watch storage growth against the pre-sync baseline — it must not grow by the payload sizes from step 2.
- [ ] 12. Watch console: no `CD_WorkMaterialBlob` import activity, no CKAsset downloads. If step 5 found ONE zone and the watch DOES pull assets, that is the refutation of the exclusion design → second-container fallback.
- [ ] 13. Capture a note from the Watch: it still lands on the desk (watch upsert path, 16k cap) and syncs up.

**Headless App Intent**
- [ ] 14. With the app **fully quit**, run the Shortcut / `CaptureWorkboardIntent` with an attachment. The intent process writes to the shared store; confirm **no 134410** in the log for either store.
- [ ] 15. Repeat with the app **running in the foreground** — this is the collision case TN3164 names. Confirm no 134410, no duplicate rows, no "Metadata Inconsistency".
- [ ] 16. Launch the app afterwards: the intent's capture appears on the desk exactly once and exports to CloudKit (the inbox claim was acknowledged only after both rows were durable).
- [ ] 17. Kill the app mid-capture (blob written, material not) and relaunch: replay repairs it into one complete card — no duplicate, no bytes lost.

**Quota / account**
- [ ] 18. Sign out of iCloud: the desk banner shows the existing localized `noAccount` copy; local capture keeps working, cards fall back to local availability.

---

## Artifacts preserved (scratchpad, NOT the repo)
`desk-fixnotes/spike-harness/` — `spike.swift`, `realmodel.swift`, and `Conversations-16-contents.xml` (the exact model-16 XML that compiled clean and drove the 33 real-model assertions). Port assertions from these into `ConduckTests/WorkboardModelMigrationTests.swift` rather than rewriting from scratch. The build cache `~/Library/Caches/gigaduck-builds/desk-spike/` was cleaned per the standing rule.

## Codex consult — INCONCLUSIVE
I spent my one consult on the undocumented same-container/same-scope zone question. `codex exec` ran for 20+ minutes without emitting a byte (process alive, output file 0 bytes; a second long-lived `codex` process from another session was also running). Reporting the block rather than swapping models. Nothing in this report depends on it — every DOCUMENTED row above is a primary Apple source I fetched and quoted directly, and the open question is explicitly marked as needing Gate-2 measurement, not a second opinion.

## For the next agents
- **Foundation:** use the XML block above verbatim; `byteSize` has NO `defaultValueString`. Prove `Conversations 16.mom` is in the built `.momd` before claiming registration.
- **ByteSync:** no `context.assign(_:to:)` needed. `performLoad()` is already multi-store correct — don't touch it. Wrap the Blobs description in `#if !os(watchOS)`. Use the `.dictionaryResultType` projection for availability. Handle the second `_SUPPORT` directory anywhere the store is copied/cleaned, and give `init(inMemory:storeURL:)` a second description.
- **Orchestrator:** two items for the record — (1) the zone question is genuinely undocumented and is Gate 2's step 5, with a documented second-container fallback that costs config, not architecture; (2) TN3164's prescribed mitigation (only the app process attaches `cloudKitContainerOptions`) is a hardening the plan's §C does not currently specify, and it addresses a surface that already exists today.

**VERDICT: FEASIBLE**
