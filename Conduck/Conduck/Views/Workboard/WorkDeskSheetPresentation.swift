// SPDX-License-Identifier: Apache-2.0

// Conversation preparation and its material chooser share a page presentation.
// Compact iPhone and iPad windows use the available height for the keyboard;
// wider windows fit the content's bounded ideal height. Neither introduces a
// navigation toolbar: each page owns its visible header and single action row.

import SwiftUI

extension View {
    func workDeskConversationSheetPresentation() -> some View {
        modifier(WorkDeskConversationSheetPresentation())
    }
}

private struct WorkDeskConversationSheetPresentation: ViewModifier {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS)
        if horizontalSizeClass == .compact {
            content
                .presentationSizing(.page)
                .presentationDetents([.large])
        } else {
            content
                .presentationSizing(.page.fitted(horizontal: false, vertical: true))
        }
        #else
        content
            .presentationSizing(.page.fitted(horizontal: false, vertical: true))
        #endif
    }
}
