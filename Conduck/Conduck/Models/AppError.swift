// SPDX-License-Identifier: Apache-2.0

// Conduck
// AppError.swift
//
// Application error taxonomy with gappy numeric error codes
// (1-7, 9-11, 14-15, 20-23, 99) — the gaps are intentional, frozen for
// Shortcuts user-facing continuity. Gappy slots (8, 13, 16, 17) are filled
// and (24, 25) appended with the `stt*` taxonomy.
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
    // the chat turn. Fail-fast taxonomy: `maxAttempts` is 1 for all seven (the
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
    // returned by OpenRouter when the account is out of credits. Non-retryable
    // (retrying without adding credits won't help); actionable recovery copy.
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

    // Remote Agent gateway, body/status-aware (55-57). All three are
    // non-retryable config/usage problems — retrying the same request against
    // the same model won't change the verdict (the chat Retry chip is always
    // available regardless, so the user can still re-send after fixing the
    // model / shortening the chat / waiting out the rate limit).
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
            return String(localized: "remoteAgent.error.authFailed", defaultValue: "Could not authenticate with your personal AI.")
        case .remoteAgentTimeout:
            return String(localized: "remoteAgent.error.timeout", defaultValue: "Your personal AI took too long to respond.")
        case .remoteAgentServerError:
            return String(localized: "remoteAgent.error.serverError", defaultValue: "Your personal AI gateway reported an error.")
        case .remoteAgentCertMismatch:
            return String(localized: "remoteAgent.error.certMismatch", defaultValue: "Your gateway's certificate fingerprint changed.")
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
            return String(localized: "remoteAgent.error.outOfCredits", defaultValue: "Your AI provider is out of credits. Add credits with your provider, then try again.")
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
            return String(localized: "stt.error.customCertMismatch", defaultValue: "Your custom STT server's certificate fingerprint changed.")

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
            return String(localized: "tts.error.customCertMismatch", defaultValue: "Your custom voice server's certificate fingerprint changed.")

        // Agent file transfer (user-run file-server). Never name the credential.
        case .fileTransferNotConfigured:
            return String(localized: "fileTransfer.error.notConfigured", defaultValue: "File transfer isn't set up for this gateway.")
        case .fileTransferUnreachable:
            return String(localized: "fileTransfer.error.unreachable", defaultValue: "Couldn't reach your file-server.")
        case .fileTransferAuthFailed:
            return String(localized: "fileTransfer.error.authFailed", defaultValue: "Your file-server rejected the connection.")
        case .fileTransferCertMismatch:
            return String(localized: "fileTransfer.error.certMismatch", defaultValue: "Your file-server's certificate fingerprint changed.")
        case .fileTransferServerError:
            return String(localized: "fileTransfer.error.serverError", defaultValue: "Your file-server reported an error.")
        case .fileTransferUploadFailed:
            return String(localized: "fileTransfer.error.uploadFailed", defaultValue: "Couldn't upload the file to your gateway.")
        case .fileTransferFileUnavailable:
            return String(localized: "fileTransfer.error.fileUnavailable", defaultValue: "That file is no longer on your gateway.")
        case .fileTransferNotAFileServer:
            return String(localized: "fileTransfer.error.notAFileServer", defaultValue: "That address answered, but it isn't serving your files.")

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
        case .remoteAgentUnreachable:
            return String(localized: "remoteAgent.error.unreachable.recovery", defaultValue: "Check the gateway is running and accessible from this device.")
        case .remoteAgentAuthFailed:
            return String(localized: "remoteAgent.error.authFailed.recovery", defaultValue: "Open Settings and verify the bearer token for your gateway.")
        case .remoteAgentTimeout:
            return String(localized: "remoteAgent.error.timeout.recovery", defaultValue: "Try again — the gateway may be processing a long reply.")
        case .remoteAgentServerError:
            return String(localized: "remoteAgent.error.serverError.recovery", defaultValue: "Check the gateway logs, then try again.")
        case .remoteAgentCertMismatch:
            return String(localized: "remoteAgent.error.certMismatch.recovery", defaultValue: "Open Settings and update the pinned fingerprint, or remove the pin to use system trust.")
        case .remoteAgentInvalidResponse:
            return String(localized: "remoteAgent.error.invalidResponse.recovery", defaultValue: "Check the gateway is running an OpenAI-compatible /v1/chat/completions endpoint.")
        case .remoteAgentVisionUnsupported:
            return String(localized: "remoteAgent.error.visionUnsupported.recovery", defaultValue: "Enable photo support on your gateway, or keep chatting with text.")
        case .remoteAgentImageTooLarge:
            return String(localized: "remoteAgent.error.imageTooLarge.recovery", defaultValue: "Your gateway rejected the image as too large. Try a smaller image, or raise your gateway's image-size limit.")
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
        case .sttCustomCertMismatch:
            return String(localized: "stt.error.customCertMismatch.recovery", defaultValue: "Open Settings and update the pinned fingerprint, or remove the pin to use system trust.")
        // The three keys below carry a `.v2` suffix because the pre-redesign
        // strings are already in `Localizable.xcstrings`, and the catalog value
        // WINS over `defaultValue:` — rewording the default alone would ship the
        // stale copy. A new key uses its `defaultValue:`.
        case .fileTransferNotConfigured:
            return String(localized: "fileTransfer.error.notConfigured.recovery.v2", defaultValue: "Open Settings → Personal AI, tap this gateway, and open File transfer.")
        case .fileTransferUnreachable:
            return String(localized: "fileTransfer.error.unreachable.recovery", defaultValue: "Check your file-server is running and reachable from this device.")
        case .fileTransferAuthFailed:
            return String(localized: "fileTransfer.error.authFailed.recovery.v2", defaultValue: "Open Settings → Personal AI, tap this gateway, open File transfer, and generate a new password your file server accepts.")
        case .fileTransferCertMismatch:
            return String(localized: "fileTransfer.error.certMismatch.recovery.v2", defaultValue: "If you changed your file server's certificate, open its File transfer section, tap Forget file transfer, and set it up again. If you changed nothing, stop — the connection may be intercepted.")
        case .fileTransferServerError:
            return String(localized: "fileTransfer.error.serverError.recovery", defaultValue: "Check your file-server's logs, then try again.")
        case .fileTransferUploadFailed:
            return String(localized: "fileTransfer.error.uploadFailed.recovery", defaultValue: "Tap Retry. If it keeps failing, check your file-server is running.")
        case .fileTransferFileUnavailable:
            return String(localized: "fileTransfer.error.fileUnavailable.recovery", defaultValue: "Re-attach the file and send again.")
        case .fileTransferNotAFileServer:
            return String(localized: "fileTransfer.error.notAFileServer.recovery", defaultValue: "It's most likely a login page, a dashboard, or the wrong address — not a file server. The file-server URL is a different address and port from your gateway's.")
        default:
            return String(localized: "api.error.unknown.recovery", defaultValue: "Try again.")
        }
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
             .remoteAgentCertMismatch, .remoteAgentInvalidResponse,
             .remoteAgentVisionUnsupported, .remoteAgentImageTooLarge,
             .remoteAgentOutOfCredits,
             .remoteAgentModelUnavailable, .remoteAgentContextTooLong,
             .remoteAgentRateLimited,
             // Route problems — the AI endpoint isn't there / isn't usable.
             // Retrying the same request against the same URL cannot change
             // the verdict; the user has to fix the server or the URL.
             .remoteAgentEndpointUnexpectedResponse, .remoteAgentEndpointWrongEnvelope,
             .remoteAgentEndpointNotFound, .remoteAgentModelRequired,
             .sttCustomEndpointNotConfigured, .sttCustomCertMismatch,
             .ttsSynthesisFailed, .ttsUnauthorized, .ttsContentBlocked,
             .ttsCustomEndpointNotConfigured, .ttsCustomCertMismatch,
             .fileTransferNotConfigured, .fileTransferAuthFailed,
             .fileTransferCertMismatch, .fileTransferFileUnavailable,
             // The URL points at something that isn't a file server — retrying
             // the same PUT against the same login page cannot change the verdict.
             .fileTransferNotAFileServer:
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
