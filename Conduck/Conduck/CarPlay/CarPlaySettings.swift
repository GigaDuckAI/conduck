// SPDX-License-Identifier: Apache-2.0

// Conduck
// CarPlaySettings.swift
//
// CarPlay surface. Singleton cache for the STT API key + optional
// language hint so the CarPlay scene can hand them to `STTClient.transcribe`
// without re-entering the `SettingsManager` actor inside the audio/upload
// pipeline (Keychain reads from CarPlay scene context have caused intermittent
// stalls under HFP route negotiation). The one exception is a turn that is
// about to be REFUSED for want of a key: that path re-reads live, because a
// cached nil cannot be trusted and a refusal is not the hot path.
//
// Populated at app launch from `ConduckApp.init()` and on every
// `.settingsDidChangeRemotely` fan-out. Reader is fire-and-forget: the cached
// key MAY be nil on the very first turn after a cold launch — because the user
// has never set one, or because the launch happened before first unlock and the
// Keychain could not answer for a key that is present and correct. Those are
// DIFFERENT facts, and this cache does NOT tell them apart: it holds a key or
// it holds nothing. Two things keep them apart where it matters. Inside
// `refreshFromSettings`, the typed read decides whether an unreadable re-read
// may blank a key already cached for the same preset (it may not — I3). And
// `CarPlayRecordingService.processRecording` never asks this cache which fact
// it is looking at: a turn about to be refused re-resolves through
// `STTKeyReadiness.resolve` at capture time, live, and speaks the sentence that
// reading earns, then returns to the list — no crash.
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
    /// runs, for a preset that needs no key at all, if the user hasn't
    /// onboarded the active preset yet, OR if the Keychain could not answer.
    ///
    /// A nil here is therefore NOT evidence of an empty slot, and nothing may
    /// speak a refusal off it: this cache lives for the whole PROCESS, and a
    /// launch before first unlock reads every slot exactly as an empty one —
    /// a nil cached there would otherwise outlive the unlock and cost the driver
    /// the rest of the drive. The refusal lane re-resolves live instead (see the
    /// file header), and `refreshFromSettings` refuses to blank a good cached
    /// key on an unreadable re-read.
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
        // The TYPED read, for the SAME presetID the snapshot resolved, and taken
        // at all only when this preset needs a key — an in-process Apple preset
        // must not touch the Keychain to learn it needs nothing. The cached key
        // is then derived FROM this one read rather than from `snapshot.apiKey`,
        // so the value stored and the verdict the preserve rule below branches
        // on can never be two different readings of one slot (the same one-read
        // rule `SettingsManager.ttsSnapshot` keeps). Off the hot path: this runs
        // at launch and on settings changes, never inside a turn.
        let read: APIKeyReadResult?
        if STTKeyReadiness.requiresKey(provider: snapshot.provider, customConfig: snapshot.customConfig) {
            read = await SettingsManager.shared.apiKeyReadResult(forPresetID: snapshot.presetID)
        } else {
            read = nil
        }
        let resolvedKey: String?
        switch read {
        case .present(let key): resolvedKey = key
        // Both readings leave this cache holding no key — what separates them is
        // the verdict beside it, which is the whole point of storing one.
        case .missing, .unreadable: resolvedKey = nil
        // No read taken: the preset needs no key, so there is none to cache.
        case nil: resolvedKey = nil
        }

        let presetChanged = snapshot.presetID != self.activePresetID
        self.activePresetID = snapshot.presetID
        self.preferredLanguage = lang
        self.customModel = snapshot.customModel
        // An UNREADABLE read is not proof the slot emptied (I3), so it may not
        // blank a key this cache already holds for the SAME preset: a Keychain
        // that stops answering mid-drive would otherwise cost the driver every
        // remaining capture of the session, with no way to fix it from the car.
        // What the cache keeps is the last key it could actually establish. A
        // preset switch invalidates the old key by definition — it belongs to
        // another slot — and `.missing` is a real answer, so both of those
        // overwrite.
        if case .some(.unreadable) = read, !presetChanged, self.sttAPIKey?.isEmpty == false {
            return
        }
        self.sttAPIKey = resolvedKey
    }
}
#endif
