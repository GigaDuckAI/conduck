// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkMaterialStoragePolicyTests.swift
//
// One decision governs where every material's bytes live, so these tests pin
// the whole matrix: the ceiling is inclusive, an unmeasured size never syncs,
// and the kind never changes the answer. Lanes with no UI — the share inbox,
// the headless intent, the Watch — depend on that being decided here rather
// than re-derived per call site.

import XCTest
@testable import Conduck

final class WorkMaterialStoragePolicyTests: XCTestCase {
    private let ceiling = Constants.workboardSyncCeilingBytes

    func testSizesWithinTheCeilingSync() {
        XCTAssertEqual(WorkMaterialStoragePolicy.mode(kind: .file, byteSize: 1), .syncedPayload)
        XCTAssertEqual(
            WorkMaterialStoragePolicy.mode(kind: .image, byteSize: ceiling / 2),
            .syncedPayload
        )
        XCTAssertEqual(
            WorkMaterialStoragePolicy.mode(kind: .file, byteSize: ceiling - 1),
            .syncedPayload
        )
    }

    func testTheCeilingItselfSyncs() {
        XCTAssertEqual(
            WorkMaterialStoragePolicy.mode(kind: .file, byteSize: ceiling),
            .syncedPayload,
            "the ceiling is the largest payload that syncs, not the first that does not"
        )
        XCTAssertEqual(
            WorkMaterialStoragePolicy.mode(kind: .file, byteSize: ceiling + 1),
            .localVault
        )
    }

    func testUnmeasuredSizeTakesTheLocalVault() {
        XCTAssertEqual(
            WorkMaterialStoragePolicy.mode(kind: .file, byteSize: 0),
            .localVault,
            "a payload of unknown size may not be promised to CloudKit"
        )
        XCTAssertEqual(WorkMaterialStoragePolicy.mode(kind: .file, byteSize: -1), .localVault)
        XCTAssertEqual(
            WorkMaterialStoragePolicy.mode(kind: .file, byteSize: .min),
            .localVault,
            "an overflowed or garbage size fails to the reattachable side"
        )
    }

    func testLargePayloadsAboveTheCeilingStayLocalWhateverTheirSize() {
        XCTAssertEqual(
            WorkMaterialStoragePolicy.mode(kind: .file, byteSize: 256 * 1024 * 1024),
            .localVault,
            "the share cap is well above the sync ceiling; those files reattach instead"
        )
        XCTAssertEqual(WorkMaterialStoragePolicy.mode(kind: .file, byteSize: .max), .localVault)
    }

    func testEveryKindGetsTheSameAnswerForTheSameSize() {
        for kind in WorkMaterialKind.allCases {
            XCTAssertEqual(
                WorkMaterialStoragePolicy.mode(kind: kind, byteSize: ceiling),
                .syncedPayload,
                "\(kind) at the ceiling must sync like every other kind"
            )
            XCTAssertEqual(
                WorkMaterialStoragePolicy.mode(kind: kind, byteSize: ceiling + 1),
                .localVault,
                "\(kind) above the ceiling must take the vault like every other kind"
            )
            XCTAssertEqual(
                WorkMaterialStoragePolicy.mode(kind: kind, byteSize: 0),
                .localVault,
                "\(kind) without a measured size must take the vault"
            )
        }
    }

    func testPolicyNeverReturnsMetadataOnly() {
        for byteSize in [Int64.min, -1, 0, 1, ceiling, ceiling + 1, .max] {
            XCTAssertNotEqual(
                WorkMaterialStoragePolicy.mode(kind: .note, byteSize: byteSize),
                .metadataOnly,
                "a payload-free material is decided at the draft, never asked of the policy"
            )
        }
    }

    func testCeilingSitsBelowTheOnlyPublishedAssetFigure() {
        XCTAssertLessThan(
            ceiling,
            50 * 1024 * 1024,
            "the ceiling stays under the archived 50 MB figure until device evidence raises it"
        )
        XCTAssertGreaterThan(ceiling, 0)
    }
}
