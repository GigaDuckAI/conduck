// SPDX-License-Identifier: Apache-2.0

// Conduck
// STTConnectionTestSuite.swift
//
// Custom STT — Feature 3 — the rich staged "Test Connection" engine + its
// value-type result model. Unlike the cheap per-provider key-check probes
// (`STTGETProbe` / `QwenSTTProbe` / `CustomOpenAISTTProbe`, which only assert
// "the key reaches the server and authenticates"), this suite runs THREE
// sequential stages against a single pinned ephemeral session and surfaces a
// live checklist:
//
//   ① Reachability + TLS  — the transcription POST's handshake. URLError is
//      classified exactly like `RemoteAgentClient+TestConnection.performTestConnection`
//      (timeout / unreachable / cert). Three certificate refusals, each with its
//      own remedy and none collapsible into another — a chain this device
//      doesn't trust (fix the SERVER), a pinned key that disagreed with a chain
//      the system DID trust (stop: the connection may be intercepted), and a key
//      algorithm Conduck cannot fingerprint (the certificate is fine; reissue it
//      or clear the pin). Never "the certificate changed": on the mismatch's
//      real shape nothing on the user's server changed, and saying so sends them
//      hunting a configuration they never touched. All three are terminal, so
//      none is recoverable from this screen. The wording itself is
//      `CertificateTrustCopy`'s, rendered below — this comment must not restate
//      it, or the two drift.
//   ② Auth — the SAME response's HTTP status. ONLY 401 / 403 fail this stage;
//      every other status means the key reached the auth layer and was
//      accepted (a 5xx is a server problem, surfaced at stage ③).
//   ③ Transcription round-trip — multipart POST of the bundled spoken clip
//      (`Resources/stt-probe-spoken.m4a`, "testing one two three"), decoded
//      `.openAICompat`. Empty `text` → `.failed("no transcript")` (the case
//      silence can NOT catch — the whole point of a spoken clip). Non-empty →
//      `.passed` + the transcript + a LOOSE token contains-check vs the
//      expected phrase (≥50% of expected words present, digit-or-word
//      tolerant). A fuzzy miss is a SOFT pass — a working server that
//      mis-hears one word is NOT hard-failed. Undecodable → `.failed`.
//   ④ Latency — `ContinuousClock` around the transcription POST → `latencyMS`.
//
// Provider-agnostic: the custom endpoint runs the full suite as its DEFAULT
// Test action; built-in providers keep the cheap key-check and expose an
// opt-in "Run full test" link that routes through the same engine.
//
// Privacy (non-negotiable): the API key / bearer token is ONLY ever attached
// to the `URLRequest` via `STTAuthScheme.apply` — it NEVER enters a stage
// detail string, an error, or a log. The only transcript surfaced is the
// bundled known phrase. Failure reasons are status/category-derived only.

import Foundation

// MARK: - Data model (value types — additive, NOT an overload of `KeyValidationState`)

/// The three sequential stages of the rich Test Connection. Ordered — the
/// suite runs them in `allCases` order and short-circuits the remainder when
/// an earlier stage hard-fails (a reachability failure makes auth /
/// transcription meaningless).
enum STTTestStage: String, Sendable, Equatable, CaseIterable {
    /// ① TLS handshake + host reachability.
    case reachability
    /// ② HTTP-status auth check (401 / 403 only).
    case auth
    /// ③ Real spoken-clip transcription round-trip.
    case transcription
}

/// Per-stage lifecycle. `.skipped` is distinct from `.failed`: this stage never
/// ran because an EARLIER one blocked it, so it says nothing about the server.
/// The UI renders `.skipped` amber, `.failed` red.
enum STTStageStatus: Sendable, Equatable {
    /// Not yet started.
    case pending
    /// In flight — render a spinner.
    case running
    /// Completed successfully.
    case passed
    /// Completed and failed. `reason` is a taxonomy-derived, key-free string.
    case failed(reason: String)
    /// Never ran — an earlier stage blocked it. `reason` is key-free.
    case skipped(reason: String)
}

/// One row in the staged checklist. `Identifiable` off `stage` so a `ForEach`
/// can animate per-stage status transitions.
struct STTTestStageResult: Identifiable, Sendable, Equatable {
    var id: STTTestStage { stage }
    let stage: STTTestStage
    var status: STTStageStatus
    /// Optional secondary detail (e.g. "HTTP 200", "Connected — TLS OK"). Always
    /// status/category-derived — NEVER carries the key, URL, or transcript.
    var detail: String?
}

/// The full result of a Test Connection run. Re-published on every progress
/// tick so the UI animates the checklist live as stages complete.
struct STTTestSuiteResult: Sendable, Equatable {
    /// The three stage rows, in `STTTestStage.allCases` order.
    var stages: [STTTestStageResult]

    /// The transcript the server returned for the bundled clip — surfaced in a
    /// monospaced "Heard:" card. Nil until stage ③ produces non-empty text.
    /// This is the ONLY transcript ever shown (a known bundled phrase).
    var transcript: String?

    /// Round-trip latency of the transcription POST, in milliseconds. Nil
    /// until stage ③ completes.
    var latencyMS: Int?

    /// True iff every stage `.passed` (a `.skipped` stage does NOT count as
    /// passed — it never ran).
    var allPassed: Bool {
        stages.allSatisfy { if case .passed = $0.status { return true } else { return false } }
    }

    /// Seed a fresh all-pending result for the live-animation start state.
    static var pending: STTTestSuiteResult {
        STTTestSuiteResult(
            stages: STTTestStage.allCases.map {
                STTTestStageResult(stage: $0, status: .pending, detail: nil)
            },
            transcript: nil,
            latencyMS: nil
        )
    }
}

// MARK: - Engine

/// Staged Test Connection engine. `enum` (no instances) with a named-static
/// `run(...)` entry point — matches the `RemoteAgentClient+TestConnection`
/// named-static convention and keeps stack traces readable.
enum STTConnectionTestSuite {

    /// Bundled spoken probe clip — ~1.3 s mono 16 kHz AAC of "testing one two
    /// three". See `Conduck/Resources/stt-probe-spoken.m4a`.
    private static let probeAssetName = "stt-probe-spoken"
    private static let probeAssetExt  = "m4a"
    private static let probeAssetMIME = "audio/mp4"
    private static let probeAssetFilename = "probe.m4a"

    /// The phrase spoken in the bundled clip — the loose token contains-check
    /// compares the server's transcript against this. Lowercase, no proper
    /// nouns, digit-or-word tolerant.
    static let expectedPhrase = "testing one two three"

    /// Run the full staged suite against `url` with `token` + `auth` + optional
    /// `fingerprint` pin + `model`. Calls `progress` after EVERY stage status
    /// change so the UI animates the checklist live. Returns the final result
    /// (also delivered through the last `progress` tick).
    ///
    /// Privacy: `token` flows ONLY onto the `URLRequest` via `auth.apply` —
    /// never into a stage detail, the returned result, or a log.
    ///
    /// - Parameters:
    ///   - url: FULL transcribe URL (caller resolves base + path).
    ///   - token: API key / bearer token. Never surfaced.
    ///   - auth: effective auth scheme (`.bearer` / `.none` / `.headerName`).
    ///   - fingerprint: optional pinned SHA-256 hex, applied ON TOP of the
    ///     system's own trust evaluation; nil → system trust alone.
    ///   - model: model tag for the multipart `model` field.
    ///   - progress: live tick — invoked on the calling context with the
    ///     latest snapshot after each stage transition.
    static func run(
        url: URL,
        token: String,
        auth: STTAuthScheme,
        fingerprint: String?,
        model: String,
        progress: @Sendable (STTTestSuiteResult) -> Void
    ) async -> STTTestSuiteResult {
        // Per-call ephemeral pinning session — install the
        // `RemoteAgentTrustEvaluator` for THIS run only, never on
        // `URLSession.shared`. Same 15 s short-probe timeout as the gateway
        // Test Connection (NOT the 300 s converse budget). Copies the session
        // block from `RemoteAgentClient+TestConnection` ~L79-89.
        let evaluator = RemoteAgentTrustEvaluator(pinnedFingerprintHex: fingerprint)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Constants.remoteAgentTestConnectionTimeout
        config.timeoutIntervalForResource = Constants.remoteAgentTestConnectionTimeout
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: config, delegate: evaluator, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        // The whole attempt snapshot, not loose Bools: only it carries
        // `pinComparisonUnsupported`, and this screen is where a user types a
        // fingerprint in — so it is the surface most likely to meet a key
        // Conduck cannot hash, and the worst place to answer that with an
        // interception warning.
        return await perform(
            url: url,
            token: token,
            auth: auth,
            model: model,
            session: session,
            signals: { evaluator.attemptSignals },
            progress: progress
        )
    }

    #if DEBUG
    /// Test-only injection seam — runs the suite through a caller-supplied
    /// `URLSession` (e.g. a `MockURLProtocol`-backed session) without a real
    /// network round-trip, with the attempt verdicts a mocked transport cannot
    /// produce supplied as a closure (production reads them off the evaluator
    /// only after the awaited request returns). `signals` defaults to `.empty` —
    /// no verdict — so a test exercising a refusal has to name which one.
    ///
    /// `#if DEBUG` IS the fence: a caller-supplied session carries no evaluator,
    /// so every certificate verdict this run reports comes from the arguments
    /// rather than from a challenge. `run(...)` is a THIN wrapper over the same
    /// `perform(...)` body precisely so this can be fenced without production
    /// depending on it — the shared body is what both call, and only this
    /// entrance disappears from a Release or Archive build.
    static func runForTesting(
        url: URL,
        token: String,
        auth: STTAuthScheme,
        model: String,
        session: URLSession,
        signals: @escaping @Sendable () -> RemoteAgentTrustEvaluator.AttemptTrustSignals = { .empty },
        progress: @Sendable (STTTestSuiteResult) -> Void
    ) async -> STTTestSuiteResult {
        await perform(
            url: url, token: token, auth: auth, model: model,
            session: session, signals: signals, progress: progress
        )
    }
    #endif

    /// The staged run itself, over a ready session and a ready verdict source.
    /// `private` so the only ways in are `run(...)` (which builds the pinned
    /// session) and, in a Debug build, `runForTesting(...)`.
    private static func perform(
        url: URL,
        token: String,
        auth: STTAuthScheme,
        model: String,
        session: URLSession,
        signals: @escaping @Sendable () -> RemoteAgentTrustEvaluator.AttemptTrustSignals,
        progress: @Sendable (STTTestSuiteResult) -> Void
    ) async -> STTTestSuiteResult {
        var result = STTTestSuiteResult.pending

        // Helper: mutate one stage's status (+ optional detail) and tick.
        func update(_ stage: STTTestStage, _ status: STTStageStatus, detail: String? = nil) {
            if let idx = result.stages.firstIndex(where: { $0.stage == stage }) {
                result.stages[idx].status = status
                if let detail { result.stages[idx].detail = detail }
            }
            progress(result)
        }

        // Build the multipart request up front. A missing bundled asset is a
        // bundling regression — fail stage ③ loudly (the founder/QA notices in
        // CI) rather than silently passing.
        let requestResult = Self.buildTranscriptionRequest(
            url: url, token: token, auth: auth, model: model
        )
        guard case .success(let request) = requestResult else {
            // Asset-load failure — fail every stage with a key-free reason so
            // the run never silently "passes" against a missing clip.
            update(.reachability, .running)
            update(.reachability, .failed(reason: Self.assetMissingReason))
            update(.auth, .failed(reason: Self.assetMissingReason))
            update(.transcription, .failed(reason: Self.assetMissingReason))
            return result
        }

        // ── Stage ① + ③ share one round-trip ──────────────────────────────
        // The transcription POST IS the reachability/TLS handshake AND the
        // auth/status check AND the round-trip. We issue it once, time it, and
        // classify the outcome across all three stages.
        update(.reachability, .running)

        let clock = ContinuousClock()
        let start = clock.now
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            // Classify via the single source of truth in `RemoteAgentTrustEvaluator`
            // so a transient `.secureConnectionFailed` (cold tunnel) is NOT
            // mislabeled "untrusted certificate" — it stays a retryable failure.
            switch RemoteAgentTrustEvaluator.classifyTransportError(error.code, signals: signals()) {
            case .timeout:
                update(.reachability, .failed(reason: Self.timeoutReason))
            case .unreachable, .notEstablished, .offline, .cancelled:
                // The gateway lane splits these further to reason about whether a
                // request may already have run; a transcription probe has no such
                // stake, so they share the one unreachable reason.
                update(.reachability, .failed(reason: Self.unreachableReason))
            case .certMismatch:
                // Pin set + the evaluator confirmed a genuine mismatch → hard
                // `.failed` (never auto-offer re-trust; that defeats pinning).
                update(.reachability, .failed(reason: Self.certMismatchReason))
            case .certKeyUnpinnable:
                // System trust passed and the digest could not be computed, so
                // no comparison happened. Terminal like the two above, but its
                // own reason: this stage must not report a possible interception
                // over a certificate this device just accepted.
                update(.reachability, .failed(reason: Self.certKeyUnpinnableReason))
            case .untrustedCert:
                // The system rejected the chain. Terminal: a pin can only ever
                // narrow what is accepted, so there is nothing this screen could
                // offer that would make the connection work. Name the fix on the
                // server instead.
                update(.reachability, .failed(reason: Self.untrustedCertReason))
            case .blockedByATS:
                // NOT reachability: iOS refused the address before any connect,
                // so the server never had a chance to answer and
                // `unreachableReason`'s "couldn't reach the server" would name
                // the wrong thing. The remedy is the address.
                update(.reachability, .failed(reason: Self.insecureBlockedReason))
            }
            // Reachability did not cleanly pass → auth + transcription cannot
            // run. Mark them skipped with a dependency reason.
            update(.auth, .skipped(reason: Self.blockedByReachabilityReason))
            update(.transcription, .skipped(reason: Self.blockedByReachabilityReason))
            return result
        } catch {
            update(.reachability, .failed(reason: Self.unreachableReason))
            update(.auth, .skipped(reason: Self.blockedByReachabilityReason))
            update(.transcription, .skipped(reason: Self.blockedByReachabilityReason))
            return result
        }

        let elapsed = clock.now - start

        guard let http = response as? HTTPURLResponse else {
            update(.reachability, .failed(reason: Self.invalidResponseReason))
            update(.auth, .skipped(reason: Self.blockedByReachabilityReason))
            update(.transcription, .skipped(reason: Self.blockedByReachabilityReason))
            return result
        }

        // ① The handshake completed and we have an HTTP response → reachability
        // + TLS are good.
        update(.reachability, .passed, detail: Self.tlsOKDetail)

        // ② Auth — ONLY 401 / 403 fail this stage. Every other status means the
        // key reached the auth layer and was accepted.
        update(.auth, .running)
        switch http.statusCode {
        case 401, 403:
            update(.auth, .failed(reason: Self.authFailedReason))
            update(.transcription, .skipped(reason: Self.blockedByAuthReason))
            return result
        default:
            update(.auth, .passed, detail: Self.authOKDetail)
        }

        // ③ Transcription round-trip. A 5xx is a server problem surfaced HERE
        // (auth already passed). A 2xx with a decodable, non-empty transcript
        // is the win condition.
        update(.transcription, .running)
        result.latencyMS = Int(elapsed.components.seconds * 1000)
            + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
        progress(result)

        if (500..<600).contains(http.statusCode) {
            update(.transcription, .failed(reason: Self.serverErrorReason))
            return result
        }
        if !(200..<300).contains(http.statusCode) {
            // 4xx other than 401/403 (e.g. 400 / 413 / 422) on a known-good
            // clip means the server rejected the request shape (wrong model,
            // unsupported format) — a real transcription failure to surface.
            update(.transcription, .failed(reason: Self.rejectedReason))
            return result
        }

        let decoded: STTResponse
        do {
            decoded = try STTResponseDecoder.decode(data, shape: .openAICompat)
        } catch AppError.noSpeechDetected {
            // A valid OpenAI-compatible 200 whose transcript is empty — the case
            // silence can't catch. The decoder now THROWS `.noSpeechDetected`
            // here (it used to return ""), so surface the empty-transcript
            // message, NOT an "isn't OpenAI-compatible" verdict.
            update(.transcription, .failed(reason: Self.emptyTranscriptReason))
            return result
        } catch {
            update(.transcription, .failed(reason: Self.undecodableReason))
            return result
        }

        let transcript = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            // The case silence can NOT catch: a 200 with empty text. This is
            // exactly why the clip is spoken — surface it as a hard failure.
            update(.transcription, .failed(reason: Self.emptyTranscriptReason))
            return result
        }

        // Non-empty transcript → the server transcribed real speech. Store it
        // and run the LOOSE phrase check: a fuzzy miss is a SOFT pass (a
        // working server that mis-hears one word is never hard-failed).
        result.transcript = transcript
        let matched = Self.looselyMatches(transcript, expected: expectedPhrase)
        update(
            .transcription,
            .passed,
            detail: matched ? Self.transcriptMatchDetail : Self.transcriptSoftPassDetail
        )
        return result
    }

    // MARK: - Request construction

    /// Build the multipart transcription `URLRequest` for the bundled spoken
    /// clip. Returns `.failure` when the bundled asset is missing (a bundling
    /// regression) so the caller can fail the run loudly. The key is attached
    /// via `auth.apply` and NEVER surfaced.
    private static func buildTranscriptionRequest(
        url: URL,
        token: String,
        auth: STTAuthScheme,
        model: String
    ) -> Result<URLRequest, Error> {
        // Missing-asset guard mirrors `QwenSTTProbe` / `CustomOpenAISTTProbe`.
        guard let assetURL = Bundle.main.url(forResource: probeAssetName,
                                             withExtension: probeAssetExt) else {
            return .failure(AppError.invalidResponse)
        }
        let audioData: Data
        do {
            audioData = try Data(contentsOf: assetURL)
        } catch {
            return .failure(AppError.invalidResponse)
        }

        let (boundary, body) = STTMultipartBuilder.build(
            audioData: audioData,
            audioMIME: probeAssetMIME,
            audioFilename: probeAssetFilename,
            model: model,
            language: nil,
            fieldNames: .openAICompat
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Constants.remoteAgentTestConnectionTimeout
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")
        auth.apply(to: &request, apiKey: token)
        request.httpBody = body
        return .success(request)
    }

    // MARK: - Loose phrase match (independently unit-testable)

    /// Loose token contains-check: does `transcript` cover at least HALF of the
    /// expected phrase's words? Both sides are lowercased + punctuation-
    /// stripped; each expected token is satisfied either by its word form
    /// (`"two"`) OR its digit form (`"2"`), since a Whisper server may emit
    /// either. Returns true on a ≥50% hit. This is a SOFT signal — the caller
    /// soft-passes on a miss (a working server that mis-hears one word must
    /// never be hard-failed).
    static func looselyMatches(_ transcript: String, expected: String) -> Bool {
        let heardTokens = Set(Self.tokenize(transcript))
        let expectedTokens = Self.tokenize(expected)
        guard !expectedTokens.isEmpty else { return true }

        var hits = 0
        for token in expectedTokens {
            let alternates = Self.digitWordAlternates(token)
            if !alternates.isDisjoint(with: heardTokens) {
                hits += 1
            }
        }
        // ≥50% of expected tokens present.
        return Double(hits) >= Double(expectedTokens.count) * 0.5
    }

    /// Lowercase, strip everything but alphanumerics → whitespace-split into
    /// tokens. `"Testing, 1 2 3!"` → `["testing", "1", "2", "3"]`.
    static func tokenize(_ string: String) -> [String] {
        let scalars = string.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(scalars)
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
    }

    /// Map a token to the set of forms a server might emit — its own form plus
    /// its digit/word counterpart for the small numbers in the expected phrase.
    /// `"two"` → `{"two", "2"}`; `"2"` → `{"2", "two"}`; everything else maps
    /// to itself only.
    private static func digitWordAlternates(_ token: String) -> Set<String> {
        let wordToDigit = ["zero": "0", "one": "1", "two": "2", "three": "3",
                           "four": "4", "five": "5", "six": "6", "seven": "7",
                           "eight": "8", "nine": "9", "ten": "10"]
        var forms: Set<String> = [token]
        if let digit = wordToDigit[token] {
            forms.insert(digit)
        } else if let word = wordToDigit.first(where: { $0.value == token })?.key {
            forms.insert(word)
        }
        return forms
    }

    // MARK: - Key-free, taxonomy-derived stage reasons / details
    //
    // Every string here is status/category-only — it NEVER carries the key,
    // URL, or transcript. Localized with explicit English defaults so the
    // build compiles without an xcstrings sync.

    private static var timeoutReason: String {
        String(localized: "stt.test.reachability.timeout",
                defaultValue: "Timed out reaching the server.")
    }
    private static var unreachableReason: String {
        String(localized: "stt.test.reachability.unreachable",
                defaultValue: "Couldn't reach the server.")
    }
    // Internal for the same reason as `untrustedCertReason` below, and the
    // shared copy for the same reason: a mismatch reaches this stage only when
    // the system TRUSTED the chain, so the reason has to carry the interception
    // warning — a bare "doesn't match the pinned fingerprint" reads like a
    // typo the user should correct.
    static var certMismatchReason: String {
        CertificateTrustCopy.pinMismatchRefusalWithRemedy
    }
    // Internal (not private) so the suite's tests can assert the EXACT reason a
    // rejected chain produces — the one refusal wording, shared with the gateway
    // editor so the two surfaces can't name different remedies.
    static var untrustedCertReason: String {
        CertificateTrustCopy.untrustedRefusalWithRemedy
    }
    // Internal for the same reason as the two above: the tests assert the EXACT
    // reason, and the wording is shared so this stage cannot invent a third
    // story about an unfingerprintable key.
    static var certKeyUnpinnableReason: String {
        CertificateTrustCopy.keyUnpinnableRefusalWithRemedy
    }
    // The lane-neutral -1022 remedy, shared word-for-word with
    // `AppError.insecureConnectionBlocked`'s recovery so the voice-endpoint test
    // and a failed transcription cannot tell one user two stories.
    private static var insecureBlockedReason: String {
        AppError.insecureConnectionBlocked.recoverySuggestion
            ?? String(localized: "remoteAgent.error.insecureBlocked.recovery.v2",
                      defaultValue: "Plain http:// only reaches an address on your own network. Use the server's IP address or its .local name, or put it behind https://.")
    }
    private static var invalidResponseReason: String {
        String(localized: "stt.test.reachability.invalidResponse",
                defaultValue: "Server returned an unexpected response.")
    }
    // `.v2` key: the original wording blamed reachability, which is now only one
    // of the ways stage ① ends (a rejected certificate is the other) — and the
    // catalog value WINS over `defaultValue:`, so the reword needs a fresh key.
    private static var blockedByReachabilityReason: String {
        String(localized: "stt.test.skipped.blockedByReachability.v2",
                defaultValue: "Skipped — the connection to the server didn't complete.")
    }
    private static var blockedByAuthReason: String {
        String(localized: "stt.test.skipped.blockedByAuth",
                defaultValue: "Skipped — authentication failed.")
    }
    private static var authFailedReason: String {
        String(localized: "stt.test.auth.failed",
                defaultValue: "The server rejected the key (401/403).")
    }
    private static var serverErrorReason: String {
        String(localized: "stt.test.transcription.serverError",
                defaultValue: "The server hit an error (5xx). Check its logs.")
    }
    private static var rejectedReason: String {
        String(localized: "stt.test.transcription.rejected",
                defaultValue: "The server rejected the clip — check the model name and audio format.")
    }
    private static var undecodableReason: String {
        String(localized: "stt.test.transcription.undecodable",
                defaultValue: "Couldn't read the server's response — it isn't OpenAI-compatible.")
    }
    // Internal (not private) so the suite's tests can assert the EXACT reason
    // for a 200-empty (vs the undecodable verdict) — guards the regression where
    // a decoder throw was mis-mapped to "isn't OpenAI-compatible".
    static var emptyTranscriptReason: String {
        String(localized: "stt.test.transcription.empty",
                defaultValue: "The server answered but returned no transcript.")
    }
    private static var assetMissingReason: String {
        String(localized: "stt.test.assetMissing",
                defaultValue: "The bundled test clip is missing from the app.")
    }
    private static var tlsOKDetail: String {
        String(localized: "stt.test.reachability.ok",
                defaultValue: "Connected — TLS OK")
    }
    private static var authOKDetail: String {
        String(localized: "stt.test.auth.ok",
                defaultValue: "Key accepted")
    }
    private static var transcriptMatchDetail: String {
        String(localized: "stt.test.transcription.match",
                defaultValue: "Heard the test phrase")
    }
    private static var transcriptSoftPassDetail: String {
        String(localized: "stt.test.transcription.softPass",
                defaultValue: "Got a transcript (didn't exactly match the phrase)")
    }
}
