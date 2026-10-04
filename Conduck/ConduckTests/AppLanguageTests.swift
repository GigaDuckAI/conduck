// SPDX-License-Identifier: Apache-2.0

// Language selection must remain device-local, survive restart, and converge
// on Watch across queued, live and replayed phone deliveries. These tests use
// isolated defaults; no account, App Group or credentials are opened.

import XCTest
@testable import Conduck

final class AppLanguageTests: XCTestCase {
    func testFreshInstallFallsBackWithoutCompletingLanguageChoice() {
        let store = AppLanguageStore(defaults: InMemoryDefaultsStore())
        XCTAssertNil(store.selection)
        XCTAssertEqual(store.language, .english)
        XCTAssertNil(store.watchPayload)
    }

    func testChoiceSurvivesRestartAndDoesNotChangeAnotherDevice() {
        let phoneDefaults = InMemoryDefaultsStore()
        let phone = AppLanguageStore(defaults: phoneDefaults)
        let ipad = AppLanguageStore(defaults: InMemoryDefaultsStore())
        phone.select(.spanish)
        XCTAssertEqual(AppLanguageStore(defaults: phoneDefaults).selection, .spanish)
        XCTAssertNil(ipad.selection)
        XCTAssertEqual(ipad.language, .english)
    }

    func testUnknownStoredLanguageRequiresChoice() {
        let defaults = InMemoryDefaultsStore()
        defaults.set("future-language", forKey: AppLanguageStore.selectionKey)
        let store = AppLanguageStore(defaults: defaults)
        XCTAssertNil(store.selection)
        XCTAssertEqual(store.language, .english)
    }

    func testPreferredLanguageSuggestionHonorsSupportedRegionalVariants() {
        XCTAssertEqual(AppLanguage.suggested(preferredLanguages: ["fr-FR", "es-MX"]), .spanish)
        XCTAssertEqual(AppLanguage.suggested(preferredLanguages: ["zh-Hant-TW"]), .chinese)
        XCTAssertEqual(AppLanguage.suggested(preferredLanguages: ["ja-JP"]), .japanese)
        XCTAssertEqual(AppLanguage.suggested(preferredLanguages: ["de-DE"]), .english)
    }

    func testWatchInheritsAndRetainsChoiceAfterRestart() throws {
        let phone = AppLanguageStore(defaults: InMemoryDefaultsStore())
        let watchDefaults = InMemoryDefaultsStore()
        let watch = AppLanguageStore(defaults: watchDefaults)
        phone.select(.japanese)
        XCTAssertTrue(watch.inheritFromPhone(try XCTUnwrap(phone.watchPayload)))
        XCTAssertEqual(AppLanguageStore(defaults: watchDefaults).language, .japanese)
    }

    func testWatchRejectsStaleAndDuplicateDelivery() throws {
        let phone = AppLanguageStore(defaults: InMemoryDefaultsStore())
        let watch = AppLanguageStore(defaults: InMemoryDefaultsStore())
        phone.select(.spanish)
        let old = try XCTUnwrap(phone.watchPayload)
        phone.select(.chinese)
        let latest = try XCTUnwrap(phone.watchPayload)
        XCTAssertTrue(watch.inheritFromPhone(latest))
        XCTAssertFalse(watch.inheritFromPhone(old))
        XCTAssertFalse(watch.inheritFromPhone(latest))
        XCTAssertEqual(watch.language, .chinese)
    }

    func testWatchRejectsMalformedAndAbsentMessagesWithoutResetting() throws {
        let phone = AppLanguageStore(defaults: InMemoryDefaultsStore())
        let watch = AppLanguageStore(defaults: InMemoryDefaultsStore())
        phone.select(.spanish)
        let good = try XCTUnwrap(phone.watchPayload)
        XCTAssertTrue(watch.inheritFromPhone(good))
        let payloads: [Any?] = [nil, "es", [:], ["language": "unknown"],
                               ["language": "ja", "source": UUID().uuidString, "revision": Double.infinity]]
        for payload in payloads {
            XCTAssertFalse(watch.inheritFromPhone(payload))
        }
        XCTAssertEqual(watch.language, .spanish)
    }

    func testNewPairedPhoneCanReplacePriorPhoneChoice() throws {
        let firstPhone = AppLanguageStore(defaults: InMemoryDefaultsStore())
        let newPhone = AppLanguageStore(defaults: InMemoryDefaultsStore())
        let watch = AppLanguageStore(defaults: InMemoryDefaultsStore())
        firstPhone.select(.chinese)
        XCTAssertTrue(watch.inheritFromPhone(try XCTUnwrap(firstPhone.watchPayload)))
        newPhone.select(.english)
        XCTAssertTrue(watch.inheritFromPhone(try XCTUnwrap(newPhone.watchPayload)))
        XCTAssertEqual(watch.language, .english)
    }

    func testFoundationAndResourcesReadExplicitLanguageBundles() {
        for (language, expected) in [(AppLanguage.spanish, "Idioma de la app"),
                                     (.chinese, "应用语言"), (.japanese, "アプリの言語")] {
            let bundle = AppLocalization.bundle(for: language, in: .main)
            let string = String(localized: "appLanguage.label", defaultValue: "App language", bundle: bundle, locale: language.locale)
            let resource = LocalizedStringResource("appLanguage.label", defaultValue: "App language", locale: language.locale, bundle: .atURL(bundle.bundleURL))
            XCTAssertEqual(string, expected)
            XCTAssertEqual(String(localized: resource), expected)
        }
    }

    func testTranslatedPluralResourcesRenderCountsWithoutRawPlaceholders() {
        for (language, noun) in [(AppLanguage.spanish, "archivo"), (.chinese, "文件"), (.japanese, "表示")] {
            let bundle = AppLocalization.bundle(for: language, in: .main)
            for count in [1, 3] {
                let resource = LocalizedStringResource(
                    "thread.outputs.heldBack.type.capped",
                    defaultValue: "Review lists the first ^[\(count) file](inflect: true).",
                    locale: language.locale,
                    bundle: .atURL(bundle.bundleURL)
                )
                let rendered = String(localized: resource)
                XCTAssertTrue(rendered.contains(String(count)), rendered)
                XCTAssertTrue(rendered.contains(noun), rendered)
                XCTAssertFalse(rendered.contains("%"), rendered)
            }
        }
    }
}
