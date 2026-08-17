// SPDX-License-Identifier: Apache-2.0

// Conduck
// AppError.swift
//
// Application error taxonomy with gappy numeric error codes
// (1-7, 9-11, 14-15, 20-23, 99) — the gaps are intentional, frozen for
// Shortcuts user-facing continuity. Gappy slots (8, 13, 16, 17) are filled
// and (24, 25) appended with the `stt*` taxonomy. The live range runs 1-75 with
// 27 a permanently reserved gap, plus the 99 catch-all; every emitted code
// round-trips through `from(errorCode:message:)`.
//
// No `rateLimitExceeded(usage:)`, `previewRateLimitExceeded(remaining:)`,
// `receiptVerificationFailed`, `invalidTransactionID`, `llmUnavailable`,
// `shouldShowUpgrade` computed prop, or `UsageStats` references — Conduck
// is BYO-key + no subscription.

import Foundation

/// Application-wide error types.
///
/// Each case declares:
/// - `errorDescription` — banner copy shown in Shortcuts (iOS) / menu bar popover (macOS)
/// - `recoverySuggestion` — secondary line on platforms that surface it
/// - `isRetryable` — whether the STT retry loop should loop
/// - `maxAttempts` — cap on how many times the retry loop runs for this error
/// - `shouldPreserveForRetry` — whether the audio should be saved to
///   PendingRetryStore so the user can retry from inside the app later
enum AppError: LocalizedError {
    // Network errors (1-7)
    case networkError(Error)
    case invalidURL
    case noInternetConnection
    case requestTimeout
    case persistentNetworkFailure
    case invalidResponse
    case decodingError(Error)

    // STT auth / quota (8, 13, 16, 17)
    case sttAuthFailed              // 8  — 401 Mistral; user-fixable (re-enter key)
    case sttQuotaExceeded           // 13 — 429 Mistral (billing-fatal, non-retryable)
    case sttTooManyRequests         // 16 — reserved for V1.x Custom preset transient 429
    case sttServerError             // 17 — 5xx upstream, retryable

    // Apple on-device STT (18). Concrete throw sites live in
    // `AppleSpeechRunner`. Fires when `AssetInventory`
    // reports the per-locale `SpeechTranscriber` model is not installed.
    case appleSpeechModelNotInstalled  // 18 — user must download in Settings

    // Request / API errors (9-11, 14-15)
    case invalidRequest(message: String)   // 9
    case apiFailure(message: String)       // 10
    case audioInvalid                      // 11
    case audioMissingData                  // 14
    case settingsLoadFailed                // 15

    // Remote Agent (12, 19, 26, 28-31) — Personal AI gateway taxonomy
    // (OpenClaw + Hermes). Codes 12 + 19 gap-fill the earlier numbering; 26-31
    // append. Code 27 is a RESERVED GAP — no `.remoteAgentSessionBusy`
    // (OpenClaw HTTP 423): client-owned history pins no server
    // session, so no per-session lock is contended.
    // Do NOT reuse 27 — it stays a gap to keep every other code stable.
    // Codes 32-33 = V1.1 multimodal (vision) cases — see the tail below.
    case remoteAgentNotConfigured   // 12 — URL or token missing
    case remoteAgentUnreachable     // 19 — connection refused, DNS, initial-connect timeout

    // STT operational (20-23)
    case sttProviderUnreachable     // 20 — was `sttUnavailable`; retryable, preserveForRetry
    case noSpeechDetected           // 21 — empty transcript (provider 2xx, no recognizable speech) on every surface; also CarPlay VAD no-speech
    case audioTooLarge              // 22 — >15MB; non-retryable
    case sttMissingAPIKey           // 23 — was `apiKeyMisconfigured`; user-fixable

    // New tail cases (24, 25)
    case audioProcessingFailed      // 24 — Mistral 422 (corrupt/unsupported audio)
    case sttDecodingFailure         // 25 — Mistral response shape unexpected

    // Remote Agent tail (26, 28-31) — code 27 is a reserved gap (was
    // `.remoteAgentSessionBusy`; retired under client-owned history).
    case remoteAgentAuthFailed      // 26 — HTTP 401 / 403 from gateway
    case remoteAgentTimeout         // 28 — URLSession resource budget exceeded
    case remoteAgentServerError     // 29 — gateway 5xx
    case remoteAgentCertMismatch    // 30 — pinned fingerprint mismatch
    case remoteAgentInvalidResponse // 31 — JSON decode / missing choices[0].message.content

    // Remote Agent multimodal (32-33) — V1.1 Core Attachments. Both
    // non-retryable (retrying the same image bytes against the same model
    // won't change the verdict; the user must switch model or shrink the
    // image via the Max-image-dimension setting). Surfaced via the body-aware
    // `RemoteAgentClient.mapBodyError` in BOTH send paths.
    case remoteAgentVisionUnsupported // 32 — model rejects image content
    case remoteAgentImageTooLarge     // 33 — gateway 413 / "image too large"

    // Custom OpenAI-compatible STT endpoint (34-35) — BYO self-hosted STT.
    // Both non-retryable (a missing endpoint URL or a changed cert pin is a
    // user-side config problem, not a transient one). Transient 429 reuses
    // 16 (`sttTooManyRequests`), unreachable reuses 20
    // (`sttProviderUnreachable`), auth reuses 8 (`sttAuthFailed`).
    case sttCustomEndpointNotConfigured // 34 — no custom base URL stored
    case sttCustomCertMismatch          // 35 — pinned fingerprint mismatch

    // Cloud Text-to-Speech (36-39) — planned cloud TTS. All `shouldPreserveForRetry
    // = false`: a failed SPOKEN reply is never queued (the text reply is
    // already on screen, and the Apple `AVSpeechSynthesizer` fallback is the
    // free always-available recovery). Mostly internal fallback signals —
    // rarely user-facing.
    case ttsProviderUnreachable     // 36 — transient (408/429/5xx); retryable, maxAttempts ≤ 2
    case ttsSynthesisFailed         // 37 — bad voice/request (400/404/422) terminal; non-retryable
    case ttsEmptyAudio              // 38 — 2xx but zero audio bytes; non-retryable
    case ttsUnauthorized            // 39 — key rejected for TTS (401/403): missing text-to-speech scope; non-retryable
    case ttsRateLimited             // 40 — 402/429: rate-limited or out of quota/credit; one retry then Apple fallback
    case ttsContentBlocked          // 41 — provider safety filter blocked the text (Gemini `promptFeedback.blockReason`); 200 w/ no audio; non-retryable

    // Custom OpenAI-compatible TTS endpoint (42-43) — BYO `/v1/audio/speech`.
    case ttsCustomEndpointNotConfigured // 42 — no custom base URL stored; non-retryable
    case ttsCustomCertMismatch          // 43 — pinned fingerprint mismatch; non-retryable

    // Agent file transfer (44-50) — planned user-run file-server (rclone webdav over
    // HTTPS). The device PUTs file bytes to the server then references them in
    // the chat turn. The family spans 44-50 plus 61, 66 and 70. Fail-fast
    // taxonomy: `maxAttempts` is 1 for every member of it (the
    // staged item + a visible Retry control own retry, NOT a silent loop or
    // `PendingRetryStore`, so `shouldPreserveForRetry` is false for all).
    // Retryable (transient): upload-failed / unreachable / server-error.
    // Non-retryable (user-side config / gone): auth / cert / not-configured /
    // file-unavailable. Privacy: NEVER name the credential in any string.
    // Codes start at 44 — 36-43 are the cloud-TTS block (merged from main).
    case fileTransferNotConfigured   // 44 — file-server URL or credential missing
    case fileTransferUnreachable     // 45 — connect refused / DNS / connect-timeout
    case fileTransferAuthFailed      // 46 — file-server 401/403
    case fileTransferCertMismatch    // 47 — pinned fingerprint mismatch (file-server host)
    case fileTransferServerError     // 48 — file-server 5xx
    case fileTransferUploadFailed    // 49 — PUT failed/incomplete (fail-fast; user retries)
    case fileTransferFileUnavailable // 50 — stored file gone on retry / probe 404 (user re-attaches)

    // Apple Speech Recognition TCC (51) — split out of `sttAuthFailed` (8):
    // a Speech-Recognition permission denial is a Settings toggle, not a
    // rejected cloud key, so it needs its own copy + relay code (the Watch
    // relay decodes the numeric slot; 8 would surface "key rejected").
    case speechPermissionDenied      // 51 — Speech Recognition TCC off; Apple on-device STT can't run

    // Remote Agent — hosted-provider billing (52). HTTP 402 Payment Required,
    // returned by OpenRouter when the account is out of credits. Retryable, and
    // its own copy says why: the verdict rides an account balance the user is
    // told to top up, so the same request succeeds once they have. Retry is
    // an explicit tap, never a loop (`maxAttempts` 1), and an early one costs
    // nothing — 402 means there is no balance to spend.
    case remoteAgentOutOfCredits     // 52 — HTTP 402; hosted provider out of credits

    // macOS mic exclusivity (53) — the in-window composer mic and the menu-bar
    // DictationService own SEPARATE AVAudioRecorder instances, and macOS has no
    // AVAudioSession arbitration, so the SpeechExclusivity mic-lease refuses a
    // SECOND concurrent capture (prevents the "there already is a thread" HAL
    // double-start). macOS-only; never crosses the relay wire. Non-retryable.
    case audioMicBusy                // 53 — another capture already holds the mic

    // Apple on-device STT — language unsupported (54). Distinct from
    // `appleSpeechModelNotInstalled` (18): the requested non-English language
    // isn't in Apple's on-device `SpeechTranscriber.supportedLocales` at all,
    // so there is nothing to download — the recovery is "switch to a cloud
    // provider", NOT "download the model". Only reachable via an explicit
    // non-English `preferredLanguage`; the auto path floors to English, so it
    // never fires by default. Crosses the Watch relay wire (errorCode 54).
    case appleSpeechLanguageUnsupported  // 54 — language not supported on-device

    // Remote Agent gateway, body/status-aware (55-57). 55 and 56 are
    // non-retryable config/usage problems — retrying the same request against
    // the same model won't change the verdict, so the user fixes the model name
    // or shortens the chat first. 57 is retryable: a rate-limit window is
    // external state that expires on its own, and its recovery copy tells the
    // user to wait it out, so the affordance to act on that has to exist.
    //   55 — model name invalid / delisted / not a chat model (body-aware:
    //        `RemoteAgentClient.mapBodyError`, 400/404).
    //   56 — conversation exceeds the model's context window (body-aware, 400).
    //   57 — HTTP 429; provider rate-limit / free-tier daily cap.
    case remoteAgentModelUnavailable // 55 — model unavailable / wrong model id
    case remoteAgentContextTooLong   // 56 — history exceeds model context window
    case remoteAgentRateLimited      // 57 — HTTP 429 rate-limit / daily cap

    // Gateway ROUTE problems (58-60, 62) — the gateway host answers, but the
    // OpenAI-compatible AI route isn't there / isn't usable. Distinct from
    // `.remoteAgentUnreachable` (host silent) and `.remoteAgentAuthFailed`
    // (route there, credential wrong): these say "you reached A server,
    // just not an AI one." All are config problems, never retryable.
    //
    // 58 is the app's answer to the trap `conduck-connect` calls "the flag that
    // bites everyone": OpenClaw's OpenAI chat endpoint is OFF by default, and a
    // disabled endpoint serves the Control-UI **HTML at HTTP 200** — so a
    // status-only probe reads it as success. Never assert "it returned a web
    // page" in 58's copy — a proxy's plaintext error lands here too. Say what
    // we know and let the per-backend remedy
    // (`RemoteAgentBackendMetadata.endpointDisabledRemedy`) name the likely
    // cause (the remedy fires for 62 as well: a disabled endpoint that answers
    // `{}` is the same trap wearing JSON).
    case remoteAgentEndpointUnexpectedResponse // 58 — 2xx, but the body isn't JSON (HTML page, plaintext)
    case remoteAgentEndpointNotFound           // 59 — 404 on the probe route
    case remoteAgentModelRequired              // 60 — gateway demands an explicit model
    // The JSON twin of 58: the probe body PARSED as JSON but isn't the required
    // envelope (bare array, `{"models":…}`, `{}`). Split from 58 because the fix
    // differs — 58's likely cause is a web page / disabled endpoint, 62's is a
    // server that speaks JSON but not the contract shape (the likeliest failure
    // of a home-built custom adapter), so the copy can name the exact rule.
    case remoteAgentEndpointWrongEnvelope      // 62 — 2xx + valid JSON, but no top-level "data"

    // File-server ROUTE problem (61) — the file-lane twin of 58/59: the host at
    // the file-server URL answers, but it is not serving files. Two throw sites,
    // one cause class ("you reached A server, just not a WebDAV one"):
    //   • the staged test's read stage got the WRONG BYTES back — we PUT a known
    //     13-byte probe and the GET returned something else (a login page, an SSO
    //     wall, a dashboard that 200s everything). This is the case the byte-echo
    //     compare exists to catch, and it MUST NOT read as "your server errored":
    //     the server's own logs show a clean 200.
    //   • the PUT itself came back 404/405/501 — the endpoint isn't a writable
    //     WebDAV root (the likeliest real misconfiguration: a read-only nginx, or
    //     the gateway's own web UI on the wrong port).
    // Config problem, never retryable. Privacy: never name the credential.
    case fileTransferNotAFileServer  // 61 — host answers, but isn't serving files

    // Certificate NOT TRUSTED (63-66) — ONE cause, one code per lane. This
    // device rejected the chain the server presented. Strictly distinct from the
    // `*CertMismatch` family (30/35/43/47), which fires only after the system
    // ACCEPTED the chain and the presented key still disagreed with the pin —
    // the interception shape, where the remedy is to stop and check. Here there
    // is nothing to check and nothing to correct on the device at all: a pin can
    // only TIGHTEN a trusted chain, never rescue an untrusted one (App Transport
    // Security lets an app tighten trust evaluation but not loosen it), so
    // "remove the pin and fall back on system trust" is never the remedy —
    // system trust is what refused. Terminal and never retryable: the fix is on
    // the SERVER, which is why all four share
    // `CertificateTrustCopy.untrustedRemedy` verbatim — one cause must not ship
    // four different remedies.
    case remoteAgentCertUntrusted    // 63 — gateway certificate not trusted by this device
    case sttCustomCertUntrusted      // 64 — custom STT endpoint's certificate not trusted
    case ttsCustomCertUntrusted      // 65 — custom voice endpoint's certificate not trusted
    case fileTransferCertUntrusted   // 66 — file-server certificate not trusted

    // Pin could not be COMPUTED (67-70) — one code per lane, the third and
    // narrowest certificate outcome. The system TRUSTED the chain and then
    // Conduck could not hash the leaf's public key, because its algorithm is
    // outside the SPKI prefix table (Ed25519, RSA-1024/8192, P-521). So the pin
    // was never compared — nothing disagreed with anything.
    //
    // Kept out of BOTH other families on purpose. It is not 30/35/43/47: those
    // mean a pinned key disagreed, which is the interception shape, and saying
    // so here would raise the app's most alarming message at a user whose
    // certificate is perfectly good. It is not 63-66 either: the chain passed,
    // so there is nothing to fix on the server. Terminal and never retryable —
    // the same key produces the same verdict every time — and all four share
    // `CertificateTrustCopy.keyUnpinnableRemedy`, the one remedy in the app that
    // may offer to clear a saved fingerprint (see that property for why).
    case remoteAgentCertKeyUnpinnable    // 67 — gateway key algorithm can't be fingerprinted
    case sttCustomCertKeyUnpinnable      // 68 — custom STT endpoint's key can't be fingerprinted
    case ttsCustomCertKeyUnpinnable      // 69 — custom voice endpoint's key can't be fingerprinted
    case fileTransferCertKeyUnpinnable   // 70 — file-server key can't be fingerprinted

    // Gateway failure forensics (71-73). These exist because the send path used
    // to collapse three very different situations into copy the user could not
    // act on: an unmapped status, a route/upstream outage, and a connection that
    // never opened all rendered as `.apiFailure`'s "Something went wrong".
    //
    // `status` is OPTIONAL on purpose. A live failure knows the number and says
    // it; a failure reconstructed from a persisted `failureCode` (or off the
    // Watch relay wire) does NOT — `from(errorCode:message:)` carries a code,
    // never a second integer, and the discarded `.apiFailure` text is untrusted
    // input that must never be parsed back into copy. So the number degrades to
    // absent rather than becoming a guess.
    case remoteAgentUnexpectedStatus(status: Int?)  // 71 — a status Conduck has no mapping for
    // 502/503/504/530: something ANSWERED, but not the gateway itself. Kept out
    // of 29 (`serverError`) because 29 sends the user to read gateway logs, and
    // here the gateway may never have seen the request. Deliberately does NOT
    // name Cloudflare or "the tunnel": a 502/504 can equally come from the
    // gateway's own model provider, which the user cannot restart.
    case remoteAgentServiceUnavailable             // 72 — a server in the route is unavailable
    // The connection never opened (DNS didn't resolve, or the host refused).
    // Split from 19 so the copy can say delivery is unlikely. It says "unlikely",
    // never "nothing was sent": without transport metrics the app cannot prove a
    // negative, and even metrics could not prove the gateway didn't execute.
    case remoteAgentNotEstablished                 // 73 — no connection was established

    // The default pointer can't take a NEW chat (74). Three things this case is,
    // and each one is the reason it is not code 12:
    //
    //   1. Code 12 asserts "No personal AI gateway is configured", which is FALSE
    //      the moment any other gateway on this device works. The measured case
    //      is a restored iPad with five verified gateways being told none were
    //      set up, with no way to tell which sentence was the lie.
    //   2. It fires ONLY on the MINT path for a NEW conversation. A conversation
    //      already BOUND to a dead gateway keeps throwing 12, unchanged: routing
    //      is per-conversation, and 74 there would read as an invitation to
    //      re-point a thread the app must never re-point. Clone to switch.
    //   3. `gatewayName` is a DISPLAY NAME from
    //      `RemoteAgentRefMetadata.displayName(for:customs:)` — never a URL,
    //      never a raw ref. It is OPTIONAL for the same reason 71's `status` is:
    //      a live throw fills it, and a failure reconstructed from a bare wire
    //      code cannot, so the name degrades to ABSENT rather than to a guess.
    case remoteAgentDefaultNeedsSetup(gatewayName: String?)  // 74 — the default pointer can't take a new chat

    // The STT key slot could not be READ (75), which is not the same fact as
    // there being no key in it — and code 23 asserts the second one. Keys are
    // stored `kSecAttrAccessibleAfterFirstUnlock`, so on a device that has
    // rebooted and not yet been unlocked every slot answers the same way an
    // empty slot does. Telling that user "No STT API key set" is a false
    // statement about a device that is correctly configured, and it points them
    // at a settings screen where they would find their key already there.
    //
    // The two are separable because `SettingsManager.apiKeyReadResult` returns
    // the TYPED `APIKeyReadResult`: `errSecItemNotFound` is provable absence
    // (23), and every other non-success status — plus a success carrying an
    // undecodable payload — is this code. Nothing infers absence from a nil.
    case sttKeyUnreadable                                    // 75 — the Keychain could not answer for the STT key

    // Catch-all (99)
    case unknown(Error)

    var errorDescription: String? {
        switch self {
        // Network errors
        case .networkError(let error):
            return String(localized: "network.error.generic", defaultValue: "Network error: \(error.localizedDescription)")
        case .invalidURL:
            return String(localized: "request.error.invalidURL", defaultValue: "Invalid API endpoint URL")
        case .noInternetConnection:
            return String(localized: "network.error.noConnection", defaultValue: "No internet. Conduck needs Wi-Fi or cellular to work.")
        case .requestTimeout:
            return String(localized: "network.error.timeout", defaultValue: "Request timed out. Network might be spotty.")
        case .persistentNetworkFailure:
            return String(localized: "network.error.persistentFailure", defaultValue: "Couldn't reach the server. Recording saved — open Conduck to retry.")
        case .invalidResponse:
            return String(localized: "request.error.invalidResponse", defaultValue: "Got an unexpected response from the server.")
        case .decodingError(let error):
            return String(localized: "request.error.decodingError", defaultValue: "Couldn't read the server response: \(error.localizedDescription)")

        // STT auth / quota
        case .sttAuthFailed:
            return String(localized: "stt.error.authFailed", defaultValue: "Your STT API key was rejected. Open Conduck → Settings to update it.")
        case .sttQuotaExceeded:
            return String(localized: "stt.error.quotaExceeded", defaultValue: "Your STT provider quota is exhausted. Check your billing dashboard.")
        case .sttTooManyRequests:
            return String(localized: "stt.error.tooManyRequests", defaultValue: "STT provider is rate-limiting requests. Try again in a moment.")
        case .sttServerError:
            return String(localized: "stt.error.serverError", defaultValue: "STT provider is having issues on their end. Recording saved — open Conduck to retry.")
        case .appleSpeechModelNotInstalled:
            // New key (`…v2`) so the reworded copy wins over the catalog entry
            // for the old "isn't downloaded yet" string (catalog-value-wins rule).
            return String(localized: "stt.error.appleSpeechModelNotInstalled.v2", defaultValue: "On-device voice model isn't ready for this language yet.")
        case .appleSpeechLanguageUnsupported:
            return String(localized: "stt.error.appleSpeechLanguageUnsupported", defaultValue: "Apple Speech doesn't support this language on-device.")
        case .speechPermissionDenied:
            return String(localized: "stt.error.speechPermissionDenied", defaultValue: "Speech Recognition is turned off for Conduck.")

        // Request / API errors
        case .invalidRequest(let message):
            return message
        case .apiFailure:
            // `.v2` key so the reworded copy wins over the catalog's old "our end"
            // value (catalog-value-wins rule). No-backend app: never imply a
            // intermediary server — this case wraps network/decoding/unknown errors,
            // whose "server" is the user's own gateway or STT provider.
            return String(localized: "api.error.failure.v2", defaultValue: "Something went wrong with the last request. Try again in a moment.")
        case .audioInvalid:
            return String(localized: "audio.error.invalid", defaultValue: "Couldn't read that audio. Record again.")
        case .audioMissingData:
            return String(localized: "audio.error.missingData", defaultValue: "No audio data to transcribe.")
        case .audioMicBusy:
            return String(localized: "audio.error.micBusy", defaultValue: "The microphone is already in use by another recording.")
        case .settingsLoadFailed:
            return String(localized: "settings.error.loadFailed", defaultValue: "Failed to load settings. Using defaults.")

        // STT operational
        case .sttProviderUnreachable:
            return String(localized: "stt.error.providerUnreachable", defaultValue: "STT provider is unreachable. Recording saved — open Conduck to retry.")
        case .noSpeechDetected:
            // Neutral by design: 21 covers genuine silence AND unintelligible
            // audio (the provider returned 2xx with an empty transcript) — the
            // copy must not blame the user's voice or mic technique.
            return String(localized: "audio.error.noSpeechDetected", defaultValue: "No speech was recognized in the recording.")
        case .audioTooLarge:
            return String(localized: "audio.error.tooLarge", defaultValue: "Recording too long. Keep it under 5 minutes.")
        case .sttMissingAPIKey:
            return String(localized: "stt.error.missingKey", defaultValue: "No STT API key set. Open Conduck → Settings to add one.")
        case .sttKeyUnreadable:
            // Says what is TRUE (the key could not be read) and never what is
            // merely likely (that there is no key). Carries its own instruction
            // in the cause line, like `.sttMissingAPIKey` does, because one lane
            // that raises it is a Shortcut, which renders `errorDescription`
            // alone and has no second slot for a remedy.
            //
            // It makes NO claim about the recording, and the `.v2` key is that
            // removal. The claim read as a `ConverseIntent` guarantee, but ARMED
            // is not SAVED: `PendingRetryGuard.arm` reports a `PendingRetryStore`
            // save failure on its token instead of throwing, and that save is a
            // `.completeFileProtection` write — least certain in the very window
            // this code exists for, a device that has rebooted and not been
            // unlocked. Several lanes raise 75 and not all of them can verify
            // the promise, so it belongs to the surfaces that can: the deferred
            // "Recording Saved" notification, which is scheduled only when the
            // bytes actually landed, and the live Retry affordance the in-app
            // and wrist banners sit beside.
            //
            // Catalog-value-wins rule: a reworded existing key ships the OLD
            // string, so this is a new key.
            return String(localized: "stt.error.keyUnreadable.v2", defaultValue: "Couldn't read your STT API key. If this device just restarted, unlock it and try again.")

        // New tail
        case .audioProcessingFailed:
            return String(localized: "audio.error.processingFailed", defaultValue: "STT provider couldn't process that audio. Record again.")
        case .sttDecodingFailure:
            return String(localized: "stt.error.decodingFailure", defaultValue: "STT provider returned an unexpected response format.")

        // Remote Agent (Personal AI gateway — OpenClaw / Hermes)
        case .remoteAgentNotConfigured:
            return String(localized: "remoteAgent.error.notConfigured", defaultValue: "No personal AI gateway is configured.")
        case .remoteAgentUnreachable:
            return String(localized: "remoteAgent.error.unreachable", defaultValue: "Could not reach your personal AI gateway.")
        case .remoteAgentAuthFailed:
            // `.v2`: 26 carries 401 AND 403, and a 403 is a refusal that can
            // happen before any credential is looked at — an origin that
            // rejects the `Host` its tunnel forwards (Ollama's default) never
            // reaches the authentication step at all. "Could not authenticate"
            // asserts an attempt that did not occur, and on a keyless gateway
            // it also names a credential the user deliberately doesn't have.
            // "The request … was refused" is true of both statuses and names
            // no refuser, matching `unexpectedStatus`'s restraint.
            // Catalog-value-wins rule: a reworded existing key ships the OLD
            // string, so this is a new key.
            return String(localized: "remoteAgent.error.authFailed.v2", defaultValue: "The request to your personal AI was refused.")
        case .remoteAgentTimeout:
            return String(localized: "remoteAgent.error.timeout", defaultValue: "Your personal AI took too long to respond.")
        case .remoteAgentServerError:
            return String(localized: "remoteAgent.error.serverError", defaultValue: "Your personal AI gateway reported an error.")
        case .remoteAgentUnexpectedStatus(let status):
            // Two keys, not one interpolation with a placeholder value: a
            // reconstructed failure has no number, and "HTTP 0" would be a lie.
            if let status {
                return String(localized: "remoteAgent.error.unexpectedStatus", defaultValue: "Your gateway answered with HTTP \(status), which Conduck doesn't recognise.")
            }
            return String(localized: "remoteAgent.error.unexpectedStatus.unknown", defaultValue: "Your gateway answered in a way Conduck doesn't recognise.")
        case .remoteAgentServiceUnavailable:
            return String(localized: "remoteAgent.error.serviceUnavailable", defaultValue: "A server involved in this connection is temporarily unavailable.")
        case .remoteAgentNotEstablished:
            return String(localized: "remoteAgent.error.notEstablished", defaultValue: "Conduck couldn't open a connection to your gateway.")
        case .remoteAgentDefaultNeedsSetup(let gatewayName):
            // Two keys, not one interpolation: a 74 reconstructed off the wire
            // carries no name, and "Your default AI, , isn't set up" is a defect.
            // Cause only — the remedy lives in `recoverySuggestion`, because
            // `descriptionWithRecovery` concatenates the pair and a remedy baked
            // into both halves would ship twice.
            if let gatewayName {
                return String(localized: "remoteAgent.error.defaultNeedsSetup", defaultValue: "Your default AI, \(gatewayName), isn't set up on this device.")
            }
            // Serves THREE readings and has to be true for all of them: a broken
            // default whose name could not be resolved, a device with no default
            // chosen at all, and a 74 rebuilt from a bare code. Hence "doesn't
            // know which AI to use" rather than naming a fault.
            return String(localized: "remoteAgent.error.defaultNeedsSetup.unnamed", defaultValue: "Conduck doesn't know which AI to use for new chats.")
        case .remoteAgentCertMismatch:
            // Each `*CertMismatch` line names the SERVER whose key disagreed;
            // the remedy is shared and lives in `recoverySuggestion`. Never
            // phrases this as the fingerprint having "changed" — the app cannot
            // know that, and on the interception shape this verdict now has,
            // nothing on the user's server changed at all.
            return String(localized: "remoteAgent.error.certMismatch", defaultValue: "Your gateway's certificate doesn't match the fingerprint you pinned.")
        case .remoteAgentInvalidResponse:
            return String(localized: "remoteAgent.error.invalidResponse", defaultValue: "Your personal AI returned an unexpected response.")
        case .remoteAgentVisionUnsupported:
            // "gateway", never "model" (vocabulary rule): the client
            // can't attribute the decline to the adapter vs the engine — the
            // old "This model can't read images." was measurably wrong (a
            // vision-capable engine behind a text-only adapter). Hedged copy:
            // this string also fires on regex-heuristic classifications.
            return String(localized: "remoteAgent.error.visionUnsupported", defaultValue: "This gateway couldn't use the photo.")
        case .remoteAgentImageTooLarge:
            return String(localized: "remoteAgent.error.imageTooLarge", defaultValue: "An attached image was too large for your gateway.")
        case .remoteAgentOutOfCredits:
            // Cause only, like its 429 sibling. The remedy is an account
            // balance, which belongs in `recoverySuggestion` where the two-slot
            // surfaces can reach it — Diagnostics renders the fix row from it,
            // and the gateway editor renders nothing else. `descriptionWithRecovery`
            // rejoins the pair for the single-line surfaces.
            return String(localized: "remoteAgent.error.outOfCredits", defaultValue: "Your AI provider is out of credits.")
        case .remoteAgentModelUnavailable:
            return String(localized: "remoteAgent.error.modelUnavailable", defaultValue: "That AI model isn't available.")
        case .remoteAgentContextTooLong:
            return String(localized: "remoteAgent.error.contextTooLong", defaultValue: "This chat got too long for the model.")
        case .remoteAgentRateLimited:
            return String(localized: "remoteAgent.error.rateLimited", defaultValue: "Your AI provider is rate-limiting you.")
        case .remoteAgentEndpointUnexpectedResponse:
            return String(localized: "remoteAgent.error.endpointUnexpectedResponse", defaultValue: "Your gateway answered, but not like an AI endpoint.")
        case .remoteAgentEndpointWrongEnvelope:
            return String(localized: "remoteAgent.error.endpointWrongEnvelope", defaultValue: "Your gateway answered JSON, but not in the shape Conduck needs.")
        case .remoteAgentEndpointNotFound:
            return String(localized: "remoteAgent.error.endpointNotFound", defaultValue: "Your gateway didn't recognise the AI endpoint.")
        case .remoteAgentModelRequired:
            return String(localized: "remoteAgent.error.modelRequired", defaultValue: "Your gateway needs you to name a model.")

        // Custom OpenAI-compatible STT endpoint
        case .sttCustomEndpointNotConfigured:
            return String(localized: "stt.error.customEndpointNotConfigured", defaultValue: "No custom STT endpoint is configured.")
        case .sttCustomCertMismatch:
            return String(localized: "stt.error.customCertMismatch", defaultValue: "Your custom STT server's certificate doesn't match the fingerprint you pinned.")

        // Cloud Text-to-Speech (internal fallback signals — the spoken reply
        // silently falls back to Apple's voice, so these are rarely surfaced).
        case .ttsProviderUnreachable:
            return String(localized: "tts.error.providerUnreachable", defaultValue: "Couldn't reach the voice provider. Using the built-in voice.")
        case .ttsSynthesisFailed:
            return String(localized: "tts.error.synthesisFailed", defaultValue: "Couldn't generate the spoken reply. Using the built-in voice.")
        case .ttsEmptyAudio:
            return String(localized: "tts.error.emptyAudio", defaultValue: "The voice provider returned no audio. Using the built-in voice.")
        case .ttsUnauthorized:
            return String(localized: "tts.error.unauthorized", defaultValue: "Your API key isn't allowed to make spoken replies. Using the built-in voice.")
        case .ttsRateLimited:
            return String(localized: "tts.error.rateLimited", defaultValue: "The voice provider is rate-limited or out of quota. Using the built-in voice.")
        case .ttsContentBlocked:
            return String(localized: "tts.error.contentBlocked", defaultValue: "The voice provider's safety filter blocked this text. Using the built-in voice.")

        // Custom OpenAI-compatible TTS endpoint
        case .ttsCustomEndpointNotConfigured:
            return String(localized: "tts.error.customEndpointNotConfigured", defaultValue: "No custom voice endpoint is configured.")
        case .ttsCustomCertMismatch:
            return String(localized: "tts.error.customCertMismatch", defaultValue: "Your custom voice server's certificate doesn't match the fingerprint you pinned.")

        // Agent file transfer (user-run file-server). Never name the credential.
        case .fileTransferNotConfigured:
            return String(localized: "fileTransfer.error.notConfigured", defaultValue: "File transfer isn't set up for this gateway.")
        case .fileTransferUnreachable:
            return String(localized: "fileTransfer.error.unreachable", defaultValue: "Couldn't reach your file-server.")
        case .fileTransferAuthFailed:
            return String(localized: "fileTransfer.error.authFailed", defaultValue: "Your file-server rejected the connection.")
        case .fileTransferCertMismatch:
            return String(localized: "fileTransfer.error.certMismatch", defaultValue: "Your file server's certificate doesn't match the fingerprint you pinned.")
        case .fileTransferServerError:
            return String(localized: "fileTransfer.error.serverError", defaultValue: "Your file-server reported an error.")
        case .fileTransferUploadFailed:
            return String(localized: "fileTransfer.error.uploadFailed", defaultValue: "Couldn't upload the file to your file server.")
        case .fileTransferFileUnavailable:
            return String(localized: "fileTransfer.error.fileUnavailable", defaultValue: "That file is no longer on your file server.")
        case .fileTransferNotAFileServer:
            return String(localized: "fileTransfer.error.notAFileServer", defaultValue: "That address answered, but it isn't serving your files.")

        // Certificate not trusted. Each line names the SERVER whose certificate
        // was refused (the banner can surface far from the screen that
        // configured it); the remedy is shared and lives in `recoverySuggestion`.
        // Never phrase this as the certificate having "changed" — nothing
        // changed, and implying it did reads as an attack in progress.
        case .remoteAgentCertUntrusted:
            return String(localized: "remoteAgent.error.certUntrusted", defaultValue: "This device doesn't trust your gateway's certificate.")
        case .sttCustomCertUntrusted:
            return String(localized: "stt.error.customCertUntrusted", defaultValue: "This device doesn't trust your custom STT server's certificate.")
        case .ttsCustomCertUntrusted:
            return String(localized: "tts.error.customCertUntrusted", defaultValue: "This device doesn't trust your custom voice server's certificate.")
        case .fileTransferCertUntrusted:
            return String(localized: "fileTransfer.error.certUntrusted", defaultValue: "This device doesn't trust your file server's certificate.")

        // Pin could not be computed. Each line names the SERVER and the actual
        // cause — the KEY TYPE, not the certificate — so the user does not read
        // it as "my certificate is broken". Never says the certificate doesn't
        // match: nothing was compared.
        case .remoteAgentCertKeyUnpinnable:
            return String(localized: "remoteAgent.error.certKeyUnpinnable", defaultValue: "Your gateway's certificate uses a key type Conduck can't fingerprint, so your pinned fingerprint can't be checked.")
        case .sttCustomCertKeyUnpinnable:
            return String(localized: "stt.error.customCertKeyUnpinnable", defaultValue: "Your custom STT server's certificate uses a key type Conduck can't fingerprint, so your pinned fingerprint can't be checked.")
        case .ttsCustomCertKeyUnpinnable:
            return String(localized: "tts.error.customCertKeyUnpinnable", defaultValue: "Your custom voice server's certificate uses a key type Conduck can't fingerprint, so your pinned fingerprint can't be checked.")
        case .fileTransferCertKeyUnpinnable:
            return String(localized: "fileTransfer.error.certKeyUnpinnable", defaultValue: "Your file server's certificate uses a key type Conduck can't fingerprint, so your pinned fingerprint can't be checked.")

        case .unknown(let error):
            return String(localized: "api.error.unknown", defaultValue: "An unexpected error occurred: \(error.localizedDescription)")
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .noInternetConnection:
            return String(localized: "network.error.noConnection.recovery", defaultValue: "Check your connection and try again.")
        case .requestTimeout:
            return String(localized: "network.error.timeout.recovery", defaultValue: "Try a shorter recording or check your signal.")
        case .persistentNetworkFailure:
            return String(localized: "network.error.persistentFailure.recovery", defaultValue: "Better reception or Wi-Fi usually sorts it.")
        case .sttAuthFailed:
            return String(localized: "stt.error.authFailed.recovery", defaultValue: "Verify the key in your provider dashboard, then paste it again.")
        case .sttQuotaExceeded:
            return String(localized: "stt.error.quotaExceeded.recovery", defaultValue: "Top up your provider account or wait for the next billing cycle.")
        case .sttTooManyRequests:
            return String(localized: "stt.error.tooManyRequests.recovery", defaultValue: "Should be back in a minute or two.")
        case .sttServerError:
            return String(localized: "stt.error.serverError.recovery", defaultValue: "Should be back in a minute or two.")
        case .appleSpeechModelNotInstalled:
            return String(localized: "stt.error.appleSpeechModelNotInstalled.recovery.v2", defaultValue: "Switch to a cloud voice provider in Settings → Voice, or try a different language.")
        case .appleSpeechLanguageUnsupported:
            return String(localized: "stt.error.appleSpeechLanguageUnsupported.recovery", defaultValue: "Switch to a cloud provider in Settings to transcribe this language.")
        case .speechPermissionDenied:
            return String(localized: "stt.error.speechPermissionDenied.recovery", defaultValue: "Allow it in Settings → Privacy & Security → Speech Recognition. Watch recordings transcribe on your iPhone — enable it there.")
        case .sttProviderUnreachable:
            return String(localized: "stt.error.providerUnreachable.recovery", defaultValue: "Should be back in a minute or two.")
        case .apiFailure:
            return String(localized: "api.error.failure.recovery", defaultValue: "Should be back in a minute or two.")
        case .sttMissingAPIKey:
            return String(localized: "stt.error.missingKey.recovery", defaultValue: "Open Settings → STT API Key to add one.")
        case .sttKeyUnreadable:
            // An EXPLICIT arm rather than the generic "Try again.": the fix is a
            // specific act (unlock the device) that a bare retry invitation does
            // not name, and the surfaces that render one line would otherwise
            // drop the remedy entirely.
            return String(localized: "stt.error.keyUnreadable.recovery", defaultValue: "Unlock this device, then open Conduck and retry.")
        case .audioInvalid:
            return String(localized: "audio.error.invalid.recovery", defaultValue: "Record new audio.")
        case .audioMicBusy:
            return String(localized: "audio.error.micBusy.recovery", defaultValue: "Finish the other recording first, then try again.")
        case .audioProcessingFailed:
            return String(localized: "audio.error.processingFailed.recovery", defaultValue: "Record new audio.")
        case .audioTooLarge:
            return String(localized: "audio.error.tooLarge.recovery", defaultValue: "Split it into shorter recordings.")
        case .noSpeechDetected:
            return String(localized: "audio.error.noSpeechDetected.recovery", defaultValue: "Try recording again.")
        case .sttDecodingFailure:
            return String(localized: "stt.error.decodingFailure.recovery", defaultValue: "If this persists, the provider may have changed its API.")
        case .remoteAgentNotConfigured:
            return String(localized: "remoteAgent.error.notConfigured.recovery", defaultValue: "Open Settings → Personal AI and add a URL and bearer token.")
        case .remoteAgentDefaultNeedsSetup:
            // An EXPLICIT arm, never `default:`: the generic "Try again."
            // `descriptionWithRecovery` deliberately drops would leave the one
            // surface that renders a single line with nothing to act on.
            //
            // Says "AI", never "gateway", matching the shipped
            // `UnconfiguredCopy.DefaultNeedsSetup` strings the empty state uses.
            // Never mentions a bearer token — 12's recovery does, which is wrong
            // for a keyless gateway anyway and doubly wrong here, where the
            // problem is WHICH AI, not a missing credential. The first clause
            // defuses the panic the false "nothing is configured" banner caused,
            // before asking the user for anything.
            return String(localized: "remoteAgent.error.defaultNeedsSetup.recovery", defaultValue: "Your other AIs still work. Open Settings → Personal AI and pick one for new chats.")
        case .remoteAgentUnreachable:
            // `.v2`: 19 is now the UNCERTAIN bucket. The codes that prove a
            // connection never opened moved to 73, and a genuinely offline
            // device moved to 3, so what remains here (a dropped connection, a
            // non-URLError throw, a cold TLS handshake with no trust verdict)
            // is exactly the set where the app cannot tell whether the request
            // landed. Saying so matters because these gateways run tools.
            // Catalog-value-wins rule: a reworded existing key ships the OLD
            // string, so this is a new key.
            return String(localized: "remoteAgent.error.unreachable.recovery.v2", defaultValue: "Check the gateway is reachable from this device. Conduck can't tell whether the request arrived, so if it could run tools, check the gateway before trying again.")
        case .remoteAgentAuthFailed:
            // `.v2`: 26 has two live causes and cannot tell them apart here — a
            // credential the gateway rejected, and an origin that refuses the
            // request as it arrives over the HTTPS route (the measured case:
            // Ollama rejects any `Host` that isn't a local address, and tunnels
            // forward the original one, so a tunnel pointed straight at it 403s
            // every time). Naming only the token sends a KEYLESS gateway's owner
            // hunting for a credential that doesn't exist. Both possibilities,
            // neither asserted — the shape `unexpectedStatus.recovery` uses.
            // Stays framework-neutral: 26 also fires for OpenRouter, where a
            // proxy remedy would be noise, and per-framework facts drift.
            // Catalog-value-wins rule: a reworded existing key ships the OLD
            // string, so this is a new key.
            return String(localized: "remoteAgent.error.authFailed.recovery.v2", defaultValue: "Check this gateway's token if it has one, and check anything in front of it — a proxy or tunnel can forward the request in a form your server refuses.")
        case .remoteAgentTimeout:
            // `.v2`: a timeout is the other half of the uncertain bucket — the
            // gateway may still be working, and a second attempt can repeat
            // both the work and its cost on the user's own key.
            return String(localized: "remoteAgent.error.timeout.recovery.v2", defaultValue: "It may still be working on this one. Check the gateway before trying again, because another attempt could repeat the work and the cost.")
        case .remoteAgentServerError:
            return String(localized: "remoteAgent.error.serverError.recovery", defaultValue: "Check the gateway logs, then try again.")
        case .remoteAgentUnexpectedStatus:
            return String(localized: "remoteAgent.error.unexpectedStatus.recovery", defaultValue: "That came from your server, or from something in front of it. Check both, then try again.")
        case .remoteAgentServiceUnavailable:
            return String(localized: "remoteAgent.error.serviceUnavailable.recovery", defaultValue: "Check your gateway, anything in front of it such as a tunnel or proxy, and the model provider it uses.")
        case .remoteAgentNotEstablished:
            return String(localized: "remoteAgent.error.notEstablished.recovery", defaultValue: "Check the address is still current and the gateway is running. The request most likely never reached it.")
        case .remoteAgentInvalidResponse:
            return String(localized: "remoteAgent.error.invalidResponse.recovery", defaultValue: "Check the gateway is running an OpenAI-compatible /v1/chat/completions endpoint.")
        case .remoteAgentVisionUnsupported:
            return String(localized: "remoteAgent.error.visionUnsupported.recovery", defaultValue: "Enable photo support on your gateway, or keep chatting with text.")
        case .remoteAgentImageTooLarge:
            return String(localized: "remoteAgent.error.imageTooLarge.recovery", defaultValue: "Your gateway rejected the image as too large. Try a smaller image, or raise your gateway's image-size limit.")
        case .remoteAgentOutOfCredits:
            // BYO-key: the balance is on the user's OWN provider account, so the
            // remedy points there and nowhere else. Without this arm 52 falls to
            // the generic "Try again." — which the gateway editor renders as its
            // WHOLE message, telling a user with no credit to keep retrying.
            return String(localized: "remoteAgent.error.outOfCredits.recovery", defaultValue: "Add credits with your provider, then try again.")
        case .remoteAgentModelUnavailable:
            return String(localized: "remoteAgent.error.modelUnavailable.recovery", defaultValue: "Check the model name in Settings, or pick a different one.")
        case .remoteAgentContextTooLong:
            return String(localized: "remoteAgent.error.contextTooLong.recovery", defaultValue: "Start a new chat, or switch to a model with a bigger context window.")
        case .remoteAgentRateLimited:
            return String(localized: "remoteAgent.error.rateLimited.recovery", defaultValue: "Wait a moment, then try again — free models often have daily limits.")
        case .remoteAgentEndpointUnexpectedResponse:
            // Deliberately does NOT claim "it returned a web page" — a `{}` body
            // lands here too. The editor pairs this with the per-backend
            // `endpointDisabledRemedy` (OpenClaw's chat-endpoint flag, Hermes's
            // API_SERVER_ENABLED), which names the LIKELY cause without asserting it.
            return String(localized: "remoteAgent.error.endpointUnexpectedResponse.recovery", defaultValue: "It answered with something other than an AI endpoint's data. The endpoint may be switched off on your server, or the URL may point at a web page.")
        case .remoteAgentEndpointWrongEnvelope:
            // Names the exact rule — this is the likeliest failure of a
            // home-built adapter, and "check your server" would waste its
            // builder's time. The contract URL is the one place the rule lives.
            return String(localized: "remoteAgent.error.endpointWrongEnvelope.recovery", defaultValue: "The /v1/models reply must be an object with a top-level \"data\" array. Contract: conduck.com/setup/adapter/v1")
        case .remoteAgentEndpointNotFound:
            return String(localized: "remoteAgent.error.endpointNotFound.recovery", defaultValue: "Check the Gateway URL is your server's base address, not a full /v1/… path.")
        case .remoteAgentModelRequired:
            return String(localized: "remoteAgent.error.modelRequired.recovery", defaultValue: "Open this gateway's settings and set a Model, for example llama3.")
        case .sttCustomEndpointNotConfigured:
            return String(localized: "stt.error.customEndpointNotConfigured.recovery", defaultValue: "Open Settings → STT and add your custom endpoint's URL.")
        // The two `.v2` keys below carry that suffix because the pre-redesign
        // strings are already in `Localizable.xcstrings`, and the catalog value
        // WINS over `defaultValue:` — rewording the default alone would ship the
        // stale copy. A new key uses its `defaultValue:`.
        case .fileTransferNotConfigured:
            return String(localized: "fileTransfer.error.notConfigured.recovery.v2", defaultValue: "Open Settings → Personal AI, tap this gateway, and open File transfer.")
        case .fileTransferUnreachable:
            return String(localized: "fileTransfer.error.unreachable.recovery", defaultValue: "Check your file-server is running and reachable from this device.")
        case .fileTransferAuthFailed:
            return String(localized: "fileTransfer.error.authFailed.recovery.v2", defaultValue: "Open Settings → Personal AI, tap this gateway, open File transfer, and generate a new password your file server accepts.")
        case .fileTransferServerError:
            return String(localized: "fileTransfer.error.serverError.recovery", defaultValue: "Check your file-server's logs, then try again.")
        case .fileTransferUploadFailed:
            return String(localized: "fileTransfer.error.uploadFailed.recovery", defaultValue: "Tap Retry. If it keeps failing, check your file-server is running.")
        case .fileTransferFileUnavailable:
            return String(localized: "fileTransfer.error.fileUnavailable.recovery", defaultValue: "Re-attach the file and send again.")
        case .fileTransferNotAFileServer:
            return String(localized: "fileTransfer.error.notAFileServer.recovery", defaultValue: "It's most likely a login page, a dashboard, or the wrong address — not a file server. The file-server URL is a different address and port from your gateway's.")
        // One cause, ONE remedy: all four certificate-not-trusted codes return
        // the shared text verbatim — the same words the gateway editor and the
        // voice-endpoint test suite render. The fix is on the server, so it
        // cannot legitimately differ by lane, and four paraphrases of one
        // instruction would read as four different problems.
        case .remoteAgentCertUntrusted, .sttCustomCertUntrusted,
             .ttsCustomCertUntrusted, .fileTransferCertUntrusted:
            return CertificateTrustCopy.untrustedRemedy
        // The pin-mismatch family gets the same treatment for the same reason,
        // and `.ttsCustomCertMismatch` is listed here rather than left to
        // `default:` — falling through would answer a verdict its own
        // `isRetryable` calls terminal with "Try again."
        case .remoteAgentCertMismatch, .sttCustomCertMismatch,
             .ttsCustomCertMismatch, .fileTransferCertMismatch:
            return CertificateTrustCopy.pinMismatchRemedy
        // Same rule, third family: one cause, one remedy, verbatim on all four
        // lanes. Listed explicitly rather than left to `default:` for the reason
        // above — the generic "Try again." would invite a retry that reaches the
        // identical verdict, and would bury the two things the user can act on.
        case .remoteAgentCertKeyUnpinnable, .sttCustomCertKeyUnpinnable,
             .ttsCustomCertKeyUnpinnable, .fileTransferCertKeyUnpinnable:
            return CertificateTrustCopy.keyUnpinnableRemedy
        default:
            return Self.genericRecovery
        }
    }

    /// The last-resort recovery. Named so `descriptionWithRecovery` can
    /// recognise — and drop — it: a bare "Try again." bolted onto a terminal
    /// refusal is exactly the retry invitation the certificate taxonomy exists
    /// to prevent.
    private static var genericRecovery: String {
        String(localized: "api.error.unknown.recovery", defaultValue: "Try again.")
    }

    /// What happened AND what to do, as ONE string, for the surfaces that render
    /// a single line and have no second slot for the remedy — and, unlike the
    /// chat thread, no Troubleshoot chip that could reach one. Drops the generic
    /// fallback rather than appending it, so a terminal refusal never picks up a
    /// "Try again." it cannot honour.
    var descriptionWithRecovery: String {
        let what = errorDescription ?? ""
        guard let recovery = recoverySuggestion, recovery != Self.genericRecovery else { return what }
        return what.isEmpty ? recovery : "\(what) \(recovery)"
    }

    /// Whether the retry loop should treat this error as recoverable.
    /// Pair with `maxAttempts` to actually cap how many times we retry.
    var isRetryable: Bool {
        switch self {
        case .networkError, .requestTimeout, .noInternetConnection,
             .apiFailure, .sttProviderUnreachable, .sttServerError,
             .sttTooManyRequests,
             .remoteAgentUnreachable,
             .remoteAgentTimeout, .remoteAgentServerError,
             // 72/73 are transient by nature: a route outage clears, and a
             // gateway that is down or moved can come back. Both still retry
             // only on an explicit user tap (`maxAttempts` 1 below).
             .remoteAgentServiceUnavailable, .remoteAgentNotEstablished,
             // 52/57 turn on state OUTSIDE the request — an account balance and
             // a rate-limit window — and each one's shipped copy instructs the
             // user to change exactly that ("Add credits with your provider,
             // then try again"; "Wait a moment, then try again"). Calling them
             // terminal gives an instruction and withholds the means to follow
             // it, and the user pays for that in a stranded turn: re-attaching
             // every file and retyping the prompt to send a request the provider
             // accepts. An early tap costs nothing — 402 means there is no
             // balance to spend, and 429 doesn't bill. Retry stays an explicit
             // user tap, never a loop (`maxAttempts` 1 below).
             .remoteAgentOutOfCredits, .remoteAgentRateLimited,
             // 75 belongs beside 52/57 on the same test: what refused is state
             // OUTSIDE the request — a Keychain that has not been unlocked yet —
             // and it clears on its own the moment the user unlocks the device,
             // at which point the identical bytes succeed. Calling it terminal
             // would deny the retry its own copy instructs the user to make.
             // Never a loop: `maxAttempts` leaves it at 1, so the retry is the
             // user's tap and nothing spins against a locked Keychain.
             .sttKeyUnreadable,
             .ttsProviderUnreachable, .ttsEmptyAudio, .ttsRateLimited,
             .fileTransferUploadFailed, .fileTransferUnreachable,
             .fileTransferServerError:
            return true
        case .invalidURL, .invalidResponse, .decodingError,
             .invalidRequest, .persistentNetworkFailure,
             .audioInvalid, .audioMissingData, .audioMicBusy, .settingsLoadFailed,
             .sttAuthFailed, .speechPermissionDenied,
             .sttQuotaExceeded, .sttMissingAPIKey,
             .noSpeechDetected, .audioTooLarge,
             .audioProcessingFailed, .sttDecodingFailure,
             .appleSpeechModelNotInstalled, .appleSpeechLanguageUnsupported,
             .remoteAgentNotConfigured, .remoteAgentAuthFailed,
             // 74 sits beside 12 for the same reason: retrying the same bytes
             // against the same dead pointer reaches the same verdict. The audio
             // is still worth keeping — see `shouldPreserveForRetry`, where 74 is
             // the deliberate exception — but the loop must not spin on it.
             .remoteAgentDefaultNeedsSetup,
             .remoteAgentCertMismatch, .remoteAgentInvalidResponse,
             .remoteAgentVisionUnsupported, .remoteAgentImageTooLarge,
             .remoteAgentModelUnavailable, .remoteAgentContextTooLong,
             // Route problems — the AI endpoint isn't there / isn't usable.
             // Retrying the same request against the same URL cannot change
             // the verdict; the user has to fix the server or the URL.
             .remoteAgentEndpointUnexpectedResponse, .remoteAgentEndpointWrongEnvelope,
             .remoteAgentEndpointNotFound, .remoteAgentModelRequired,
             // 71 joins the route family: a status Conduck has no mapping for
             // is a configuration or middlebox fact, and the same request
             // against the same URL returns the same status.
             .remoteAgentUnexpectedStatus,
             .sttCustomEndpointNotConfigured, .sttCustomCertMismatch,
             .ttsSynthesisFailed, .ttsUnauthorized, .ttsContentBlocked,
             .ttsCustomEndpointNotConfigured, .ttsCustomCertMismatch,
             .fileTransferNotConfigured, .fileTransferAuthFailed,
             .fileTransferCertMismatch, .fileTransferFileUnavailable,
             // The URL points at something that isn't a file server — retrying
             // the same PUT against the same login page cannot change the verdict.
             .fileTransferNotAFileServer,
             // Certificate not trusted — terminal on every lane. The device will
             // refuse the same certificate every time, so a retry only delays
             // the message that names the server-side fix.
             .remoteAgentCertUntrusted, .sttCustomCertUntrusted,
             .ttsCustomCertUntrusted, .fileTransferCertUntrusted,
             // Pin not computable — terminal too. The leaf's key algorithm is
             // the same on every attempt, so the digest is unhashable every
             // time; only reissuing the certificate or clearing the pin changes
             // the outcome.
             .remoteAgentCertKeyUnpinnable, .sttCustomCertKeyUnpinnable,
             .ttsCustomCertKeyUnpinnable, .fileTransferCertKeyUnpinnable:
            return false
        case .unknown:
            return true
        }
    }

    /// Cap on total attempts (including the first) before failing.
    ///
    /// Transport blips (DNS, dropped packet) often recover on the second try,
    /// so network-layer errors keep the full 3 attempts. Upstream service
    /// outages (Mistral down) rarely recover inside 3 seconds — 2 attempts
    /// shaves ~9 s of user-visible waiting before the banner, and the user
    /// still has the in-app "Retry" button via PendingRetryStore.
    var maxAttempts: Int {
        switch self {
        case .noInternetConnection, .networkError, .requestTimeout:
            return 3
        case .sttProviderUnreachable, .sttServerError, .sttTooManyRequests, .apiFailure:
            return 2
        // Cloud TTS: a single retry then fall back to Apple's voice (free,
        // always available) — never burn more than 2 attempts on a spoken reply.
        // `.ttsEmptyAudio` shares this budget: the Gemini preview model can
        // return text tokens instead of audio on a 200, and one ~1 s retry
        // usually self-heals before the Apple fallback (the production providers
        // never emit empty 200s, so they never spin here).
        case .ttsProviderUnreachable, .ttsEmptyAudio, .ttsRateLimited:
            return 2
        // Remote Agent: a single retry; the user sees a banner with an
        // explicit Try Again rather than a silent burn of their own LLM
        // budget. (There is no lock-busy / 423 path under client-owned
        // history, so no multi-attempt-with-jitter arm exists.)
        case .remoteAgentUnreachable, .remoteAgentTimeout, .remoteAgentServerError:
            return 1
        default:
            return 1
        }
    }

    /// Whether the recording should be saved to `PendingRetryStore` so the
    /// user can retry from inside the app later. True for transient upstream
    /// issues where waiting a minute is likely to help; false for user-side
    /// problems (silence, bad format, missing key) where retrying the same
    /// bytes won't change the outcome.
    var shouldPreserveForRetry: Bool {
        switch self {
        case .persistentNetworkFailure, .sttProviderUnreachable, .sttServerError:
            return true
        // The deliberate exception to the "transient upstream only" rule above.
        // 74 is a user-side problem and `isRetryable` is false for it, but the
        // audio is bit-for-bit valid, the fix is one tap, and after that tap the
        // SAME bytes succeed. Preserving is what lets `ConverseIntent`'s
        // `shouldPreserveForRetry` arm keep the recording armed instead of
        // disarming it — otherwise a broken default silently eats the words the
        // user already spoke.
        case .remoteAgentDefaultNeedsSetup:
            return true
        // 75 for 74's reason: the bytes are bit-for-bit valid, the fix is an
        // unlock rather than a re-record, and the SAME bytes succeed afterwards.
        // `ConverseIntent` does not depend on this — it refuses a blackout above
        // its catch chain, where no disarm can reach the recording at all — so
        // this arm is what makes the answer right for any OTHER lane that
        // decides preservation from the taxonomy.
        case .sttKeyUnreadable:
            return true
        default:
            return false
        }
    }

    /// Whether the local Diagnostics screen can actually help with this failure —
    /// the SINGLE source of truth behind every "Troubleshoot" affordance
    /// (`DiagnosticsFocus` gates on it). False for local audio problems and
    /// self-evident content/usage errors Diagnostics can't diagnose (record
    /// again, image too large, chat too long, mic busy); true for the
    /// environmental class it CAN reason about — connection / gateway / auth /
    /// cert / model / permission / file-transfer / sync / STT / TTS transport.
    /// Keeping this a deny-list (not an allow-list) means a newly-added code is
    /// troubleshootable by default — safer for recall than silently hiding it.
    var isTroubleshootable: Bool {
        switch self {
        case .audioInvalid, .audioMissingData, .settingsLoadFailed,
             .noSpeechDetected, .audioTooLarge, .audioProcessingFailed,
             .audioMicBusy, .remoteAgentVisionUnsupported, .remoteAgentImageTooLarge,
             .remoteAgentContextTooLong, .ttsContentBlocked:
            return false
        default:
            return true
        }
    }

    /// Create AppError from the numeric `errorCode` slot — inverse of the
    /// `errorCode: Int` getter below. Every numeric code Conduck emits is
    /// round-trippable; the Watch's `AppleSpeechRelayCoordinator.handleReply`
    /// is the sole decoder for iPhone-side errors over the relay wire, so
    /// missing inverse mappings collapse user-visible failures to a blank
    /// banner.
    ///
    /// Cases with associated values that can't be reconstructed from a code
    /// (`.networkError(Error)`, `.decodingError(Error)`, `.unknown(Error)`)
    /// fall through to `.apiFailure(message:)` so the wire-side message is
    /// at least surfaced.
    static func from(errorCode: Int, message: String?) -> AppError {
        switch errorCode {
        case 1: return .apiFailure(message: message ?? "")        // networkError(Error) — Error not reconstructible
        case 2: return .invalidURL
        case 3: return .noInternetConnection
        case 4: return .requestTimeout
        case 5: return .persistentNetworkFailure
        case 6: return .invalidResponse
        case 7: return .apiFailure(message: message ?? "")        // decodingError(Error) — Error not reconstructible
        case 8: return .sttAuthFailed
        case 9: return .invalidRequest(message: message ?? "")
        case 10: return .apiFailure(message: message ?? "")
        case 11: return .audioInvalid
        case 12: return .remoteAgentNotConfigured
        case 13: return .sttQuotaExceeded
        case 14: return .audioMissingData
        case 15: return .settingsLoadFailed
        case 16: return .sttTooManyRequests
        case 17: return .sttServerError
        case 18: return .appleSpeechModelNotInstalled
        case 19: return .remoteAgentUnreachable
        case 20: return .sttProviderUnreachable
        case 21: return .noSpeechDetected
        case 22: return .audioTooLarge
        case 23: return .sttMissingAPIKey
        case 24: return .audioProcessingFailed
        case 25: return .sttDecodingFailure
        case 26: return .remoteAgentAuthFailed
        // case 27 — RESERVED GAP (was .remoteAgentSessionBusy; retired).
        // Falls through to .apiFailure via `default`; do not reuse.
        case 28: return .remoteAgentTimeout
        case 29: return .remoteAgentServerError
        case 30: return .remoteAgentCertMismatch
        case 31: return .remoteAgentInvalidResponse
        case 32: return .remoteAgentVisionUnsupported
        case 33: return .remoteAgentImageTooLarge
        case 34: return .sttCustomEndpointNotConfigured
        case 35: return .sttCustomCertMismatch
        case 36: return .ttsProviderUnreachable
        case 37: return .ttsSynthesisFailed
        case 38: return .ttsEmptyAudio
        case 39: return .ttsUnauthorized
        case 40: return .ttsRateLimited
        case 41: return .ttsContentBlocked
        case 42: return .ttsCustomEndpointNotConfigured
        case 43: return .ttsCustomCertMismatch
        case 44: return .fileTransferNotConfigured
        case 45: return .fileTransferUnreachable
        case 46: return .fileTransferAuthFailed
        case 47: return .fileTransferCertMismatch
        case 48: return .fileTransferServerError
        case 49: return .fileTransferUploadFailed
        case 50: return .fileTransferFileUnavailable
        case 51: return .speechPermissionDenied
        case 52: return .remoteAgentOutOfCredits
        case 53: return .audioMicBusy
        case 54: return .appleSpeechLanguageUnsupported
        case 55: return .remoteAgentModelUnavailable
        case 56: return .remoteAgentContextTooLong
        case 57: return .remoteAgentRateLimited
        case 58: return .remoteAgentEndpointUnexpectedResponse
        case 59: return .remoteAgentEndpointNotFound
        case 60: return .remoteAgentModelRequired
        case 61: return .fileTransferNotAFileServer
        case 62: return .remoteAgentEndpointWrongEnvelope
        case 63: return .remoteAgentCertUntrusted
        case 64: return .sttCustomCertUntrusted
        case 65: return .ttsCustomCertUntrusted
        case 66: return .fileTransferCertUntrusted
        case 67: return .remoteAgentCertKeyUnpinnable
        case 68: return .sttCustomCertKeyUnpinnable
        case 69: return .ttsCustomCertKeyUnpinnable
        case 70: return .fileTransferCertKeyUnpinnable
        // 71 reconstructs WITHOUT its status. The wire and the persisted row
        // carry a code and nothing else, and `message` here is untrusted text
        // (it arrives off the Watch relay), so parsing a number back out of it
        // would be both unreliable and a copy-injection path. Absent number →
        // the `.unknown` variant of the copy.
        case 71: return .remoteAgentUnexpectedStatus(status: nil)
        case 72: return .remoteAgentServiceUnavailable
        case 73: return .remoteAgentNotEstablished
        // 74 reconstructs WITHOUT its gateway name, on 71's exact reasoning: the
        // wire and the persisted row carry one Int and nothing else, and
        // `message` is untrusted relay text that must never be parsed back into
        // user copy. Absent name → the unnamed variant, which is written to be
        // true on its own.
        case 74: return .remoteAgentDefaultNeedsSetup(gatewayName: nil)
        case 75: return .sttKeyUnreadable
        case 99: return .apiFailure(message: message ?? "")       // unknown(Error) — Error not reconstructible
        default:
            return .apiFailure(message: message ?? "")
        }
    }

}

// MARK: - CustomNSError Conformance

/// Makes AppError display user-friendly messages in Shortcuts and system dialogs.
/// Without this, iOS shows "AppError error 9" instead of our errorDescription.
///
/// Error codes are stable — never renumber. Gappy slots are intentional: the
/// numbering is frozen so Shortcuts users see stable error codes for each
/// failure mode across releases.
extension AppError: CustomNSError {
    static var errorDomain: String {
        "Conduck.AppError"
    }

    var errorCode: Int {
        switch self {
        case .networkError: return 1
        case .invalidURL: return 2
        case .noInternetConnection: return 3
        case .requestTimeout: return 4
        case .persistentNetworkFailure: return 5
        case .invalidResponse: return 6
        case .decodingError: return 7
        case .sttAuthFailed: return 8
        case .invalidRequest: return 9
        case .apiFailure: return 10
        case .audioInvalid: return 11
        case .remoteAgentNotConfigured: return 12
        case .sttQuotaExceeded: return 13
        case .audioMissingData: return 14
        case .settingsLoadFailed: return 15
        case .sttTooManyRequests: return 16
        case .sttServerError: return 17
        case .appleSpeechModelNotInstalled: return 18
        case .remoteAgentUnreachable: return 19
        case .sttProviderUnreachable: return 20
        case .noSpeechDetected: return 21
        case .audioTooLarge: return 22
        case .sttMissingAPIKey: return 23
        case .audioProcessingFailed: return 24
        case .sttDecodingFailure: return 25
        case .remoteAgentAuthFailed: return 26
        // 27 is a reserved gap (was .remoteAgentSessionBusy; retired).
        case .remoteAgentTimeout: return 28
        case .remoteAgentServerError: return 29
        case .remoteAgentCertMismatch: return 30
        case .remoteAgentInvalidResponse: return 31
        case .remoteAgentVisionUnsupported: return 32
        case .remoteAgentImageTooLarge: return 33
        case .sttCustomEndpointNotConfigured: return 34
        case .sttCustomCertMismatch: return 35
        case .ttsProviderUnreachable: return 36
        case .ttsSynthesisFailed: return 37
        case .ttsEmptyAudio: return 38
        case .ttsUnauthorized: return 39
        case .ttsRateLimited: return 40
        case .ttsContentBlocked: return 41
        case .ttsCustomEndpointNotConfigured: return 42
        case .ttsCustomCertMismatch: return 43
        case .fileTransferNotConfigured: return 44
        case .fileTransferUnreachable: return 45
        case .fileTransferAuthFailed: return 46
        case .fileTransferCertMismatch: return 47
        case .fileTransferServerError: return 48
        case .fileTransferUploadFailed: return 49
        case .fileTransferFileUnavailable: return 50
        case .speechPermissionDenied: return 51
        case .appleSpeechLanguageUnsupported: return 54
        case .remoteAgentOutOfCredits: return 52
        case .audioMicBusy: return 53
        case .remoteAgentModelUnavailable: return 55
        case .remoteAgentContextTooLong: return 56
        case .remoteAgentRateLimited: return 57
        case .remoteAgentEndpointUnexpectedResponse: return 58
        case .remoteAgentEndpointWrongEnvelope: return 62
        case .remoteAgentEndpointNotFound: return 59
        case .remoteAgentModelRequired: return 60
        case .fileTransferNotAFileServer: return 61
        case .remoteAgentCertUntrusted: return 63
        case .sttCustomCertUntrusted: return 64
        case .ttsCustomCertUntrusted: return 65
        case .fileTransferCertUntrusted: return 66
        case .remoteAgentCertKeyUnpinnable: return 67
        case .sttCustomCertKeyUnpinnable: return 68
        case .ttsCustomCertKeyUnpinnable: return 69
        case .fileTransferCertKeyUnpinnable: return 70
        case .remoteAgentUnexpectedStatus: return 71
        case .remoteAgentServiceUnavailable: return 72
        case .remoteAgentNotEstablished: return 73
        case .remoteAgentDefaultNeedsSetup: return 74
        case .sttKeyUnreadable: return 75
        case .unknown: return 99
        }
    }

    var errorUserInfo: [String: Any] {
        var userInfo: [String: Any] = [:]

        // This is the key that iOS/Shortcuts uses to display the error message
        if let description = errorDescription {
            userInfo[NSLocalizedDescriptionKey] = description
        }

        if let recovery = recoverySuggestion {
            userInfo[NSLocalizedRecoverySuggestionErrorKey] = recovery
        }

        return userInfo
    }
}
