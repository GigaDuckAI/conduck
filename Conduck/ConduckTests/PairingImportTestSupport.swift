// Conduck
// PairingImportTestSupport.swift
//
// Shared helper for the pairing-import PERSISTENCE tests.
//
// `executePairingImport` takes RESOLVED certificate pins — the values
// `resolvePairingTrust` decided after probing the server — precisely so the
// pins a payload CLAIMS can never reach storage unchecked. The persistence
// tests, however, are about the commit mechanics (slot writes, roster upsert,
// rollback, transport hints), not about the trust decision, and they were
// written against payload-carried pins.
//
// This helper says explicitly what those tests mean: "persist as if the trust
// gate had decided to honour exactly what the payload asked for." Trust
// decisions themselves are covered by `PairingTrustDecisionTests` and the
// probe tests in `RemoteAgentClientTests`.

import Foundation
@testable import Conduck

extension SettingsViewModel {

    /// Import using the pins the PAYLOAD claims, as the resolved values.
    ///
    /// Test-only. Production code must route through `resolvePairingTrust` —
    /// calling `executePairingImport` with `payload.certFP` in the app would
    /// reinstate the unchecked-pin hole this parameterisation exists to close.
    func executePairingImportUsingPayloadPins(
        _ payload: PairingPayload,
        target: RemoteAgentRef
    ) async -> PairingImportOutcome {
        await executePairingImport(
            payload,
            target: target,
            resolvedGatewayPin: payload.certFP,
            resolvedFileServerPin: SettingsViewModel.claimedFileServerPin(for: payload)
        )
    }
}
