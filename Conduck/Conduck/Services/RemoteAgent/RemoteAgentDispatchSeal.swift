// SPDX-License-Identifier: Apache-2.0

// Conduck
// RemoteAgentDispatchSeal.swift
//
// Equality for an explicitly reviewed gateway connection. A stable ref names
// a configurable slot; this comparison additionally seals the destination,
// authentication, model and trust settings that the person reviewed. The
// ephemeral session pointer is intentionally irrelevant to stateless routing.
// No secret or endpoint is logged, serialized or exposed by this comparison.

import Foundation

extension SettingsManager.RemoteAgentSnapshot {
    nonisolated func hasSameDispatchDestination(as other: Self) -> Bool {
        ref == other.ref && url == other.url && token == other.token
            && authScheme == other.authScheme && model == other.model
            && certFingerprintHex == other.certFingerprintHex
    }
}
