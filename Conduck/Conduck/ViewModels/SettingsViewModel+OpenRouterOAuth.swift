// SPDX-License-Identifier: Apache-2.0

// Conduck
// SettingsViewModel+OpenRouterOAuth.swift
//
// "Sign in with OpenRouter" — the view-model half. `OpenRouterOAuth` owns the
// PKCE cryptography and the one network hop; this file owns the only thing that
// has to persist across the web-auth sheet: the in-flight transaction and, for a
// few seconds afterwards, the key the exchange minted.
//
// WHY THE KEY LIVES HERE AT ALL. Every other credential in the gateway editor
// has a SecureField to live in — the user typed it, so the View already holds
// it and the view model can stay secret-free. A signed-in key has no such home:
// it materialises from the code exchange, and the gateway is not saveable yet
// because the user still has to choose a model. Writing it to the Keychain at
// that moment would leave a gateway that looks configured and cannot send. So
// it waits here, and the View is handed an OPAQUE HANDLE plus four characters of
// tail — enough to render "Signed in ✓ ••••1234", not enough to be a secret.
//
// WHAT BOUNDS THE VAULT (this is the whole argument for it being acceptable):
//   • It is `@ObservationIgnored`, so no `body` can read it, and its two
//     dictionaries are `private` to THIS file — the only route in from anywhere
//     else in the module is `issuedKey(for:)` with a handle already in hand.
//     There is no enumerate, so a view that lost its handle cannot go fishing.
//   • An entry is created only by an exchange that actually returned a key.
//   • It is CONSUMED the instant `saveRemoteAgent`'s Keychain write succeeds.
//   • Discard is HANDLE-SCOPED. A stale step tearing down cannot erase the
//     transaction a newer step just started — which is precisely the bug a
//     "clear the pending sign-in" API would ship.
//   • The step that owns a handle discards it on disappear, so backing out of
//     setup leaves nothing behind in memory.
//
// THE TRANSACTION IS SINGLE-USE, ENFORCED BY REMOVAL. `completeOpenRouterSignIn`
// takes the transaction OUT of the pending map before it exchanges, so a second
// call with the same handle finds nothing and fails instead of sending the code
// twice. That is stricter than "drop it on success": an authorization code buys
// a REAL key in the user's account, so a replay does not merely waste a request,
// it can mint a second key they never asked for (see `OpenRouterOAuth`'s header
// on why the exchange is one attempt).
//
// BACKING OUT IS NOT A ROLLBACK. The exchange creates the key at OpenRouter
// immediately, so discarding a handle removes only Conduck's copy. The staged
// row therefore carries a deep link to that key's own settings page
// (`openRouterKeySettingsURL`), computed on-device from the key's SHA-256 — the
// key itself never leaves. Discarding destroys the vault entry and with it the
// only way to compute that digest, so a step that is about to discard asks for
// the URL FIRST and keeps showing it: the digest is not a credential, and a user
// who abandons a sign-in still owns the key it created.
//
// NEVER LOGGED: the verifier, the code, the key. No message built below carries
// any of them, and no error case can, because `OpenRouterOAuthError` carries
// none.

import Foundation

// MARK: - Sign-in state

/// The view model's in-flight sign-ins and the keys they minted.
///
/// A struct with `private` storage rather than two dictionaries on the view
/// model, because `private` here means "this file", and this file is the only
/// place a raw key may be read. Every other file in the module — the gateway
/// editor, the guided-setup steps, the pairing flows — can reach a key only by
/// presenting the handle it was given, and can never list what is held.
struct OpenRouterOAuthSignInState {
    /// Started, not yet exchanged. Holds the PKCE verifier, so it is as
    /// sensitive as the key itself until it is used.
    private var pending: [UUID: OpenRouterOAuthTransaction] = [:]

    /// Exchanged, not yet saved. The only copy of a key the user cannot retype.
    private var issued: [UUID: String] = [:]

    /// Record a freshly-minted transaction as in flight.
    mutating func begin(_ transaction: OpenRouterOAuthTransaction) {
        pending[transaction.handle] = transaction
    }

    /// Take a transaction OUT of the pending map — the single-use enforcement.
    /// Returns nil for a handle that was never started, already exchanged, or
    /// discarded, which is what makes a replayed callback fail closed.
    mutating func claimTransaction(_ handle: UUID) -> OpenRouterOAuthTransaction? {
        pending.removeValue(forKey: handle)
    }

    /// Park the key an exchange returned, addressed by its handle.
    mutating func store(key: String, for handle: UUID) {
        issued[handle] = key
    }

    /// The key for a handle, or nil once it has been consumed or discarded.
    /// The ONLY read path, and it demands a handle — there is no enumeration.
    func issuedKey(for handle: UUID) -> String? {
        issued[handle]
    }

    /// Forget everything about ONE handle. Idempotent, and deliberately
    /// handle-scoped: a stale step's teardown must not touch a newer sign-in.
    mutating func discard(_ handle: UUID) {
        pending.removeValue(forKey: handle)
        issued.removeValue(forKey: handle)
    }
}

// MARK: - Outcome

/// What a completed callback amounted to, from the step's point of view.
///
/// `failed` carries its own message even though the view model has already
/// written that message into the ref's validation state, so a caller that wants
/// to branch on the text (a test, or a future surface with its own error row)
/// does not have to reach into a dictionary to find out what happened.
enum OpenRouterSignInOutcome: Equatable {
    /// A key was minted and parked under `handle`; `keyTail` is its last four
    /// characters, which is all a View is ever given of it.
    case staged(handle: UUID, keyTail: String)
    /// The user backed out. Silent by contract — no message, no error row.
    case cancelled
    /// Everything else. The message is already on screen via the ref's
    /// validation state; every one of them ends by pointing at the paste field.
    case failed(message: String)
}

// MARK: - SettingsViewModel

extension SettingsViewModel {

    /// The ref this whole feature configures. OpenRouter is the only hosted
    /// lane, and the only backend with an authorization server to sign in to.
    private var openRouterRef: RemoteAgentRef { .builtin(.openrouter) }

    // MARK: Availability

    /// Whether this build can start a sign-in at all — it needs the private-use
    /// callback scheme its Info.plist claims. A build without one (a host
    /// process with no `ConduckOAuthCallbackScheme`, or one whose namespace is
    /// not a legal URL scheme) hides the button entirely rather than offering an
    /// action that cannot come back.
    var openRouterSignInAvailable: Bool {
        OpenRouterOAuth.callbackScheme?.isEmpty == false
    }

    // MARK: Begin

    /// Mint a transaction and hand the step everything it needs to open the
    /// web-auth sheet: the handle to quote back, the URL to open, and the scheme
    /// the callback must arrive on.
    ///
    /// Returns nil when this device cannot start a SECURE sign-in — no callback
    /// scheme, or the system refused cryptographic randomness. Both write the
    /// same field-actionable message ("paste an API key instead") into the ref's
    /// validation state, so the existing error row reports it and the caller has
    /// nothing to do but stop. There is deliberately no degraded path: a
    /// predictable verifier removes the only protection PKCE provides.
    func beginOpenRouterSignIn() -> (handle: UUID, authorizationURL: URL, callbackScheme: String)? {
        guard let scheme = OpenRouterOAuth.callbackScheme, !scheme.isEmpty else {
            remoteAgentValidationStates[openRouterRef] = .invalid(
                message: Self.openRouterSignInUnavailableMessage
            )
            return nil
        }
        do {
            let transaction = try OpenRouterOAuth.makeTransaction(scheme: scheme)
            openRouterOAuthState.begin(transaction)
            return (transaction.handle, transaction.authorizationURL, scheme)
        } catch {
            remoteAgentValidationStates[openRouterRef] = .invalid(
                message: Self.openRouterSignInUnavailableMessage
            )
            return nil
        }
    }

    // MARK: Complete

    /// Turn the callback the web-auth sheet returned into a staged key.
    ///
    /// Order matters and is load-bearing: the transaction is CLAIMED (removed)
    /// first, so nothing that follows can run twice for one handle; the callback
    /// is then validated against that exact transaction — scheme and path, which
    /// is what stands in for the `state` parameter OpenRouter does not document;
    /// and only then is the code exchanged, exactly once.
    ///
    /// On success the key is parked and the gateway is probed IMMEDIATELY. That
    /// probe is not decoration: it is what loads the model catalogue, and the
    /// user cannot press Connect until they have picked a model from it. A
    /// FAILING probe still returns `.staged` and KEEPS the key — the probe
    /// surfaces its own verdict in the ref's validation state, and throwing away
    /// a real, already-created OpenRouter key because one HTTP request went
    /// wrong would cost the user a second sign-in and leave an orphan key in
    /// their account.
    func completeOpenRouterSignIn(handle: UUID, callbackURL: URL) async -> OpenRouterSignInOutcome {
        // Unknown handle: a callback for a sign-in this view model never started,
        // already finished, or discarded when its step went away. Same message as
        // a malformed callback, because from the user's side it is the same
        // event — what came back did not match what we sent.
        guard let transaction = openRouterOAuthState.claimTransaction(handle) else {
            return fail(with: Self.openRouterSignInInvalidCallbackMessage)
        }

        let code: String
        switch OpenRouterOAuth.extractCode(from: callbackURL, for: transaction) {
        case .success(let value):
            code = value
        case .failure(let error):
            return fail(with: Self.openRouterSignInMessage(for: error))
        }

        switch await OpenRouterOAuth.exchange(
            code: code,
            transaction: transaction,
            transport: openRouterOAuthTransport
        ) {
        case .success(let key):
            openRouterOAuthState.store(key: key, for: handle)
            // Auto-probe with the intent, never with the key: `testRemoteAgent`
            // resolves the handle back through `resolveStagedToken`, so the raw
            // key does not travel through one more call site than it must.
            await testRemoteAgent(ref: openRouterRef, stagedToken: .oauthIssued(handle), name: nil)
            return .staged(handle: handle, keyTail: openRouterIssuedKeyTail(handle: handle) ?? "")
        case .failure(.cancelled):
            // The user stopped it. They are not owed a message about work they
            // ended themselves, and the step resets its own busy state.
            return .cancelled
        case .failure(let error):
            return fail(with: Self.openRouterSignInMessage(for: error))
        }
    }

    /// Write a failure onto the ref's existing error row AND return it, so the
    /// step needs no error-rendering code of its own.
    private func fail(with message: String) -> OpenRouterSignInOutcome {
        remoteAgentValidationStates[openRouterRef] = .invalid(message: message)
        return .failed(message: message)
    }

    /// The sign-in ended without a callback and without the user cancelling —
    /// the auth session itself failed (no presentation context, or a session the
    /// system tore down). Reported exactly like a callback that did not match,
    /// because it is the same fact: nothing usable came back.
    func failOpenRouterSignIn(handle: UUID) {
        discardOpenRouterSignIn(handle: handle)
        _ = fail(with: Self.openRouterSignInInvalidCallbackMessage)
    }

    // MARK: Discard + inspection

    /// Forget ONE sign-in: its pending transaction and its staged key. Called
    /// when the user picks a different credential source, when the step leaves
    /// the screen, and after a failure. Idempotent, and scoped to the handle so
    /// a late teardown cannot reach into a newer sign-in.
    func discardOpenRouterSignIn(handle: UUID) {
        openRouterOAuthState.discard(handle)
    }

    /// The last four characters of the staged key — the only part of it a View
    /// ever sees. Nil means the handle is unknown (never staged, consumed by a
    /// save, or discarded), which is how a step tells a live staging from a
    /// stale one.
    ///
    /// A key too short for four characters to be a tail rather than the whole
    /// secret renders as bullets instead. OpenRouter's keys are far longer than
    /// that; the guard is here so the property holds by construction rather than
    /// by trusting a provider's format.
    func openRouterIssuedKeyTail(handle: UUID) -> String? {
        guard let key = openRouterOAuthState.issuedKey(for: handle) else { return nil }
        guard key.count >= 8 else { return String(repeating: "•", count: 4) }
        return String(key.suffix(4))
    }

    /// The staged key rendered the way every other stored key on screen is —
    /// through the app's one masking helper, so a signed-in key and a saved key
    /// read as the same kind of credential rather than two different formats.
    /// Nil means the handle is unknown, which is how a step tells a live staging
    /// from a stale one.
    func openRouterIssuedMaskedKey(handle: UUID) -> String? {
        guard let key = openRouterOAuthState.issuedKey(for: handle) else { return nil }
        return maskedTail(key)
    }

    /// OpenRouter's settings page for the STAGED key, so a user who backs out
    /// can delete the key the exchange really did create. Nil for an unknown
    /// handle — so a caller that needs the URL to survive a discard must read it
    /// BEFORE discarding.
    func openRouterKeySettingsURL(handle: UUID) -> URL? {
        guard let key = openRouterOAuthState.issuedKey(for: handle) else { return nil }
        return OpenRouterOAuth.keySettingsURL(forKey: key)
    }

    /// OpenRouter's settings page for the SAVED gateway key. Reads the Keychain
    /// here rather than anywhere nearer a View — the digest is built in-actor and
    /// only the URL crosses out. Nil when no key is stored.
    func openRouterStoredKeySettingsURL() async -> URL? {
        guard let key = await SettingsManager.shared.getRemoteAgentToken(for: openRouterRef),
              !key.isEmpty
        else { return nil }
        return OpenRouterOAuth.keySettingsURL(forKey: key)
    }

    // MARK: - Copy

    /// Surfaced when an `.oauthIssued` intent resolves to nothing at commit /
    /// probe time — the vault entry was consumed by an earlier save, or the step
    /// that owned it went away. Mirrors `reuseMissingVoiceKeyMessage`: name the
    /// two ways forward, and never imply the key can be recovered.
    static var oauthMissingKeyMessage: String {
        String(localized: "settings.remoteAgent.openRouter.signIn.missingKey",
               defaultValue: "That OpenRouter sign-in is no longer available. Sign in again, or paste an API key.")
    }

    /// This device cannot start a SECURE sign-in — no callback scheme, or no
    /// cryptographic randomness. Terminal for the feature, not for the screen.
    static var openRouterSignInUnavailableMessage: String {
        String(localized: "settings.remoteAgent.openRouter.signIn.unavailable",
               defaultValue: "Conduck couldn't start a secure sign-in on this device. Paste an API key instead.")
    }

    /// The callback did not match the transaction that started it — a stale
    /// callback, a malformed one, or an auth session that ended with nothing.
    static var openRouterSignInInvalidCallbackMessage: String {
        String(localized: "settings.remoteAgent.openRouter.signIn.invalidCallback",
               defaultValue: "The sign-in didn't come back the way Conduck expected. Try again, or paste an API key.")
    }

    /// Error → sentence. Every arm ends by naming the paste field, because that
    /// is the alternative that always works; none of them names a provider
    /// status code, and none can carry a secret (the error enum holds none).
    ///
    /// `outcomeUnknown` is the one arm that says something unusual, and it has
    /// to: the request WAS sent, so OpenRouter may have created a key before the
    /// answer went missing. Telling the user a key might exist is the difference
    /// between an honest failure and one that quietly litters their account.
    static func openRouterSignInMessage(for error: OpenRouterOAuthError) -> String {
        switch error {
        case .randomnessUnavailable:
            return openRouterSignInUnavailableMessage
        case .invalidCallback:
            return openRouterSignInInvalidCallbackMessage
        case .providerDenied, .rejected:
            // A provider `?error=` and a 403 are the same event to the user:
            // OpenRouter would not complete the sign-in. The provider's own error
            // token is deliberately not echoed.
            return String(localized: "settings.remoteAgent.openRouter.signIn.rejected",
                          defaultValue: "OpenRouter didn't accept the sign-in. Try again, or paste an API key.")
        case .rateLimited:
            return String(localized: "settings.remoteAgent.openRouter.signIn.rateLimited",
                          defaultValue: "OpenRouter is rate-limiting sign-ins. Wait a moment, or paste an API key.")
        case .network:
            return String(localized: "settings.remoteAgent.openRouter.signIn.network",
                          defaultValue: "Couldn't reach OpenRouter. Check your connection, or paste an API key.")
        case .outcomeUnknown:
            return String(localized: "settings.remoteAgent.openRouter.signIn.outcomeUnknown",
                          defaultValue: "OpenRouter didn't answer in time. If a new key appeared in your OpenRouter account, you can remove it there. Try again, or paste an API key.")
        case .badRequest, .methodNotAllowed, .malformedResponse, .serverError, .unexpectedStatus:
            // One sentence for every "the answer was not what the exchange is
            // written against", including 5xx. Splitting it would ask the user to
            // act on a distinction they cannot act on — the remedy is identical.
            return String(localized: "settings.remoteAgent.openRouter.signIn.unexpected",
                          defaultValue: "OpenRouter answered in a way Conduck didn't expect. Try again, or paste an API key.")
        case .cancelled:
            // Unreachable from `completeOpenRouterSignIn`, which returns
            // `.cancelled` before it reaches this mapping. Present so the switch
            // stays exhaustive without a `default:` that would swallow a future
            // case silently.
            return openRouterSignInInvalidCallbackMessage
        }
    }
}
