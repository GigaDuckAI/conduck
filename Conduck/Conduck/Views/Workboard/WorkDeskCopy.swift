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

    /// What a project holds, for the line under its title. It reports the
    /// project record's OWN contents and never that the project is "ready":
    /// a send also needs a reachable gateway and present bytes, and only the
    /// brief establishes those, so a header claiming readiness would outrun
    /// what this view can know.
    /// Whether the line under the desk title has anything to say. A project
    /// always does — it reports its own brief state — even when the desk holds
    /// nothing else. Gating that on the desk's material count hid a project's
    /// saved instructions the moment the last material was deleted, because the
    /// count asks about the DESK and the brief is a fact about the project.
    static func showsHeaderSubtitle(deskHasMaterials: Bool, isSearching: Bool, hasProject: Bool) -> Bool {
        deskHasMaterials || isSearching || hasProject
    }

    static func projectBriefState(hasBrief: Bool) -> LocalizedStringResource {
        if hasBrief {
            return LocalizedStringResource("workdesk.project.brief.saved", defaultValue: "Instructions saved")
        }
        return LocalizedStringResource("workdesk.project.brief.none", defaultValue: "No instructions yet")
    }
}
