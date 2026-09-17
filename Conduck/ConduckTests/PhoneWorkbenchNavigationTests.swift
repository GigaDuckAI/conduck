// SPDX-License-Identifier: Apache-2.0

// The iPhone's flip button is one tap between sections, driven by the shared
// router's `selectDestination` — the same call the wide Chats|Work switch and
// the compact iPad tab bar make. These tests drive the real router: a flip
// routes both ways, re-selecting the current section is a no-op, and an
// external destination change (a deep link) needs no menu to close.

import XCTest
@testable import Conduck

#if os(iOS)
@MainActor
final class PhoneWorkbenchNavigationTests: XCTestCase {
    private typealias Destination = PersonalWorkbenchRouter.Destination

    func testFlipRoutesBothDirections() {
        let router = PersonalWorkbenchRouter()
        XCTAssertEqual(router.destination, .chats, "Chat owns launch and must be the first section.")

        router.selectDestination(.work)
        XCTAssertEqual(router.destination, .work)

        router.selectDestination(.chats)
        XCTAssertEqual(router.destination, .chats)
    }

    func testSelectingTheCurrentSectionChangesNothing() {
        for destination: Destination in [.chats, .work] {
            let router = PersonalWorkbenchRouter()
            router.destination = destination

            router.selectDestination(destination)
            router.selectDestination(destination)

            XCTAssertEqual(router.destination, destination)
        }
    }

    func testExternalRouteAndFlipComposeWithoutResidue() {
        let router = PersonalWorkbenchRouter()

        // A deep link lands on Work directly; the flip still returns to Chats.
        router.destination = .work
        router.selectDestination(.chats)
        XCTAssertEqual(router.destination, .chats)

        // A reveal (capture route) also lands on Work directly.
        _ = router.beginWorkReveal()
        XCTAssertEqual(router.destination, .work)
        router.selectDestination(.chats)
        XCTAssertEqual(router.destination, .chats)
    }
}
#endif
