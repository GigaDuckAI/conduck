// SPDX-License-Identifier: Apache-2.0

// Gate-1 headless spike: two-configuration / two-SQLite Core Data topology.
// Mimics the Conduck `Conversations` model shape: all attributes optional,
// nil defaults, no relationships, no uniqueness constraints, external binary
// storage on payload/thumbnail columns.

import CoreData
import Foundation

// MARK: - Reporting

var failures: [String] = []
var passes = 0

func check(_ cond: Bool, _ label: String) {
    if cond { passes += 1; print("  PASS  \(label)") }
    else { failures.append(label); print("  FAIL  \(label)") }
}

func section(_ s: String) { print("\n=== \(s) ===") }

// MARK: - Programmatic model builders

func attr(_ name: String, _ type: NSAttributeType, external: Bool = false) -> NSAttributeDescription {
    let a = NSAttributeDescription()
    a.name = name
    a.attributeType = type
    a.isOptional = true
    a.defaultValue = nil
    a.allowsExternalBinaryDataStorage = external
    return a
}

func entity(_ name: String, _ attrs: [NSAttributeDescription]) -> NSEntityDescription {
    let e = NSEntityDescription()
    e.name = name
    e.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
    e.properties = attrs
    return e
}

func coreEntities() -> [NSEntityDescription] {
    let conversation = entity("Conversation", [
        attr("id", .UUIDAttributeType),
        attr("title", .stringAttributeType),
        attr("updatedAt", .dateAttributeType),
    ])
    let workItem = entity("WorkItem", [
        attr("id", .UUIDAttributeType),
        attr("title", .stringAttributeType),
        attr("createdAt", .dateAttributeType),
        attr("ownerRevision", .integer64AttributeType),
    ])
    let workMaterial = entity("WorkMaterial", [
        attr("id", .UUIDAttributeType),
        attr("workItemID", .UUIDAttributeType),
        attr("kind", .stringAttributeType),
        attr("storageMode", .stringAttributeType),
        attr("byteSize", .integer64AttributeType),
        attr("textContent", .stringAttributeType),
        attr("payload", .binaryDataAttributeType, external: true),
        attr("thumbnailData", .binaryDataAttributeType, external: true),
        attr("createdAt", .dateAttributeType),
    ])
    return [conversation, workItem, workMaterial]
}

/// Extra optional column on a pre-existing entity — forces a REAL lightweight
/// migration of the Core store (v1 hashes no longer match).
func coreEntitiesWithAddedColumn() -> [NSEntityDescription] {
    let ents = coreEntities()
    if let m = ents.first(where: { $0.name == "WorkMaterial" }) {
        m.properties = m.properties + [attr("contentHash", .stringAttributeType)]
    }
    return ents
}

func blobEntity() -> NSEntityDescription {
    entity("WorkMaterialBlob", [
        attr("materialID", .UUIDAttributeType),
        attr("payload", .binaryDataAttributeType, external: true),
        attr("byteSize", .integer64AttributeType),
        attr("contentHash", .stringAttributeType),
        attr("createdAt", .dateAttributeType),
        attr("updatedAt", .dateAttributeType),
    ])
}

/// v1 — the shipped shape: every entity in the DEFAULT configuration, no
/// named configurations declared at all.
func modelV1() -> NSManagedObjectModel {
    let m = NSManagedObjectModel()
    m.entities = coreEntities()
    return m
}

/// v2 — adds `WorkMaterialBlob` and declares two named configurations.
/// `Core` = every pre-existing entity, `Blobs` = the new entity only.
func modelV2(migrateCore: Bool = false) -> NSManagedObjectModel {
    let m = NSManagedObjectModel()
    let core = migrateCore ? coreEntitiesWithAddedColumn() : coreEntities()
    let blob = blobEntity()
    m.entities = core + [blob]
    m.setEntities(core, forConfigurationName: "Core")
    m.setEntities([blob], forConfigurationName: "Blobs")
    return m
}

// MARK: - Store plumbing

let root = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("desk-spike-\(UUID().uuidString)", isDirectory: true)
try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

func desc(_ url: URL, configuration: String?, migrate: Bool = true) -> NSPersistentStoreDescription {
    let d = NSPersistentStoreDescription(url: url)
    d.type = NSSQLiteStoreType
    d.configuration = configuration
    d.shouldMigrateStoreAutomatically = migrate
    d.shouldInferMappingModelAutomatically = migrate
    d.shouldAddStoreAsynchronously = false
    // Production parity: both flags are attached to every description.
    d.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
    d.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
    return d
}

/// Load a container over the given descriptions. Returns nil + the errors if
/// any description failed (mirrors `performLoad`'s first-failure-wins shape).
@discardableResult
func load(model: NSManagedObjectModel, _ descriptions: [NSPersistentStoreDescription]) -> (NSPersistentContainer?, [Error]) {
    let c = NSPersistentContainer(name: "Spike", managedObjectModel: model)
    c.persistentStoreDescriptions = descriptions
    var errors: [Error] = []
    c.loadPersistentStores { _, error in if let error { errors.append(error) } }
    return (errors.isEmpty ? c : nil, errors)
}

/// Production-parity teardown: remove every store from the coordinator, the
/// way `WorkboardModelMigrationTests` does before reopening under a new model.
func close(_ c: NSPersistentContainer) {
    let psc = c.persistentStoreCoordinator
    for store in psc.persistentStores { try? psc.remove(store) }
}

func insert(_ ctx: NSManagedObjectContext, _ entityName: String, _ values: [String: Any?]) -> NSManagedObject {
    let obj = NSEntityDescription.insertNewObject(forEntityName: entityName, into: ctx)
    for (k, v) in values { obj.setValue(v, forKey: k) }
    return obj
}

func count(_ ctx: NSManagedObjectContext, _ entityName: String) -> Int {
    let r = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
    return (try? ctx.count(for: r)) ?? -1
}

func fetchAll(_ ctx: NSManagedObjectContext, _ entityName: String) -> [NSManagedObject] {
    let r = NSFetchRequest<NSManagedObject>(entityName: entityName)
    return (try? ctx.fetch(r)) ?? []
}

// Stable ids so assertions survive reopen.
let itemID = UUID(uuidString: "DE5C0000-0000-4000-A000-000000000001")!
let matA = UUID(uuidString: "AAAAAAAA-0000-4000-A000-000000000001")!
let matB = UUID(uuidString: "BBBBBBBB-0000-4000-A000-000000000002")!

// =====================================================================
section("T1 — v1 DEFAULT-config store opens under NAMED config `Core` in v2")
// =====================================================================
do {
    let url = root.appendingPathComponent("t1.sqlite")

    // v1: no named configurations at all (nil == default configuration).
    let (c1, e1) = load(model: modelV1(), [desc(url, configuration: nil)])
    check(c1 != nil, "T1 v1 store loads under the default configuration \(e1)")
    if let c1 {
        let ctx = c1.newBackgroundContext()
        ctx.performAndWait {
            _ = insert(ctx, "WorkItem", ["id": itemID, "title": "Desk", "createdAt": Date(), "ownerRevision": 3])
            _ = insert(ctx, "WorkMaterial", [
                "id": matA, "workItemID": itemID, "kind": "note", "storageMode": "localVault",
                "byteSize": 128, "textContent": "hello v1", "thumbnailData": Data(repeating: 0x7, count: 4096),
                "createdAt": Date(),
            ])
            _ = insert(ctx, "Conversation", ["id": UUID(), "title": "chat", "updatedAt": Date()])
            try! ctx.save()
        }
        close(c1)
    }

    // Version-hash evidence: unchanged Core entities keep identical hashes,
    // so `Core` is compatible with the v1 store with no migration at all.
    let h1 = modelV1().entityVersionHashesByName
    let h2 = modelV2().entityVersionHashesByName
    check(h1["WorkMaterial"] == h2["WorkMaterial"], "T1 WorkMaterial version hash identical v1 vs v2 (no-op migration)")
    check(h2["WorkMaterialBlob"] != nil, "T1 v2 model carries WorkMaterialBlob")
    check(modelV2().configurations.sorted() == ["Blobs", "Core"], "T1 v2 declares exactly [Blobs, Core]")
    check(modelV2().entities(forConfigurationName: "Core")?.count == 3, "T1 `Core` holds the 3 pre-existing entities")
    check(modelV2().entities(forConfigurationName: "Blobs")?.map(\.name) == ["WorkMaterialBlob"], "T1 `Blobs` holds only the blob entity")

    // THE CLAIM: same file, v2 model, description pinned to `Core`.
    let (c2, e2) = load(model: modelV2(), [desc(url, configuration: "Core")])
    check(c2 != nil, "T1 v1 file reopens under configuration `Core` in v2 \(e2)")
    if let c2 {
        let ctx = c2.newBackgroundContext()
        ctx.performAndWait {
            check(count(ctx, "WorkItem") == 1, "T1 WorkItem row survived")
            check(count(ctx, "WorkMaterial") == 1, "T1 WorkMaterial row survived")
            check(count(ctx, "Conversation") == 1, "T1 Conversation row survived")
            let m = fetchAll(ctx, "WorkMaterial").first
            check(m?.value(forKey: "textContent") as? String == "hello v1", "T1 textContent intact")
            check((m?.value(forKey: "thumbnailData") as? Data)?.count == 4096, "T1 external thumbnail bytes intact")
            check(m?.value(forKey: "id") as? UUID == matA, "T1 material id intact")
        }
        // A blob insert must FAIL here: `Blobs` is not mounted in this container.
        let bctx = c2.newBackgroundContext()
        bctx.performAndWait {
            _ = insert(bctx, "WorkMaterialBlob", ["materialID": matA, "byteSize": 1])
            var threw = false
            do { try bctx.save() } catch { threw = true }
            check(threw, "T1 inserting a blob with no `Blobs` store mounted fails on save (control)")
            bctx.rollback()
        }
        close(c2)
    }

    // ★ PITFALL: pointing the WRONG configuration at an existing file does NOT
    // fail. Core Data validates only the entities the configuration names, so a
    // Core sqlite opened as `Blobs` silently gains a blob table and hides every
    // Core row. Filenames must be distinct and asserted at load time.
    let (c3, e3) = load(model: modelV2(), [desc(url, configuration: "Blobs", migrate: false)])
    check(c3 != nil, "T1 PITFALL: v1 Core file opens under `Blobs` with no error (\(e3.count) errors)")
    if let c3 {
        let ctx = c3.newBackgroundContext()
        ctx.performAndWait {
            check(count(ctx, "WorkMaterialBlob") == 0, "T1 PITFALL: mis-pointed store presents an empty blob table")
            let r = NSFetchRequest<NSFetchRequestResult>(entityName: "WorkMaterial")
            var outcome = "threw"
            if let n = try? ctx.count(for: r) { outcome = "count=\(n)" }
            check(outcome == "count=1",
                  "T1 PITFALL: Core rows stay READABLE through a `Blobs`-configured coordinator (\(outcome)) — nothing fails, nothing looks wrong")
        }
        close(c3)
    }
}

// =====================================================================
section("T5 — recovery: Blobs sqlite deleted while Core survives")
// =====================================================================
do {
    let cURL = root.appendingPathComponent("r-core.sqlite")
    let bURL = root.appendingPathComponent("r-blobs.sqlite")
    let (c1, _) = load(model: modelV2(), [desc(cURL, configuration: "Core"), desc(bURL, configuration: "Blobs")])
    check(c1 != nil, "T5 fresh two-store container loads")
    if let c1 {
        let ctx = c1.newBackgroundContext()
        ctx.performAndWait {
            _ = insert(ctx, "WorkMaterial", ["id": matA, "workItemID": itemID, "storageMode": "syncedPayload"])
            _ = insert(ctx, "WorkMaterialBlob", ["materialID": matA, "byteSize": 4, "contentHash": "gone"])
            try! ctx.save()
        }
        close(c1)
    }
    for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: bURL.path + suffix))
    }
    let (c2, e2) = load(model: modelV2(), [desc(cURL, configuration: "Core"), desc(bURL, configuration: "Blobs")])
    check(c2 != nil, "T5 container reloads after the Blobs file is deleted \(e2)")
    if let c2 {
        let ctx = c2.newBackgroundContext()
        ctx.performAndWait {
            check(count(ctx, "WorkMaterial") == 1, "T5 Core rows unaffected by the lost Blobs store")
            check(count(ctx, "WorkMaterialBlob") == 0, "T5 Blobs store recreated empty (material becomes .syncedPending)")
        }
        close(c2)
    }
}

// =====================================================================
section("T1b — real lightweight migration of `Core` (new optional column)")
// =====================================================================
do {
    let url = root.appendingPathComponent("t1b.sqlite")
    let (c1, _) = load(model: modelV1(), [desc(url, configuration: nil)])
    check(c1 != nil, "T1b v1 store loads")
    if let c1 {
        let ctx = c1.newBackgroundContext()
        ctx.performAndWait {
            _ = insert(ctx, "WorkMaterial", ["id": matB, "workItemID": itemID, "kind": "audio",
                                             "byteSize": 999, "textContent": "pre-migration"])
            try! ctx.save()
        }
        close(c1)
    }

    let hv1 = modelV1().entityVersionHashesByName["WorkMaterial"]
    let hv2 = modelV2(migrateCore: true).entityVersionHashesByName["WorkMaterial"]
    check(hv1 != hv2, "T1b added column changes WorkMaterial's version hash (migration is real, not a no-op)")

    let (c2, e2) = load(model: modelV2(migrateCore: true), [desc(url, configuration: "Core")])
    check(c2 != nil, "T1b v1 file lightweight-migrates under `Core` \(e2)")
    if let c2 {
        let ctx = c2.newBackgroundContext()
        ctx.performAndWait {
            let m = fetchAll(ctx, "WorkMaterial").first
            check(m?.value(forKey: "textContent") as? String == "pre-migration", "T1b old value intact after migration")
            check(m?.value(forKey: "contentHash") == nil, "T1b new column is nil")
            m?.setValue("sha-1234", forKey: "contentHash")
            var ok = true
            do { try ctx.save() } catch { ok = false }
            check(ok, "T1b write to the new column succeeds")
        }
        close(c2)
    }
}

// =====================================================================
section("T2 — production-like two-SQLite topology: CRUD, close, reopen, re-migrate")
// =====================================================================
let coreURL = root.appendingPathComponent("Conversations.sqlite")
let blobURL = root.appendingPathComponent("ConversationBlobs.sqlite")
do {
    // Realistic upgrade path: the Core file already exists as a v1 DEFAULT
    // store; the Blobs file does not exist yet.
    let (c0, _) = load(model: modelV1(), [desc(coreURL, configuration: nil)])
    check(c0 != nil, "T2 pre-existing v1 Core file created")
    if let c0 {
        let ctx = c0.newBackgroundContext()
        ctx.performAndWait {
            _ = insert(ctx, "WorkItem", ["id": itemID, "title": "Desk", "createdAt": Date()])
            _ = insert(ctx, "WorkMaterial", ["id": matA, "workItemID": itemID, "kind": "note",
                                             "storageMode": "localVault", "textContent": "legacy row"])
            try! ctx.save()
        }
        close(c0)
    }

    // First v2 launch: two descriptions, one container, one coordinator.
    let (c1, e1) = load(model: modelV2(), [
        desc(coreURL, configuration: "Core"),
        desc(blobURL, configuration: "Blobs"),
    ])
    check(c1 != nil, "T2 two-store container loads (existing Core + fresh Blobs) \(e1)")
    guard let c1 else { exit(1) }

    check(c1.persistentStoreCoordinator.persistentStores.count == 2, "T2 coordinator mounts exactly 2 stores")
    check(FileManager.default.fileExists(atPath: blobURL.path), "T2 Blobs sqlite created on disk")

    let payload = Data(repeating: 0x42, count: 3 * 1024 * 1024) // 3 MB, external storage
    let ctx = c1.newBackgroundContext()
    ctx.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    ctx.performAndWait {
        // Existing legacy row survived the config change.
        check(count(ctx, "WorkMaterial") == 1, "T2 legacy WorkMaterial visible through `Core`")

        // Publication protocol order: blob first, then material.
        _ = insert(ctx, "WorkMaterialBlob", [
            "materialID": matB, "payload": payload, "byteSize": Int64(payload.count),
            "contentHash": "sha-b", "createdAt": Date(), "updatedAt": Date(),
        ])
        var ok = true
        do { try ctx.save() } catch { ok = false; print("    blob save error: \(error)") }
        check(ok, "T2 blob row saves with NO explicit context.assign(_:to:) (entity is in one config only)")

        _ = insert(ctx, "WorkMaterial", [
            "id": matB, "workItemID": itemID, "kind": "audio",
            "storageMode": "syncedPayload", "byteSize": Int64(payload.count), "textContent": "new row",
        ])
        var ok2 = true
        do { try ctx.save() } catch { ok2 = false }
        check(ok2, "T2 material row saves into the Core store in the same context")
    }

    // Cross-store read + update + delete in one context.
    ctx.performAndWait {
        let blobs = fetchAll(ctx, "WorkMaterialBlob")
        check(blobs.count == 1, "T2 blob fetch through the two-store coordinator")
        check((blobs.first?.value(forKey: "payload") as? Data)?.count == payload.count, "T2 3 MB external payload round-trips")
        blobs.first?.setValue("sha-b2", forKey: "contentHash")

        // Projection-only fetch that must never fault the payload in.
        let proj = NSFetchRequest<NSDictionary>(entityName: "WorkMaterialBlob")
        proj.resultType = .dictionaryResultType
        proj.propertiesToFetch = ["materialID", "byteSize", "contentHash", "updatedAt"]
        let rows = (try? ctx.fetch(proj)) ?? []
        check(rows.count == 1 && rows.first?["payload"] == nil, "T2 dictionary projection returns metadata without payload")

        try! ctx.save()
    }

    // Store-of-record check: which physical store holds each object.
    ctx.performAndWait {
        let psc = c1.persistentStoreCoordinator
        let coreStore = psc.persistentStores.first { $0.url?.lastPathComponent == coreURL.lastPathComponent }
        let blobStore = psc.persistentStores.first { $0.url?.lastPathComponent == blobURL.lastPathComponent }
        let mat = fetchAll(ctx, "WorkMaterial").first { $0.value(forKey: "id") as? UUID == matB }
        let blob = fetchAll(ctx, "WorkMaterialBlob").first
        check(mat?.objectID.persistentStore === coreStore, "T2 WorkMaterial lands in the Core sqlite")
        check(blob?.objectID.persistentStore === blobStore, "T2 WorkMaterialBlob lands in the Blobs sqlite")
    }

    close(c1)

    // --- Reopen (same models, same files) ---
    let (c2, e2) = load(model: modelV2(), [
        desc(coreURL, configuration: "Core"),
        desc(blobURL, configuration: "Blobs"),
    ])
    check(c2 != nil, "T2 two-store container reopens \(e2)")
    if let c2 {
        let ctx2 = c2.newBackgroundContext()
        ctx2.performAndWait {
            check(count(ctx2, "WorkMaterial") == 2, "T2 both materials present after reopen")
            check(count(ctx2, "WorkMaterialBlob") == 1, "T2 blob present after reopen")
            let b = fetchAll(ctx2, "WorkMaterialBlob").first
            check(b?.value(forKey: "contentHash") as? String == "sha-b2", "T2 blob update persisted")
            check((b?.value(forKey: "payload") as? Data)?.count == 3 * 1024 * 1024, "T2 external payload survives reopen")

            // Paired deletion across stores in one save (plan §C blob GC).
            let mat = fetchAll(ctx2, "WorkMaterial").first { $0.value(forKey: "id") as? UUID == matB }
            if let mat { ctx2.delete(mat) }
            for blob in fetchAll(ctx2, "WorkMaterialBlob") { ctx2.delete(blob) }
            var ok = true
            do { try ctx2.save() } catch { ok = false; print("    paired-delete error: \(error)") }
            check(ok, "T2 paired cross-store delete commits in one save")
            check(count(ctx2, "WorkMaterial") == 1 && count(ctx2, "WorkMaterialBlob") == 0, "T2 paired delete took effect")
        }
        close(c2)
    }

    // --- Re-migrate: reopen under a v2 whose Core gained a column ---
    let (c3, e3) = load(model: modelV2(migrateCore: true), [
        desc(coreURL, configuration: "Core"),
        desc(blobURL, configuration: "Blobs"),
    ])
    check(c3 != nil, "T2 two-store topology lightweight-migrates the Core store in place \(e3)")
    if let c3 {
        let ctx3 = c3.newBackgroundContext()
        ctx3.performAndWait {
            check(count(ctx3, "WorkMaterial") == 1, "T2 rows survive the two-store re-migration")
            check(count(ctx3, "WorkMaterialBlob") == 0, "T2 Blobs store still readable after Core migrated")
            _ = insert(ctx3, "WorkMaterialBlob", ["materialID": matA, "byteSize": 7, "contentHash": "sha-a", "payload": Data(repeating: 1, count: 32)])
            var ok = true
            do { try ctx3.save() } catch { ok = false }
            check(ok, "T2 blob writes still work after the Core-only migration")
        }
        close(c3)
    }
}

// =====================================================================
section("T3 — external-storage placement + 30 MB ceiling round trip")
// =====================================================================
do {
    let (c, e) = load(model: modelV2(), [
        desc(coreURL, configuration: "Core"),
        desc(blobURL, configuration: "Blobs"),
    ])
    check(c != nil, "T3 container loads \(e)")
    if let c {
        let big = Data(repeating: 0x5A, count: 30 * 1024 * 1024)
        let ctx = c.newBackgroundContext()
        var savedOK = true
        ctx.performAndWait {
            _ = insert(ctx, "WorkMaterialBlob", ["materialID": UUID(), "payload": big,
                                                 "byteSize": Int64(big.count), "contentHash": "sha-30mb"])
            do { try ctx.save() } catch { savedOK = false; print("    30MB save error: \(error)") }
            ctx.reset()
        }
        check(savedOK, "T3 30 MB payload saves through external binary storage")

        let ctx2 = c.newBackgroundContext()
        ctx2.performAndWait {
            let r = NSFetchRequest<NSManagedObject>(entityName: "WorkMaterialBlob")
            r.predicate = NSPredicate(format: "contentHash == %@", "sha-30mb")
            let b = (try? ctx2.fetch(r))?.first
            check((b?.value(forKey: "payload") as? Data)?.count == 30 * 1024 * 1024, "T3 30 MB payload reads back whole")

            // Metadata-only projection over the same row must not touch payload.
            let p = NSFetchRequest<NSDictionary>(entityName: "WorkMaterialBlob")
            p.resultType = .dictionaryResultType
            p.propertiesToFetch = ["materialID", "byteSize", "contentHash"]
            let rows = (try? ctx2.fetch(p)) ?? []
            check(rows.count >= 1, "T3 batch metadata projection over blobs works")
        }

        // External binaries live in a _SUPPORT directory beside their OWN sqlite.
        let blobSupport = root.appendingPathComponent(".ConversationBlobs_SUPPORT/_EXTERNAL_DATA")
        let coreSupport = root.appendingPathComponent(".Conversations_SUPPORT/_EXTERNAL_DATA")
        let blobFiles = (try? FileManager.default.contentsOfDirectory(atPath: blobSupport.path))?.count ?? 0
        let coreFiles = (try? FileManager.default.contentsOfDirectory(atPath: coreSupport.path))?.count ?? 0
        check(blobFiles > 0, "T3 blob external files land beside the Blobs sqlite (found \(blobFiles))")
        print("  info  Core _SUPPORT external files: \(coreFiles)")
        close(c)
    }
}

// =====================================================================
section("T4 — two independent coordinators over the same two files (process parity)")
// =====================================================================
do {
    // Two containers = two coordinators over the same pair of sqlite files,
    // approximating app + headless App Intent processes sharing the store.
    let (a, ea) = load(model: modelV2(), [desc(coreURL, configuration: "Core"), desc(blobURL, configuration: "Blobs")])
    let (b, eb) = load(model: modelV2(), [desc(coreURL, configuration: "Core"), desc(blobURL, configuration: "Blobs")])
    check(a != nil && b != nil, "T4 two coordinators mount the same two files \(ea)\(eb)")
    if let a, let b {
        let ida = UUID()
        let ctxA = a.newBackgroundContext()
        ctxA.performAndWait {
            _ = insert(ctxA, "WorkMaterialBlob", ["materialID": ida, "byteSize": 5, "contentHash": "cross"])
            try! ctxA.save()
        }
        let ctxB = b.newBackgroundContext()
        ctxB.performAndWait {
            let r = NSFetchRequest<NSManagedObject>(entityName: "WorkMaterialBlob")
            r.predicate = NSPredicate(format: "materialID == %@", ida as CVarArg)
            check(((try? ctxB.fetch(r))?.count ?? 0) == 1, "T4 second coordinator reads the first's blob write")
        }
        close(a); close(b)
    }
}

// MARK: - Result

print("\n================ RESULT ================")
print("passes: \(passes)   failures: \(failures.count)")
for f in failures { print("  - \(f)") }
try? FileManager.default.removeItem(at: root)
exit(failures.isEmpty ? 0 : 1)
