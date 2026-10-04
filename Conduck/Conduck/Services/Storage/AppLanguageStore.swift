// SPDX-License-Identifier: Apache-2.0

// App language is a device preference, never an iCloud preference. The paired
// iPhone couriers a versioned selection to Watch; CarPlay runs in its process.
// Missing/unknown choices use English without completing the first-launch gate.
// Speech recognition language and user/AI conversation content are independent.

import Foundation
import AppIntents
import Observation
#if os(watchOS)
import WidgetKit
#endif

nonisolated enum AppLanguage: String, CaseIterable, Sendable, Identifiable {
    case english = "en"
    case spanish = "es"
    case chinese = "zh-Hans"
    case japanese = "ja"

    var id: String { rawValue }
    var nativeName: String {
        switch self {
        case .english: "English"
        case .spanish: "Español"
        case .chinese: "简体中文"
        case .japanese: "日本語"
        }
    }
    var locale: Locale { Locale(identifier: rawValue) }

    static func suggested(preferredLanguages: [String] = Locale.preferredLanguages) -> Self {
        for identifier in preferredLanguages {
            switch identifier.split(separator: "-").first {
            case "en": return .english
            case "es": return .spanish
            case "zh": return .chinese
            case "ja": return .japanese
            default: continue
            }
        }
        return .english
    }
}

extension Notification.Name {
    nonisolated static let appLanguageDidChange = Notification.Name("appLanguageDidChange")
}

@Observable
nonisolated final class AppLanguageStore: @unchecked Sendable {
    static let shared = AppLanguageStore()
    static let selectionKey = "app.language.selection.v1"
    static let watchMessageKey = "appLanguageSelection"
    private static let revisionKey = "app.language.revision.v1"
    private static let sourceKey = "app.language.source.v1"
    private let defaults: any DefaultsStore
    private let lock = NSRecursiveLock()
    private var observationRevision = 0

    init(defaults: any DefaultsStore = SettingsDependencies.processDefault.defaults) {
        self.defaults = defaults
    }

    var selection: AppLanguage? {
        lock.lock()
        defer { lock.unlock() }
        _ = observationRevision
        return AppLanguage(rawValue: defaults.string(forKey: Self.selectionKey) ?? "")
    }
    var language: AppLanguage {
        lock.lock()
        defer { lock.unlock() }
        _ = observationRevision
        return selection ?? .english
    }

    func select(_ language: AppLanguage) {
        lock.lock()
        defaults.set(language.rawValue, forKey: Self.selectionKey)
        let revision = max(defaults.double(forKey: Self.revisionKey) + 1, Date().timeIntervalSince1970 * 1000)
        defaults.set(revision, forKey: Self.revisionKey)
        if defaults.string(forKey: Self.sourceKey) == nil {
            defaults.set(UUID().uuidString, forKey: Self.sourceKey)
        }
        defaults.synchronize()
        observationRevision += 1
        lock.unlock()
        announceChange()
    }

    /// Optional until the phone has made an explicit choice. Absence never
    /// clears the wrist's last received choice (including with an older phone).
    var watchPayload: [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        guard let selection, let source = defaults.string(forKey: Self.sourceKey) else { return nil }
        return ["language": selection.rawValue, "revision": defaults.double(forKey: Self.revisionKey), "source": source]
    }

    @discardableResult
    func inheritFromPhone(_ payload: Any?) -> Bool {
        guard let payload = payload as? [String: Any],
              let raw = payload["language"] as? String, let language = AppLanguage(rawValue: raw),
              let revision = payload["revision"] as? Double, revision.isFinite, revision > 0,
              let source = payload["source"] as? String, UUID(uuidString: source) != nil else { return false }
        lock.lock()
        if defaults.string(forKey: Self.sourceKey) == source,
           revision <= defaults.double(forKey: Self.revisionKey) {
            lock.unlock()
            return false
        }
        defaults.set(language.rawValue, forKey: Self.selectionKey)
        defaults.set(revision, forKey: Self.revisionKey)
        defaults.set(source, forKey: Self.sourceKey)
        defaults.synchronize()
        observationRevision += 1
        lock.unlock()
        announceChange()
        return true
    }

    private func announceChange() {
        Task { @MainActor in
            #if os(watchOS)
            WatchAppShortcuts.updateAppShortcutParameters()
            #else
            ConduckShortcuts.updateAppShortcutParameters()
            #endif
        }
        #if os(watchOS)
        Task { @MainActor in ControlCenter.shared.reloadAllControls() }
        #endif
        let post: @Sendable () -> Void = {
            NotificationCenter.default.post(name: .appLanguageDidChange, object: nil)
            // The existing observer fan-out refreshes phone -> Watch delivery,
            // extension snapshots, menu bar chrome and device Settings views.
            NotificationCenter.default.post(name: Notification.Name("settingsDidChangeRemotely"), object: nil)
        }
        if Thread.isMainThread { post() } else { DispatchQueue.main.async(execute: post) }
    }
}

// Foundation's default Bundle selection follows the OS language. An explicit
// lproj bundle makes errors, notifications, AppKit menus and CarPlay use the
// app's choice too. Keep native initializers at call sites so Xcode still
// extracts string keys and interpolation metadata into the catalogs.
nonisolated enum AppLocalization {
    static var language: AppLanguage { AppLanguageStore.shared.language }
    static var locale: Locale { language.locale }
    static var bundle: Bundle { bundle(for: language, in: .main) }
    static var resourceBundle: LocalizedStringResource.BundleDescription { .atURL(bundle.bundleURL) }

    static func byteCount(_ bytes: Int64, style: ByteCountFormatStyle.Style = .file) -> String {
        bytes.formatted(ByteCountFormatStyle(style: style, locale: locale))
    }

    static func bundle(for language: AppLanguage, in source: Bundle) -> Bundle {
        guard let path = source.path(forResource: language.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return source }
        return bundle
    }
}
