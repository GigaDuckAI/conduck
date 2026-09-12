// SPDX-License-Identifier: Apache-2.0

// The iPad native split may retain its first binding while Work stays mounted
// behind Chats. Exercise that same binding across destination changes so its
// first inactive snapshot cannot freeze the native toggle permanently.

import SwiftUI
import XCTest
@testable import Conduck

#if os(iOS)
@MainActor
final class WorkboardSidebarVisibilityBindingTests: XCTestCase {
    func testRetainedBindingUsesTheCurrentDestinationForEveryToggle() {
        let workspace = WorkDeskWorkspaceState(organization: .init(fetch: { .init() }, apply: { _ in .init() }))
        let router = PersonalWorkbenchRouter()
        let binding = WorkboardExperience.sidebarVisibilityBinding(
            workspace: workspace, router: router, standaloneIsActive: false
        )

        XCTAssertEqual(router.destination, .chats)
        binding.wrappedValue = .detailOnly
        XCTAssertTrue(workspace.showsSidebar, "The hidden Work split must ignore native write-backs")

        router.destination = .work
        binding.wrappedValue = .detailOnly
        XCTAssertFalse(workspace.showsSidebar, "The original binding must become active after entering Work")
        XCTAssertEqual(binding.wrappedValue, .detailOnly)
        binding.wrappedValue = .all
        XCTAssertTrue(workspace.showsSidebar)

        router.destination = .chats
        binding.wrappedValue = .detailOnly
        XCTAssertTrue(workspace.showsSidebar, "Leaving Work must silence the same retained binding again")

        router.destination = .work
        workspace.showsSidebar = false
        XCTAssertEqual(binding.wrappedValue, .detailOnly, "The getter must follow the retained workspace directly")
        binding.wrappedValue = .all
        XCTAssertTrue(workspace.showsSidebar)
    }

    func testStandaloneHostWithoutRouterUsesItsExplicitGate() {
        let workspace = WorkDeskWorkspaceState(organization: .init(fetch: { .init() }, apply: { _ in .init() }))
        let active = WorkboardExperience.sidebarVisibilityBinding(
            workspace: workspace, router: nil, standaloneIsActive: true
        )
        active.wrappedValue = .detailOnly
        XCTAssertFalse(workspace.showsSidebar)

        let inactive = WorkboardExperience.sidebarVisibilityBinding(
            workspace: workspace, router: nil, standaloneIsActive: false
        )
        inactive.wrappedValue = .all
        XCTAssertFalse(workspace.showsSidebar)
    }
}
#endif
