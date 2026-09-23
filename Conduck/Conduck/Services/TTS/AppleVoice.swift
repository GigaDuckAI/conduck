// SPDX-License-Identifier: Apache-2.0

// Conduck
// AppleVoice.swift
//
// The user's choice of Apple on-device voice (iOS / macOS — NOT the Watch
// target, whose `.default`-only voice tier has nothing to pick from).
//
// WHY AN EXPLICIT PICK: Apple never exposes Siri voices to third-party apps,
// but it does expose the downloadable Enhanced and Premium voices (Settings →
// Accessibility → Read & Speak → Voices). `AVSpeechSynthesisVoice(language:)`
// returns only the language default, and it cannot be relied on to follow the
// user's Spoken Content voice choice (a developer-reported iOS 26 regression,
// Apple forums thread 804648). So the app asks for the voice by identifier.
//
// THREE PIECES, split so the policy is testable without AVFoundation:
//   - `AppleVoiceDescriptor` + `AppleVoiceCatalog` — pure: which installed
//     voices the picker offers and in what order. Tests feed plain descriptors
//     (a real `AVSpeechSynthesisVoice` cannot be built with chosen traits).
//   - `LiveAppleVoices` — the thin AVFoundation adapter that produces them.
//   - `AppleVoicePreferences` — the DEVICE-LOCAL storage (App Groups defaults
//     only, never iCloud KVS, never the Watch envelope): installed voices
//     differ per device, so a synced identifier would name a voice the other
//     device lacks. Keyed by the device voice locale, so a device whose
//     language changes starts from the system default for the new language.
//
// SILENCE: `speechVoices()` keeps listing Enhanced/Premium voices that were
// downloaded once and later removed (common after an iOS upgrade), and
// speaking with one produces silence. The list cannot tell them apart, so the
// guard lives at PLAYBACK (`ReplyVoice.startAppleLeg`): a picked voice that
// does not start speaking is replaced by the system default, the
// substitution is shown, and the pick is recorded here as unavailable until
// the user re-picks it, a sample of it plays, or the installed-voice list
// changes. A pick whose voice the list no longer names at all is different:
// that voice was removed, usually on purpose, so the pick is forgotten and
// the device returns to Automatic without a warning (`forgetPickIfRemoved`).
// The mark stores a fingerprint of the installed-voice list, so it
// expires by itself when a download or deletion changes that list — the
// process-lifetime `InstalledVoiceListCache` observers catch the change
// with no Settings screen open. While marked, replies the
// pick would have spoken still carry the substitution marker.
//
// LANGUAGE TAGS: `currentLanguageCode()` can report Mandarin as `cmn-CN` while
// the voices are tagged `zh-CN`; every comparison here goes through
// `AppleVoiceCatalog.canonicalLanguage`.

#if !os(watchOS)
import Foundation
import AVFoundation
import CryptoKit
#if os(iOS)
import UIKit     // UIApplication.didBecomeActiveNotification — fingerprint cache
#else
import AppKit    // NSApplication.didBecomeActiveNotification — fingerprint cache
#endif

// MARK: - Pick (one turn's resolved choice)

/// The picked voice, resolved for the device voice locale it was stored
/// under. `locale` is the device voice language at resolution time
/// (`AVSpeechSynthesisVoice.currentLanguageCode()`).
struct AppleVoicePick: Equatable, Sendable {
    let identifier: String
    let locale: String
    /// The pick failed to start earlier and the installed-voice list has not
    /// changed since: replies it applies to go straight to the default voice,
    /// still marked as a substitution.
    var isUnavailable = false

    /// Whether the pick speaks a reply in `language`. It applies only when
    /// the reply's reconciled language IS the device locale — a German reply
    /// on an English device is read by the German default voice, never by an
    /// English voice with English pronunciation. Reconciliation is
    /// `SpeechLanguageDetector.reconcile`, the same rule `SpeechPlayer` uses,
    /// so `zh-CN` and `zh-TW` stay distinct.
    func applies(toReplyLanguage language: String?) -> Bool {
        let device = AppleVoiceCatalog.canonicalLanguage(locale)
        let requested = SpeechLanguageDetector.reconcile(hint: language, deviceCode: device) ?? device
        return AppleVoiceCatalog.canonicalLanguage(requested) == device
    }
}

// MARK: - Descriptor + catalog (pure)

/// A plain description of one installed Apple voice.
struct AppleVoiceDescriptor: Identifiable, Equatable, Sendable {
    enum Quality: Int, Comparable, Sendable {
        case standard = 0
        case enhanced
        case premium

        static func < (lhs: Quality, rhs: Quality) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let identifier: String
    let name: String
    /// BCP-47 language of the voice (`en-GB`).
    let language: String
    let quality: Quality
    let isNovelty: Bool
    let isPersonal: Bool

    var id: String { identifier }
}

/// Which voices the picker offers, and in what order.
enum AppleVoiceCatalog {

    /// A voice the user may pick for `deviceLocale`: same base language (any
    /// region, so an en-GB device can choose an American voice), except
    /// Chinese, whose region carries the Simplified/Traditional identity and
    /// must match exactly. Novelty voices (Zarvox, Bells, …) and Personal
    /// Voice are never offered — Personal Voice needs its own authorization.
    static func isSelectable(_ voice: AppleVoiceDescriptor, deviceLocale: String) -> Bool {
        guard !voice.isNovelty, !voice.isPersonal else { return false }
        let device = canonicalLanguage(deviceLocale)
        let voiceLanguage = canonicalLanguage(voice.language)
        let deviceBase = SpeechLanguageDetector.baseLanguage(device)
        guard SpeechLanguageDetector.baseLanguage(voiceLanguage) == deviceBase else { return false }
        if deviceBase == "zh" {
            return voiceLanguage == device
        }
        return true
    }

    /// The picker's rows: selectable voices, one per identifier, best quality
    /// first, then by name, then by language.
    static func candidates(from voices: [AppleVoiceDescriptor], deviceLocale: String) -> [AppleVoiceDescriptor] {
        var seen = Set<String>()
        return voices
            .filter { isSelectable($0, deviceLocale: deviceLocale) && seen.insert($0.identifier).inserted }
            .sorted { a, b in
                if a.quality != b.quality { return a.quality > b.quality }
                let byName = a.name.localizedStandardCompare(b.name)
                if byName != .orderedSame { return byName == .orderedAscending }
                return a.language < b.language
            }
    }

    /// One spelling per language tag for comparisons: hyphenated, lowercased,
    /// and Mandarin's `cmn` folded into `zh` (region and script kept).
    static func canonicalLanguage(_ code: String) -> String {
        let tag = code.replacingOccurrences(of: "_", with: "-").lowercased()
        if tag == "cmn" || tag.hasPrefix("cmn-") {
            return "zh" + tag.dropFirst(3)
        }
        return tag
    }
}

// MARK: - AVFoundation adapter

/// The only place AVFoundation voices become descriptors.
enum LiveAppleVoices {

    /// The device voice language — the same code `SpeechPlayer` resolves the
    /// default voice from.
    static func deviceLocale() -> String {
        AVSpeechSynthesisVoice.currentLanguageCode()
    }

    /// Every voice the system lists as installed. May include voices whose
    /// assets were removed — see the file header.
    static func installed() -> [AppleVoiceDescriptor] {
        AVSpeechSynthesisVoice.speechVoices().map { descriptor(for: $0) }
    }

    /// The installed-voice list, cached per process (`InstalledVoiceListCache`):
    /// every reply with a pick reads it, and enumerating every installed voice
    /// per reply is wasted work when the list rarely changes.
    static func installedList() -> InstalledVoiceList {
        InstalledVoiceListCache.live.value()
    }

    /// A stable digest of the installed-voice list. Changes when a voice is
    /// downloaded or removed, which is when an unavailable mark should expire.
    static func fingerprint() -> String {
        installedList().fingerprint
    }

    nonisolated static func readInstalledList() -> InstalledVoiceList {
        InstalledVoiceList(identifiers: AVSpeechSynthesisVoice.speechVoices().map(\.identifier))
    }

    /// Whether the system lists `identifier` as installed — the ONLY signal
    /// `AppleVoicePreferences` treats as the voice being removed. A miss
    /// against the cached list is confirmed with a fresh read before anyone
    /// acts on it, since the cached (or a just-raced) read may predate a
    /// download.
    static func isListed(_ identifier: String) -> Bool {
        if installedList().identifiers.contains(identifier) { return true }
        InstalledVoiceListCache.live.invalidate()
        return installedList().identifiers.contains(identifier)
    }

    /// The voice for `identifier`, or nil when the system cannot resolve it.
    static func descriptor(forIdentifier identifier: String) -> AppleVoiceDescriptor? {
        AVSpeechSynthesisVoice(identifier: identifier).map { descriptor(for: $0) }
    }

    private static func descriptor(for voice: AVSpeechSynthesisVoice) -> AppleVoiceDescriptor {
        let quality: AppleVoiceDescriptor.Quality
        switch voice.quality {
        case .premium: quality = .premium
        case .enhanced: quality = .enhanced
        default: quality = .standard
        }
        return AppleVoiceDescriptor(
            identifier: voice.identifier,
            name: voice.name,
            language: voice.language,
            quality: quality,
            isNovelty: voice.voiceTraits.contains(.isNoveltyVoice),
            isPersonal: voice.voiceTraits.contains(.isPersonalVoice)
        )
    }
}

/// The identifiers the system lists as installed, and their digest.
nonisolated struct InstalledVoiceList: Sendable, Equatable {
    let identifiers: Set<String>
    let fingerprint: String

    init(identifiers: [String]) {
        self.identifiers = Set(identifiers)
        let digest = SHA256.hash(data: Data(self.identifiers.sorted().joined(separator: "\n").utf8))
        fingerprint = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// Holds the installed-voice list between replies. Two signals drop it: the
/// system's voice-list change notification, and the app becoming active — a
/// download or deletion in the system Settings app while this app was
/// suspended may never deliver the first. Observers live for the process, so
/// a removed pick is noticed, and a mark expires, without any Settings screen
/// open.
nonisolated final class InstalledVoiceListCache: @unchecked Sendable {
    static let live: InstalledVoiceListCache = {
        let cache = InstalledVoiceListCache(compute: LiveAppleVoices.readInstalledList)
        #if os(iOS)
        let foreground = UIApplication.didBecomeActiveNotification
        #else
        let foreground = NSApplication.didBecomeActiveNotification
        #endif
        for name in [AVSpeechSynthesizer.availableVoicesDidChangeNotification, foreground] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
                cache.invalidate()
            }
        }
        return cache
    }()

    private let lock = NSLock()
    private let compute: @Sendable () -> InstalledVoiceList
    private var cached: InstalledVoiceList?
    /// Bumped by every invalidation, so a value computed across one is used
    /// for that call but never stored.
    private var generation = 0

    init(compute: @escaping @Sendable () -> InstalledVoiceList) {
        self.compute = compute
    }

    /// Enumerates OUTSIDE the lock: an observer that fires on the posting
    /// thread while the voice list is read calls `invalidate()`, which would
    /// otherwise wait on a lock its own thread holds.
    func value() -> InstalledVoiceList {
        lock.lock()
        if let cached {
            lock.unlock()
            return cached
        }
        let startedAt = generation
        lock.unlock()

        let fresh = compute()

        lock.lock()
        if generation == startedAt { cached = fresh }
        lock.unlock()
        return fresh
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        cached = nil
        generation += 1
    }
}

// MARK: - Device-local storage

/// Reads and writes the pick and its unavailable mark. SYNCHRONOUS over the
/// App-Group suite (the `showDockIconAtLaunch` idiom) so the speak path and
/// the Settings view read it without an actor hop. Never KVS: see the file
/// header.
enum AppleVoicePreferences {

    static func pickedIdentifier(
        forLocale locale: String,
        defaults: any DefaultsStore = SettingsDependencies.processDefault.defaults
    ) -> String? {
        let value = defaults.string(forKey: Constants.appleVoiceKey(forLocale: locale))
        return (value?.isEmpty == false) ? value : nil
    }

    /// Store (or clear, with nil) the pick. Always drops the unavailable mark:
    /// choosing a voice, even the same one again, is the user asking to try it.
    static func setPickedIdentifier(
        _ identifier: String?,
        forLocale locale: String,
        defaults: any DefaultsStore = SettingsDependencies.processDefault.defaults
    ) {
        let key = Constants.appleVoiceKey(forLocale: locale)
        if let identifier, !identifier.isEmpty {
            defaults.set(identifier, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        clearUnavailable(forLocale: locale, defaults: defaults)
    }

    /// True while the stored pick is the identifier that last failed to start
    /// AND the installed-voice list still has the fingerprint it had then.
    /// `fingerprint` defaults to the live list (computed only when a mark for
    /// the current pick exists); tests pass one.
    static func isPickUnavailable(
        forLocale locale: String,
        fingerprint: String? = nil,
        defaults: any DefaultsStore = SettingsDependencies.processDefault.defaults
    ) -> Bool {
        guard let picked = pickedIdentifier(forLocale: locale, defaults: defaults),
              let mark = defaults.string(forKey: Constants.appleVoiceUnavailableKey(forLocale: locale))
        else { return false }
        let parts = mark.split(separator: "\n", maxSplits: 1).map(String.init)
        guard parts.first == picked else { return false }
        guard parts.count == 2 else { return true }
        return parts[1] == (fingerprint ?? LiveAppleVoices.fingerprint())
    }

    /// Mark `identifier` as not starting, against the current installed-voice
    /// list (`fingerprint` defaults to the live one; tests pass one).
    static func markUnavailable(
        _ identifier: String,
        forLocale locale: String,
        fingerprint: String? = nil,
        defaults: any DefaultsStore = SettingsDependencies.processDefault.defaults
    ) {
        let list = fingerprint ?? LiveAppleVoices.fingerprint()
        defaults.set("\(identifier)\n\(list)", forKey: Constants.appleVoiceUnavailableKey(forLocale: locale))
    }

    static func clearUnavailable(
        forLocale locale: String,
        defaults: any DefaultsStore = SettingsDependencies.processDefault.defaults
    ) {
        defaults.removeObject(forKey: Constants.appleVoiceUnavailableKey(forLocale: locale))
    }

    /// Forgets the pick when the system no longer lists its voice, and
    /// returns the pick that remains. A voice gone from the list was removed,
    /// most often on purpose in the system settings, so the device quietly
    /// returns to Automatic: no warning, no substitution marker. (A voice the
    /// list still names but that speaks silence is the other case — the
    /// playback guard marks it unavailable instead, and keeps it.)
    /// `isListed` defaults to the live list; tests pass one.
    @discardableResult
    static func forgetPickIfRemoved(
        forLocale locale: String,
        isListed: ((String) -> Bool)? = nil,
        defaults: any DefaultsStore = SettingsDependencies.processDefault.defaults
    ) -> String? {
        let isListed = isListed ?? { LiveAppleVoices.isListed($0) }
        guard let identifier = pickedIdentifier(forLocale: locale, defaults: defaults) else { return nil }
        guard isListed(identifier) else {
            setPickedIdentifier(nil, forLocale: locale, defaults: defaults)
            return nil
        }
        return identifier
    }

    /// The pick for spoken replies, or nil when nothing is picked or its
    /// voice was removed (`forgetPickIfRemoved`). A pick marked unavailable
    /// comes back with `isUnavailable` set, so replies it applies to use the
    /// default voice AND carry the substitution marker. A listed pick the
    /// system cannot resolve, or that is no longer selectable for this
    /// locale, is marked unavailable here (and kept), so Settings says why the
    /// default is speaking. `deviceLocale` / `isListed` / `lookup` /
    /// `fingerprint` default to the live device (nil); tests pass them.
    static func currentPick(
        deviceLocale: String? = nil,
        isListed: ((String) -> Bool)? = nil,
        lookup: ((String) -> AppleVoiceDescriptor?)? = nil,
        fingerprint: String? = nil,
        defaults: any DefaultsStore = SettingsDependencies.processDefault.defaults
    ) -> AppleVoicePick? {
        let deviceLocale = deviceLocale ?? LiveAppleVoices.deviceLocale()
        let lookup = lookup ?? { LiveAppleVoices.descriptor(forIdentifier: $0) }
        guard let identifier = forgetPickIfRemoved(forLocale: deviceLocale, isListed: isListed, defaults: defaults) else {
            return nil
        }
        if isPickUnavailable(forLocale: deviceLocale, fingerprint: fingerprint, defaults: defaults) {
            return AppleVoicePick(identifier: identifier, locale: deviceLocale, isUnavailable: true)
        }
        guard let voice = lookup(identifier),
              AppleVoiceCatalog.isSelectable(voice, deviceLocale: deviceLocale) else {
            markUnavailable(identifier, forLocale: deviceLocale, fingerprint: fingerprint, defaults: defaults)
            return AppleVoicePick(identifier: identifier, locale: deviceLocale, isUnavailable: true)
        }
        return AppleVoicePick(identifier: identifier, locale: deviceLocale)
    }
}
#endif
