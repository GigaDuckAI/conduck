// SPDX-License-Identifier: Apache-2.0

// Conduck
// FileDeliveryNotice.swift
//
// The INBOUND counterpart to `MissingOutputNotice`. That file answers "did this
// turn promise a file the served folder does not have?"; this one answers the
// question the user is left holding in the other direction — "my file went up,
// and then nothing was ever said about it".
//
// WHY SILENCE IS THE WRONG DEFAULT HERE TOO. The user did real work to stand up
// a second server, uploaded a file through it, and got back a reply that never
// mentions it. With no word anywhere in the app, the only available conclusion
// is that the feature is broken — which is the one reading the app can neither
// confirm nor deny.
//
// WHAT IT MUST NEVER BECOME, and this is the whole design constraint: NOT "your
// agent ignored your file". That verdict is unreachable from here. The same
// silent reply is equally consistent with the agent never opening the file,
// opening it and not mentioning it, opening it and finding it irrelevant, its
// PDF parser failing, and reading it perfectly while answering badly. A textual
// heuristic ("does the reply mention the filename?") would fire most confidently
// on the most common benign case — an agent that used the file and simply
// answered the question — so this file reads NO reply text at all. Its entire
// input is turn structure.
//
// IT ANCHORS TO THE USER'S OWN TURN, NEVER TO A REPLY. Nothing persisted links a
// reply to the turn it answers: `ConversationStore.fetchMessages` orders by
// `createdAt` alone, so "the reply that followed this file" is an inference from
// adjacency, and adjacency breaks on concurrent sends, cross-device writes and
// CloudKit arrival order. Anchoring to the user turn needs no such inference —
// every fact the row states is a fact about THAT turn — and the row still lands
// immediately above the reply, which is where the user is looking.
//
// PURE + DERIVED, never persisted, for the same reason as `MissingOutputNotice`:
// with no stored verdict there is no reconciliation step to get wrong, and the
// row retires by itself the moment its evidence moves.
//
// PRIVACY (see the spec's Privacy & Security section): takes records, returns an
// id. No filename, storedKey, URL or reply text is read here, and nothing in
// this path logs.

import Foundation

enum FileDeliveryNotice {

    /// The turn the "delivered, and that is all Conduck can see" row belongs to:
    /// the NEWEST turn that provably handed a file to the file server, or nil
    /// when this thread has none. `messages` must be `createdAt`-ascending —
    /// the order `fetchMessages` returns and the thread renders.
    ///
    /// ONE ROW PER CONVERSATION, on the NEWEST qualifying turn. The delivery
    /// receipt is per-turn, but the caveat beside it is a permanent property of
    /// the architecture and reads identically every time; repeated under every
    /// file the user has ever sent, it becomes a nag, and a nag is read past by
    /// the second occurrence. Newest rather than oldest because the row is
    /// orientation for the exchange in progress: the newest qualifying turn is
    /// one the user just caused, so a row appearing there is expected, whereas
    /// one pinned to a file sent forty turns ago is scrolled out of the world.
    ///
    /// FOUR CONJUNCTIVE TESTS, every one of which fails CLOSED (no row) on doubt:
    ///   - USER role: only the user's own turn can carry an upload.
    ///   - `status == "sent"`: the request actually went. A `sending` turn has
    ///     not made the claim yet, and a `failed` one already draws the delivery
    ///     error row — neither may also say "delivered". A legacy nil status is
    ///     refused with them: it predates the file-transfer route entirely, so
    ///     it is never evidence of a delivery.
    ///   - `fileTransferLaneID != nil`: the dispatch latched a real physical
    ///     lane AND recorded which one — the durable proof that a handoff
    ///     happened rather than being planned.
    ///   - an attachment that is a server reference AND still carries a
    ///     non-empty `storedKey`. The flag ALONE is not enough, and that is the
    ///     load-bearing half: a clone continuation onto a lane that does not
    ///     carry keeps `isServerReference` while DETACHING the key
    ///     (`ConversationStore.copyAttachments`), leaving a tombstone that
    ///     addresses nothing on any server. The key is also exactly what
    ///     `ConverseRequest.spliceServerFileRefs` spends when it tells the agent
    ///     where the file is, so requiring it keeps the row's claim and the wire
    ///     in step.
    ///
    /// THE COST, written down so it reads as a decision and not an oversight.
    /// The dual-route uploads (`.dualImage` / `.dualText`) put real bytes on the
    /// file server while deliberately leaving `isServerReference` FALSE — their
    /// content also rides inline, which is their whole point — so those turns
    /// get no row. That is the cheap direction: their content reached the agent
    /// inline regardless, so a reply that ignores them is not the same puzzle.
    ///
    /// Pure; `nonisolated` so the test target can call it off the main actor.
    /// Linear in the message count, and no text is scanned.
    nonisolated static func noticeTurnID(in messages: [MessageRecord]) -> UUID? {
        messages.last(where: deliveredAFile)?.id
    }

    /// Whether ONE turn provably handed a file to the file server. See
    /// `noticeTurnID` for why each test is here and which failure it closes.
    nonisolated static func deliveredAFile(_ message: MessageRecord) -> Bool {
        message.role == "user"
            && message.status == "sent"
            && message.fileTransferLaneID != nil
            && message.attachments.contains { attachment in
                attachment.isServerFile && !(attachment.storedKey ?? "").isEmpty
            }
    }
}
