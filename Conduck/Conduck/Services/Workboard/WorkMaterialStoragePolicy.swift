// SPDX-License-Identifier: Apache-2.0

// Conduck
// WorkMaterialStoragePolicy.swift
//
// The single place that decides where one material's bytes live. Every ingest
// lane — in-app drop, picker, share inbox, headless intent, Watch — routes its
// storage-mode choice through here, so the sync ceiling is enforced by
// construction on the lanes that have no UI to warn from.
//
// The answer is deliberately kind-independent: a screenshot, a document and a
// voice note under the ceiling all sync, and everything above it stays in the
// device-local vault with reattach. `kind` is part of the question because the
// decision belongs to the material as a whole, not to its byte count alone.

import Foundation

nonisolated enum WorkMaterialStoragePolicy {
    /// Bytes ride private CloudKit only when their size is both known and
    /// within the ceiling. An unknown or unmeasured size (zero or negative)
    /// takes the local vault: absence of proof that a payload fits is not
    /// proof that it fits, and a blob that cannot export would strand the
    /// material on the device that captured it with no reattach affordance.
    ///
    /// A payload-free material never asks — `metadataOnly` is decided at the
    /// draft, before any byte count exists.
    static func mode(kind: WorkMaterialKind, byteSize: Int64) -> WorkMaterialStorageMode {
        guard byteSize > 0, byteSize <= Constants.workboardSyncCeilingBytes else {
            return .localVault
        }
        return .syncedPayload
    }
}
