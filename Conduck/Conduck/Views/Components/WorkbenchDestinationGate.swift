// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkbenchDestinationGate.swift
//
// The Work/Chats shell keeps BOTH destinations mounted so an unsent Chat draft
// and an unfinished Work thought survive the section switch, and animates only
// root opacity. Opacity hides pixels; it does not silence the other channels a
// mounted view still owns — toolbar/title preferences, and sheets, alerts and
// system pickers, which are presented by the window rather than by the view's
// own layer. Without a gate, a hidden destination can float a picker over the
// visible one or re-anchor a sheet on return.
//
// This file owns the whole rule: the environment value naming which destination
// is on screen, and the ONE binding wrapper every gated presentation uses.

import SwiftUI

private struct WorkbenchDestinationIsActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether the destination reading this value is the one on screen. Every
    /// mounted destination reads it before contributing navigation chrome or
    /// originating a presentation.
    var workbenchDestinationIsActive: Bool {
        get { self[WorkbenchDestinationIsActiveKey.self] }
        set { self[WorkbenchDestinationIsActiveKey.self] = newValue }
    }
}

extension Binding where Value == Bool {
    /// Only the active destination may ORIGINATE a presentation; a dismissal is
    /// always accepted, so the deactivation sweep can still tear down whatever
    /// was already on screen when the destination went inactive.
    func gated(by isActive: Bool) -> Binding<Bool> {
        Binding(
            get: { isActive && wrappedValue },
            set: { newValue in
                if !newValue || isActive { wrappedValue = newValue }
            }
        )
    }
}

extension Binding {
    /// The `item:`-style presentation form of the same rule, with `nil` as the
    /// dismissed state.
    func gated<Wrapped>(by isActive: Bool) -> Binding<Wrapped?> where Value == Wrapped? {
        Binding<Wrapped?>(
            get: { isActive ? wrappedValue : nil },
            set: { newValue in
                if newValue == nil || isActive { wrappedValue = newValue }
            }
        )
    }
}
