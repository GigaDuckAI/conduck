// SPDX-License-Identifier: Apache-2.0

#if os(macOS)
import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Voice-capture shortcut (default ⌘⇧1; user-configurable in Settings → General).
    static let toggleVoiceCapture = Self("toggleVoiceCapture", default: .init(.one, modifiers: [.command, .shift]))

    /// Region-capture + voice shortcut (default ⌘⇧2; user-configurable in
    /// Settings → General) for "Screenshot & Ask": drag-select a screen region,
    /// then talk; the cropped screenshot + the transcript are sent together as
    /// one multimodal turn.
    static let captureRegionAndVoice = Self("captureRegionAndVoice", default: .init(.two, modifiers: [.command, .shift]))

    /// Capture-to-Work shortcut (default ⌃⌘W; user-configurable in
    /// Settings → General): the same press that starts a private capture stops
    /// and saves it. Nothing on this lane reaches a gateway, so it carries no
    /// destination readiness check.
    ///
    /// ⌃⌘W rather than the ⌘⇧n family the other two use: ⌘⇧3…5 are system
    /// screenshot shortcuts, so the series has no free neighbour, and ⌘W is
    /// close-window in every app — a Work default that shipped as ⌘⇧W would
    /// read as a typo of it. The Control modifier keeps the mnemonic (W for
    /// Work) without sitting one modifier away from destroying the front window.
    static let captureToWork = Self("captureToWork", default: .init(.w, modifiers: [.control, .command]))
}
#endif
