// SPDX-License-Identifier: Apache-2.0

// Work desk copy whose wording depends on a value. The app currently has one
// UI language; keep the singular material label explicit while returning a
// localization resource so both forms remain in the compiled string catalog.

import Foundation

nonisolated enum WorkDeskCopy {
    static func materialCount(_ count: Int) -> LocalizedStringResource {
        if count == 1 {
            return LocalizedStringResource("workdesk.material.count.one", defaultValue: "1 material")
        }
        return LocalizedStringResource("workdesk.material.count", defaultValue: "\(count) materials")
    }
}
