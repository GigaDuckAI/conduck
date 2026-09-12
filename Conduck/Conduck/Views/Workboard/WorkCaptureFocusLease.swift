// SPDX-License-Identifier: Apache-2.0

// Async capture completion can outlive the View value that started it. Its
// captured environment is not evidence that Work is still visible. A retained
// lease invalidates old completions on hide or teardown, including a later
// return to the same scope, while the draft's content can still finish saving.

import Foundation

@MainActor
final class WorkCaptureFocusLease {
    struct Request {
        fileprivate let generation: UUID
        fileprivate let scope: WorkDeskScope
    }

    private var generation = UUID()
    private var isActive = false

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        generation = UUID()
        isActive = active
    }

    func invalidate() {
        generation = UUID()
        isActive = false
    }

    func capture(scope: WorkDeskScope) -> Request? {
        isActive ? Request(generation: generation, scope: scope) : nil
    }

    func permits(_ request: Request?, currentScope: WorkDeskScope, destinationIsActive: Bool) -> Bool {
        guard let request else { return false }
        return isActive && destinationIsActive && request.generation == generation && request.scope == currentScope
    }
}
