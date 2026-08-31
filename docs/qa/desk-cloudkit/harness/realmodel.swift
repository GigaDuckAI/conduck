// SPDX-License-Identifier: Apache-2.0

// Gate-1 part 2: the SAME claim against the REAL compiled Conduck models.
// out15.mom = `Conversations 15.xcdatamodel` verbatim (default configuration only).
// out16.mom = that XML + entity `WorkMaterialBlob` + <configuration> elements.

import CoreData
import Foundation

var failures: [String] = []
var passes = 0
func check(_ c: Bool, _ l: String) {
    if c { passes += 1; print("  PASS  \(l)") } else { failures.append(l); print("  FAIL  \(l)") }
}

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let m15 = NSManagedObjectModel(contentsOf: dir.appendingPathComponent("out15.mom"))!
let m16 = NSManagedObjectModel(contentsOf: dir.appendingPathComponent("out16.mom"))!

let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("real-spike-\(UUID().uuidString)", isDirectory: true)
try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let coreURL = root.appendingPathComponent("Conversations.sqlite")
let blobURL = root.appendingPathComponent("ConversationBlobs.sqlite")

func desc(_ url: URL, _ config: String?) -> NSPersistentStoreDescription {
    let d = NSPersistentStoreDescription(url: url)
    d.type = NSSQLiteStoreType
    d.configuration = config
    d.shouldMigrateStoreAutomatically = true
    d.shouldInferMappingModelAutomatically = true
    d.shouldAddStoreAsynchronously = false
    d.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
    d.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
    return d
}
func load(_ m: NSManagedObjectModel, _ ds: [NSPersistentStoreDescription]) -> (NSPersistentContainer?, [Error]) {
    let c = NSPersistentContainer(name: "Conversations", managedObjectModel: m)
    c.persistentStoreDescriptions = ds
    var errs: [Error] = []
    c.loadPersistentStores { _, e in if let e { errs.append(e) } }
    return (errs.isEmpty ? c : nil, errs)
}
func close(_ c: NSPersistentContainer) {
    for s in c.persistentStoreCoordinator.persistentStores { try? c.persistentStoreCoordinator.remove(s) }
}
func count(_ ctx: NSManagedObjectContext, _ e: String) -> Int {
    (try? ctx.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: e))) ?? -1
}

print("=== R1 — model shape (real .mom files) ===")
check(m15.configurations.filter { $0 != "PF_DEFAULT_CONFIGURATION_NAME" }.isEmpty,
      "R1 model 15 declares NO named configurations (\(m15.configurations))")
check(m16.configurations.filter { $0 != "PF_DEFAULT_CONFIGURATION_NAME" }.sorted() == ["Blobs", "Core"],
      "R1 model 16 declares [Blobs, Core] (\(m16.configurations.sorted()))")
let coreNames = Set(m16.entities(forConfigurationName: "Core")?.map(\.name.self).compactMap { $0 } ?? [])
check(coreNames == Set(m15.entities.compactMap(\.name)),
      "R1 `Core` == exactly model 15's 7 entities (\(coreNames.sorted()))")
check(m16.entities(forConfigurationName: "Blobs")?.compactMap(\.name) == ["WorkMaterialBlob"],
      "R1 `Blobs` == [WorkMaterialBlob]")
for name in m15.entities.compactMap(\.name) {
    check(m15.entityVersionHashesByName[name] == m16.entityVersionHashesByName[name],
          "R1 \(name) version hash unchanged 15→16")
}
let blob = m16.entitiesByName["WorkMaterialBlob"]!
check(blob.properties.allSatisfy { ($0 as? NSAttributeDescription)?.isOptional ?? false }, "R1 every blob attribute is optional")
check(blob.relationshipsByName.isEmpty, "R1 blob has no relationships")
check(blob.uniquenessConstraints.isEmpty, "R1 blob has no uniqueness constraints")
check((blob.attributesByName["payload"])?.allowsExternalBinaryDataStorage == true, "R1 blob payload is external binary storage")
check((blob.attributesByName["byteSize"])?.defaultValue as? Int == 0 || blob.attributesByName["byteSize"]?.defaultValue == nil,
      "R1 blob byteSize default (\(String(describing: blob.attributesByName["byteSize"]?.defaultValue)))")

print("\n=== R2 — real v15 default store → v16 `Core`, plus a fresh `Blobs` store ===")
let deskID = UUID(uuidString: "DE5C0000-0000-4000-A000-000000000001")!
let matID = UUID(uuidString: "AAAAAAAA-0000-4000-A000-000000000001")!
do {
    let (c, e) = load(m15, [desc(coreURL, nil)])
    check(c != nil, "R2 v15 store loads under the default configuration \(e)")
    if let c {
        let ctx = c.newBackgroundContext()
        ctx.performAndWait {
            let conv = NSEntityDescription.insertNewObject(forEntityName: "Conversation", into: ctx)
            conv.setValue(UUID(), forKey: "id"); conv.setValue("chat", forKey: "title")
            let item = NSEntityDescription.insertNewObject(forEntityName: "WorkItem", into: ctx)
            item.setValue(deskID, forKey: "id"); item.setValue("Desk", forKey: "title")
            let mat = NSEntityDescription.insertNewObject(forEntityName: "WorkMaterial", into: ctx)
            mat.setValue(matID, forKey: "id"); mat.setValue(deskID, forKey: "workItemID")
            mat.setValue("note", forKey: "kind"); mat.setValue("localVault", forKey: "storageMode")
            mat.setValue("legacy desk note", forKey: "textContent")
            mat.setValue("regular", forKey: "cardSize")
            mat.setValue(Data(repeating: 0x9, count: 8192), forKey: "thumbnailData")
            let disp = NSEntityDescription.insertNewObject(forEntityName: "WorkDispatch", into: ctx)
            disp.setValue(UUID(), forKey: "id")
            try! ctx.save()
        }
        close(c)
    }
}
do {
    let (c, e) = load(m16, [desc(coreURL, "Core"), desc(blobURL, "Blobs")])
    check(c != nil, "R2 real v15 file opens under `Core` in v16 alongside a fresh `Blobs` store \(e)")
    guard let c else { exit(1) }
    check(c.persistentStoreCoordinator.persistentStores.count == 2, "R2 two stores mounted")
    let ctx = c.newBackgroundContext()
    ctx.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    let payload = Data(repeating: 0xAB, count: 5 * 1024 * 1024)
    ctx.performAndWait {
        check(count(ctx, "WorkItem") == 1 && count(ctx, "WorkMaterial") == 1 && count(ctx, "Conversation") == 1 && count(ctx, "WorkDispatch") == 1,
              "R2 all model-15 rows intact after the configuration change")
        let r = NSFetchRequest<NSManagedObject>(entityName: "WorkMaterial")
        let mat = (try? ctx.fetch(r))?.first
        check(mat?.value(forKey: "textContent") as? String == "legacy desk note", "R2 textContent intact")
        check(mat?.value(forKey: "cardSize") as? String == "regular", "R2 model-15-only column `cardSize` intact")
        check((mat?.value(forKey: "thumbnailData") as? Data)?.count == 8192, "R2 external thumbnail bytes intact")

        // Publication order: blob durable first, then the material flips mode.
        let b = NSEntityDescription.insertNewObject(forEntityName: "WorkMaterialBlob", into: ctx)
        b.setValue(matID, forKey: "materialID"); b.setValue(payload, forKey: "payload")
        b.setValue(Int64(payload.count), forKey: "byteSize"); b.setValue("sha-real", forKey: "contentHash")
        b.setValue(Date(), forKey: "createdAt"); b.setValue(Date(), forKey: "updatedAt")
        var ok = true
        do { try ctx.save() } catch { ok = false; print("    err \(error)") }
        check(ok, "R2 blob saves into the Blobs store (no explicit assign)")
        mat?.setValue("syncedPayload", forKey: "storageMode")
        do { try ctx.save() } catch { ok = false }
        check(ok, "R2 material flips to .syncedPayload in the Core store")
    }
    ctx.performAndWait {
        let psc = c.persistentStoreCoordinator
        let cs = psc.persistentStores.first { $0.url?.lastPathComponent == "Conversations.sqlite" }
        let bs = psc.persistentStores.first { $0.url?.lastPathComponent == "ConversationBlobs.sqlite" }
        let mat = (try? ctx.fetch(NSFetchRequest<NSManagedObject>(entityName: "WorkMaterial")))?.first
        let b = (try? ctx.fetch(NSFetchRequest<NSManagedObject>(entityName: "WorkMaterialBlob")))?.first
        check(mat?.objectID.persistentStore === cs, "R2 WorkMaterial routed to Conversations.sqlite")
        check(b?.objectID.persistentStore === bs, "R2 WorkMaterialBlob routed to ConversationBlobs.sqlite")
    }
    close(c)
}
print("\n=== R3 — reopen + re-migrate ===")
do {
    let (c, e) = load(m16, [desc(coreURL, "Core"), desc(blobURL, "Blobs")])
    check(c != nil, "R3 two-store topology reopens \(e)")
    if let c {
        let ctx = c.newBackgroundContext()
        ctx.performAndWait {
            check(count(ctx, "WorkMaterial") == 1 && count(ctx, "WorkMaterialBlob") == 1, "R3 rows survive reopen")
            let b = (try? ctx.fetch(NSFetchRequest<NSManagedObject>(entityName: "WorkMaterialBlob")))?.first
            check((b?.value(forKey: "payload") as? Data)?.count == 5 * 1024 * 1024, "R3 5 MB external payload survives reopen")

            // Availability projection: metadata only, payload never faulted.
            let p = NSFetchRequest<NSDictionary>(entityName: "WorkMaterialBlob")
            p.resultType = .dictionaryResultType
            p.propertiesToFetch = ["materialID", "byteSize", "contentHash", "updatedAt"]
            let rows = (try? ctx.fetch(p)) ?? []
            check(rows.count == 1 && rows[0]["contentHash"] as? String == "sha-real" && rows[0]["payload"] == nil,
                  "R3 availability projection returns hash+size without payload")

            // Paired delete across both stores, one save.
            for e in ["WorkMaterial", "WorkMaterialBlob"] {
                for o in (try? ctx.fetch(NSFetchRequest<NSManagedObject>(entityName: e))) ?? [] { ctx.delete(o) }
            }
            var ok = true
            do { try ctx.save() } catch { ok = false }
            check(ok && count(ctx, "WorkMaterial") == 0 && count(ctx, "WorkMaterialBlob") == 0, "R3 paired cross-store delete commits atomically per-save")
        }
        close(c)
    }
    // Re-run the same v16 load once more (migration idempotence).
    let (c2, e2) = load(m16, [desc(coreURL, "Core"), desc(blobURL, "Blobs")])
    check(c2 != nil, "R3 second v16 load is a no-op re-migration \(e2)")
    if let c2 { close(c2) }
}

print("\n================ RESULT ================")
print("passes: \(passes)   failures: \(failures.count)")
for f in failures { print("  - \(f)") }
try? FileManager.default.removeItem(at: root)
exit(failures.isEmpty ? 0 : 1)
