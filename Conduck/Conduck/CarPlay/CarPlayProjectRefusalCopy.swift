// SPDX-License-Identifier: Apache-2.0

// Conduck
// CarPlayProjectRefusalCopy.swift
//
// What the car says when a Work project's conversation cannot take a new
// turn. Two refusals reach CarPlay: an archived project, and a free library
// with more active projects than the allowance and no choice made yet. The
// store raises them as `WorkDeskStoreError` from `appendMessage` (the phone's
// mapping) and answers the pre-flight as `WorkProjectAccessError`; both land
// on the same two sentences here.
//
// Driver-safe by construction: each sentence names the one place the fix
// lives (Work on the iPhone) and never says "try again" — nothing at the
// wheel can change a project's standing, so a retry prompt would only send
// the driver back into the same refusal.

import Foundation

enum CarPlayProjectRefusalCopy {
    static func phrase(_ refusal: WorkProjectAccessError) -> String {
        switch refusal {
        case .archived:
            String(localized: "carplay.project.archived.speak",
                   defaultValue: "This project is archived. Restore it in Work on your iPhone to continue.")  // xcstrings
        case .selectionRequired:
            String(localized: "carplay.project.selectionRequired.speak",
                   defaultValue: "Choose your active projects in Work on your iPhone to continue.")  // xcstrings
        }
    }

    /// The spoken line for a send-path throw, or nil for anything that is not
    /// a project refusal — the caller then falls through to its ordinary
    /// error mapping.
    static func phrase(for error: Error) -> String? {
        if let refusal = error as? WorkProjectAccessError { return phrase(refusal) }
        switch error as? WorkDeskStoreError {
        case .projectArchived: return phrase(.archived)
        case .projectSelectionRequired: return phrase(.selectionRequired)
        default: return nil
        }
    }
}
