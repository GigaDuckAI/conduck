// SPDX-License-Identifier: Apache-2.0

// Conduck
// ProjectActivityRefusalCopy.swift
//
// The words a Chats surface uses when a Work project refuses a new turn —
// archived, or waiting for the free plan's active-project choice. One
// vocabulary for the notice above the composer, the send-path refusal and
// VoiceOver, on every platform: the sentences are the store's own
// (`WorkDeskStoreError`), so a refusal reads the same whether the notice said
// it before the tap or the write raised it after.

import Foundation

enum ProjectActivityRefusalCopy: Equatable {
    case projectArchived
    case projectSelectionRequired

    init(_ refusal: WorkProjectAccessError) {
        switch refusal {
        case .archived: self = .projectArchived
        case .selectionRequired: self = .projectSelectionRequired
        }
    }

    var sentence: String {
        switch self {
        case .projectArchived:
            WorkDeskStoreError.projectArchived.localizedDescription
        case .projectSelectionRequired:
            WorkDeskStoreError.projectSelectionRequired.localizedDescription
        }
    }

    /// VoiceOver announces the ACTION the Work button performs.
    var accessibilityLabel: String {
        switch self {
        case .projectArchived:
            String(localized: "composer.locked.project.archived.a11yLabel",
                   defaultValue: "Open this project in Work")  // xcstrings: chat-ui
        case .projectSelectionRequired:
            String(localized: "composer.locked.project.selection.a11yLabel",
                   defaultValue: "Choose active projects in Work")  // xcstrings: chat-ui
        }
    }

    var accessibilityHint: String {
        switch self {
        case .projectArchived:
            String(localized: "composer.locked.project.archived.a11yHint",
                   defaultValue: "This project is archived. Restore it in Work to send messages.")  // xcstrings: chat-ui
        case .projectSelectionRequired:
            String(localized: "composer.locked.project.selection.a11yHint",
                   defaultValue: "Choose your active projects in Work to send messages.")  // xcstrings: chat-ui
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .projectArchived: "composer.locked.projectArchived"
        case .projectSelectionRequired: "composer.locked.projectSelection"
        }
    }
}
