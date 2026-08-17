// SPDX-License-Identifier: Apache-2.0

// Conduck
// STTKeyReadinessTests.swift
//
// BEHAVIOURAL tests — not a source guard — over the policy that decides what a
// nil STT API key MEANS. `STTKeyReadiness.requiresKey` and
// `STTKeyReadiness.classify` are pure by design precisely so this file can
// exist: the live `resolve` needs a Keychain, and an unsigned simulator has
// none, but the decision the Keychain feeds is separable and is the part that
// was wrong.
//
// THE DEFECT THIS PINS. `activeSTTSnapshot()` returns `apiKey: String?`, and
// that nil is two different facts wearing one shape: "there is no key" and "the
// Keychain could not answer". Keys are written
// `kSecAttrAccessibleAfterFirstUnlock`, so a rebooted, not-yet-unlocked iPhone
// — the Action-Button-from-the-lock-screen case, the single most likely place
// for a headless capture to start — reads every stored key back as nil. The
// intent treated that as proof of absence: it told a correctly configured user
// they had no speech-to-text key, and threw away the recording they had just
// made to say it.
//
// Invariant I3 is the rule being enforced here, in one line: an unreadable slot
// is NEVER proof of absence. `.notConfigured` is reachable from exactly ONE
// Keychain status (`errSecItemNotFound`) and from nothing else — no timeout, no
// auth failure, no locked keychain, and no "we never looked".

import XCTest
import Security
@testable import Conduck

final class STTKeyReadinessTests: XCTestCase {

    // MARK: - requiresKey — who needs a key at all

    /// Apple's on-device provider runs in-process and is authorised by TCC, so
    /// there is no key to be missing and no reading to misinterpret.
    func testInProcessProviderNeedsNoKey() {
        XCTAssertFalse(
            STTKeyReadiness.requiresKey(provider: .appleOnDevice, customConfig: nil),
            "An in-process provider has no credential — asking the Keychain about one would invent a "
            + "failure mode Apple on-device does not have."
        )
    }

    /// A BYO endpoint configured `auth == .none` is a keyless local server.
    func testKeylessCustomEndpointNeedsNoKey() {
        let keyless = CustomSTTConfig(
            url: URL(string: "https://example.invalid/v1/audio/transcriptions"),
            model: "whisper-1",
            auth: STTAuthScheme.none,
            certFingerprint: nil
        )
        XCTAssertFalse(
            STTKeyReadiness.requiresKey(provider: .customOpenAICompat, customConfig: keyless),
            "A keyless BYO endpoint must not be refused for a key it never wanted."
        )
    }

    /// Every cloud provider that signs its requests does need one.
    func testCloudProvidersNeedAKey() {
        for provider in [STTProvider.mistralVoxtral, .openAITranscribe, .elevenLabsScribe, .openRouter] {
            XCTAssertTrue(
                STTKeyReadiness.requiresKey(provider: provider, customConfig: nil),
                "\(provider.id) authenticates on the wire, so its key is load-bearing."
            )
        }
        let bearer = CustomSTTConfig(
            url: URL(string: "https://example.invalid/v1/audio/transcriptions"),
            model: "whisper-1",
            auth: .bearer,
            certFingerprint: nil
        )
        XCTAssertTrue(
            STTKeyReadiness.requiresKey(provider: .customOpenAICompat, customConfig: bearer),
            "A bearer-auth BYO endpoint needs its key like any other."
        )
    }

    // MARK: - classify — the readings, one arm each

    func testNoKeyRequiredIsReadyWithAnEmptyKey() {
        XCTAssertEqual(
            STTKeyReadiness.classify(requiresKey: false, snapshotKey: nil, typedRead: nil),
            .ready(""),
            "A preset that needs no key is ready, and the empty string is what the transcribe call takes."
        )
    }

    func testASnapshotKeyIsUsedWithoutASecondKeychainRead() {
        XCTAssertEqual(
            STTKeyReadiness.classify(requiresKey: true, snapshotKey: "sk-live", typedRead: nil),
            .ready("sk-live"),
            "The happy path must not depend on a typed re-read — it is the path that pays for one."
        )
    }

    func testOnlyItemNotFoundIsCalledNotConfigured() {
        XCTAssertEqual(
            STTKeyReadiness.classify(requiresKey: true, snapshotKey: nil, typedRead: .missing),
            .notConfigured,
            "`errSecItemNotFound` is the one status that PROVES the slot is empty — and the only one a "
            + "pre-microphone refusal may be built on."
        )
    }

    func testALockedKeychainIsUnreadableNotAbsent() {
        XCTAssertEqual(
            STTKeyReadiness.classify(
                requiresKey: true,
                snapshotKey: nil,
                typedRead: .unreadable(errSecInteractionNotAllowed)
            ),
            .unreadable,
            "This is the defect in one assertion: a device that has rebooted and not been unlocked must "
            + "never be told its key is missing (I3)."
        )
    }

    /// The re-read can answer where the snapshot's collapsed nil could not — a
    /// keychain that unlocked, or a migration that completed, in between. Same
    /// preset ID, so the key still pairs with the snapshot's provider.
    func testAKeyThatAppearsOnTheSecondLookIsUsed() {
        XCTAssertEqual(
            STTKeyReadiness.classify(requiresKey: true, snapshotKey: nil, typedRead: .present("sk-late")),
            .ready("sk-late"),
            "Refusing a key the Keychain just handed over would waste a capture for nothing."
        )
    }

    /// An empty string is not a key. It must take the same route a nil does
    /// rather than being handed to the transcribe call as a credential.
    func testAnEmptySnapshotKeyIsNotTreatedAsAKey() {
        XCTAssertEqual(
            STTKeyReadiness.classify(requiresKey: true, snapshotKey: "", typedRead: .missing),
            .notConfigured,
            "An empty string would authenticate nothing; it must be explained, not sent."
        )
    }

    /// "Nobody looked" is not "nobody has one". The absent typed read is the
    /// caller-error shape, and its answer has to be the non-destructive arm.
    func testNoTypedReadForAKeyRequiringPresetIsUnreadableNotAbsent() {
        XCTAssertEqual(
            STTKeyReadiness.classify(requiresKey: true, snapshotKey: nil, typedRead: nil),
            .unreadable,
            "A caller that skipped the typed read established nothing, and an unestablished fact must "
            + "not become a refusal that names the user's configuration."
        )
    }

    // MARK: - The I3 property, over the whole status space

    /// Driven through the REAL `APIKeyReadResult.classify`, so this asserts the
    /// property end to end rather than against hand-built enum cases: of every
    /// Keychain outcome, exactly one may reach `.notConfigured`.
    func testNoKeychainStatusExceptItemNotFoundCanProduceNotConfigured() {
        let statuses: [(name: String, status: OSStatus, data: Data?)] = [
            ("interactionNotAllowed (locked, pre-first-unlock)", errSecInteractionNotAllowed, nil),
            ("authFailed",                                       errSecAuthFailed,            nil),
            ("notAvailable",                                     errSecNotAvailable,          nil),
            ("decode",                                           errSecDecode,                nil),
            ("param",                                            errSecParam,                 nil),
            ("missingEntitlement",                               errSecMissingEntitlement,    nil),
            ("success with empty payload",                       errSecSuccess,               Data()),
            ("success with no payload",                          errSecSuccess,               nil),
        ]
        for row in statuses {
            let read = APIKeyReadResult.classify(status: row.status, data: row.data)
            let verdict = STTKeyReadiness.classify(requiresKey: true, snapshotKey: nil, typedRead: read)
            XCTAssertEqual(
                verdict, .unreadable,
                "\(row.name) says the Keychain could not answer, not that the slot is empty. Calling it "
                + "absence is how a working device gets told it has no key and loses the recording (I3)."
            )
            XCTAssertNotEqual(verdict, .notConfigured, "\(row.name) must never prove absence.")
        }

        // The contrast, so the property above is a distinction and not a
        // constant: the one status that DOES prove it still does.
        XCTAssertEqual(
            STTKeyReadiness.classify(
                requiresKey: true,
                snapshotKey: nil,
                typedRead: APIKeyReadResult.classify(status: errSecItemNotFound, data: nil)
            ),
            .notConfigured,
            "Control: a genuinely empty slot must still be reported as one, or the pre-flight refuses "
            + "nothing and the whole check is decorative."
        )
    }
}
