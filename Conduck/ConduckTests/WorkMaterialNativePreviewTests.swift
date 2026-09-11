// SPDX-License-Identifier: Apache-2.0

// Embedded file readers outlive a dismissal request. Their disposable source
// survives until each native reader closes; editing metadata should not reset
// an open document, while replacement or a type change must reload it.

import XCTest
@testable import Conduck

@MainActor
final class WorkMaterialNativePreviewTests: XCTestCase {
    func testReclaimWaitsForEveryReaderAndIsIdempotent() {
        var reclaims = 0
        let lease = WorkMaterialPreviewLease(url: URL(fileURLWithPath: "/fixture/document.pdf")) { reclaims += 1 }
        let first = lease.acquire(), second = lease.acquire()
        lease.requestReclaim()
        XCTAssertEqual(reclaims, 0)
        lease.release(first)
        lease.release(first)
        XCTAssertEqual(reclaims, 0)
        lease.release(second)
        XCTAssertEqual(reclaims, 1)
        lease.requestReclaim()
        lease.release(second)
        XCTAssertEqual(reclaims, 1)
    }

    func testReclaimWithoutAnEmbeddedReaderIsImmediate() {
        var reclaims = 0
        let lease = WorkMaterialPreviewLease(url: URL(fileURLWithPath: "/fixture/document.pdf")) { reclaims += 1 }
        lease.requestReclaim()
        lease.requestReclaim()
        XCTAssertEqual(reclaims, 1)
    }

    func testNotesPreserveReaderButSourceAndTypeChangesReload() {
        var material = WorkboardMaterialSnapshot(kind: .file, name: "Document.txt", mimeType: "text/plain",
            revision: 10, sourceByteIdentity: "synced:original")
        let original = WorkMaterialNativePreviewKey(material: material)
        material.annotation = "Read page two"
        material.revision += 1
        XCTAssertEqual(WorkMaterialNativePreviewKey(material: material), original)
        material.sourceByteIdentity = "synced:replacement"
        XCTAssertNotEqual(WorkMaterialNativePreviewKey(material: material), original)
        material.sourceByteIdentity = "synced:original"
        material.mimeType = "application/json"
        XCTAssertNotEqual(WorkMaterialNativePreviewKey(material: material), original)
        material.mimeType = "text/plain"
        material.availability = .syncPending
        XCTAssertNotEqual(WorkMaterialNativePreviewKey(material: material), original)
    }
}
