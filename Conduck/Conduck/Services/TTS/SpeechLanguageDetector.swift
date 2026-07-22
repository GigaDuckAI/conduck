// Conduck
// SpeechLanguageDetector.swift
//
// Detects the dominant natural language of a sanitized agent reply so Apple's
// on-device `AVSpeechSynthesizer` can speak it in a voice for THAT language
// instead of the DEVICE language. STT is language-agnostic (the user speaks any
// language), so a reply comes back in whatever language the user used; the cloud
// TTS providers auto-detect language from the text, but Apple — the fresh-install
// default AND the universal offline/error fallback on every surface — does not:
// it picks `AVSpeechSynthesisVoice(language: currentLanguageCode())` (the device
// language), so a German reply on an English device is read by an English voice.
// This helper supplies the missing content-language hint.
//
// CROSS-PLATFORM: compiles into BOTH the iOS/macOS `Conduck` target and the
// `ConduckWatch Watch App` target (like `SpeechSegmenter.swift`). Foundation +
// NaturalLanguage ONLY — deliberately NO AVFoundation: voice AVAILABILITY is
// checked at the selection site (`SpeechPlayer.selectVoice` / `WatchReplySpeaker`),
// which keeps this type deterministically unit-testable regardless of which
// voices the running simulator/device happens to have installed.
//
// PRIVACY: the reply text is privacy-sensitive — NEVER logged here.
//
// WHY A CONFIDENCE GATE: Apple's own `NLLanguageRecognizer` header warns language
// identification is unreliable on short strings (especially < ~30 chars). A wrong
// guess would pick a WORSE voice than the device default (e.g. mis-flag "OK." as
// Italian). So `detect` returns nil unless it is confident — and a nil hint means
// the selection site keeps today's device-language behavior. The gate is
// script-conditioned: Latin short strings ("Ja."/"No.") are ambiguous and need a
// real length floor, but a few kana/Hangul characters already pin the language,
// and Han-only text (Chinese vs kanji-only Japanese) is genuinely ambiguous so it
// is held to a TIGHTER probability bar.

import Foundation
import NaturalLanguage

enum SpeechLanguageDetector {

    /// Cap on how much of the reply the recognizer inspects — language is a
    /// whole-text property, so the leading prefix is plenty and keeps detection
    /// cheap on the main actor for very long replies.
    private static let inspectionPrefix = 2000

    /// Detect the reply's dominant language and return a REGION-QUALIFIED BCP-47
    /// code (`"de-DE"`, `"ja-JP"`, `"zh-CN"`, …) that `AVSpeechSynthesisVoice`
    /// can resolve, or `nil` when detection is not confident enough or the
    /// language has no curated voice mapping. `nil` = "no opinion" → the caller
    /// keeps the device-language voice.
    static func detect(_ text: String) -> String? {
        let sample = String(text.prefix(inspectionPrefix))

        // Single pass: count letters + note which disambiguating scripts appear.
        var letterCount = 0
        var latinLetterCount = 0
        var hasKana = false
        var hasHangul = false
        var hasHan = false
        for scalar in sample.unicodeScalars {
            guard CharacterSet.letters.contains(scalar) else { continue }
            letterCount += 1
            switch scalar.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF65...0xFF9F, 0x1B000...0x1B16F:
                hasKana = true                                   // Hiragana / Katakana (incl. halfwidth + supplement)
            case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F, 0xD7B0...0xD7FF:
                hasHangul = true                                 // Hangul syllables + Jamo (incl. Extended-A/B)
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF, 0x20000...0x2FA1F:
                hasHan = true                                    // CJK ideographs (incl. Ext-B…F above the BMP)
            case 0x0041...0x007A, 0x00C0...0x024F, 0x1E00...0x1EFF:
                latinLetterCount += 1                            // Latin + Latin-1/Extended + Extended Additional (Vietnamese tone marks)
            default:
                break
            }
        }

        // Script-conditioned gate. Kana/Hangul pin the language even in a few
        // characters; Han-only is Chinese/Japanese-ambiguous → tighter bar; a
        // Latin-heavy string needs real length before ID is trustworthy; other
        // non-Latin scripts (Cyrillic/Arabic/Greek/…) are self-disambiguating.
        let floor: Int
        let minTopProbability: Double
        let minMargin: Double
        if hasKana || hasHangul {
            floor = 3;  minTopProbability = 0.70; minMargin = 0.20
        } else if hasHan {
            floor = 4;  minTopProbability = 0.85; minMargin = 0.30
        } else if latinLetterCount * 2 >= letterCount {
            floor = 12; minTopProbability = 0.70; minMargin = 0.20
        } else {
            floor = 4;  minTopProbability = 0.70; minMargin = 0.20
        }
        guard letterCount >= floor else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let dominant = recognizer.dominantLanguage, dominant != .undetermined else { return nil }

        // `languageHypotheses` returns an UNORDERED dictionary — sort it
        // ourselves. Require the top hypothesis to agree with `dominantLanguage`
        // (they normally do; a disagreement means low confidence → bail).
        let hypotheses = recognizer.languageHypotheses(withMaximum: 2)
        let ranked = hypotheses.sorted { $0.value > $1.value }
        guard let top = ranked.first, top.key == dominant else { return nil }
        let secondProbability = ranked.count > 1 ? ranked[1].value : 0
        guard top.value >= minTopProbability, (top.value - secondProbability) >= minMargin else { return nil }

        return bcp47(for: dominant)
    }

    /// Reconcile a detected `hint` against the device voice language: when the
    /// two share the SAME base language, prefer the device code so a British user
    /// keeps `en-GB` (and a Portuguese user `pt-PT`) instead of being forced to
    /// the curated majority region (`en-US` / `pt-BR`). Different base languages
    /// → use the hint. `nil` hint → `nil` (no opinion).
    ///
    /// Consequence: an English reply on an English-language device reconciles to
    /// the device code → the selection is byte-identical to today (zero
    /// behavior change for the majority-language case).
    static func reconcile(hint: String?, deviceCode: String) -> String? {
        guard let hint else { return nil }
        let hintBase = baseLanguage(hint)
        // Chinese carries its Simplified/Traditional identity in the region/script
        // subtag (zh-CN vs zh-TW / zh-HK), which the detector already resolved
        // from the text's script. A same-base device region must NOT override it
        // — that could read Simplified content in a Traditional / Cantonese voice.
        // Every OTHER language's base match is a pure accent choice (en-GB vs
        // en-US, pt-PT vs pt-BR), where keeping the device region is what we want.
        guard hintBase != "zh" else { return hint }
        return hintBase == baseLanguage(deviceCode) ? deviceCode : hint
    }

    /// Lowercased base-language subtag. Uses Foundation's `Locale.Language`
    /// (the codebase idiom — cf. `AppleSpeechRunner`) so script-first, legacy,
    /// 3-letter, and underscore-delimited identifiers canonicalize correctly.
    private static func baseLanguage(_ code: String) -> String {
        (Locale.Language(identifier: code).languageCode?.identifier ?? code).lowercased()
    }

    /// Curated `NLLanguage` → region-qualified BCP-47 map. Covers the languages
    /// Apple ships default (compact) voices for; an UNMAPPED language returns nil
    /// (→ device-language fallback). Hand-curated on purpose — it doubles as the
    /// self-documenting supported set, with no opaque likely-subtags derivation.
    /// Ambiguous-region languages pick the majority default (`pt-BR`, `en-US`);
    /// `reconcile` protects the device-region case.
    private static func bcp47(for language: NLLanguage) -> String? {
        switch language {
        case .arabic:            return "ar-001"
        case .bulgarian:         return "bg-BG"
        case .bengali:           return "bn-IN"
        case .catalan:           return "ca-ES"
        case .czech:             return "cs-CZ"
        case .danish:            return "da-DK"
        case .german:            return "de-DE"
        case .greek:             return "el-GR"
        case .english:           return "en-US"
        case .spanish:           return "es-ES"
        case .finnish:           return "fi-FI"
        case .french:            return "fr-FR"
        case .hebrew:            return "he-IL"
        case .hindi:             return "hi-IN"
        case .croatian:          return "hr-HR"
        case .hungarian:         return "hu-HU"
        case .indonesian:        return "id-ID"
        case .italian:           return "it-IT"
        case .japanese:          return "ja-JP"
        case .kannada:           return "kn-IN"
        case .korean:            return "ko-KR"
        case .malay:             return "ms-MY"
        case .norwegian:         return "nb-NO"
        case .dutch:             return "nl-NL"
        case .polish:            return "pl-PL"
        case .portuguese:        return "pt-BR"
        case .romanian:          return "ro-RO"
        case .russian:           return "ru-RU"
        case .slovak:            return "sk-SK"
        case .swedish:           return "sv-SE"
        case .tamil:             return "ta-IN"
        case .telugu:            return "te-IN"
        case .thai:              return "th-TH"
        case .turkish:           return "tr-TR"
        case .ukrainian:         return "uk-UA"
        case .vietnamese:        return "vi-VN"
        case .simplifiedChinese: return "zh-CN"
        case .traditionalChinese: return "zh-TW"
        default:                 return nil
        }
    }
}
