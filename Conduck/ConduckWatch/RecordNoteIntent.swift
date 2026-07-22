import AppIntents
import Foundation

/// App Intent triggered by the ControlWidget to start a recording on Apple Watch.
/// Runs in the main app process (`.foreground(.immediate)`) and forwards the
/// request to `WatchRecordingCoordinator.shared`. The coordinator queues the
/// request across the identity-resolution wait so a fresh-install Action
/// Button press is not silently dropped.
///
/// Localized strings use `LocalizedStringResource` per Apple's App Intents
/// requirements. Descriptions must not contain platform names (e.g., "Watch")
/// — Apple rejects uploads with ITMS-90626 otherwise.
struct RecordNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "GigaAction"
    static var description: IntentDescription = IntentDescription(
        LocalizedStringResource("Capture a voice transcription with Conduck")
    )
    static var supportedModes: IntentModes = [.foreground(.immediate)]

    @MainActor
    func perform() async throws -> some IntentResult {
        WatchRecordingCoordinator.shared.requestStart()
        return .result()
    }
}
