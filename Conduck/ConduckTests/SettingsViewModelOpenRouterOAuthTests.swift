// SPDX-License-Identifier: Apache-2.0

// Conduck
// SettingsViewModelOpenRouterOAuthTests.swift
//
// The view-model half of "Sign in with OpenRouter": what happens to a key
// between the moment the exchange returns it and the moment the Keychain owns
// it. `OpenRouterOAuthTests` locks the PKCE wire contract; this file locks the
// VAULT contract, which is where the interesting failure modes live:
//
//   • A handle is the only address. Save and Test resolve `.oauthIssued(handle)`
//     view-model-side, so a test can prove the key reached the Keychain without
//     any View ever holding it.
//   • CONSUMED ON SAVE, EXACTLY ONCE. The second save with the same handle must
//     fail closed rather than re-committing a key that is no longer staged —
//     otherwise a double-tap could resurrect a credential the user replaced.
//   • NOT consumed by a probe. The same key still has to survive the model pick
//     and the Connect that follows, so a `testRemoteAgent` must leave it intact.
//   • The transaction is SINGLE-USE. A callback that does not match burns the
//     transaction, so a retry with the right URL fails too — the code buys a real
//     API key, and a replay would mint a second one.
//   • An unknown handle is a dead end everywhere, with a message that names the
//     two ways forward (sign in again, or paste a key), never a generic error.
//   • DISCARD IS HANDLE-SCOPED. A stale step tearing down must not erase the
//     sign-in the user has already started — the bug a handle-less "forget the
//     pending sign-in" API would ship.
//   • CONSUMED ONLY AFTER THE WRITE. A save whose Keychain write fails keeps the
//     key, because it is the one credential the user cannot retype.
//   • A CANCEL IS SILENT ONLY BEFORE THE SEND. Once the request is gone the
//     outcome is unknown and the user is told a key may exist.
//   • Every error keeps its own remedy. Collapsing the copy is invisible to
//     every other assertion and costs the user the action that would work.
//
// DETERMINISM: the exchange runs through an INJECTED transport
// (`openRouterOAuthTransport`), never the global mock handler, so these cases
// cannot contaminate — or be contaminated by — a suite running in parallel.
//
// THE AUTO-PROBE IS DEAD-ENDED, NOT STUBBED. `completeOpenRouterSignIn` probes
// the gateway on success (that probe is what loads the model catalogue), and the
// probe goes through `RemoteAgentClient.shared`, which builds its own session
// per call and takes no injected transport — there is no seam to stub it at.
// So each test empties the ref's URL buffer first: the probe then fails inside
// `validateRemoteAgent`'s URL guard and never reaches the network. That is a
// REAL probe failure, which is exactly the path worth exercising here — the
// contract says a failed probe still returns `.staged` and KEEPS the key.
//
// Isolation mirrors `SettingsViewModelStagedTokenTests`: wipe the per-ref slots
// in both App-Group defaults and the KVS mirror plus the gateway token, and use
// synthetic values only. Under `CONDUCK_TESTING` every store is an in-memory
// double, so the Keychain assertions read the double, never a real item.

import XCTest
@testable import Conduck

@MainActor
final class SettingsViewModelOpenRouterOAuthTests: XCTestCase {

    private let defaults = TestStores.defaults
    private let openrouter: RemoteAgentRef = .builtin(.openrouter)

    /// A key long enough that a four-character tail is a tail, not the secret.
    private let issuedKey = "sk-or-test-1234"

    /// The message every dead-end `.oauthIssued` resolution surfaces. Kept here
    /// as the contract these tests assert against; update in lockstep with the
    /// source.
    private let missingKeyMessage = String(
        localized: "settings.remoteAgent.openRouter.signIn.missingKey",
        defaultValue: "That OpenRouter sign-in is no longer available. Sign in again, or paste an API key."
    )

    /// The one failure message allowed to say a key may exist anyway.
    private let outcomeUnknownMessage = String(
        localized: "settings.remoteAgent.openRouter.signIn.outcomeUnknown",
        defaultValue: "OpenRouter didn't answer in time. If a new key appeared in your OpenRouter account, you can remove it there. Try again, or paste an API key."
    )

    /// What a callback that doesn't match the transaction reports.
    private let invalidCallbackMessage = String(
        localized: "settings.remoteAgent.openRouter.signIn.invalidCallback",
        defaultValue: "The sign-in didn't come back the way Conduck expected. Try again, or paste an API key."
    )

    // MARK: - Fixtures

    /// Thread-safe invocation counter. "Exactly one send" is a property of this
    /// feature, not an implementation detail, so it is counted, never assumed.
    nonisolated private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }
        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    override func setUp() async throws {
        try await super.setUp()
        await wipeState()
    }

    override func tearDown() async throws {
        await wipeState()
        try await super.tearDown()
    }

    private func wipeState() async {
        // Never leave the shared secret store's failure seam armed — another
        // suite writing the same account would fail for reasons of ours.
        TestStores.secrets.failWrites(for: nil)
        for backend in RemoteAgentBackend.allCases {
            let ref = RemoteAgentRef.builtin(backend)
            for key in [
                Constants.remoteAgentURLKey(for: ref),
                Constants.remoteAgentCertFingerprintKey(for: ref),
                Constants.remoteAgentAuthSchemeKey(for: ref),
                Constants.remoteAgentModelKey(for: ref)
            ] {
                defaults.removeObject(forKey: key)
                TestStores.kvs.removeObject(forKey: key)
            }
            try? await SettingsManager.shared.clearRemoteAgentToken(for: ref)
        }
    }

    /// A hydrated view model whose OpenRouter auto-probe cannot reach the
    /// network. Emptying the URL buffer is what dead-ends it (see the header):
    /// Save is unaffected, because a fixed-endpoint built-in commits its
    /// descriptor's URL rather than the buffer.
    private func makeVM() async -> SettingsViewModel {
        let vm = SettingsViewModel()
        await vm.loadSettings()
        await Task.yield()
        vm.editorHasUnsavedChanges = true
        vm.remoteAgentURLStrings[openrouter] = ""
        vm.remoteAgentModelStrings[openrouter] = "openai/gpt-4o-mini"
        return vm
    }

    /// A transport that answers every request with the same scripted result, and
    /// counts how many times it was asked.
    private func stubTransport(
        counter: CallCounter,
        _ handler: @escaping @Sendable (URLRequest) throws -> (Data, URLResponse)
    ) -> OpenRouterOAuthTransport {
        OpenRouterOAuthTransport { request in
            counter.increment()
            return try handler(request)
        }
    }

    private nonisolated static func keyResponse(_ key: String) throws -> (Data, URLResponse) {
        let body = try JSONSerialization.data(withJSONObject: ["key": key])
        let response = HTTPURLResponse(
            url: OpenRouterOAuth.exchangeURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (body, response)
    }

    /// The callback the provider would return for `handle` — the same shape
    /// `makeTransaction` builds, so a test can forge a matching OR a mismatching
    /// one without reaching into the transaction.
    private func callbackURL(handle: UUID, code: String = "auth-code-123") -> URL {
        let scheme = OpenRouterOAuth.callbackScheme ?? "com.example.conduck"
        return URL(string:
            "\(scheme):\(OpenRouterOAuth.callbackPathPrefix)\(handle.uuidString.lowercased())?code=\(code)"
        )!
    }

    /// Begin a sign-in and drive it to a staged key with a scripted transport.
    private func stageSignIn(
        vm: SettingsViewModel,
        counter: CallCounter,
        key scripted: String? = nil
    ) async -> (handle: UUID, outcome: OpenRouterSignInOutcome)? {
        guard let start = vm.beginOpenRouterSignIn() else { return nil }
        // Capture the key BY VALUE — the transport closure is `@Sendable` and
        // must not reach back into the (main-actor) test case.
        let key = scripted ?? issuedKey
        vm.openRouterOAuthTransport = stubTransport(counter: counter) { _ in
            try Self.keyResponse(key)
        }
        let outcome = await vm.completeOpenRouterSignIn(
            handle: start.handle,
            callbackURL: callbackURL(handle: start.handle)
        )
        return (start.handle, outcome)
    }

    // MARK: - Begin

    /// A sign-in this build can actually complete: a handle to quote back, an
    /// authorization URL on OpenRouter's own host, and the private-use callback
    /// scheme the Info.plist claims (not a hard-coded one).
    func testBeginSignIn_mintsHandleAuthorizationURLAndSchemeFromInfoPlist() async {
        let vm = await makeVM()

        XCTAssertTrue(
            vm.openRouterSignInAvailable,
            "The test host bundle carries ConduckOAuthCallbackScheme, so sign-in must be offered."
        )
        guard let start = vm.beginOpenRouterSignIn() else {
            return XCTFail("Expected a transaction on a build with a callback scheme.")
        }

        XCTAssertEqual(
            start.authorizationURL.host(), "openrouter.ai",
            "The authorization page must be on OpenRouter's own host, derived from the locked base URL."
        )
        XCTAssertEqual(
            start.callbackScheme,
            Bundle.main.object(forInfoDictionaryKey: "ConduckOAuthCallbackScheme") as? String,
            "The callback scheme must come from build identity, never a literal."
        )
        let query = URLComponents(url: start.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(
            query.first(where: { $0.name == "code_challenge_method" })?.value, "S256",
            "The authorization request must declare PKCE S256."
        )
        XCTAssertTrue(
            query.first(where: { $0.name == "callback_url" })?.value?
                .contains(start.handle.uuidString.lowercased()) == true,
            "The handle is the nonce — it must ride in the callback URL."
        )
        XCTAssertNil(
            vm.openRouterIssuedKeyTail(handle: start.handle),
            "Beginning a sign-in must not stage a key; only a completed exchange may."
        )

        vm.discardOpenRouterSignIn(handle: start.handle)
    }

    // MARK: - Complete → stage → save → consumed

    /// The happy path end to end: the exchange stages a key addressed by handle,
    /// the View is given only a four-character tail, Save commits it to the
    /// Keychain — and the SECOND save with the same handle fails closed, because
    /// the commit consumed the vault entry.
    func testCompleteThenSave_commitsKeyAndConsumesTheHandle() async {
        let vm = await makeVM()
        let counter = CallCounter()

        guard let staged = await stageSignIn(vm: vm, counter: counter) else {
            return XCTFail("Expected a transaction on a build with a callback scheme.")
        }

        XCTAssertEqual(counter.count, 1, "The code→key exchange must happen exactly once.")
        XCTAssertEqual(
            staged.outcome,
            .staged(handle: staged.handle, keyTail: "1234"),
            "A successful exchange stages the key and hands back only its last four characters."
        )
        XCTAssertEqual(
            vm.openRouterIssuedKeyTail(handle: staged.handle), "1234",
            "The staged tail must stay readable while the user picks a model."
        )

        let ok = await vm.saveRemoteAgent(ref: openrouter, name: nil, stagedToken: .oauthIssued(staged.handle))
        XCTAssertTrue(ok, "A staged sign-in plus a model is a complete OpenRouter config — Save must commit.")

        let stored = await SettingsManager.shared.getRemoteAgentToken(for: openrouter)
        XCTAssertEqual(
            stored, issuedKey,
            "The issued key must reach the Keychain verbatim — that write is the whole point of the flow."
        )
        XCTAssertNil(
            vm.openRouterIssuedKeyTail(handle: staged.handle),
            "A committed save CONSUMES the vault entry — the key lives in the Keychain now, nowhere else."
        )

        let second = await vm.saveRemoteAgent(ref: openrouter, name: nil, stagedToken: .oauthIssued(staged.handle))
        XCTAssertFalse(second, "A consumed handle must fail closed, never re-commit.")
        XCTAssertEqual(
            vm.remoteAgentRowState(for: openrouter),
            .invalid(message: missingKeyMessage),
            "The dead end must name the two ways forward, not a generic error."
        )
    }

    // MARK: - Probe does not consume

    /// A probe READS the vault. The same key has to survive it and still be
    /// there for the Connect that follows, so a `testRemoteAgent` must leave the
    /// entry intact — proven by saving successfully afterwards.
    func testTestRemoteAgentDoesNotConsumeTheStagedKey() async {
        let vm = await makeVM()
        let counter = CallCounter()

        guard let staged = await stageSignIn(vm: vm, counter: counter) else {
            return XCTFail("Expected a transaction on a build with a callback scheme.")
        }

        // A second, explicit probe on top of the automatic one.
        await vm.testRemoteAgent(ref: openrouter, stagedToken: .oauthIssued(staged.handle), name: nil)

        XCTAssertEqual(
            vm.openRouterIssuedKeyTail(handle: staged.handle), "1234",
            "Probing must not consume the staged key — only a committed save may."
        )
        let ok = await vm.saveRemoteAgent(ref: openrouter, name: nil, stagedToken: .oauthIssued(staged.handle))
        XCTAssertTrue(ok, "The key must still be committable after any number of probes.")
        let stored = await SettingsManager.shared.getRemoteAgentToken(for: openrouter)
        XCTAssertEqual(stored, issuedKey, "The post-probe save must persist the same key.")
        XCTAssertEqual(counter.count, 1, "Probing must never re-run the code exchange.")
    }

    /// A failing probe (here: the dead-ended URL guard) must NOT throw the key
    /// away. It is a real, already-created OpenRouter key; discarding it would
    /// cost the user a second sign-in and leave an orphan in their account.
    func testFailingProbeKeepsTheStagedKey() async {
        let vm = await makeVM()
        let counter = CallCounter()

        guard let staged = await stageSignIn(vm: vm, counter: counter) else {
            return XCTFail("Expected a transaction on a build with a callback scheme.")
        }

        guard case .staged = staged.outcome else {
            return XCTFail("A probe failure must still report the key as staged, got \(staged.outcome).")
        }
        XCTAssertNotEqual(
            vm.remoteAgentRowState(for: openrouter), .valid,
            "Precondition: this suite's probe is dead-ended, so it cannot have passed."
        )
        XCTAssertEqual(
            vm.openRouterIssuedKeyTail(handle: staged.handle), "1234",
            "A failed probe keeps the key so Retry costs no second sign-in."
        )
    }

    // MARK: - Unknown / stale handles

    /// A callback for a sign-in this view model never started is refused, and
    /// nothing is exchanged.
    func testCompleteWithUnknownHandle_failsWithoutExchanging() async {
        let vm = await makeVM()
        let counter = CallCounter()
        let key = issuedKey
        vm.openRouterOAuthTransport = stubTransport(counter: counter) { _ in
            try Self.keyResponse(key)
        }
        let stranger = UUID()

        let outcome = await vm.completeOpenRouterSignIn(
            handle: stranger, callbackURL: callbackURL(handle: stranger)
        )

        XCTAssertEqual(
            outcome, .failed(message: invalidCallbackMessage),
            "An unknown handle must fail closed with the mismatched-callback message."
        )
        XCTAssertEqual(counter.count, 0, "An unmatched callback must never reach the exchange.")
        XCTAssertNil(vm.openRouterIssuedKeyTail(handle: stranger), "Nothing may be staged for it.")
    }

    /// A callback whose PATH carries a different handle does not match the
    /// transaction that started it — and burns it, so even the correct callback
    /// cannot be replayed afterwards. That single-use property is what keeps one
    /// authorization code from minting two real API keys.
    func testCallbackWithForeignHandle_failsAndBurnsTheTransaction() async {
        let vm = await makeVM()
        let counter = CallCounter()
        let key = issuedKey
        vm.openRouterOAuthTransport = stubTransport(counter: counter) { _ in
            try Self.keyResponse(key)
        }
        guard let start = vm.beginOpenRouterSignIn() else {
            return XCTFail("Expected a transaction on a build with a callback scheme.")
        }

        let mismatched = await vm.completeOpenRouterSignIn(
            handle: start.handle, callbackURL: callbackURL(handle: UUID())
        )
        XCTAssertEqual(
            mismatched, .failed(message: invalidCallbackMessage),
            "The full callback — scheme AND path — is what stands in for `state`; a foreign handle must be refused."
        )

        let retry = await vm.completeOpenRouterSignIn(
            handle: start.handle, callbackURL: callbackURL(handle: start.handle)
        )
        XCTAssertEqual(
            retry, .failed(message: invalidCallbackMessage),
            "The transaction is single-use: a retry with the RIGHT callback must fail too."
        )
        XCTAssertEqual(counter.count, 0, "Neither attempt may reach the exchange.")
        XCTAssertNil(vm.openRouterIssuedKeyTail(handle: start.handle), "Nothing may be staged.")
    }

    /// Discarding is what a step's teardown does. A callback that lands
    /// afterwards must find nothing.
    func testDiscardThenComplete_failsWithNothingStaged() async {
        let vm = await makeVM()
        let counter = CallCounter()
        let key = issuedKey
        vm.openRouterOAuthTransport = stubTransport(counter: counter) { _ in
            try Self.keyResponse(key)
        }
        guard let start = vm.beginOpenRouterSignIn() else {
            return XCTFail("Expected a transaction on a build with a callback scheme.")
        }

        vm.discardOpenRouterSignIn(handle: start.handle)
        // Idempotent — a step may discard the same handle more than once.
        vm.discardOpenRouterSignIn(handle: start.handle)

        let outcome = await vm.completeOpenRouterSignIn(
            handle: start.handle, callbackURL: callbackURL(handle: start.handle)
        )
        XCTAssertEqual(
            outcome, .failed(message: invalidCallbackMessage),
            "A discarded transaction must be as unknown as one that never existed."
        )
        XCTAssertEqual(counter.count, 0, "A discarded sign-in must never reach the exchange.")
        XCTAssertNil(vm.openRouterIssuedKeyTail(handle: start.handle), "No vault entry may survive a discard.")
    }

    // MARK: - Exchange failure

    /// A timeout is the one failure that must NOT claim nothing happened: the
    /// request was sent, so OpenRouter may have created the key anyway. The copy
    /// says so, and the exchange is not retried behind the user's back.
    func testExchangeTimeout_reportsOutcomeUnknownAfterExactlyOneSend() async {
        let vm = await makeVM()
        let counter = CallCounter()
        vm.openRouterOAuthTransport = stubTransport(counter: counter) { _ in
            throw URLError(.timedOut)
        }
        guard let start = vm.beginOpenRouterSignIn() else {
            return XCTFail("Expected a transaction on a build with a callback scheme.")
        }

        let outcome = await vm.completeOpenRouterSignIn(
            handle: start.handle, callbackURL: callbackURL(handle: start.handle)
        )

        XCTAssertEqual(
            outcome, .failed(message: outcomeUnknownMessage),
            "A lost answer must tell the user a key may exist — that is the only honest report."
        )
        XCTAssertEqual(counter.count, 1, "A timeout must NOT be retried: a second attempt can mint a second key.")
        XCTAssertNil(vm.openRouterIssuedKeyTail(handle: start.handle), "A failed exchange stages nothing.")
        XCTAssertEqual(
            vm.remoteAgentRowState(for: openrouter),
            .invalid(message: outcomeUnknownMessage),
            "The failure must land on the screen's existing error row, pointing at the paste field."
        )
    }

    // MARK: - Save with a handle that resolves to nothing

    /// Save with a handle the vault never knew must fail closed and persist
    /// NOTHING — the resolution guard runs before any store write.
    func testSaveWithUnknownHandle_failsClosedPersistsNothing() async {
        let vm = await makeVM()

        let ok = await vm.saveRemoteAgent(ref: openrouter, name: nil, stagedToken: .oauthIssued(UUID()))

        XCTAssertFalse(ok, "An unresolvable sign-in handle must never commit a gateway.")
        XCTAssertEqual(
            vm.remoteAgentRowState(for: openrouter),
            .invalid(message: missingKeyMessage),
            "The failure must tell the user to sign in again or paste a key."
        )
        let stored = await SettingsManager.shared.hasStoredRemoteAgentSlots(for: openrouter)
        XCTAssertFalse(stored, "A failed save must leave no per-ref slots behind (nothing persisted on failure).")
        let token = await SettingsManager.shared.getRemoteAgentToken(for: openrouter)
        XCTAssertNil(token, "A failed save must write no token.")
    }

    /// Test Connection with an unresolvable handle dead-ends BEFORE the probe,
    /// with the same message Save uses — never an unauthenticated probe.
    func testTestConnectionWithUnknownHandle_failsWithoutProbing() async {
        let vm = await makeVM()

        await vm.testRemoteAgent(ref: openrouter, stagedToken: .oauthIssued(UUID()), name: nil)

        XCTAssertEqual(
            vm.remoteAgentRowState(for: openrouter),
            .invalid(message: missingKeyMessage),
            "A missing vault entry must dead-end before the probe — same message as Save."
        )
    }

    // MARK: - Discard is HANDLE-SCOPED

    /// Two sign-ins can be alive at once — a step tears down while the user has
    /// already started the next one — and discarding the stale handle must not
    /// touch the fresh one. A "forget the pending sign-in" API without a handle
    /// would erase the transaction the user is standing in front of, and they
    /// would be told to sign in again while an orphan key sat in their account.
    func testDiscardIsScopedToItsOwnHandle() async {
        let vm = await makeVM()
        let counter = CallCounter()

        guard let first = vm.beginOpenRouterSignIn() else {
            return XCTFail("Expected a transaction on a build with a callback scheme.")
        }
        guard let second = await stageSignIn(vm: vm, counter: counter) else {
            return XCTFail("Expected a second, independent transaction.")
        }
        XCTAssertNotEqual(first.handle, second.handle, "Precondition: two distinct sign-ins.")

        vm.discardOpenRouterSignIn(handle: first.handle)

        XCTAssertEqual(
            vm.openRouterIssuedKeyTail(handle: second.handle), "1234",
            "Discarding a STALE handle must leave the newer sign-in's key staged."
        )
        let ok = await vm.saveRemoteAgent(
            ref: openrouter, name: nil, stagedToken: .oauthIssued(second.handle)
        )
        XCTAssertTrue(ok, "The surviving handle must still commit.")
        let stored = await SettingsManager.shared.getRemoteAgentToken(for: openrouter)
        XCTAssertEqual(stored, issuedKey, "…and commit the key the second sign-in minted.")
    }

    // MARK: - Cancellation

    /// A cancel observed BEFORE the request is sent is the one silent outcome:
    /// nothing was created at OpenRouter, so there is nothing to tell the user.
    /// It must leave the error row alone — a red line for an action the user
    /// ended themselves is the behaviour this arm exists to prevent.
    ///
    /// The task below is main-actor isolated like this test, so it cannot begin
    /// until the test suspends at `await task.value`; `cancel()` therefore lands
    /// first, with no sleep and no race.
    func testCancelBeforeTheExchange_isSilentAndNeverSends() async {
        let vm = await makeVM()
        let counter = CallCounter()
        let key = issuedKey
        vm.openRouterOAuthTransport = stubTransport(counter: counter) { _ in
            try Self.keyResponse(key)
        }
        guard let start = vm.beginOpenRouterSignIn() else {
            return XCTFail("Expected a transaction on a build with a callback scheme.")
        }
        let callback = callbackURL(handle: start.handle)

        let task = Task { await vm.completeOpenRouterSignIn(handle: start.handle, callbackURL: callback) }
        task.cancel()
        let outcome = await task.value

        XCTAssertEqual(outcome, .cancelled, "A user cancel is silent by contract.")
        XCTAssertEqual(counter.count, 0, "Nothing may be sent for a sign-in already cancelled.")
        XCTAssertEqual(
            vm.remoteAgentRowState(for: openrouter), .unset,
            "A silent cancel must not paint an error row for work the user stopped."
        )
    }

    /// A cancel that lands AFTER the request left is NOT silent: OpenRouter may
    /// already have created the key, and the only honest report is the one that
    /// says so. This is the reachable case — the step's teardown cancels the
    /// sign-in task, and on macOS the app window stays clickable while the auth
    /// window is up.
    func testCancelDuringTheExchange_reportsAnUnknownOutcome() async {
        let vm = await makeVM()
        let counter = CallCounter()
        vm.openRouterOAuthTransport = stubTransport(counter: counter) { _ in
            throw URLError(.cancelled)
        }
        guard let start = vm.beginOpenRouterSignIn() else {
            return XCTFail("Expected a transaction on a build with a callback scheme.")
        }

        let outcome = await vm.completeOpenRouterSignIn(
            handle: start.handle, callbackURL: callbackURL(handle: start.handle)
        )

        XCTAssertEqual(
            outcome, .failed(message: outcomeUnknownMessage),
            "An in-flight cancel must tell the user a key may exist, not vanish silently."
        )
        XCTAssertEqual(counter.count, 1, "Still exactly one attempt.")
        XCTAssertNil(vm.openRouterIssuedKeyTail(handle: start.handle), "Nothing is staged.")
    }

    // MARK: - The route back to a key the exchange created

    /// The staged key's OpenRouter page — the ONLY route a user has to delete a
    /// key they decide not to keep, because the exchange created it for real.
    /// Nil for a handle the vault does not know, which is what makes it safe for
    /// a View to use nil as "nothing staged".
    func testKeySettingsURLResolvesTheStagedKeyAndNothingElse() async {
        let vm = await makeVM()
        let counter = CallCounter()

        guard let staged = await stageSignIn(vm: vm, counter: counter) else {
            return XCTFail("Expected a transaction on a build with a callback scheme.")
        }

        XCTAssertEqual(
            vm.openRouterKeySettingsURL(handle: staged.handle),
            OpenRouterOAuth.keySettingsURL(forKey: issuedKey),
            "The link must address THIS key's page, by its own digest."
        )
        XCTAssertNil(
            vm.openRouterKeySettingsURL(handle: UUID()),
            "An unknown handle has no key and therefore no page."
        )
        XCTAssertEqual(
            vm.openRouterIssuedMaskedKey(handle: staged.handle), maskedTail(issuedKey),
            "The staged key is masked by the app's one masking helper, like every stored key."
        )
    }

    /// The SAVED key's OpenRouter page, read from the Keychain view-model-side.
    /// It is what the manage card links to, so a nil here silently removes the
    /// user's only in-app route to the key that is actually in use.
    func testStoredKeySettingsURLTracksTheSavedToken() async {
        let vm = await makeVM()

        let before = await vm.openRouterStoredKeySettingsURL()
        XCTAssertNil(before, "With no key stored there is no page to link to.")

        try? await SettingsManager.shared.setRemoteAgentToken(issuedKey, for: openrouter)
        let after = await vm.openRouterStoredKeySettingsURL()
        XCTAssertEqual(
            after, OpenRouterOAuth.keySettingsURL(forKey: issuedKey),
            "The manage card must link to the key that is actually stored."
        )

        try? await SettingsManager.shared.clearRemoteAgentToken(for: openrouter)
        let cleared = await vm.openRouterStoredKeySettingsURL()
        XCTAssertNil(cleared, "A cleared key leaves no page behind.")
    }

    // MARK: - Masking

    /// A credential too short for four characters to be a TAIL rather than most
    /// of the secret renders as bullets. The whole handle/tail design exists to
    /// keep raw key material off the screen; a six-character key showing four of
    /// its characters would defeat it in the one place it matters.
    func testAShortKeyIsMaskedRatherThanPartlyRevealed() async {
        let vm = await makeVM()
        let counter = CallCounter()

        guard let staged = await stageSignIn(vm: vm, counter: counter, key: "abc12") else {
            return XCTFail("Expected a transaction on a build with a callback scheme.")
        }

        XCTAssertEqual(
            vm.openRouterIssuedKeyTail(handle: staged.handle), "••••",
            "Under eight characters there is no tail to show — only bullets."
        )
        XCTAssertFalse(
            vm.openRouterIssuedMaskedKey(handle: staged.handle)?.contains("12") == true,
            "No fragment of a short key may reach a View."
        )
    }

    // MARK: - Copy

    /// Every arm of the error→sentence map, because collapsing them is invisible
    /// to every other test and costs the user the remedy: a rate-limited person
    /// told "that didn't come back the way Conduck expected" waits instead of
    /// retrying, and an offline person is never told to check their connection.
    /// Enumerated case by case so a NEW error with no copy fails the build here.
    func testEveryErrorMapsToItsOwnRemedy() {
        let unavailable = SettingsViewModel.openRouterSignInUnavailableMessage
        let invalid = SettingsViewModel.openRouterSignInInvalidCallbackMessage
        let rejected = String(
            localized: "settings.remoteAgent.openRouter.signIn.rejected",
            defaultValue: "OpenRouter didn't accept the sign-in. Try again, or paste an API key."
        )
        let rateLimited = String(
            localized: "settings.remoteAgent.openRouter.signIn.rateLimited",
            defaultValue: "OpenRouter is rate-limiting sign-ins. Wait a moment, or paste an API key."
        )
        let network = String(
            localized: "settings.remoteAgent.openRouter.signIn.network",
            defaultValue: "Couldn't reach OpenRouter. Check your connection, or paste an API key."
        )
        let unexpected = String(
            localized: "settings.remoteAgent.openRouter.signIn.unexpected",
            defaultValue: "OpenRouter answered in a way Conduck didn't expect. Try again, or paste an API key."
        )

        let expectations: [(OpenRouterOAuthError, String)] = [
            (.randomnessUnavailable, unavailable),
            (.invalidCallback, invalid),
            (.providerDenied(code: "access_denied"), rejected),
            (.providerDenied(code: nil), rejected),
            (.rejected, rejected),
            (.rateLimited, rateLimited),
            (.network, network),
            (.outcomeUnknown, outcomeUnknownMessage),
            (.badRequest, unexpected),
            (.methodNotAllowed, unexpected),
            (.malformedResponse, unexpected),
            (.serverError(503), unexpected),
            (.unexpectedStatus(418), unexpected),
            (.cancelled, invalid),
        ]

        for (error, expected) in expectations {
            XCTAssertEqual(
                SettingsViewModel.openRouterSignInMessage(for: error), expected,
                "\(error) must keep its own remedy."
            )
        }

        // Every sentence has to end somewhere the user can actually go, and the
        // paste field is the alternative that always works.
        for (_, message) in expectations {
            XCTAssertTrue(
                message.lowercased().contains("api key"),
                "Every sign-in failure must name the paste field: \(message)"
            )
        }
        XCTAssertTrue(
            outcomeUnknownMessage.contains("remove it there"),
            "Only the unknown-outcome sentence may say a key might exist — and it must."
        )
    }

    // MARK: - The vault is consumed only AFTER the Keychain owns the key

    /// A save whose Keychain write FAILS must leave the staged key intact. It is
    /// the only copy of a credential the user cannot retype, so consuming it
    /// before the write succeeded would strand them: Retry would fail closed
    /// with "sign in again", and the key the exchange created would be orphaned
    /// in their OpenRouter account.
    func testAFailedTokenWriteKeepsTheStagedKeyRetryable() async {
        let vm = await makeVM()
        let counter = CallCounter()

        guard let staged = await stageSignIn(vm: vm, counter: counter) else {
            return XCTFail("Expected a transaction on a build with a callback scheme.")
        }

        let account = Constants.remoteAgentTokenKeychainAccount(for: openrouter)
        TestStores.secrets.failWrites(for: account)
        let ok = await vm.saveRemoteAgent(
            ref: openrouter, name: nil, stagedToken: .oauthIssued(staged.handle)
        )
        TestStores.secrets.failWrites(for: nil)

        XCTAssertFalse(ok, "A token write that fails must not report a saved gateway.")
        XCTAssertEqual(
            vm.openRouterIssuedKeyTail(handle: staged.handle), "1234",
            "The vault entry may only be consumed once the Keychain actually owns the key."
        )
        let stored = await SettingsManager.shared.getRemoteAgentToken(for: openrouter)
        XCTAssertNil(stored, "Precondition: the write really did fail.")

        // And the key is still committable, which is the whole point of keeping it.
        let retry = await vm.saveRemoteAgent(
            ref: openrouter, name: nil, stagedToken: .oauthIssued(staged.handle)
        )
        XCTAssertTrue(retry, "Retry must cost the user no second sign-in.")
        let after = await SettingsManager.shared.getRemoteAgentToken(for: openrouter)
        XCTAssertEqual(after, issuedKey)
    }
    func testOAuthConnectionRemainsAvailableAtConfiguredGatewayCap() async throws {
        let seeded = (0..<Constants.maxConfiguredGateways).map {
            CustomGateway(id: UUID(), name: "Allowance \($0)")
        }
        // Preserve the suite's unrelated roster fixture and restore it verbatim.
        let priorLocal = defaults.data(forKey: Constants.customGatewaysRegistryKey)
        let priorCloud = TestStores.kvs.data(forKey: Constants.customGatewaysRegistryKey)
        defer {
            if let priorLocal { defaults.set(priorLocal, forKey: Constants.customGatewaysRegistryKey) }
            else { defaults.removeObject(forKey: Constants.customGatewaysRegistryKey) }
            if let priorCloud { TestStores.kvs.set(priorCloud, forKey: Constants.customGatewaysRegistryKey) }
            else { TestStores.kvs.removeObject(forKey: Constants.customGatewaysRegistryKey) }
        }
        let data = try JSONEncoder().encode(seeded)
        defaults.set(data, forKey: Constants.customGatewaysRegistryKey)
        TestStores.kvs.set(data, forKey: Constants.customGatewaysRegistryKey)
        let vm = await makeVM()
        XCTAssertFalse(vm.canAddConfiguredGateway)
        XCTAssertTrue(vm.canConfigureRemoteAgent(openrouter))
        guard let staged = await stageSignIn(vm: vm, counter: CallCounter()) else {
            return XCTFail("Expected a transaction on a build with a callback scheme")
        }
        let saved = await vm.saveRemoteAgent(ref: openrouter, name: nil, stagedToken: .oauthIssued(staged.handle))
        XCTAssertTrue(saved)
        XCTAssertNil(vm.openRouterIssuedKeyTail(handle: staged.handle))
        let stored = await SettingsManager.shared.getRemoteAgentToken(for: openrouter)
        XCTAssertEqual(stored, issuedKey)
        let inventory = await SettingsManager.shared.remoteAgentInventory()
        XCTAssertEqual(inventory.allowanceRefs.count, Constants.maxConfiguredGateways)
    }

}
