// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkboardDeepLinkRoute.swift
//
// Where a Work deep link lands. Work is ONE desk
// (`Constants.workboardDeskItemID`), so this route takes NO payload: a link
// that names material names material that landed on that desk, never a board
// to choose between, and a link carrying no id routes exactly like one that
// does. The signature is the guarantee — there is no id to honour.
//
// It is a value rather than a method inside the shell's `body` because the
// reload is the load-bearing half. `WorkCaptureRefreshCoordinator` owns every
// board load, so the link ASKS for a reload instead of running one; and it
// reveals the desk BEFORE asking, because the coordinator defers a reload
// requested while Work is hidden.

import Foundation

@MainActor
struct WorkboardDeepLinkRoute {
    typealias ScheduleRefresh = @MainActor () -> Void

    private let router: PersonalWorkbenchRouter
    private let scheduleRefresh: ScheduleRefresh

    init(router: PersonalWorkbenchRouter, scheduleRefresh: @escaping ScheduleRefresh) {
        self.router = router
        self.scheduleRefresh = scheduleRefresh
    }

    /// Reveal the desk, then ask for its reload. The window itself is
    /// foregrounded by the scene host, which consumes the same notification.
    func open() {
        router.destination = .work
        scheduleRefresh()
    }
}
