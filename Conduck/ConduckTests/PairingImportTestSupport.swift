// SPDX-License-Identifier: Apache-2.0

// Conduck
// PairingImportTestSupport.swift
//
// Shared helper for the pairing-import PERSISTENCE tests.
//
// `executePairingImport` takes RESOLVED certificate pins — the values
// `resolvePairingTrust` decided after probing the server. A pairing payload
// carries no certificate field at all, so the resolver's only possible answer
// is "ordinary system trust", and every import therefore commits with `nil`
// pins. The persistence tests are about the commit mechanics (slot writes,
// roster upsert, rollback, transport hints), not about the trust decision.
//
// This helper says explicitly what those tests mean: "persist the way a real
// import does, with the pins the trust gate actually produces." Trust decisions
// themselves are covered by `PairingTrustDecisionTests` and the probe tests in
// `RemoteAgentClientTests`.

import Foundation
@testable import Conduck

extension SettingsViewModel {

    /// Import with the pins a resolved pairing always carries: none.
    ///
    /// Test-only — production code routes through `resolvePairingTrust`, which
    /// is what proves the server was reachable and trusted before anything is
    /// written.
    func executePairingImportWithResolvedTrust(
        _ payload: PairingPayload,
        target: RemoteAgentRef
    ) async -> PairingImportOutcome {
        await executePairingImport(
            payload,
            target: target,
            resolvedGatewayPin: nil,
            resolvedFileServerPin: nil
        )
    }
}
