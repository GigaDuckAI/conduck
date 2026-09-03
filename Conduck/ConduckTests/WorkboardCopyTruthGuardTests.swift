// SPDX-License-Identifier: Apache-2.0
// Conduck
// WorkboardCopyTruthGuardTests.swift
//
// COPY GUARD over the Work desk's user-facing strings, read from the shipped
// catalog on disk rather than through `String(localized:)` — the catalog's `en`
// value is what a user actually reads, and it wins over a source
// `defaultValue:` at runtime, so a guard that resolves the string proves
// nothing about the row that ships.
//
// Four rules, each of which held false copy in front of a user before it
// existed:
//
// (1) VOCABULARY. Work opens, keeps and removes; it never sends, dispatches,
// briefs, or holds a draft. There is no code path from the desk to a gateway,
// so any Work string implying one describes software that does not exist.
// (2) THE SYNC PROMISE. `WorkMaterialStoragePolicy` keeps a payload over
// `Constants.workboardSyncCeilingBytes` in the device-local vault behind a
// reattach, so the tutorial's sync line must name that lane instead of
// promising every byte on every device.
// (3) TWO SURFACES WHOSE COPY IS ONLY TRUE KEY BY KEY. The voice sheet is the
// one Work surface with an outbound destination — the speech provider the
// person configured — so it must name it instead of denying it, and it may not
// deny that the destination is an AI either: several selectable providers ARE
// AI models. What it may promise is the boundary the desk enforces, which is
// that the audio is transcribed and never becomes part of a conversation. The
// desk's sync banner speaks about cards, because the shared Chat rows it would
// otherwise borrow speak about conversations.
// (4) BOTH DIRECTIONS OF THE CATALOG. A key referenced in source with no row
// renders from its `defaultValue:` and can never be translated; a row no
// source references is dead weight that outlives the surface it was written
// for. Neither is visible in a diff.
// (5) THE DISCARD IS THE ONE DESTRUCTIVE AFFORDANCE ON A WORK SURFACE. Nothing
// reclaims a Work capture the desk never accepted, so the retry card's discard
// deletes the only copy of what somebody said; its confirmation has to name
// the device the bytes are on and say they do not come back.
//
// Rules (1) to (3) are scoped to `workboard.*`. Rule (4) also covers
// `pendingRetry.*`, the retry card's own keys: the card is a Work surface, but
// its queue serves Chat as well, so those rows may legitimately say *sent* and
// are deliberately kept out of the vocabulary scan. `intent.workboardCapture.*`
// is Shortcut-facing identity whose copy legitimately says "without sending it
// to an AI", and it is declared twice (app and Watch) so the one-target scan
// below cannot see both halves.

import XCTest

final class WorkboardCopyTruthGuardTests: XCTestCase {

    private static let keyPrefix = "workboard."

    /// The prefixes rule (4) walks in both directions. `pendingRetry.*` joins
    /// `workboard.*` because the retry card is a Work surface: the keys carry
    /// the other prefix only because the queue behind them also holds Chat
    /// captures, and a row nobody references would be just as invisible there.
    private static let catalogPrefixes = ["workboard.", "pendingRetry."]

    /// The one Work-prefixed string that may talk about sending: the menu bar's
    /// Ask button is the CHAT lane, and it really does reach the gateway. It
    /// lives under a `workboard.` key because it shares the quick-capture
    /// popover, not because Work sends anything.
    private static let chatLaneKeys: Set<String> = ["workboard.menuBar.ask.help"]

    /// The inertness promise. Removed before the vocabulary scan so the one
    /// sentence Work is allowed to say about sending does not trip the rule
    /// that exists to keep every OTHER sentence from saying it.
    private static let inertnessPhrases = [
        "nothing is sent",
        "nothing was sent",
        "nothing has been sent"
    ]

    /// The Work strings whose lane DOES have an outbound hop, for which the
    /// promise above is not stripped — the vocabulary rule has to see the word.
    /// A recording handed to the voice sheet is transcribed by whichever
    /// speech provider the person configured, and `STTClient`'s provider table
    /// is mostly cloud vendors, so on every configuration but Apple's
    /// on-device engine the audio leaves the device. `testTheVoiceSheetNames…`
    /// below states the positive form of the same rule.
    private static let outboundHopKeys: Set<String> = ["workboard.voice.privacy"]

    /// Denials of AI involvement. A Work recording's one destination is the
    /// speech provider the person picked, and the roster it is picked from
    /// holds AI models: `STTProvider.openAI` is `gpt-4o-transcribe`,
    /// `STTProvider.gemini` is a Gemini model, and a custom OpenAI-compatible
    /// endpoint can be anything — frequently the same vendor already answering
    /// the person's chat. So a Work string may not say the audio never reaches
    /// an AI. It is a phrase list rather than a ban on the word: the honest
    /// sentence is allowed to mention the AI it is drawing a boundary against.
    private static let aiDenialPhrases = [
        "never to an ai",
        "not to an ai",
        "never reaches an ai",
        "no ai sees",
        "without an ai",
        "never an ai"
    ]

    /// The desk's own sync notice. Three rows, one per actionable account
    /// state, kept separate from `sync.icloud.banner.*` because those say
    /// "conversations" and the desk holds cards.
    private static let deskSyncBannerKeys = [
        "workboard.sync.banner.noAccount",
        "workboard.sync.banner.restricted",
        "workboard.sync.banner.quotaExceeded"
    ]

    private static let retiredWords = [
        "send", "sends", "sending", "sent",
        "draft", "drafts",
        "brief", "briefs", "briefing",
        "dispatch", "dispatches", "dispatched"
    ]

    // MARK: - Catalog access

    private func catalogStrings() throws -> [String: Any] {
        let url = RefusalLaneSource.projectContainerURL
            .appendingPathComponent("Conduck/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try XCTUnwrap(json?["strings"] as? [String: Any], "the catalog has no strings table")
    }

    /// The `en` value of one row, or nil for a row that carries none (a
    /// bare-English literal whose key IS the string). A row with plural
    /// variations has no `stringUnit` of its own; `pluralVariations` reads
    /// those.
    private func englishValue(_ entry: Any) -> String? {
        guard let entry = entry as? [String: Any],
              let localizations = entry["localizations"] as? [String: Any],
              let english = localizations["en"] as? [String: Any],
              let unit = english["stringUnit"] as? [String: Any] else { return nil }
        return unit["value"] as? String
    }

    /// The `en` plural categories of one row, keyed by category name, or nil
    /// for a row that carries a single value.
    private func pluralVariations(_ entry: Any) -> [String: String]? {
        guard let entry = entry as? [String: Any],
              let localizations = entry["localizations"] as? [String: Any],
              let english = localizations["en"] as? [String: Any],
              let variations = english["variations"] as? [String: Any],
              let plural = variations["plural"] as? [String: Any] else { return nil }
        var values: [String: String] = [:]
        for (category, body) in plural {
            if let unit = (body as? [String: Any])?["stringUnit"] as? [String: Any],
               let value = unit["value"] as? String {
                values[category] = value
            }
        }
        return values.isEmpty ? nil : values
    }

    /// Every `.swift` file in the app target, concatenated. The Watch app and
    /// the two share extensions are deliberately excluded: they own their own
    /// catalogs, and a key they alone reference would read as dead here.
    private func appTargetSource() throws -> String {
        let root = RefusalLaneSource.projectContainerURL.appendingPathComponent("Conduck")
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil),
            "the app target's source tree is unreadable — update this guard's path derivation"
        )
        var combined = ""
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            combined += (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        XCTAssertFalse(combined.isEmpty, "no Swift source found under \(root.path)")
        return combined
    }

    // MARK: - (1) Vocabulary

    func testNoWorkStringDescribesSendingDispatchingOrADraft() throws {
        let strings = try catalogStrings()

        for (key, entry) in strings where key.hasPrefix(Self.keyPrefix) {
            guard !Self.chatLaneKeys.contains(key), let value = englishValue(entry) else { continue }

            var scanned = value.lowercased()
            if !Self.outboundHopKeys.contains(key) {
                for phrase in Self.inertnessPhrases {
                    scanned = scanned.replacingOccurrences(of: phrase, with: " ")
                }
            }
            let words = Set(scanned.split(whereSeparator: { !$0.isLetter }).map(String.init))
            let offenders = words.intersection(Self.retiredWords).sorted()

            XCTAssertTrue(
                offenders.isEmpty,
                "\(key) says \(offenders.joined(separator: ", ")): \(value)\n"
                    + "Work opens, keeps and removes. It has no gateway API, so a Work "
                    + "string may not describe sending, dispatching, or a draft."
            )
        }
    }

    /// The voice sheet is the one Work surface with a destination, so its
    /// privacy line has to name that destination rather than deny it, and it
    /// has to describe the destination truthfully — which rules out both
    /// "nothing is sent" and "never to an AI". The inertness phrases are
    /// checked on the RAW value: the vocabulary scan above deliberately stops
    /// exempting this key, and this is the assertion that says why in the
    /// failure message.
    func testTheVoiceSheetNamesTheSpeechProviderAndDeniesNeitherTheHopNorTheAI() throws {
        let strings = try catalogStrings()
        let value = try XCTUnwrap(
            englishValue(try XCTUnwrap(strings["workboard.voice.privacy"])),
            "the voice sheet's privacy line must carry an English value"
        )
        let lowered = value.lowercased()

        for phrase in Self.inertnessPhrases {
            XCTAssertFalse(
                lowered.contains(phrase),
                "the recording is handed to the speech provider the person configured, and "
                    + "STTClient's table is mostly cloud vendors, so this line may not promise "
                    + "that nothing is sent: \(value)"
            )
        }
        XCTAssertFalse(
            lowered.contains("nothing leaves"),
            "same rule, said the other way round: \(value)"
        )
        for phrase in Self.aiDenialPhrases {
            XCTAssertFalse(
                lowered.contains(phrase),
                "gpt-4o-transcribe, Gemini and a custom OpenAI-compatible endpoint are all "
                    + "selectable speech providers and all of them are AI models, so this line "
                    + "may not promise the recording never reaches one: \(value)"
            )
        }
        XCTAssertTrue(
            lowered.contains("speech provider"),
            "the line has to name where the audio actually goes: \(value)"
        )
        XCTAssertTrue(
            lowered.contains("conversation"),
            "having given up both denials, the line has to state the boundary that does "
                + "hold — the audio is transcribed and never becomes part of a conversation, "
                + "which is what no code path from the desk to a gateway actually buys: \(value)"
        )
    }

    /// The desk banner's three rows. They exist because the shared
    /// `sync.icloud.banner.*` copy says "conversations" and the surface
    /// rendering it is a desk of cards; a row that drifts back to the Chat
    /// word puts a claim about the wrong data in front of the reader.
    func testTheDeskSyncBannerSpeaksAboutCardsRatherThanConversations() throws {
        let strings = try catalogStrings()

        for key in Self.deskSyncBannerKeys {
            let value = try XCTUnwrap(
                englishValue(try XCTUnwrap(strings[key], "\(key) has no catalog row")),
                "\(key) must carry an English value"
            )
            let lowered = value.lowercased()

            XCTAssertTrue(
                lowered.contains("card"),
                "\(key) is the DESK's banner and has to name what the desk holds: \(value)"
            )
            XCTAssertFalse(
                lowered.contains("conversation"),
                "\(key) renders over a board of cards; only the Chat rows may say "
                    + "conversations: \(value)"
            )
            XCTAssertTrue(
                lowered.contains("icloud"),
                "\(key) has to name the account the person can actually go and fix: \(value)"
            )
        }
    }

    // MARK: - (2) The sync promise

    func testTheTutorialSyncLineNamesTheDeviceLocalLane() throws {
        let strings = try catalogStrings()
        let value = try XCTUnwrap(
            englishValue(try XCTUnwrap(strings["workboard.tutorial.point.review"])),
            "the tutorial's third line must carry an English value"
        )
        let lowered = value.lowercased()

        XCTAssertTrue(
            lowered.contains("icloud"),
            "the line still has to teach that the desk syncs: \(value)"
        )
        XCTAssertFalse(
            lowered.contains("everything"),
            "a payload over Constants.workboardSyncCeilingBytes never leaves the device "
                + "that captured it, so the line may not promise everything: \(value)"
        )
        XCTAssertFalse(
            lowered.contains("all your devices"),
            "an oversized payload reaches no other device until it is reattached there: \(value)"
        )
    }

    // MARK: - (4) Both directions of the catalog

    func testEveryWorkKeyInSourceHasACatalogRow() throws {
        let strings = try catalogStrings()
        let source = try appTargetSource()

        for prefix in Self.catalogPrefixes {
            for key in workKeys(in: source, prefix: prefix) {
                XCTAssertNotNil(
                    strings[key],
                    "\(key) is referenced in the app target but has no catalog row — it would "
                        + "render from its defaultValue and could never be translated."
                )
            }
        }
    }

    func testEveryWorkCatalogRowIsReferencedInSource() throws {
        let strings = try catalogStrings()
        let source = try appTargetSource()

        for key in strings.keys
        where Self.catalogPrefixes.contains(where: { key.hasPrefix($0) }) {
            XCTAssertTrue(
                source.contains("\"\(key)\""),
                "\(key) has a catalog row no app-target source references — it outlived "
                    + "the surface it was written for."
            )
        }
    }

    // MARK: - (5) The one destructive affordance

    /// The retry card's discard deletes bytes nothing else will ever reclaim,
    /// so its confirmation carries two claims rather than one: WHERE the
    /// recording is, and that it does not come back. A dialog that says only
    /// "are you sure?" asks a question the person cannot answer.
    func testTheDiscardConfirmationSaysWhereTheRecordingIsAndThatItIsGone() throws {
        let strings = try catalogStrings()
        let body = try XCTUnwrap(
            englishValue(try XCTUnwrap(
                strings["pendingRetry.card.discard.confirm.body"],
                "the discard confirmation has no catalog row"
            )),
            "the discard confirmation must carry an English value"
        )
        let lowered = body.lowercased()

        XCTAssertTrue(
            lowered.contains("this device"),
            "the recording is in this device's app-group container and syncs nowhere, so the "
                + "confirmation has to say which device loses it: \(body)"
        )
        XCTAssertTrue(
            lowered.contains("cannot be recovered") || lowered.contains("can't be recovered"),
            "nothing reclaims a Work capture the desk never accepted, so this is the only "
                + "copy of what somebody said and the dialog may not imply it can be got "
                + "back: \(body)"
        )
    }

    /// The backlog count renders on the iOS card and, at exactly one, in the
    /// menu bar's own error state — so a single `%lld recordings waiting` row
    /// ships "1 recordings waiting" to a Mac user. The catalog carries the
    /// plural categories; the source `defaultValue:` cannot.
    func testTheBacklogCountRowCarriesPluralVariations() throws {
        let strings = try catalogStrings()
        let variations = try XCTUnwrap(
            pluralVariations(try XCTUnwrap(
                strings["pendingRetry.card.count"],
                "the backlog count has no catalog row"
            )),
            "pendingRetry.card.count renders a number and must carry plural variations — "
                + "MenuBar/DictationService.swift renders it at a count of one."
        )

        let one = try XCTUnwrap(variations["one"], "the singular category is missing")
        let other = try XCTUnwrap(variations["other"], "the plural category is missing")
        XCTAssertFalse(
            one.contains("recordings"),
            "the singular category still reads as a plural: \(one)"
        )
        XCTAssertTrue(other.contains("recordings"), "the plural category reads as a singular: \(other)")
    }

    /// Every `"<prefix>…"` literal in the given text. These keys are always
    /// written out in full at the call site, so a literal scan is exact here in
    /// a way it would not be for the catalog's formatted-literal rows.
    private func workKeys(in source: String, prefix: String) -> Set<String> {
        var keys: Set<String> = []
        var remainder = Substring(source)
        while let open = remainder.range(of: "\"\(prefix)") {
            let afterQuote = remainder.index(after: open.lowerBound)
            guard let close = remainder[afterQuote...].firstIndex(of: "\"") else { break }
            let candidate = String(remainder[afterQuote..<close])
            if candidate.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" }) {
                keys.insert(candidate)
            }
            remainder = remainder[remainder.index(after: close)...]
        }
        return keys
    }
}
