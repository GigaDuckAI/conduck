// SPDX-License-Identifier: Apache-2.0

// Conduck
// AppleVoiceTests.swift
//
// The pure half of the Apple voice picker (`Services/TTS/AppleVoice.swift`):
// when a pick applies to a reply, which installed voices are offered and in
// what order, and the device-local storage of the pick and its unavailable
// mark. Voices are plain `AppleVoiceDescriptor`s — a real
// `AVSpeechSynthesisVoice` can't be built with chosen quality/traits, so the
// AVFoundation adapter is left to device QA. iOS/macOS only.

#if !os(watchOS)
import XCTest
@testable import Conduck

@MainActor
final class AppleVoiceTests: XCTestCase {

    private func voice(
        _ identifier: String,
        _ language: String,
        _ quality: AppleVoiceDescriptor.Quality = .standard,
        name: String? = nil,
        novelty: Bool = false,
        personal: Bool = false
    ) -> AppleVoiceDescriptor {
        AppleVoiceDescriptor(
            identifier: identifier,
            name: name ?? identifier,
            language: language,
            quality: quality,
            isNovelty: novelty,
            isPersonal: personal
        )
    }

    // MARK: - When a pick applies

    func testPickAppliesOnlyToRepliesInTheDeviceLanguage() {
        let pick = AppleVoicePick(identifier: "ava", locale: "en-GB")
        XCTAssertTrue(pick.applies(toReplyLanguage: nil),
                      "No detected language → the device language → the pick.")
        XCTAssertTrue(pick.applies(toReplyLanguage: "en-US"),
                      "Same base language reconciles to the device locale → the pick.")
        XCTAssertFalse(pick.applies(toReplyLanguage: "de-DE"),
                       "A German reply must never be read by the English pick.")
    }

    func testChinesePickDoesNotCrossSimplifiedAndTraditional() {
        let pick = AppleVoicePick(identifier: "meijia", locale: "zh-TW")
        XCTAssertTrue(pick.applies(toReplyLanguage: "zh-TW"))
        XCTAssertFalse(pick.applies(toReplyLanguage: "zh-CN"),
                       "Simplified content keeps its own default voice on a Traditional device.")
    }

    /// Measured on macOS: a Simplified Chinese device reports `cmn-CN` while
    /// its Mandarin voices are tagged `zh-CN` (Traditional: `cmn-TW`/`zh-TW`).
    func testMandarinDeviceTagsMatchChineseVoiceTags() {
        XCTAssertTrue(AppleVoiceCatalog.isSelectable(voice("tingting", "zh-CN"), deviceLocale: "cmn-CN"))
        XCTAssertTrue(AppleVoiceCatalog.isSelectable(voice("meijia", "zh-TW"), deviceLocale: "cmn-TW"))
        XCTAssertFalse(AppleVoiceCatalog.isSelectable(voice("meijia", "zh-TW"), deviceLocale: "cmn-CN"))
        let pick = AppleVoicePick(identifier: "tingting", locale: "cmn-CN")
        XCTAssertTrue(pick.applies(toReplyLanguage: "zh-CN"))
        XCTAssertTrue(pick.applies(toReplyLanguage: nil))
        XCTAssertFalse(pick.applies(toReplyLanguage: "zh-TW"))
    }

    // MARK: - Which voices are offered

    func testSelectableVoicesShareTheBaseLanguageAndExcludeNoveltyAndPersonal() {
        XCTAssertTrue(AppleVoiceCatalog.isSelectable(voice("a", "en-US"), deviceLocale: "en-GB"),
                      "An en-GB device may pick an American voice.")
        XCTAssertFalse(AppleVoiceCatalog.isSelectable(voice("b", "fr-FR"), deviceLocale: "en-GB"))
        XCTAssertFalse(AppleVoiceCatalog.isSelectable(voice("c", "en-US", novelty: true), deviceLocale: "en-US"))
        XCTAssertFalse(AppleVoiceCatalog.isSelectable(voice("d", "en-US", personal: true), deviceLocale: "en-US"))
    }

    func testChineseCandidatesRequireTheExactRegion() {
        XCTAssertTrue(AppleVoiceCatalog.isSelectable(voice("a", "zh-CN"), deviceLocale: "zh-CN"))
        XCTAssertFalse(AppleVoiceCatalog.isSelectable(voice("b", "zh-TW"), deviceLocale: "zh-CN"))
    }

    func testCandidatesAreFilteredDedupedAndSortedBestFirst() {
        let voices = [
            voice("std-b", "en-US", .standard, name: "Bruce"),
            voice("prem-z", "en-GB", .premium, name: "Zoe"),
            voice("enh-a", "en-AU", .enhanced, name: "Alex"),
            voice("prem-a", "en-US", .premium, name: "Ava"),
            voice("prem-a", "en-US", .premium, name: "Ava"),      // listed twice
            voice("fr", "fr-FR", .premium, name: "Amélie"),       // other language
            voice("bells", "en-US", .standard, name: "Bells", novelty: true)
        ]
        let ids = AppleVoiceCatalog.candidates(from: voices, deviceLocale: "en-US").map(\.identifier)
        XCTAssertEqual(ids, ["prem-a", "prem-z", "enh-a", "std-b"])
    }

    // MARK: - Device-local storage

    func testCurrentPickIsNilWhenNothingIsPicked() {
        let store = InMemoryDefaultsStore()
        XCTAssertNil(AppleVoicePreferences.currentPick(deviceLocale: "en-US", lookup: { _ in nil }, defaults: store))
    }

    func testCurrentPickReturnsAnInstalledSelectablePick() {
        let store = InMemoryDefaultsStore()
        AppleVoicePreferences.setPickedIdentifier("ava", forLocale: "en-US", defaults: store)
        let pick = AppleVoicePreferences.currentPick(
            deviceLocale: "en-US",
            lookup: { [self] id in voice(id, "en-US", .premium) },
            defaults: store
        )
        XCTAssertEqual(pick, AppleVoicePick(identifier: "ava", locale: "en-US"))
    }

    func testAPickMarkedUnavailableComesBackFlagged() {
        let store = InMemoryDefaultsStore()
        AppleVoicePreferences.setPickedIdentifier("ava", forLocale: "en-US", defaults: store)
        AppleVoicePreferences.markUnavailable("ava", forLocale: "en-US", fingerprint: "list-1", defaults: store)
        let pick = AppleVoicePreferences.currentPick(
            deviceLocale: "en-US", lookup: { [self] id in voice(id, "en-US") },
            fingerprint: "list-1", defaults: store
        )
        XCTAssertEqual(pick?.isUnavailable, true,
                       "Replies skip it for the default voice — and still carry the substitution marker.")
        XCTAssertEqual(AppleVoicePreferences.pickedIdentifier(forLocale: "en-US", defaults: store), "ava",
                       "Marking unavailable keeps the pick itself.")
    }

    /// A download or deletion changes the installed-voice list; the mark
    /// expires by itself, with no Settings screen open to observe it.
    func testTheMarkExpiresWhenTheInstalledVoicesChange() {
        let store = InMemoryDefaultsStore()
        AppleVoicePreferences.setPickedIdentifier("ava", forLocale: "en-US", defaults: store)
        AppleVoicePreferences.markUnavailable("ava", forLocale: "en-US", fingerprint: "list-1", defaults: store)
        XCTAssertTrue(AppleVoicePreferences.isPickUnavailable(forLocale: "en-US", fingerprint: "list-1", defaults: store))
        XCTAssertFalse(AppleVoicePreferences.isPickUnavailable(forLocale: "en-US", fingerprint: "list-2", defaults: store))
        let pick = AppleVoicePreferences.currentPick(
            deviceLocale: "en-US", lookup: { [self] id in voice(id, "en-US") },
            fingerprint: "list-2", defaults: store
        )
        XCTAssertEqual(pick?.isUnavailable, false, "The next reply tries the pick again.")
    }

    func testAPickTheSystemNoLongerKnowsIsMarkedUnavailable() {
        let store = InMemoryDefaultsStore()
        AppleVoicePreferences.setPickedIdentifier("gone", forLocale: "en-US", defaults: store)
        let pick = AppleVoicePreferences.currentPick(
            deviceLocale: "en-US", lookup: { _ in nil }, fingerprint: "list-1", defaults: store
        )
        XCTAssertEqual(pick?.isUnavailable, true)
        XCTAssertTrue(AppleVoicePreferences.isPickUnavailable(forLocale: "en-US", fingerprint: "list-1", defaults: store),
                      "Settings must be able to say why the default voice is speaking.")
    }

    func testPickingAgainClearsTheUnavailableMark() {
        let store = InMemoryDefaultsStore()
        AppleVoicePreferences.setPickedIdentifier("ava", forLocale: "en-US", defaults: store)
        AppleVoicePreferences.markUnavailable("ava", forLocale: "en-US", fingerprint: "list-1", defaults: store)
        AppleVoicePreferences.setPickedIdentifier("ava", forLocale: "en-US", defaults: store)
        XCTAssertFalse(AppleVoicePreferences.isPickUnavailable(forLocale: "en-US", fingerprint: "list-1", defaults: store))
    }

    func testAMarkForADifferentVoiceDoesNotBlockTheCurrentPick() {
        let store = InMemoryDefaultsStore()
        AppleVoicePreferences.setPickedIdentifier("ava", forLocale: "en-US", defaults: store)
        AppleVoicePreferences.markUnavailable("zoe", forLocale: "en-US", fingerprint: "list-1", defaults: store)
        XCTAssertFalse(AppleVoicePreferences.isPickUnavailable(forLocale: "en-US", fingerprint: "list-1", defaults: store))
    }

    func testPicksAreKeptPerLocale() {
        let store = InMemoryDefaultsStore()
        AppleVoicePreferences.setPickedIdentifier("ava", forLocale: "en-US", defaults: store)
        XCTAssertNil(AppleVoicePreferences.pickedIdentifier(forLocale: "de-DE", defaults: store),
                     "A device whose language changes starts from the default for the new language.")
    }

    /// The pick names a voice installed on THIS device, so it must never
    /// reach iCloud KVS or the synced per-provider voice slot that also rides
    /// the Watch envelope.
    func testThePickNeverLeavesTheDevice() {
        let locale = "en-US"
        defer {
            AppleVoicePreferences.setPickedIdentifier(nil, forLocale: locale)
            TestStores.defaults.removeObject(forKey: Constants.appleVoiceUnavailableKey(forLocale: locale))
        }
        AppleVoicePreferences.setPickedIdentifier("ava", forLocale: locale)
        AppleVoicePreferences.markUnavailable("ava", forLocale: locale, fingerprint: "list-1")

        XCTAssertEqual(TestStores.defaults.string(forKey: Constants.appleVoiceKey(forLocale: locale)), "ava")
        let kvsKeys = TestStores.kvs.dictionaryRepresentation().keys
        XCTAssertFalse(kvsKeys.contains { $0.hasPrefix("tts.appleVoice") },
                       "The Apple voice pick must never be written to iCloud KVS.")
        XCTAssertNil(TestStores.defaults.string(forKey: Constants.ttsVoiceKey(for: TTSProvider.appleTTS.id)),
                     "The synced `tts.voice.apple-tts` slot (Watch envelope) stays untouched.")
        XCTAssertFalse(Constants.appleVoiceKey(forLocale: locale).hasPrefix(Constants.ttsVoiceKey(for: "")),
                       "The key must stay outside the `tts.voice.` prefix the KVS inbound mirror scans.")
    }

    /// Replies read the fingerprint while a pick is marked; the voice list is
    /// enumerated once, then again only after a change signal.
    func testFingerprintIsComputedOnceUntilInvalidated() {
        let calls = FingerprintCalls()
        let cache = VoiceListFingerprintCache { calls.next() }
        XCTAssertEqual(cache.value(), "list-1")
        XCTAssertEqual(cache.value(), "list-1")
        XCTAssertEqual(calls.count, 1)
        cache.invalidate()
        XCTAssertEqual(cache.value(), "list-2", "A voice-list change or foregrounding re-reads the list.")
        XCTAssertEqual(calls.count, 2)
    }

    /// A voice-list change posted while the list is being read must neither
    /// deadlock nor leave the pre-change value cached.
    func testAnInvalidationDuringTheReadIsNotLost() {
        let calls = FingerprintCalls()
        let cache = VoiceListFingerprintCache { calls.next() }
        calls.onFirstRead = { cache.invalidate() }
        XCTAssertEqual(cache.value(), "list-1", "The call itself still gets the value it read.")
        XCTAssertEqual(cache.value(), "list-2", "The read that raced the change is not kept.")
        XCTAssertEqual(cache.value(), "list-2")
        XCTAssertEqual(calls.count, 2)
    }

    // MARK: - Diagnostics signature

    func testConfigSignatureIsUnchangedWithoutAPickAndDistinctWithOne() {
        let base = TTSSnapshot(providerID: "apple-tts", apiKey: nil, keyState: .notRequired,
                               voice: nil, customModel: nil, customConfig: nil)
        var picked = base
        picked.appleVoice = AppleVoicePick(identifier: "ava", locale: "en-US")

        XCTAssertEqual(
            TTSOutcomeLog.configSignature(for: base),
            TTSOutcomeLog.configSignature(providerID: "apple-tts", voice: nil, customModel: nil, customConfig: nil),
            "Signatures recorded without a pick keep their existing value."
        )
        XCTAssertNotEqual(TTSOutcomeLog.configSignature(for: base), TTSOutcomeLog.configSignature(for: picked))
    }
}

private nonisolated final class FingerprintCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    /// Runs inside the first read, outside this counter's lock.
    var onFirstRead: (@Sendable () -> Void)?

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func next() -> String {
        lock.lock()
        calls += 1
        let n = calls
        lock.unlock()
        if n == 1 { onFirstRead?() }
        return "list-\(n)"
    }
}
#endif
