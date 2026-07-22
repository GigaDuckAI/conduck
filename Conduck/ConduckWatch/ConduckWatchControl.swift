import WidgetKit
import SwiftUI
import AppIntents

/// ControlWidget button for recording a transcription on Apple Watch.
/// Surfaces in: Control Center, Smart Stack, Action Button (Ultra), complications.
/// Placeholder copy; brand pass owns final wording.
struct RecordNoteControl: ControlWidget {
    /// Control kind — read from the widget bundle's `ConduckControlKind`
    /// Info.plist key (fed by `$(CONDUCK_BUNDLE_ID_BASE).watch.RecordNoteControl`;
    /// official value is the frozen `ai.gigaduck.AgentRelay`-namespaced kind).
    /// The fallback is a safety net for non-hosted contexts, never the design path.
    private static let kind =
        Bundle.main.object(forInfoDictionaryKey: "ConduckControlKind") as? String
            ?? "conduck.watch.RecordNoteControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: RecordNoteIntent()) {
                Label("GigaAction", systemImage: "waveform")  // xcstrings
            }
        }
        .displayName("GigaAction")  // xcstrings
        .description("Capture a voice transcription with Conduck")  // xcstrings
    }
}
