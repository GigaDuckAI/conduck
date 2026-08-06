// SPDX-License-Identifier: Apache-2.0

// Conduck
// HeaderIdentitySeedTests.swift
//
// Coverage for `ConversationDetailViewModel.seedHeaderIdentity` — the mint-time
// fill of the session header memo.
//
// The regression these pin: `warmHeaderMemo()` can only know about rows that
// already existed when it last ran, so a conversation created by the send path
// was ALWAYS a memo miss. The VM bound to it a line later therefore opened on
// the generic "Personal AI" placeholder and only reached the real gateway name
// after `resolveBackendDisplayName()`'s actor hops — visible as the title-bar
// pill flickering "Personal AI" between the gateway the user picked and the
// gateway that answers. The seed closes that gap by handing the memo the ref the
// row was minted with, before anything binds a VM to it.
//
// Construction mirrors `ConversationDetailViewModelInitialLoadTests`: a direct
// `@MainActor` init, then assertions with NO `await` in between — that gap is
// exactly the first render, before the init-scheduled `reload()` Task can run.
// An assertion that survives it is an assertion about frame one.

import XCTest
@testable import Conduck

@MainActor
final class HeaderIdentitySeedTests: XCTestCase {

    private let defaults = TestStores.defaults

    override func setUp() async throws {
        try await super.setUp()
        wipe()
    }

    override func tearDown() async throws {
        wipe()
        try await super.tearDown()
    }

    /// `TestStores` and the header memo are BOTH process-global — an earlier
    /// class in the same host can leave a gateway URL or token behind, which
    /// would silently satisfy the availability assertion below for the wrong
    /// reason. Wipe all three stores, not the two roster keys.
    ///
    /// The memo reset also keeps `testSeedStillLandsWhenTheMemoIsFull` from
    /// leaving it at capacity, where every later `warmHeaderMemo()` in the run
    /// would hit its stop-when-full guard and fill nothing.
    private func wipe() {
        TestStores.removeAll()
        ConversationDetailViewModel.resetHeaderMemoForTesting()
    }

    /// A just-minted row: no title snippet, `createdAt == lastActivityAt`.
    private func mintedRecord(backend: String, snippet: String? = nil) -> ConversationRecord {
        let now = Date()
        return ConversationRecord(
            id: UUID(),
            title: nil,
            createdAt: now,
            lastActivityAt: now,
            sessionID: UUID().uuidString,
            backend: backend,
            titleSnippet: snippet
        )
    }

    /// Persist a roster straight into the App-Group JSON so `gatewayBadgeRoster()`
    /// can resolve a custom ref's NAME — mirrors `CustomGatewayRegistryTests`.
    private func seedPersistedRoster(_ list: [CustomGateway]) {
        guard let data = try? JSONEncoder().encode(list) else {
            return XCTFail("roster encode failed")
        }
        defaults.set(data, forKey: Constants.customGatewaysRegistryKey)
    }

    // MARK: - The frame-one guarantee

    /// The core case: seed with a built-in ref, then build the VM the way a bind
    /// does. The gateway name must be right on the very first render.
    func testSeededBuiltinRefNamesTheGatewayOnFrameOne() async {
        let record = mintedRecord(backend: RemoteAgentRef.builtin(.openclaw).rawString)
        await ConversationDetailViewModel.seedHeaderIdentity(
            for: record,
            ref: .builtin(.openclaw),
            hasTurns: false
        )

        let vm = ConversationDetailViewModel(conversationID: record.id)

        XCTAssertEqual(vm.backendDisplayName, RemoteAgentBackend.openclaw.displayName,
                       "A seeded mint must render its own gateway before any "
                       + "resolve lands — never the \"Personal AI\" placeholder.")
        XCTAssertEqual(vm.boundRef, .builtin(.openclaw),
                       "The seed carries the binding, not just its display name.")
    }

    /// Without a seed the placeholder is what shows — the defect this exists to
    /// remove. Pinning it keeps the test above honest: if the VM's pre-resolve
    /// default ever stopped being the placeholder, the assertion above would pass
    /// for the wrong reason.
    func testUnseededConversationStillOpensOnThePlaceholder() {
        let vm = ConversationDetailViewModel(conversationID: UUID())

        XCTAssertEqual(vm.backendDisplayName, String(localized: "Personal AI"),
                       "An unseeded, un-warmed conversation has nothing to name "
                       + "on frame one — that gap is what the seed closes.")
        XCTAssertNil(vm.boundRef)
    }

    /// A custom gateway resolves through the roster snapshot the seed captured,
    /// so the pill shows the user's own name and not the generic fallback.
    func testSeededCustomRefResolvesItsRosterName() async {
        let gateway = CustomGateway(id: UUID(), name: "LiteLLM", model: nil)
        seedPersistedRoster([gateway])
        let ref = RemoteAgentRef.custom(gateway.id)
        let record = mintedRecord(backend: ref.rawString)

        await ConversationDetailViewModel.seedHeaderIdentity(
            for: record,
            ref: ref,
            hasTurns: false
        )
        let vm = ConversationDetailViewModel(conversationID: record.id)

        XCTAssertEqual(vm.backendDisplayName, "LiteLLM",
                       "A custom ref must resolve against the roster captured at "
                       + "seed time, not degrade to the generic custom label.")
        XCTAssertEqual(vm.boundRef, ref)
    }

    // MARK: - hasTurns is a parameter, not an inference

    /// A fresh mint has no turns, so the header must not offer the clone
    /// affordance on its first frame.
    func testFreshMintSeedsWithoutTurns() async {
        let record = mintedRecord(backend: RemoteAgentRef.builtin(.hermes).rawString)
        await ConversationDetailViewModel.seedHeaderIdentity(
            for: record,
            ref: .builtin(.hermes),
            hasTurns: false
        )

        let vm = ConversationDetailViewModel(conversationID: record.id)

        XCTAssertFalse(vm.hasTurns,
                       "A row created by the send path has no turns yet; the "
                       + "clone chevron must stay off until one lands.")
    }

    /// The clone case, and the reason `hasTurns` is a parameter: a clone copies
    /// the source's turns but inherits only its OPTIONAL title snippet, and an
    /// attachment-only first turn writes none. Deriving `hasTurns` from the
    /// snippet — the way the bulk warm does — would report "no turns" here and
    /// pop the clone chevron in a frame late.
    func testCloneShapedSeedKeepsTurnsWithNoTitleSnippet() async {
        let record = mintedRecord(
            backend: RemoteAgentRef.builtin(.openrouter).rawString,
            snippet: nil
        )
        await ConversationDetailViewModel.seedHeaderIdentity(
            for: record,
            ref: .builtin(.openrouter),
            hasTurns: true
        )

        let vm = ConversationDetailViewModel(conversationID: record.id)

        XCTAssertTrue(vm.hasTurns,
                      "A clone carries its source's turns even when it carries no "
                      + "snippet — the seed must be told, not left to guess.")
    }

    /// The seed and the bulk warm race on a clone: `ConversationStore` posts
    /// `.conversationsDidChange` before returning the cloned record, and macOS
    /// re-warms on that post. If the warm lands first it fills the entry from the
    /// nil snippet as "no turns", so the seed must correct that ONE field rather
    /// than bail on the existing entry — otherwise the chevron still pops in late
    /// on exactly the rows `hasTurns` was made a parameter for.
    func testCloneSeedCorrectsTurnsOnAnEntryARacingWarmAlreadyFilled() async {
        let record = mintedRecord(
            backend: RemoteAgentRef.builtin(.openclaw).rawString,
            snippet: nil
        )
        // Stands in for the warm that won the race: same row, snippet-derived
        // "no turns".
        await ConversationDetailViewModel.seedHeaderIdentity(
            for: record,
            ref: .builtin(.openclaw),
            hasTurns: false
        )
        await ConversationDetailViewModel.seedHeaderIdentity(
            for: record,
            ref: .builtin(.openclaw),
            hasTurns: true
        )

        let vm = ConversationDetailViewModel(conversationID: record.id)

        XCTAssertTrue(vm.hasTurns,
                      "A clone seed losing the race to the bulk warm must still "
                      + "correct `hasTurns`, the one field the warm has to guess.")
    }

    // MARK: - Availability comes from the configured set

    /// With nothing configured, the seeded ref cannot be available — the header
    /// must say so rather than optimistically claim it is, which would suppress
    /// the deleted-gateway recovery banner for a beat.
    func testSeedReportsUnavailableWhenNothingIsConfigured() async {
        let record = mintedRecord(backend: RemoteAgentRef.builtin(.openclaw).rawString)
        await ConversationDetailViewModel.seedHeaderIdentity(
            for: record,
            ref: .builtin(.openclaw),
            hasTurns: false
        )

        let vm = ConversationDetailViewModel(conversationID: record.id)

        XCTAssertFalse(vm.boundGatewayAvailable,
                       "Availability is read from the configured set, never "
                       + "assumed — a seed must not out-claim the real answer.")
    }

    // MARK: - Capacity

    /// The memo is capped, and the bulk warm deliberately STOPS filling when
    /// full. The seed must do the opposite and evict, because the row it carries
    /// is the one the user is about to look at. Drives the public seed+init path
    /// past capacity rather than reaching into the cache.
    ///
    /// This leaves the memo full of throwaway entries; that is harmless — every
    /// other case here asserts immediately after its own seed, and XCTest runs
    /// cases serially.
    func testSeedStillLandsWhenTheMemoIsFull() async {
        for _ in 0..<300 {
            let filler = mintedRecord(backend: RemoteAgentRef.builtin(.hermes).rawString)
            await ConversationDetailViewModel.seedHeaderIdentity(
                for: filler,
                ref: .builtin(.hermes),
                hasTurns: false
            )
        }

        let record = mintedRecord(backend: RemoteAgentRef.builtin(.openclaw).rawString)
        await ConversationDetailViewModel.seedHeaderIdentity(
            for: record,
            ref: .builtin(.openclaw),
            hasTurns: false
        )
        let vm = ConversationDetailViewModel(conversationID: record.id)

        XCTAssertEqual(vm.backendDisplayName, RemoteAgentBackend.openclaw.displayName,
                       "A full memo must evict to make room for the row being "
                       + "minted — skipping it would restore the flicker for "
                       + "exactly the conversation the user is opening.")
    }
}
