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
}
#endif
