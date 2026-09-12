// SPDX-License-Identifier: Apache-2.0

// Presentation defaults for the project conversation composer. A person's
// disclosure choice wins over later material arrivals. Fitted tablet/desktop
// sheets grow with their content only up to a useful reading height, after
// which the body scrolls and the header/actions remain available.

#if !os(watchOS)
import Foundation

enum WorkDeskComposerPolicy {
    static let maximumSheetHeight: CGFloat = 720

    static func materialsExpanded(total: Int, preference: Bool?) -> Bool {
        preference ?? (total <= 5)
    }

    static func sheetHeight(content: CGFloat, header: CGFloat, footer: CGFloat) -> CGFloat {
        min(maximumSheetHeight, max(320, content + header + footer))
    }
}
#endif
