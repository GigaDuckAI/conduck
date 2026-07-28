// SPDX-License-Identifier: Apache-2.0

// Conduck
// CertificateTrustCopy.swift
//
// The ONE wording for each certificate refusal, shared by every surface that can
// reach them (the gateway editor's Test Connection, the custom voice endpoint's
// staged test suite, the wrist, the wheel). Several surfaces, one text per cause
// — separate copies drift into several different remedies for one problem.
//
// The two REFUSAL causes are never collapsed, because their remedies are
// opposites:
//
//   UNTRUSTED CHAIN — this device rejected the certificate itself. App Transport
//   Security lets an app TIGHTEN trust evaluation (pinning) but never loosen it,
//   so a fingerprint pin cannot rescue a chain the system refused; there is no
//   "trust it anyway" the app could honour even if it offered one. The fix is on
//   the SERVER, so the message names server-side routes to a trusted certificate
//   and stops.
//
//   PIN MISMATCH — the system DID trust the chain and the presented key still
//   disagreed with the pinned fingerprint. That is the interception shape: the
//   only remaining explanation, once trust succeeded, is that the key under the
//   trusted chain is not the one the user pinned. So this copy WARNS, and it
//   never offers to drop the pin — that would trade the one control that caught
//   the problem for silence.
//
// A third, much narrower cause sits beside them and must not be folded into
// either:
//
//   KEY CANNOT BE FINGERPRINTED — the chain is system-trusted and nothing
//   disagreed with anything; Conduck simply cannot compute an SPKI digest for
//   the leaf's key algorithm (Ed25519, RSA-1024/8192, P-521), so the pin could
//   not be COMPARED. Reading it as a mismatch would tell a user with a perfectly
//   good certificate that they may be intercepted — a false alarm on the most
//   alarming message in the app, which is how people learn to dismiss the real
//   one. Reading it as an untrusted chain would send them to fix a server that
//   is already correct.
//
// All three are terminal. None invites a retry: the evaluator reaches the same
// verdict on every attempt until something outside the app changes.

import Foundation

enum CertificateTrustCopy {

    // MARK: - Untrusted chain

    /// What happened. One sentence, no jargon, no blame on the network.
    static var untrustedRefusal: String {
        String(localized: "settings.certTrust.untrusted.refusal",
                defaultValue: "This device doesn't trust the certificate this server presented, so Conduck won't connect to it.")
    }

    /// What to do about it. Every named route is free and issues a certificate
    /// devices already trust, so the user is never left with "get a real
    /// certificate" and no way to act on it.
    static var untrustedRemedy: String {
        String(localized: "settings.certTrust.untrusted.remedy",
                defaultValue: "Give the server a publicly trusted certificate: Tailscale Serve issues one automatically, Let's Encrypt is free and also issues certificates for plain IP addresses, or put a domain in front with Caddy, which renews for you.")
    }

    /// Refusal + remedy, for the surfaces that render a single string.
    static var untrustedRefusalWithRemedy: String {
        "\(untrustedRefusal) \(untrustedRemedy)"
    }

    /// The wrist form: same cause, same refusal, remedy DELEGATED to the phone.
    /// A watchOS notification body and the Watch failure banner are a few short
    /// lines, and `untrustedRemedy` names three server-side routes — so fitting
    /// it on the wrist would mean truncating the one part the user has to act
    /// on. Pointing at Conduck on iPhone hands them the full remedy on a screen
    /// that can hold it, instead of a paraphrase that would become a fourth
    /// wording for one cause. Still terminal: it never invites a retry, because
    /// nothing on the watch can change the outcome.
    static var untrustedRefusalCompact: String {
        String(localized: "settings.certTrust.untrusted.refusal.compact",
                defaultValue: "This device doesn't trust the server's certificate. Open Conduck on your iPhone to see how to fix it.")
    }

    // MARK: - Pin mismatch on a chain the system TRUSTED

    /// What happened. Never says the certificate "changed": the app cannot know
    /// that, and on the shape this verdict now has — an interception behind a
    /// certificate the system accepts — nothing on the user's server changed at
    /// all. Stating a change that never happened sends the user hunting a
    /// configuration they never touched.
    static var pinMismatchRefusal: String {
        String(localized: "settings.certTrust.pinMismatch.refusal",
                defaultValue: "This server's certificate doesn't match the fingerprint you pinned.")
    }

    /// What to do about it. The remedy is NOT server-side — it is "stop and
    /// check" — so it never names a route to a new certificate, and it never
    /// offers to remove the pin: dropping the pin would make the connection
    /// succeed while the reason it failed is still there. The re-pin arm is
    /// gated on the user having replaced the certificate THEMSELVES, which is
    /// the only case where the app's verdict is a false alarm.
    static var pinMismatchRemedy: String {
        String(localized: "settings.certTrust.pinMismatch.remedy",
                defaultValue: "If you replaced the server's certificate, update the pinned fingerprint in its settings. If you changed nothing, stop — the connection may be intercepted.")
    }

    /// Refusal + remedy, for the surfaces that render a single string.
    static var pinMismatchRefusalWithRemedy: String {
        "\(pinMismatchRefusal) \(pinMismatchRemedy)"
    }

    /// The wrist-and-wheel form: the warning stays (it is the load-bearing part
    /// of this verdict and must survive the trim), the check-it-yourself half
    /// moves to the phone, where the user can act on it. Gateway-specific
    /// wording because the gateway is the only pinned lane either surface can
    /// reach. Terminal, so it never invites a retry.
    static var pinMismatchRefusalCompact: String {
        String(localized: "settings.certTrust.pinMismatch.refusal.compact",
                defaultValue: "Your gateway's certificate doesn't match your pinned fingerprint. The connection may be intercepted — open Conduck on your iPhone.")
    }

    // MARK: - Pin could not be COMPUTED on a chain the system TRUSTED

    /// What happened. Names the KEY as the thing Conduck cannot handle, never
    /// the certificate — a user who reads "certificate problem" goes looking for
    /// an expiry or a bad chain, and there is neither. It also never says the
    /// fingerprint "doesn't match": no comparison ever ran.
    static var keyUnpinnableRefusal: String {
        String(localized: "settings.certTrust.keyUnpinnable.refusal",
                defaultValue: "This server's certificate uses a key type Conduck can't fingerprint, so your pinned fingerprint can't be checked.")
    }

    /// What to do about it. Says out loud that the certificate is fine, because
    /// the sentence before it named a problem with the certificate's key and a
    /// user who stops reading there will go looking for a server fault that
    /// isn't one.
    ///
    /// This is the ONE place in the app allowed to offer removing a saved
    /// fingerprint. Everywhere else that phrase means "switch off the control
    /// that just caught something"; here nothing was caught — system trust
    /// already passed, and dropping the pin returns the connection to exactly
    /// the trust evaluation that is passing. The other remedy (reissue with a
    /// key Conduck can hash) is named first because it keeps the pin. Do not
    /// "correct" the second one away.
    static var keyUnpinnableRemedy: String {
        String(localized: "settings.certTrust.keyUnpinnable.remedy",
                defaultValue: "The certificate itself is fine and this device trusts it — only the fingerprint check can't run. Reissue it with an RSA 2048/3072/4096 or EC P-256/P-384 key, or clear the saved fingerprint in its settings to go back to ordinary system trust.")
    }

    /// Refusal + remedy, for the surfaces that render a single string.
    static var keyUnpinnableRefusalWithRemedy: String {
        "\(keyUnpinnableRefusal) \(keyUnpinnableRemedy)"
    }

    /// The wrist-and-wheel form: cause plus "this is not an attack" in one line,
    /// remedy DELEGATED to the phone — neither remedy is actionable from a watch
    /// face or a car screen, and both name settings that only exist on iPhone.
    /// Gateway-specific wording because the gateway is the only pinned lane
    /// either surface can reach. Terminal, so it never invites a retry.
    ///
    /// Kept SHORT — the wrist renders it two lines at a time with the rest a tap
    /// away, and the car SPEAKS it, where every extra clause is time the driver
    /// spends listening to a problem they cannot act on. It still carries all
    /// three load-bearing parts: the KEY is what Conduck can't handle (never "the
    /// certificate", which sends the user hunting an expiry that isn't there),
    /// the server is explicitly fine (this verdict must never borrow the
    /// interception warning), and the fix lives on the phone.
    static var keyUnpinnableRefusalCompact: String {
        String(localized: "settings.certTrust.keyUnpinnable.refusal.compact",
                defaultValue: "Conduck can't check your pin — unsupported certificate key. Your server is fine; open Conduck on your iPhone to fix the pin.")
    }
}
