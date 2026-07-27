// SPDX-License-Identifier: Apache-2.0

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Device capability detection for tailoring user experience
enum DeviceCapabilities {
    // MARK: - Model Identifier

    /// Returns the device model identifier (e.g., "iPhone17,3" for iPhone 16)
    /// In simulator, returns the simulated device identifier if available
    static var modelIdentifier: String {
        #if targetEnvironment(simulator)
        // In simulator, check for simulated device type
        if let simulatedDevice = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulatedDevice
        }
        return "Simulator"
        #else
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        return String(cString: machine)
        #endif
    }

    // MARK: - Action Button Detection

    /// Determines if the device has an Action Button
    ///
    /// Action Button is available on:
    /// - iPhone 15 Pro, 15 Pro Max (iPhone16,1-2)
    /// - iPhone 16, 16 Plus, 16 Pro, 16 Pro Max, 16e (iPhone17,1-5)
    /// - iPhone 17, 17 Pro, 17 Pro Max, iPhone Air (iPhone18,1-4)
    /// - All future iPhones (iPhone19+) are assumed to have Action Button
    static var hasActionButton: Bool {
        let identifier = modelIdentifier

        // Simulator: assume Action Button for testing
        if identifier == "Simulator" {
            return true
        }

        // Extract major version from "iPhoneXX,Y" pattern
        guard let match = identifier.firstMatch(of: /iPhone(\d+),/) else {
            // Not an iPhone (iPad, iPod, etc.) - no Action Button
            return false
        }

        guard let majorVersion = Int(match.1) else {
            return false
        }

        // iPhone 15 Pro series only (identifier 16,1 and 16,2)
        // Note: "iPhone16,x" = iPhone 15 series (Apple's numbering is offset)
        if majorVersion == 16 {
            return identifier == "iPhone16,1" || identifier == "iPhone16,2"
        }

        // iPhone 16 and later (identifier 17+): ALL models have Action Button
        // This includes iPhone 16 series, iPhone 16e, iPhone 17 series, iPhone Air, and future models
        return majorVersion >= 17
    }

    // MARK: - iPad Detection

    /// Determines if the device is an iPad
    static var isiPad: Bool {
        #if os(macOS)
        return false
        #elseif targetEnvironment(simulator)
        // In simulator, check if simulated device is an iPad
        return modelIdentifier.hasPrefix("iPad")
        #else
        return UIDevice.current.userInterfaceIdiom == .pad
        #endif
    }

    // MARK: - Mac Detection

    /// Determines if the device is a Mac
    static var isMac: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    // MARK: - Human-Readable Model Name

    /// Returns a human-readable device name for display purposes
    static var modelName: String {
        let identifier = modelIdentifier

        // Known model mappings
        let modelNames: [String: String] = [
            // iPhone 15 series
            "iPhone15,4": "iPhone 15",
            "iPhone15,5": "iPhone 15 Plus",
            "iPhone16,1": "iPhone 15 Pro",
            "iPhone16,2": "iPhone 15 Pro Max",
            // iPhone 16 series
            "iPhone17,1": "iPhone 16 Pro",
            "iPhone17,2": "iPhone 16 Pro Max",
            "iPhone17,3": "iPhone 16",
            "iPhone17,4": "iPhone 16 Plus",
            "iPhone17,5": "iPhone 16e",
            // iPhone 17 series
            "iPhone18,1": "iPhone 17 Pro",
            "iPhone18,2": "iPhone 17 Pro Max",
            "iPhone18,3": "iPhone 17",
            "iPhone18,4": "iPhone Air",
            // Simulator
            "Simulator": "Simulator",
        ]

        if let name = modelNames[identifier] {
            return name
        }

        // For unknown models, return the identifier
        return identifier
    }

    // MARK: - Trigger Method

    /// The recommended trigger method for this device
    enum TriggerMethod: String {
        case actionButton = "action_button"
        case backTap = "back_tap"
        case controlCenterShortcut = "control_center_shortcut"
        case keyboardShortcut = "keyboard_shortcut"

        var displayName: String {
            switch self {
            case .actionButton:
                return String(localized: "Action Button")
            case .backTap:
                return String(localized: "Back Tap")
            case .controlCenterShortcut:
                return String(localized: "Control Center")
            case .keyboardShortcut:
                return String(localized: "Keyboard Shortcut")
            }
        }

        /// Title for the Settings ▸ Setup card row. Mirrors the trigger the
        /// setup guide will actually teach for this device, so the row never
        /// promises "Action Button" on hardware that lacks one (iPad → Control
        /// Center, older iPhones → Back Tap). Keep in sync with `displayName`.
        var setupCardTitle: String {
            switch self {
            case .actionButton:
                return String(localized: "Set up Action Button") // xcstrings: setup-guide
            case .backTap:
                return String(localized: "Set up Back Tap") // xcstrings: setup-guide
            case .controlCenterShortcut:
                return String(localized: "Set up Control Center") // xcstrings: setup-guide
            case .keyboardShortcut:
                return String(localized: "Set up Keyboard Shortcut") // xcstrings: setup-guide
            }
        }

        /// SF Symbol for the Settings ▸ Setup card row icon, matched to the
        /// trigger (so iPad doesn't show the Action Button glyph).
        var setupCardIcon: String {
            switch self {
            case .actionButton:
                return "button.programmable"
            case .backTap:
                return "hand.tap"
            case .controlCenterShortcut:
                return "switch.2"
            case .keyboardShortcut:
                return "keyboard"
            }
        }

        /// Nudge shown on the onboarding completion screen, tailored to the
        /// device's recommended trigger. `nil` on Mac (`.keyboardShortcut`) —
        /// the keyboard shortcut ships with a working default (and the "How to
        /// Use" guide lives in Settings → General → Menu Bar), so a "go set it
        /// up" tip is redundant noise.
        var completionTip: String? {
            switch self {
            case .actionButton:
                return String(localized: "Tip: once your AI is connected, set up the Action Button in Settings to reach it from any app.") // xcstrings: onboarding-cleanup
            case .backTap:
                return String(localized: "Tip: once your AI is connected, set up Back Tap in Settings to reach it from any app.") // xcstrings: onboarding-cleanup
            case .controlCenterShortcut:
                return String(localized: "Tip: once your AI is connected, add Conduck to Control Center to reach it from any app.") // xcstrings: onboarding-cleanup
            case .keyboardShortcut:
                return nil
            }
        }
    }

    /// Returns the recommended trigger method based on device capabilities
    static var recommendedTriggerMethod: TriggerMethod {
        if isMac {
            return .keyboardShortcut
        } else if isiPad {
            return .controlCenterShortcut
        }
        return hasActionButton ? .actionButton : .backTap
    }

}
