// Conduck
// CarPlaySettings.swift
//
// CarPlay surface. Singleton cache for the STT API key + optional
// language hint so the CarPlay scene can hand them to `STTClient.transcribe`
// without re-entering the `SettingsManager` actor inside the audio/upload
// pipeline (Keychain reads from CarPlay scene context have caused intermittent
// stalls under HFP route negotiation).
//
// Populated at app launch from `ConduckApp.init()` (wiring contract for
// manager — see agent return notes). Reader is fire-and-forget: the cache
// MAY be nil on the very first turn after a cold launch if the user has
// never set a key. In that case `CarPlayRecordingService.processRecording`
// throws `AppError.sttMissingAPIKey`, the scene speaks the resulting copy,
// and returns to the list — no crash.
//
// A later revision swaps `sttAPIKey` for a gateway bearer token field added
// beside it (per `spec.md "Per-Surface Behavior → Apple Watch + Widget"`); current callers won't churn.

#if os(iOS)
import Foundation

@MainActor
final class CarPlaySettings {
    static let shared = CarPlaySettings()

    /// Active STT preset ID (V1 default `mistral-voxtral`; V1.x user-
    /// selectable). Drives provider resolution in `CarPlayRecordingService`
    /// so the right wire-format module is used without a SettingsManager
    /// round-trip mid-turn.
    var activePresetID: String = Constants.sttActivePresetIDDefault

    /// Active STT preset's API key. Nil before `refreshFromSettings()` first
    /// runs, or if the user hasn't onboarded the active preset yet.
    var sttAPIKey: String?

    /// ISO 639-1 language hint forwarded to the active STT provider. Nil =
    /// auto-detect.
    var preferredLanguage: String?

    /// Active preset's optional custom model override (Feature 1 — Custom STT).
    /// Nil = the provider's pinned default model. Populated from the same
    /// atomic `activeSTTSnapshot()` hop as `activePresetID` / `sttAPIKey` so the
    /// CarPlay turn never observes a torn (preset-B + model-A) pairing. The
    /// CarPlay transcribe call wires this through to `STTClient.transcribe`'s
    /// `customModel:` so a Gemini/Qwen override applies on the in-car surface
    /// too. (The BYO custom endpoint itself stays out of CarPlay at V1 — its
    /// `customConfig` is not cached here; a custom-active preset falls through
    /// to the unconfigured/missing-key copy rather than transcribing.)
    var customModel: String?

    private init() {
        // Observe SettingsManager change broadcasts so the
        // CarPlay cache stays current when the user (or another device)
        // switches preset or rotates the API key. Without this, the scene
        // would keep using the old key/preset until the next cold launch.
        // Notification handler hops to main actor to safely touch our
        // properties; the underlying `refreshFromSettings()` is async.
        NotificationCenter.default.addObserver(
            forName: .settingsDidChangeRemotely,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                await CarPlaySettings.shared.refreshFromSettings()
            }
        }
    }

    /// Pull current values from `SettingsManager`. Called at app launch
    /// from `ConduckApp.init()`, on every `.settingsDidChangeRemotely`
    /// fan-out (per-preset key rotation, picker activation, cross-device
    /// KVS change), and any time CarPlay scene activation wants a fresh
    /// read.
    func refreshFromSettings() async {
        // Single atomic actor hop (mirrors the foreground transcribe sites) so
        // presetID / key / customModel always refer to the SAME preset — three
        // separate hops could tear against a concurrent preset switch.
        // Language is read in the same hop. `customConfig` (the BYO
        // endpoint's url/cert/auth) is intentionally NOT cached: CarPlay routes
        // only cloud + Apple providers at V1.
        let snapshot = await SettingsManager.shared.activeSTTSnapshot()
        let lang = await SettingsManager.shared.getPreferredLanguage()
        self.activePresetID = snapshot.presetID
        self.sttAPIKey = snapshot.apiKey
        self.preferredLanguage = lang
        self.customModel = snapshot.customModel
    }
}
#endif
