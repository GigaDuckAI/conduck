// SPDX-License-Identifier: Apache-2.0

// The phone's section menu is transient state owned by the shared router.
// These tests drive real routing in both directions and stale/hidden-menu
// actions, which must never reopen a menu or undo an external destination change.

import XCTest
@testable import Conduck

#if os(iOS)
@MainActor
final class PhoneWorkbenchNavigationTests: XCTestCase {
    private typealias Destination = PersonalWorkbenchRouter.Destination

    func testSelectingAnotherSectionRoutesBothDirectionsAndClosesTheMenu() {
        let router = PersonalWorkbenchRouter()

        for (source, target): (Destination, Destination) in [(.chats, .work), (.work, .chats)] {
            XCTAssertEqual(router.destination, source)
            router.togglePhoneSection(for: source)
            XCTAssertTrue(router.isPhoneSectionExpanded(for: source))
            XCTAssertFalse(router.isPhoneSectionExpanded(for: target))

            router.selectPhoneSection(target)

            XCTAssertEqual(router.destination, target)
            XCTAssertNil(router.expandedPhoneSection)
            XCTAssertFalse(router.isPhoneSectionExpanded(for: source))
            XCTAssertFalse(router.isPhoneSectionExpanded(for: target))
        }
    }

    func testSelectingCurrentSectionClosesWithoutChangingDestination() {
        for destination: Destination in [.chats, .work] {
            let router = PersonalWorkbenchRouter()
            router.destination = destination
            router.togglePhoneSection(for: destination)
            XCTAssertTrue(router.isPhoneSectionExpanded(for: destination))

            router.selectPhoneSection(destination)

            XCTAssertEqual(router.destination, destination)
            XCTAssertNil(router.expandedPhoneSection)
        }
    }

    func testSecondTriggerTapAndOutsideDismissalCloseWithoutRouting() {
        for destination: Destination in [.chats, .work] {
            let router = PersonalWorkbenchRouter()
            router.destination = destination
            router.togglePhoneSection(for: destination)
            XCTAssertTrue(router.isPhoneSectionExpanded(for: destination))
            router.togglePhoneSection(for: destination)
            XCTAssertNil(router.expandedPhoneSection)
            XCTAssertEqual(router.destination, destination)

            router.togglePhoneSection(for: destination)
            XCTAssertTrue(router.isPhoneSectionExpanded(for: destination))
            router.dismissPhoneSection()
            router.dismissPhoneSection()
            XCTAssertNil(router.expandedPhoneSection)
            XCTAssertEqual(router.destination, destination)
        }
    }

    func testInactiveHostCannotExpandOrCloseTheActiveHostsMenu() {
        for (active, inactive): (Destination, Destination) in [(.chats, .work), (.work, .chats)] {
            let router = PersonalWorkbenchRouter()
            router.destination = active
            router.togglePhoneSection(for: inactive)
            XCTAssertNil(router.expandedPhoneSection)

            router.togglePhoneSection(for: active)
            router.togglePhoneSection(for: inactive)
            XCTAssertEqual(router.expandedPhoneSection, active)
            XCTAssertTrue(router.isPhoneSectionExpanded(for: active))
            XCTAssertFalse(router.isPhoneSectionExpanded(for: inactive))
            XCTAssertEqual(router.destination, active)
        }
    }

    func testClosedMenuCannotRouteFromAStaleSelection() {
        for (active, other): (Destination, Destination) in [(.chats, .work), (.work, .chats)] {
            let router = PersonalWorkbenchRouter()
            router.destination = active
            router.selectPhoneSection(other)
            XCTAssertEqual(router.destination, active)

            router.togglePhoneSection(for: active)
            router.dismissPhoneSection()
            router.selectPhoneSection(other)
            XCTAssertEqual(router.destination, active)
            XCTAssertNil(router.expandedPhoneSection)
        }
    }

    func testExternalRouteClosesExpansionAndRejectsItsStaleSelection() {
        for (source, target): (Destination, Destination) in [(.chats, .work), (.work, .chats)] {
            let router = PersonalWorkbenchRouter()
            router.destination = source
            router.togglePhoneSection(for: source)

            router.destination = target

            XCTAssertNil(router.expandedPhoneSection)
            XCTAssertFalse(router.isPhoneSectionExpanded(for: source))
            router.selectPhoneSection(source)
            XCTAssertEqual(router.destination, target)
            router.togglePhoneSection(for: target)
            XCTAssertTrue(router.isPhoneSectionExpanded(for: target))
        }
    }

    func testExpiredHostDismissalCannotCloseTheNewActiveMenu() {
        for (source, target): (Destination, Destination) in [(.chats, .work), (.work, .chats)] {
            let router = PersonalWorkbenchRouter()
            router.destination = source
            router.togglePhoneSection(for: source)
            router.selectPhoneSection(target)
            router.togglePhoneSection(for: target)
            XCTAssertTrue(router.isPhoneSectionExpanded(for: target))

            // The outgoing destination can disappear after the next one is
            // already interactive; its callback owns only the old menu.
            router.dismissPhoneSection(for: source)

            XCTAssertEqual(router.destination, target)
            XCTAssertTrue(router.isPhoneSectionExpanded(for: target))
            router.dismissPhoneSection(for: target)
            XCTAssertNil(router.expandedPhoneSection)
        }
    }
}
#endif
