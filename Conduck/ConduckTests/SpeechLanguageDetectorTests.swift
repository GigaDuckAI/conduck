// SPDX-License-Identifier: Apache-2.0

// Conduck
// SpeechLanguageDetectorTests.swift
//
// Coverage for `SpeechLanguageDetector` (Services/TTS/SpeechLanguageDetector.swift)
// — the content-language hint that lets Apple's on-device synth speak a reply in
// the reply's OWN language instead of the device language.
//
// Pure Foundation + NaturalLanguage type — no AVFoundation, no clock, no network,
// no fakes — so it runs in the unsigned logic pass and never depends on which
// voices the simulator has installed (voice availability is a selection-site
// concern, checked in `SpeechPlayer`/`WatchReplySpeaker`, not here). Dropped into
// the synchronized `ConduckTests` group → auto-included in the test target.
//
// Test scope (per the language-matching design + Codex review): full-sentence
// POSITIVES, short-string FLOOR negatives, mixed-language dominance, and the
// `reconcile` device-region rule. Deliberately NO "gibberish → nil" case — the
// NLLanguageRecognizer model can shift between OS releases, making it flaky.

import XCTest
@testable import Conduck

final class SpeechLanguageDetectorTests: XCTestCase {

    // MARK: - Positives (full sentences → region-qualified BCP-47)

    func testDetectsGerman() {
        XCTAssertEqual(
            SpeechLanguageDetector.detect("Guten Morgen, wie geht es dir heute? Ich hoffe, du hast gut geschlafen."),
            "de-DE")
    }

    func testDetectsSpanish() {
        XCTAssertEqual(
            SpeechLanguageDetector.detect("Buenos días, ¿cómo estás hoy? Espero que hayas dormido bien anoche."),
            "es-ES")
    }

    func testDetectsFrench() {
        XCTAssertEqual(
            SpeechLanguageDetector.detect("Bonjour, comment allez-vous aujourd'hui ? J'espère que vous avez bien dormi."),
            "fr-FR")
    }

    func testDetectsJapanese() {
        // Kana present → the language is pinned even for a short string.
        XCTAssertEqual(
            SpeechLanguageDetector.detect("おはようございます。今日はどんな一日になるでしょうか。よく眠れましたか。"),
            "ja-JP")
    }

    func testDetectsSimplifiedChinese() {
        XCTAssertEqual(
            SpeechLanguageDetector.detect("早上好，今天天气很好，我们一起去公园散步好吗？希望你今天过得愉快。"),
            "zh-CN")
    }

    func testDetectsKorean() {
        XCTAssertEqual(
            SpeechLanguageDetector.detect("안녕하세요, 오늘 기분이 어떠세요? 어젯밤에 잘 주무셨기를 바랍니다."),
            "ko-KR")
    }

    // MARK: - Mixed language → dominant wins

    func testMixedGermanWithEnglishTermStaysGerman() {
        // German structure with an English loan/tech term — the dominant
        // language is German; the reply must not flip to an English voice.
        // Kept decisively German (many function words, one English term) so the
        // margin comfortably clears the confidence gate across OS/model versions.
        XCTAssertEqual(
            SpeechLanguageDetector.detect("Kannst du bitte den Fehler im Backend beheben und mir danach kurz Bescheid geben, damit ich mit der Arbeit weitermachen kann?"),
            "de-DE")
    }

    // MARK: - Short-string floor negatives (below the confidence floor → nil)

    func testShortLatinStringsReturnNil() {
        for s in ["OK", "Ja", "No", "Si"] {
            XCTAssertNil(SpeechLanguageDetector.detect(s), "expected nil for short string \"\(s)\"")
        }
    }

    func testEmptyAndNonLetterStringsReturnNil() {
        for s in ["", "   ", "\n\t", "🎉🎉🎉", "!!!???", "1234 567"] {
            XCTAssertNil(SpeechLanguageDetector.detect(s), "expected nil for non-letter string \"\(s)\"")
        }
    }

    // MARK: - reconcile (device-region preference on a base-language match)

    func testReconcileKeepsDeviceRegionOnSameBaseLanguage() {
        XCTAssertEqual(SpeechLanguageDetector.reconcile(hint: "en-US", deviceCode: "en-GB"), "en-GB")
        XCTAssertEqual(SpeechLanguageDetector.reconcile(hint: "pt-BR", deviceCode: "pt-PT"), "pt-PT")
    }

    func testReconcileIsCaseInsensitiveOnBaseLanguage() {
        XCTAssertEqual(SpeechLanguageDetector.reconcile(hint: "EN-us", deviceCode: "en-GB"), "en-GB")
    }

    func testReconcileUsesHintWhenBaseLanguageDiffers() {
        XCTAssertEqual(SpeechLanguageDetector.reconcile(hint: "de-DE", deviceCode: "en-US"), "de-DE")
        XCTAssertEqual(SpeechLanguageDetector.reconcile(hint: "ja-JP", deviceCode: "en-US"), "ja-JP")
    }

    func testReconcileNilHintReturnsNil() {
        XCTAssertNil(SpeechLanguageDetector.reconcile(hint: nil, deviceCode: "en-US"))
    }

    func testReconcileKeepsDetectedChineseScriptOverDeviceRegion() {
        // zh is the exception: the detector's Simplified/Traditional choice must
        // survive even when the device is another Chinese region — otherwise
        // Simplified content could be read by a Traditional/Cantonese voice.
        XCTAssertEqual(SpeechLanguageDetector.reconcile(hint: "zh-CN", deviceCode: "zh-TW"), "zh-CN")
        XCTAssertEqual(SpeechLanguageDetector.reconcile(hint: "zh-TW", deviceCode: "zh-Hant-HK"), "zh-TW")
    }
}
