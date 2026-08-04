// SPDX-License-Identifier: Apache-2.0

// Conduck
// ServerFileChipAvailabilityTests.swift
//
// A server-file chip can only fetch its bytes with BOTH halves present: the
// opaque `storedKey` naming the blob, and the durable lane that minted it (the
// credential the GET authenticates with). Missing either makes the row
// unaddressable — and both shapes occur in the wild:
//   - a cross-lane clone clears the key (it was minted on another file server)
//   - a legacy / partially-synced row can carry a key with no provable owner
//
// Without this gate such a chip stays tappable and falls through to a red
// "File transfer isn't set up for this gateway", which is a dead tap under a
// claim that is very often false: the gateway's file transfer may be perfectly
// healthy — it is THIS row that has nothing to point at.

import XCTest
@testable import Conduck

final class ServerFileChipAvailabilityTests: XCTestCase {

    func testAddressableWhenBothKeyAndLanePresent() {
        XCTAssertTrue(ServerFileChipAvailability.isAddressable(
            storedKey: "abcd__report.pdf", ownerLaneID: "lane1"
        ))
    }

    func testNilKeyIsUnaddressable() {
        // The clone tombstone: the file is still named, but there is nothing to GET.
        XCTAssertFalse(ServerFileChipAvailability.isAddressable(
            storedKey: nil, ownerLaneID: "lane1"
        ))
    }

    func testEmptyKeyIsUnaddressable() {
        XCTAssertFalse(ServerFileChipAvailability.isAddressable(
            storedKey: "", ownerLaneID: "lane1"
        ))
    }

    func testKeyWithoutOwningLaneIsUnaddressable() {
        // Just as unusable as no key: nothing authorizes the GET, so a tap could
        // only produce a misleading refusal.
        XCTAssertFalse(ServerFileChipAvailability.isAddressable(
            storedKey: "abcd__report.pdf", ownerLaneID: nil
        ))
    }

    func testKeyWithEmptyLaneIsUnaddressable() {
        XCTAssertFalse(ServerFileChipAvailability.isAddressable(
            storedKey: "abcd__report.pdf", ownerLaneID: ""
        ))
    }
}
