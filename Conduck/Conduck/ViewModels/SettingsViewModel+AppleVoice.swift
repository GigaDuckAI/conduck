// SPDX-License-Identifier: Apache-2.0

// Conduck
// SettingsViewModel+AppleVoice.swift
//
// The Apple on-device voice picker's view-model half (iOS + macOS). Reads the
// installed voices and the device-local pick through `AppleVoice.swift`; the
// pick never touches `SettingsManager`'s synced settings (installed voices
// differ per device — see that file's header). Picking a voice auditions it
// through the ordinary Apple "Speak a sample" path (`previewTTS`), which is
// also where a pick that no longer plays is marked unavailable, or cleared of
// that mark when it plays again. A mark also expires by itself when the
// installed-voice list changes (its fingerprint), so a refresh is all a
// download needs, and a pick whose voice was deleted is forgotten here
// (back to Automatic). The refresh re-reads that list rather than trusting
// the per-process cache, because the view's change handler may run before
// the cache's own observer drops the old value.

import Foundation

extension SettingsViewModel {

    /// Re-read the installed voices and this device's pick. Cheap enough to
    /// call on every appearance, on return to the foreground, and on the
    /// system's voice-list change notification.
    func refreshAppleVoices() {
        InstalledVoiceListCache.live.invalidate()
        let locale = LiveAppleVoices.deviceLocale()
        let options = AppleVoiceCatalog.candidates(from: LiveAppleVoices.installed(), deviceLocale: locale)
        let stored = AppleVoicePreferences.pickedIdentifier(forLocale: locale)
        let pick = AppleVoicePreferences.forgetPickIfRemoved(forLocale: locale)
        // A forgotten pick takes its old sample result with it: a "didn't
        // play" message must not linger under Automatic.
        if pick != stored, ttsPreviewStates[TTSProvider.appleTTS.id] != .checking {
            ttsPreviewStates[TTSProvider.appleTTS.id] = nil
        }
        appleVoiceOptions = options
        appleVoicePickID = pick
        if let pick {
            appleVoicePickUnavailable = AppleVoicePreferences.isPickUnavailable(forLocale: locale)
                || !options.contains { $0.identifier == pick }
        } else {
            appleVoicePickUnavailable = false
        }
    }


    /// Store `identifier` as this device's voice (nil = Automatic, the system
    /// default) and audition it. Choosing a voice always clears its
    /// unavailable mark — it is the user asking to try it again.
    func selectAppleVoice(_ identifier: String?) async {
        AppleVoicePreferences.setPickedIdentifier(identifier, forLocale: LiveAppleVoices.deviceLocale())
        refreshAppleVoices()
        await previewTTS(for: TTSProvider.appleTTS.id)
    }

    /// The picked voice's descriptor when it is still installed, else nil.
    var appleVoicePick: AppleVoiceDescriptor? {
        guard let appleVoicePickID else { return nil }
        return appleVoiceOptions.first { $0.identifier == appleVoicePickID }
    }

    /// The Settings copy for a picked voice that will not play — shown by
    /// the preview and on the picker. Names where to fix it, per platform.
    static var appleVoiceUnavailableMessage: String {
        #if os(macOS)
        String(
            localized: "settings.voice.apple.voice.unavailable.mac",
            defaultValue: "This voice didn't play. Download it again in System Settings → Accessibility → Read & Speak (the info button next to System Voice), then click it here to try again, or pick another. Replies use the system voice until then."
        )
        #else
        String(
            localized: "settings.voice.apple.voice.unavailable.ios",
            defaultValue: "This voice didn't play. Download it again in Settings → Accessibility → Read & Speak → Voices, then tap it here to try again, or pick another. Replies use the system voice until then."
        )
        #endif
    }
}
