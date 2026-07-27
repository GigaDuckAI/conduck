// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Language representation with ISO code and display name
struct Language: Identifiable, Hashable {
    let id: String
    let code: String
    let name: String
    let nativeName: String

    init(code: String, name: String, nativeName: String? = nil) {
        self.id = code
        self.code = code
        self.name = name
        self.nativeName = nativeName ?? name
    }
}

/// Comprehensive language list backing the STT "Spoken language" hint picker.
enum LanguageList {
    /// Common languages (displayed first in picker)
    static let commonLanguages: [Language] = [
        Language(code: "en", name: "English"),
        Language(code: "es", name: "Spanish", nativeName: "Español"),
        Language(code: "fr", name: "French", nativeName: "Français"),
        Language(code: "de", name: "German", nativeName: "Deutsch"),
        Language(code: "it", name: "Italian", nativeName: "Italiano"),
        Language(code: "pt", name: "Portuguese", nativeName: "Português"),
        Language(code: "zh", name: "Chinese", nativeName: "中文"),
        Language(code: "ja", name: "Japanese", nativeName: "日本語"),
        Language(code: "ko", name: "Korean", nativeName: "한국어"),
        Language(code: "ar", name: "Arabic", nativeName: "العربية"),
        Language(code: "ru", name: "Russian", nativeName: "Русский"),
        Language(code: "hi", name: "Hindi", nativeName: "हिन्दी"),
    ]

    /// All supported languages (alphabetically sorted)
    static let allLanguages: [Language] = [
        Language(code: "af", name: "Afrikaans"),
        Language(code: "sq", name: "Albanian", nativeName: "Shqip"),
        Language(code: "am", name: "Amharic", nativeName: "አማርኛ"),
        Language(code: "ar", name: "Arabic", nativeName: "العربية"),
        Language(code: "hy", name: "Armenian", nativeName: "Հայերեն"),
        Language(code: "az", name: "Azerbaijani", nativeName: "Azərbaycan"),
        Language(code: "eu", name: "Basque", nativeName: "Euskara"),
        Language(code: "be", name: "Belarusian", nativeName: "Беларуская"),
        Language(code: "bn", name: "Bengali", nativeName: "বাংলা"),
        Language(code: "bs", name: "Bosnian", nativeName: "Bosanski"),
        Language(code: "bg", name: "Bulgarian", nativeName: "Български"),
        Language(code: "ca", name: "Catalan", nativeName: "Català"),
        Language(code: "zh", name: "Chinese", nativeName: "中文"),
        Language(code: "hr", name: "Croatian", nativeName: "Hrvatski"),
        Language(code: "cs", name: "Czech", nativeName: "Čeština"),
        Language(code: "da", name: "Danish", nativeName: "Dansk"),
        Language(code: "nl", name: "Dutch", nativeName: "Nederlands"),
        Language(code: "en", name: "English"),
        Language(code: "et", name: "Estonian", nativeName: "Eesti"),
        Language(code: "fi", name: "Finnish", nativeName: "Suomi"),
        Language(code: "fr", name: "French", nativeName: "Français"),
        Language(code: "gl", name: "Galician", nativeName: "Galego"),
        Language(code: "ka", name: "Georgian", nativeName: "ქართული"),
        Language(code: "de", name: "German", nativeName: "Deutsch"),
        Language(code: "el", name: "Greek", nativeName: "Ελληνικά"),
        Language(code: "gu", name: "Gujarati", nativeName: "ગુજરાતી"),
        Language(code: "he", name: "Hebrew", nativeName: "עברית"),
        Language(code: "hi", name: "Hindi", nativeName: "हिन्दी"),
        Language(code: "hu", name: "Hungarian", nativeName: "Magyar"),
        Language(code: "is", name: "Icelandic", nativeName: "Íslenska"),
        Language(code: "id", name: "Indonesian", nativeName: "Bahasa Indonesia"),
        Language(code: "ga", name: "Irish", nativeName: "Gaeilge"),
        Language(code: "it", name: "Italian", nativeName: "Italiano"),
        Language(code: "ja", name: "Japanese", nativeName: "日本語"),
        Language(code: "kn", name: "Kannada", nativeName: "ಕನ್ನಡ"),
        Language(code: "kk", name: "Kazakh", nativeName: "Қазақ"),
        Language(code: "ko", name: "Korean", nativeName: "한국어"),
        Language(code: "lv", name: "Latvian", nativeName: "Latviešu"),
        Language(code: "lt", name: "Lithuanian", nativeName: "Lietuvių"),
        Language(code: "mk", name: "Macedonian", nativeName: "Македонски"),
        Language(code: "ms", name: "Malay", nativeName: "Bahasa Melayu"),
        Language(code: "ml", name: "Malayalam", nativeName: "മലയാളം"),
        Language(code: "mt", name: "Maltese", nativeName: "Malti"),
        Language(code: "mr", name: "Marathi", nativeName: "मराठी"),
        Language(code: "mn", name: "Mongolian", nativeName: "Монгол"),
        Language(code: "ne", name: "Nepali", nativeName: "नेपाली"),
        Language(code: "no", name: "Norwegian", nativeName: "Norsk"),
        Language(code: "fa", name: "Persian", nativeName: "فارسی"),
        Language(code: "pl", name: "Polish", nativeName: "Polski"),
        Language(code: "pt", name: "Portuguese", nativeName: "Português"),
        Language(code: "pa", name: "Punjabi", nativeName: "ਪੰਜਾਬੀ"),
        Language(code: "ro", name: "Romanian", nativeName: "Română"),
        Language(code: "ru", name: "Russian", nativeName: "Русский"),
        Language(code: "sr", name: "Serbian", nativeName: "Српски"),
        Language(code: "sk", name: "Slovak", nativeName: "Slovenčina"),
        Language(code: "sl", name: "Slovenian", nativeName: "Slovenščina"),
        Language(code: "es", name: "Spanish", nativeName: "Español"),
        Language(code: "sw", name: "Swahili", nativeName: "Kiswahili"),
        Language(code: "sv", name: "Swedish", nativeName: "Svenska"),
        Language(code: "ta", name: "Tamil", nativeName: "தமிழ்"),
        Language(code: "te", name: "Telugu", nativeName: "తెలుగు"),
        Language(code: "th", name: "Thai", nativeName: "ไทย"),
        Language(code: "tr", name: "Turkish", nativeName: "Türkçe"),
        Language(code: "uk", name: "Ukrainian", nativeName: "Українська"),
        Language(code: "ur", name: "Urdu", nativeName: "اردو"),
        Language(code: "uz", name: "Uzbek", nativeName: "Oʻzbek"),
        Language(code: "vi", name: "Vietnamese", nativeName: "Tiếng Việt"),
        Language(code: "cy", name: "Welsh", nativeName: "Cymraeg"),
    ]

    /// Find language by code
    static func language(for code: String) -> Language? {
        return allLanguages.first { $0.code == code }
    }

    /// Get native name for language code
    static func nativeName(for code: String) -> String {
        return language(for: code)?.nativeName ?? code.uppercased()
    }
}
