// SPDX-License-Identifier: Apache-2.0

// Conduck
// ComposerMotion.swift
//
// The composer's shared motion curves. The capture slot collapsing and the
// transcript landing in the field ride ONE spring so they read as one movement;
// on two curves (or one curve and one snap) the landing was a double reflow.
// Reduce Motion is read from the platform directly because the hosts that
// write the draft (`ContentView`, `ConversationLibraryView`) do so inside async
// handlers, outside any view body's environment.

import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor
enum ComposerMotion {
    /// The capture-slot spring; also what a landing transcript animates on.
    static let landingSpring: Animation = .spring(response: 0.34, dampingFraction: 0.82)

    /// `nil` under Reduce Motion — `withAnimation(nil)` applies the change instantly.
    static var landing: Animation? { reduceMotion ? nil : landingSpring }

    /// A row above the composer appearing or leaving (voice recovery, refusal).
    static var rowChange: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.2) }

    static var reduceMotion: Bool {
        #if os(iOS)
        UIAccessibility.isReduceMotionEnabled
        #elseif os(macOS)
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #else
        false
        #endif
    }
}
