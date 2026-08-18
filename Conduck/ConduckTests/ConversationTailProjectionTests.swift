// SPDX-License-Identifier: Apache-2.0

// Conduck
// ConversationTailProjectionTests.swift
//
// Locks `Conversation.tailProjection` — the versioned envelope naming a
// conversation's newest message — at both ends: the FROZEN GRAMMAR and its
// validity rules as pure value math, and the store write sites that must keep
// the envelope and `lastActivityAt` in step.
//
// WHAT THE COLUMN BUYS, and therefore what a failure here costs. The unseen test
// is "the tail is an agent reply AND `lastActivityAt` is past the account's view
// marker". iOS and macOS answer the first half with a lazy per-row tail fetch;
// the wrist deliberately projects no role, because a per-row message fetch on the
// slowest device in the fleet is exactly what its list design refuses to pay. So
// a broken envelope does not merely cost a fetch — it makes the Watch silently
// withhold the amber mark for a reply the user has not read.
//
// WHY VALIDITY IS AN EXACT MATCH, `lastActivityAt` INCLUDED. A bare
// `lastMessageRole` would go stale INVISIBLY in a mixed-version fleet: a build
// that appends a reply, bumps `lastActivityAt` and never touches the role leaves
// a perfectly well-formed value describing the wrong tail. Nothing inside the
// string can reveal that; only the cross-check against the conversation's own
// activity stamp can. Hence: recognised version, parseable UUID, known role,
// parseable stamp, AND a stamp naming exactly the millisecond `lastActivityAt`
// names — any mismatch in EITHER direction is stale.
//
// WHY THE STAMP IS AN INTEGER MILLISECOND COUNT. The two sides of that
// comparison do not cross CloudKit in the same encoding: the envelope rides
// inside a String the mirror carries byte for byte, while `lastActivityAt` rides
// as a CKRecord DATE field, which Apple documents as milliseconds since the Unix
// epoch and does NOT document as rounding or truncating. So the app quantises
// FIRST — every tail-producing write snaps its instant onto a millisecond
// (`TailProjection.canonical`) and stores that one `Date` in both
// `Message.createdAt` and `Conversation.lastActivityAt` while the integer goes
// in the envelope — and `read` re-quantises whatever `lastActivityAt` it is
// handed so the comparison is integer to integer. A value already sitting on a
// millisecond boundary is the one class of value rounding and truncation agree
// about, so the mirror has nothing left to decide.
//
// AND THEREFORE NO TOLERANCE WINDOW. These tests assert the comparison is exact
// at the shared precision, in both directions: noise inside one millisecond is
// absorbed by re-quantising, and a stamp naming a DIFFERENT millisecond is stale
// even when the two instants are less than a millisecond apart. A window wide
// enough to hide a quantisation disagreement would also be wide enough to accept
// the envelope of the turn one step away in the clone's deliberate
// one-millisecond-per-copied-turn spacing — it trades a detectable staleness for
// an undetectable one.
//
// WHAT QUANTISATION COSTS, AND WHERE THAT COST IS PAID. Collapsing an instant
// onto its millisecond collapses everything written inside that millisecond onto
// one stamp, and `Message.createdAt` is the only order a thread has.
// `ConversationStore.appendStamp` settles each append at least one millisecond
// past the conversation's own last activity, so the tests below assert strict
// per-conversation ordering as a property of the store, not as a hope about how
// fast a write happens to be.
//
// A FUTURE VERSION IS UNUSABLE BUT NOT REPAIRABLE. Rewriting a newer build's
// value starts a downgrade fight across the mirror: this build stamps version 1,
// the newer device restamps its own, and the two export a CKRecord at each other
// for as long as both exist.
//
// THE PRE-UPGRADE SHAPES ARE REACHED THROUGH SEAMS, NOT HOPED ABOUT. Every
// writer that bumps `lastActivityAt` writes the envelope from ONE canonical
// stamp in the SAME transaction — which is itself the invariant these tests
// assert — so the states the repair exists FOR are unreachable through the
// public API, and a suite that only drives that API pins the repair's no-op
// branches and nothing else. Two `#if CONDUCK_TESTING` seams close that:
//   - `_setTailProjectionForTesting` writes a well-formed envelope describing a
//     tail the conversation has moved past — a build that appended without
//     knowing about the column.
//   - `_setStampsForTesting` puts the activity stamp and the tail's `createdAt`
//     at an arbitrary offset inside their millisecond — a build that predates
//     `TailProjection.canonical`, which is a user's entire existing history. It
//     also builds the one pair the repair must REFUSE: two turns inside one
//     millisecond whose tail would round down past its own predecessor.
// Both of the repair's writing branches are therefore exercised directly. The
// no-op cases are pinned too, because "changes nothing for a row this build
// wrote" is the property that keeps the repair from exporting two CKRecords per
// row forever.
//
// Each store test builds its OWN isolated `inMemory` store (CloudKit OFF in the
// seam). Deterministic + headless; synthetic text only.

import XCTest
@testable import Conduck

final class ConversationTailProjectionTests: XCTestCase {

    /// Exactly on a millisecond boundary, so it is its own canonical form and
    /// any skew a test adds is the only thing the quantiser has to decide about.
    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    /// Five years before the epoch — the signed half of the grammar.
    private let preEpochStamp = Date(timeIntervalSince1970: -157_680_000)

    private func makeStore() -> ConversationStore {
        ConversationStore(inMemory: true)
    }

    private func reload(
        _ id: UUID, store: ConversationStore
    ) async throws -> ConversationRecord {
        let fetched = try await store.fetchConversation(id: id)
        return try XCTUnwrap(fetched)
    }

    /// Read a conversation's stored envelope against its OWN activity stamp —
    /// the only comparison that means anything.
    private func reading(
        _ record: ConversationRecord
    ) -> TailProjectionReading {
        TailProjection.read(record.tailProjection, lastActivityAt: record.lastActivityAt)
    }

    private func fields(of encoded: String) -> [String] {
        encoded.split(separator: TailProjection.separator,
                      omittingEmptySubsequences: false).map(String.init)
    }

    private func joined(_ parts: [String]) -> String {
        parts.joined(separator: String(TailProjection.separator))
    }

    /// Every instant this store persists must be its own canonical form —
    /// the single property the whole validity clause rests on.
    private func assertCanonical(
        _ instant: Date,
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            TailProjection.canonical(instant), instant,
            "\(what) is not on a millisecond boundary, so the mirror is free to "
                + "quantise it in a direction Apple does not document",
            file: file, line: line
        )
    }

    // MARK: - The frozen grammar

    func testTheEncodedEnvelopeIsTheFrozenFourFieldShape() throws {
        // Frozen once `Conversations 10` reaches production CloudKit: the column
        // is read by builds that will never learn a new shape, so a change takes
        // a NEW version tag rather than a new layout.
        let messageID = UUID()
        let encoded = TailProjection.encoded(
            messageID: messageID, createdAt: stamp, role: .agent
        )
        let parts = fields(of: encoded)
        XCTAssertEqual(parts.count, 4)
        XCTAssertEqual(parts[0], "1")
        XCTAssertEqual(parts[1], messageID.uuidString)
        XCTAssertEqual(parts[3], MessageRole.agent.rawValue)

        let milliseconds = try XCTUnwrap(Int64(parts[2]))
        XCTAssertEqual(
            milliseconds, TailProjection.milliseconds(from: stamp),
            "the stamp field is the instant's whole-millisecond count — the same "
                + "integer `read` recomputes from `lastActivityAt`, which is what "
                + "makes the two sides comparable at all"
        )
    }

    func testTheStampFieldIsAPlainDecimalIntegerWithNoPadding() {
        // `String(Int64)` and nothing else: no radix prefix, no zero padding, no
        // sign for a positive value, no grouping. A reader on another device
        // parses this with `Int64(_:)`, so a decoration this build invented
        // would read as stale there and nowhere here.
        for instant in [stamp, preEpochStamp, Date(timeIntervalSince1970: 0)] {
            let field = fields(
                of: TailProjection.encoded(messageID: UUID(), createdAt: instant, role: .user)
            )[2]
            XCTAssertEqual(field, String(TailProjection.milliseconds(from: instant)))
            XCTAssertEqual(Int64(field).map { String($0) }, field)
        }
    }

    func testAPreEpochTailEncodesAsANegativeMillisecondCount() throws {
        // SIGNED for a reason: a pre-1970 instant is representable in every
        // other layer of the app (an imported thread, a device whose clock was
        // wrong, `Date.distantPast`), and an unsigned encoding would either
        // refuse the row or wrap it into the far future.
        let messageID = UUID()
        let encoded = TailProjection.encoded(
            messageID: messageID, createdAt: preEpochStamp, role: .agent
        )
        let parts = fields(of: encoded)
        XCTAssertEqual(parts.count, 4, "a leading minus must not be read as a field break")
        XCTAssertTrue(parts[2].hasPrefix("-"))

        guard case .valid(let projection) = TailProjection.read(
            encoded, lastActivityAt: preEpochStamp
        ) else {
            return XCTFail("a pre-epoch tail must round trip like any other")
        }
        XCTAssertEqual(projection.messageID, messageID)
        XCTAssertEqual(projection.createdAt, preEpochStamp)
        XCTAssertEqual(projection.role, .agent)

        // And the negative side of the comparison is exact in both directions
        // exactly as the positive side is.
        let oneEarlier = TailProjection.date(
            fromMilliseconds: TailProjection.milliseconds(from: preEpochStamp) - 1
        )
        XCTAssertEqual(TailProjection.read(encoded, lastActivityAt: oneEarlier), .stale)
    }

    func testNoFieldCanContainTheSeparator() {
        // The separator is chosen so a field can never swallow it: uppercase hex
        // and hyphens, lowercase hex, digits with at most a leading minus,
        // lowercase ASCII letters.
        for instant in [stamp, preEpochStamp] {
            let parts = fields(
                of: TailProjection.encoded(messageID: UUID(), createdAt: instant, role: .user)
            )
            XCTAssertEqual(parts.count, 4)
            for field in parts {
                XCTAssertFalse(field.contains(TailProjection.separator))
                XCTAssertFalse(field.isEmpty)
            }
        }
    }

    func testTheRoundTripIsValidForBothRoles() throws {
        for role in [MessageRole.user, MessageRole.agent] {
            let messageID = UUID()
            let encoded = TailProjection.encoded(
                messageID: messageID, createdAt: stamp, role: role
            )
            let read = TailProjection.read(encoded, lastActivityAt: stamp)
            guard case .valid(let projection) = read else {
                return XCTFail("expected valid for \(role), got \(read)")
            }
            XCTAssertEqual(projection.messageID, messageID)
            XCTAssertEqual(projection.createdAt, stamp)
            XCTAssertEqual(projection.role, role)
            XCTAssertEqual(read.role, role)
            XCTAssertFalse(read.isRepairable, "a valid envelope has nothing to fix")
        }
    }

    func testTheEncoderQuantisesAStampItWasNotHandedCanonical() throws {
        // For every caller in the store this is a no-op — the row was written
        // from the same canonical `Date`. It exists so the encoder can never be
        // the place the invariant is lost: an envelope carrying a raw instant
        // would fail its own validity test against the canonical stamp beside it.
        let off = stamp.addingTimeInterval(0.000_4)
        let encoded = TailProjection.encoded(messageID: UUID(), createdAt: off, role: .agent)
        XCTAssertEqual(
            Int64(fields(of: encoded)[2]), TailProjection.milliseconds(from: stamp)
        )

        guard case .valid(let projection) = TailProjection.read(
            encoded, lastActivityAt: stamp
        ) else {
            return XCTFail("a quantised stamp must validate against its own millisecond")
        }
        XCTAssertEqual(
            projection.createdAt, stamp,
            "the decoded date is rebuilt from the integer, so it is the canonical "
                + "`Date` for that millisecond — bit-identical to the one the "
                + "writing device stored in the row"
        )
    }

    func testQuantisationRoundsToTheNearestMillisecondAndIsIdempotent() {
        // Nearest rather than truncating, so an instant already on a boundary is
        // recovered whichever direction float noise nudged it. Truncation would
        // spend the whole half-millisecond margin on one side and turn a stamp
        // that came back a nanosecond light into a stamp a millisecond early.
        let base = TailProjection.milliseconds(from: stamp)
        XCTAssertEqual(TailProjection.milliseconds(from: stamp.addingTimeInterval(0.000_4)), base)
        XCTAssertEqual(TailProjection.milliseconds(from: stamp.addingTimeInterval(-0.000_4)), base)
        XCTAssertEqual(
            TailProjection.milliseconds(from: stamp.addingTimeInterval(0.000_6)), base + 1
        )
        XCTAssertEqual(
            TailProjection.milliseconds(from: stamp.addingTimeInterval(-0.000_6)), base - 1
        )

        for instant in [stamp, preEpochStamp, stamp.addingTimeInterval(0.000_4), Date()] {
            let once = TailProjection.canonical(instant)
            XCTAssertEqual(TailProjection.canonical(once), once)
            XCTAssertEqual(TailProjection.date(fromMilliseconds:
                TailProjection.milliseconds(from: instant)), once)
        }
    }

    func testAnUnrepresentableStampReadsStaleInsteadOfTrapping() {
        // A partially-synced row can hand this a date built from a value no
        // `Int64` can hold. A trapping conversion would crash a list reload,
        // where reading one row as stale is the correct answer.
        let unusable = [
            Date(timeIntervalSince1970: .nan),
            Date(timeIntervalSince1970: .infinity),
            Date(timeIntervalSince1970: -.infinity)
        ]
        let encoded = TailProjection.encoded(messageID: UUID(), createdAt: stamp, role: .agent)
        for date in unusable {
            _ = TailProjection.milliseconds(from: date)
            XCTAssertEqual(TailProjection.read(encoded, lastActivityAt: date), .stale)
        }

        // The far ends of `Date` itself stay ordinary representable values —
        // nothing here narrows the range the rest of the app can carry.
        for date in [Date.distantPast, Date.distantFuture] {
            let canonical = TailProjection.canonical(date)
            let envelope = TailProjection.encoded(
                messageID: UUID(), createdAt: canonical, role: .user
            )
            XCTAssertEqual(TailProjection.read(envelope, lastActivityAt: canonical).role, .user)
        }
    }

    func testAnUnknownRoleRefusesToProduceAnEnvelopeAtAll() {
        // Nil rather than an envelope carrying the raw role: an unknown role can
        // never satisfy `read`, so storing one would produce a well-formed string
        // that is stale by construction — a row permanently in the repair path,
        // exporting a CKRecord for a value no reader can ever use.
        XCTAssertNil(TailProjection.encoded(messageID: UUID(), createdAt: stamp, role: "system"))
        XCTAssertNil(TailProjection.encoded(messageID: UUID(), createdAt: stamp, role: "User"))
        XCTAssertNil(TailProjection.encoded(messageID: UUID(), createdAt: stamp, role: ""))
        XCTAssertNil(TailProjection.encoded(messageID: UUID(), createdAt: stamp, role: nil))
    }

    // MARK: - Every invalid shape is stale

    func testAnAbsentEnvelopeIsStale() {
        XCTAssertEqual(TailProjection.read(nil, lastActivityAt: stamp), .stale)
        XCTAssertEqual(TailProjection.read("", lastActivityAt: stamp), .stale)
    }

    func testAWrongFieldCountIsStale() {
        let valid = TailProjection.encoded(messageID: UUID(), createdAt: stamp, role: .user)
        let parts = fields(of: valid)
        let sep = String(TailProjection.separator)

        XCTAssertEqual(
            TailProjection.read(joined(Array(parts.dropLast())), lastActivityAt: stamp),
            .stale
        )
        XCTAssertEqual(
            TailProjection.read(valid + sep + "extra", lastActivityAt: stamp), .stale
        )
        // An EMPTY field is still a field — the split must not re-align onto the
        // neighbouring value and accidentally parse.
        XCTAssertEqual(
            TailProjection.read(
                joined([parts[0], "", parts[2], parts[3]]), lastActivityAt: stamp
            ),
            .stale
        )
    }

    func testAnUnparseableVersionIsStale() {
        let valid = TailProjection.encoded(messageID: UUID(), createdAt: stamp, role: .user)
        let mangled = valid.replacingOccurrences(of: "1|", with: "v1|", options: [.anchored])
        XCTAssertEqual(TailProjection.read(mangled, lastActivityAt: stamp), .stale)
    }

    func testABadMessageIDIsStale() {
        let parts = fields(
            of: TailProjection.encoded(messageID: UUID(), createdAt: stamp, role: .user)
        )
        let mangled = joined([parts[0], "not-a-uuid", parts[2], parts[3]])
        XCTAssertEqual(TailProjection.read(mangled, lastActivityAt: stamp), .stale)
    }

    func testAStampFieldThatIsNotAnIntegerIsStale() {
        // The field is parsed with `Int64(_:)` and nothing else, so anything a
        // different encoding would have produced — a float, a hex bit pattern,
        // an ISO date, a value past `Int64` — fails the parse rather than
        // half-succeeding into a plausible instant.
        let parts = fields(
            of: TailProjection.encoded(messageID: UUID(), createdAt: stamp, role: .user)
        )
        let bad = [
            "zzzz",
            "",
            "3.5",
            "1e3",
            "0x1f",
            " 1700000000000",
            "1700000000000 ",
            "1_700_000_000_000",
            "41d9d3e284000000",
            "2023-11-14T22:13:20Z",
            "9223372036854775808"
        ]
        for value in bad {
            let mangled = joined([parts[0], parts[1], value, parts[3]])
            XCTAssertEqual(
                TailProjection.read(mangled, lastActivityAt: stamp), .stale, value
            )
        }
    }

    func testAnUnknownRoleFieldIsStale() {
        let parts = fields(
            of: TailProjection.encoded(messageID: UUID(), createdAt: stamp, role: .user)
        )
        for value in ["system", "User", "assistant"] {
            let mangled = joined([parts[0], parts[1], parts[2], value])
            XCTAssertEqual(
                TailProjection.read(mangled, lastActivityAt: stamp), .stale, value
            )
        }
    }

    func testAStampNamingAnotherMillisecondIsStaleInEitherDirection() {
        // THE clause the whole envelope exists for. Later means a message landed
        // that nobody re-projected; earlier means the envelope describes a tail
        // this conversation has moved past. Both are "do not trust this".
        let encoded = TailProjection.encoded(messageID: UUID(), createdAt: stamp, role: .agent)
        let base = TailProjection.milliseconds(from: stamp)
        for offset: Int64 in [1, -1, 1000, -1000] {
            XCTAssertEqual(
                TailProjection.read(
                    encoded, lastActivityAt: TailProjection.date(fromMilliseconds: base + offset)
                ),
                .stale,
                "a build that appended without re-projecting must be detectable"
            )
        }
        XCTAssertEqual(
            TailProjection.read(
                encoded, lastActivityAt: TailProjection.date(fromMilliseconds: base + 1)
            ),
            .stale,
            "ONE millisecond is a whole step, so the clone's per-turn spacing "
                + "never accidentally validates its neighbour's envelope"
        )
    }

    func testNoiseInsideOneMillisecondStillNamesTheSameTail() {
        // NOT laxness, and not a tolerance window — the comparison is exact at
        // the precision both sides share. `read` re-quantises `lastActivityAt`,
        // so sub-millisecond noise from an epoch conversion or a mirror's own
        // arithmetic lands back on the same integer instead of costing the wrist
        // its mark.
        let encoded = TailProjection.encoded(messageID: UUID(), createdAt: stamp, role: .agent)
        for skew in [0.000_001, -0.000_001, 0.000_4, -0.000_4] {
            XCTAssertEqual(
                TailProjection.read(encoded, lastActivityAt: stamp.addingTimeInterval(skew))
                    .role,
                .agent,
                "a \(skew)s skew is the same millisecond, so it must still validate"
            )
        }
    }

    func testASubMillisecondSkewAcrossABoundaryIsCorrectlyStale() {
        // The other half of the same rule, and the one that stops "under a
        // millisecond" from being mistaken for "close enough". These instants
        // are less than a millisecond from the envelope's and still name a
        // DIFFERENT millisecond, which is the only unit either side of the
        // mirror can express — so they describe a different tail.
        let encoded = TailProjection.encoded(messageID: UUID(), createdAt: stamp, role: .agent)
        for skew in [0.000_9, -0.000_9, 0.000_6, -0.000_6] {
            XCTAssertEqual(
                TailProjection.read(encoded, lastActivityAt: stamp.addingTimeInterval(skew)),
                .stale,
                "\(skew)s crosses a millisecond boundary, so it is a different stamp"
            )
        }
    }

    // MARK: - A newer build's envelope

    func testAFutureVersionIsUnreadableAndDeliberatelyNotRepairable() {
        let parts = fields(
            of: TailProjection.encoded(messageID: UUID(), createdAt: stamp, role: .agent)
        )
        let future = joined([
            String(TailProjection.currentVersion + 1), parts[1], parts[2], parts[3]
        ])

        let read = TailProjection.read(future, lastActivityAt: stamp)
        XCTAssertEqual(read, .unreadableVersion)
        XCTAssertNil(read.role, "unusable here, so the unseen branch stays suppressed")
        XCTAssertFalse(
            read.isRepairable,
            "rewriting it would start a downgrade fight: this build stamps "
                + "version 1, the newer device restamps its own, and the two "
                + "export a CKRecord at each other forever"
        )
    }

    func testAFutureVersionIsRecognisedBeforeAnyOtherFieldIsJudged() {
        // The version gate runs first on purpose: a newer build is free to
        // change what the other three fields mean, so parsing them under this
        // build's grammar and reporting `.stale` would turn "not mine to read"
        // into "mine to overwrite" — the downgrade fight, entered by accident.
        let parts = fields(
            of: TailProjection.encoded(messageID: UUID(), createdAt: stamp, role: .agent)
        )
        let future = joined([
            String(TailProjection.currentVersion + 1),
            "not-a-uuid-in-this-grammar",
            "0x2a",
            "orchestrator"
        ])
        XCTAssertEqual(TailProjection.read(future, lastActivityAt: stamp), .unreadableVersion)

        // Below-current cannot happen (1 is the first) and is malformed.
        let below = joined([
            String(TailProjection.currentVersion - 1), parts[1], parts[2], parts[3]
        ])
        XCTAssertEqual(TailProjection.read(below, lastActivityAt: stamp), .stale)
    }

    func testAFutureVersionIsUnreadableWhateverFieldCountItCarries() {
        // The tag has to survive a SHAPE change, not only a change of meaning:
        // one more field is the obvious next version. Judging the count first
        // would call a version-2 envelope `.stale`, which is REPAIRABLE, so this
        // build would overwrite it with four version-1 fields while the newer
        // device restamped its own — the downgrade fight, entered by accident,
        // with the newer field destroyed on every round trip.
        let ms = String(TailProjection.milliseconds(from: stamp))
        let next = String(TailProjection.currentVersion + 1)
        let wider = joined([next, UUID().uuidString, ms, "agent", "1"])
        let narrower = joined([next, UUID().uuidString, ms])

        for envelope in [wider, narrower] {
            let read = TailProjection.read(envelope, lastActivityAt: stamp)
            XCTAssertEqual(read, .unreadableVersion, envelope)
            XCTAssertFalse(read.isRepairable, envelope)
        }
    }

    func testAnUnusableReadingProjectsNoRole() {
        XCTAssertNil(TailProjectionReading.stale.role)
        XCTAssertNil(TailProjectionReading.unreadableVersion.role)
        XCTAssertTrue(TailProjectionReading.stale.isRepairable)
    }

    // MARK: - The store writes it wherever it moves `lastActivityAt`

    func testANewConversationCarriesNoEnvelope() async throws {
        let store = makeStore()
        let created = try await store.createConversation(backend: "openclaw")
        let record = try await reload(created.id, store: store)
        XCTAssertNil(
            record.tailProjection,
            "no messages, so there is no tail to describe — and an envelope here "
                + "would be stale by construction"
        )
        XCTAssertEqual(reading(record), .stale)
        // Canonical even with no envelope to validate: EVERY `lastActivityAt` in
        // the store obeys one rule, so the first append has a boundary-aligned
        // value to advance from rather than an arbitrary offset to inherit.
        assertCanonical(record.lastActivityAt, "a new conversation's lastActivityAt")
        assertCanonical(record.createdAt, "a new conversation's createdAt")
    }

    func testAppendingAUserTurnWritesAnEnvelopeThatValidatesAgainstItsOwnStamp() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let turn = try await store.appendMessage(
            role: "user", text: "hi", conversationID: convo.id,
            sourceDevice: "phone", status: "sending"
        )

        let record = try await reload(convo.id, store: store)
        XCTAssertEqual(record.lastActivityAt, turn.createdAt)
        guard case .valid(let projection) = reading(record) else {
            return XCTFail("expected valid, got \(reading(record))")
        }
        XCTAssertEqual(projection.messageID, turn.id)
        XCTAssertEqual(projection.createdAt, turn.createdAt)
        XCTAssertEqual(projection.role, .user)
    }

    func testAnAgentReplyReprojectsTheTailAsAReply() async throws {
        // The site that matters most for the wrist: an agent reply is the ONLY
        // tail that can make a row unseen, so a missed write here is precisely a
        // withheld mark for a reply the user has not read.
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let turn = try await store.appendMessage(
            role: "user", text: "hi", conversationID: convo.id,
            sourceDevice: "phone", status: "sending"
        )
        let reply = try await store.completeAgentTurn(
            userMessageID: turn.id,
            userStatus: "sent",
            agentText: "answer",
            conversationID: convo.id,
            sourceDevice: "phone"
        )

        let record = try await reload(convo.id, store: store)
        XCTAssertEqual(record.lastActivityAt, reply.createdAt)
        guard case .valid(let projection) = reading(record) else {
            return XCTFail("expected valid, got \(reading(record))")
        }
        XCTAssertEqual(projection.messageID, reply.id)
        XCTAssertEqual(projection.role, .agent)
    }

    func testAPlainAppendedReplyAlsoReprojectsTheTail() async throws {
        // The Watch's standalone dispatch persists a reply through
        // `appendMessage`, not `completeAgentTurn` — both sites must project.
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        _ = try await store.appendMessage(
            role: "user", text: "hi", conversationID: convo.id, sourceDevice: "watch"
        )
        let reply = try await store.appendMessage(
            role: "agent", text: "answer", conversationID: convo.id, sourceDevice: "watch"
        )

        let record = try await reload(convo.id, store: store)
        XCTAssertEqual(reading(record).role, .agent)
        XCTAssertEqual(record.lastActivityAt, reply.createdAt)
    }

    func testEveryAppendLeavesTheEnvelopeAndTheActivityStampInStep() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        for index in 0..<8 {
            let isUser = index.isMultiple(of: 2)
            let written = try await store.appendMessage(
                role: isUser ? "user" : "agent",
                text: "turn \(index)",
                conversationID: convo.id,
                sourceDevice: "phone"
            )
            let record = try await reload(convo.id, store: store)
            guard case .valid(let projection) = reading(record) else {
                return XCTFail("turn \(index) left the envelope stale")
            }
            XCTAssertEqual(projection.messageID, written.id)
            XCTAssertEqual(projection.role, isUser ? .user : .agent)
        }
    }

    func testEveryStampTheStoreWritesLandsOnAMillisecondBoundary() async throws {
        // THE regression that would silently blind the Watch: a write path that
        // stamps a row from a bare `Date()` puts `lastActivityAt` at an
        // arbitrary offset inside its millisecond, which the mirror is free to
        // quantise in an undocumented direction — so two devices compute
        // envelopes a millisecond apart and each reads the other's as stale.
        // Locally it looks fine, because the writer compares the value with
        // itself.
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let user = try await store.appendMessage(
            role: "user", text: "hi", conversationID: convo.id,
            sourceDevice: "phone", status: "sending"
        )
        let reply = try await store.completeAgentTurn(
            userMessageID: user.id,
            userStatus: "sent",
            agentText: "answer",
            conversationID: convo.id,
            sourceDevice: "phone"
        )
        let clone = try await store.cloneConversation(id: convo.id, toBackend: "hermes")

        assertCanonical(user.createdAt, "an appended user turn's createdAt")
        assertCanonical(reply.createdAt, "a completed agent turn's createdAt")
        for source in [convo.id, clone.conversation.id] {
            let record = try await reload(source, store: store)
            assertCanonical(record.createdAt, "a stored conversation's createdAt")
            assertCanonical(record.lastActivityAt, "a stored conversation's lastActivityAt")
            for message in try await store.fetchMessages(for: source) {
                assertCanonical(message.createdAt, "a stored message's createdAt")
            }
        }
    }

    func testAProjectionWrittenInOneTransactionValidatesAgainstItsOwnRow() async throws {
        // The pair the envelope's validity clause compares is written from ONE
        // canonical stamp in ONE transaction, so a freshly written row must be
        // valid the instant it is read back. A path that derived the two halves
        // from two `Date()` reads would fail here and nowhere else — and on the
        // wrist, which has no fallback fetch, the row would simply never carry
        // a mark again.
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let reply = try await store.appendMessage(
            role: "agent", text: "answer", conversationID: convo.id, sourceDevice: "phone"
        )
        let record = try await reload(convo.id, store: store)

        XCTAssertEqual(
            TailProjection.milliseconds(from: record.lastActivityAt),
            TailProjection.milliseconds(from: reply.createdAt),
            "one stamp, both columns"
        )
        XCTAssertEqual(
            reading(record),
            .valid(TailProjection(
                messageID: reply.id, createdAt: reply.createdAt, role: .agent
            ))
        )
    }

    func testConsecutiveAppendsIntoOneConversationAreAtLeastAMillisecondApart() async throws {
        // What quantisation would otherwise cost, closed at the write site.
        // `Message.createdAt` is the ONLY order a thread has — the render fetch,
        // the clone's copy loop and every tail pick sort on it — so two turns
        // sharing a stamp leave their order to whatever a fetch happens to
        // return, which is stable neither across two fetches here nor across two
        // devices. Asserted as a property of the store, never as a hope about
        // how slow a write happens to be.
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let turns = 12
        let clockBefore = TailProjection.milliseconds(from: Date())

        var written: [MessageRecord] = []
        for index in 0..<turns {
            written.append(
                try await store.appendMessage(
                    role: index.isMultiple(of: 2) ? "user" : "agent",
                    text: "turn \(index)",
                    conversationID: convo.id,
                    sourceDevice: "phone"
                )
            )
        }
        let clockAfter = TailProjection.milliseconds(from: Date())
        let stamps = written.map { TailProjection.milliseconds(from: $0.createdAt) }

        for index in 1..<stamps.count {
            XCTAssertGreaterThanOrEqual(
                stamps[index], stamps[index - 1] + 1,
                "turn \(index) shares a millisecond with the one before it"
            )
        }
        XCTAssertEqual(Set(stamps).count, turns, "every turn has its own stamp")

        // THE ADVANCE IS BOUNDED BY THE CONVERSATION'S OWN NEWEST ACTIVITY, not
        // by a counter that keeps running: it moves a stamp exactly far enough
        // to clear the row it is appended to, so a burst spreads over as many
        // milliseconds as it has turns and never runs away from real time.
        XCTAssertLessThanOrEqual(stamps.last ?? 0, clockAfter + Int64(turns))
        XCTAssertGreaterThanOrEqual(stamps.first ?? 0, clockBefore)

        // The returned record reports the ROW's settled stamp, not the method's
        // clock — a caller handed the clock's value could not validate the
        // envelope the same call just wrote.
        let record = try await reload(convo.id, store: store)
        let tail = try XCTUnwrap(written.last)
        XCTAssertEqual(record.lastActivityAt, tail.createdAt)
        XCTAssertEqual(reading(record).role, .agent)

        // And the render fetch's order is the order they were appended in.
        let fetched = try await store.fetchMessages(for: convo.id)
        XCTAssertEqual(fetched.map(\.id), written.map(\.id))
    }

    // MARK: - The clone, whose copied turns carry their own spacing

    func testACloneProducesAnEnvelopeThatValidatesAgainstItsSettledStamp() async throws {
        // The copy loop advances each turn one millisecond past `now`, so a
        // clone stamped `lastActivityAt = now` would claim its last activity
        // happened before its own last message. Only this envelope compares the
        // two, and the result would be a clone whose projection is stale in the
        // transaction that wrote it — every cloned thread permanently mark-less
        // on the wrist. So the clone settles `lastActivityAt` on its copied
        // tail's stamp.
        let store = makeStore()
        let source = try await store.createConversation(backend: "openclaw")
        _ = try await store.appendMessage(
            role: "user", text: "question", conversationID: source.id,
            sourceDevice: "phone", status: "sent"
        )
        _ = try await store.appendMessage(
            role: "agent", text: "answer", conversationID: source.id, sourceDevice: "phone"
        )

        let clone = try await store.cloneConversation(id: source.id, toBackend: "hermes")
        let returned = clone.conversation
        XCTAssertNotNil(returned.tailProjection)
        XCTAssertEqual(
            TailProjection.read(
                returned.tailProjection, lastActivityAt: returned.lastActivityAt
            ).role,
            .agent,
            "the returned snapshot must report the ROW's settled stamp, not the "
                + "method's clock — a record disagreeing with its own row hands "
                + "the caller an envelope it cannot validate"
        )

        let record = try await reload(returned.id, store: store)
        guard case .valid(let projection) = reading(record) else {
            return XCTFail("expected valid, got \(reading(record))")
        }
        let copies = try await store.fetchMessages(for: returned.id)
        let tail = try XCTUnwrap(copies.last)
        XCTAssertEqual(projection.messageID, tail.id)
        XCTAssertEqual(projection.createdAt, tail.createdAt)
        XCTAssertEqual(
            record.lastActivityAt, tail.createdAt,
            "the clone's activity stamp IS its copied tail's stamp"
        )
    }

    func testAdjacentClonedTurnsLandExactlyOneMillisecondApart() async throws {
        // INTEGER ARITHMETIC in the copy loop, not repeated addition of a
        // `TimeInterval`. 0.001 is not a binary fraction, so accumulating it
        // drifts and leaves every copied turn at an instant no millisecond
        // exactly names — a thread long enough would eventually round two
        // neighbours onto one stamp, and the settled tail would be a value the
        // envelope could only approximate. Deriving each turn from
        // `base + turnIndex` puts adjacent copies exactly one millisecond apart
        // and lands every one of them on a boundary.
        let store = makeStore()
        let source = try await store.createConversation(backend: "openclaw")
        for index in 0..<6 {
            _ = try await store.appendMessage(
                role: index.isMultiple(of: 2) ? "user" : "agent",
                text: "turn \(index)",
                conversationID: source.id,
                sourceDevice: "phone"
            )
        }

        let clone = try await store.cloneConversation(id: source.id, toBackend: "hermes")
        let copies = try await store.fetchMessages(for: clone.conversation.id)
        XCTAssertEqual(copies.count, 6)

        let stamps = copies.map { TailProjection.milliseconds(from: $0.createdAt) }
        for index in 1..<stamps.count {
            XCTAssertEqual(
                stamps[index] - stamps[index - 1], 1,
                "copy \(index) is not exactly one millisecond past its predecessor"
            )
        }
        for copy in copies {
            assertCanonical(copy.createdAt, "a copied turn's createdAt")
        }

        let record = try await reload(clone.conversation.id, store: store)
        XCTAssertEqual(
            TailProjection.milliseconds(from: record.lastActivityAt),
            try XCTUnwrap(stamps.last),
            "the clone's activity stamp is the last copied turn's, to the millisecond"
        )
        XCTAssertEqual(reading(record).role, .agent)
    }

    func testACloneEndingOnASyntheticFailureStillProjectsThatTurn() async throws {
        let store = makeStore()
        let source = try await store.createConversation(backend: "openclaw")
        _ = try await store.appendMessage(
            role: "agent", text: "answer", conversationID: source.id, sourceDevice: "phone"
        )
        let trailing = try await store.appendMessage(
            role: "user", text: "follow up", conversationID: source.id,
            sourceDevice: "phone", status: "sending"
        )
        await store.failTurn(messageID: trailing.id, classification: nil)

        let clone = try await store.cloneConversation(id: source.id, toBackend: "hermes")
        let continuationID = try XCTUnwrap(clone.continuationMessageID)
        let record = try await reload(clone.conversation.id, store: store)
        guard case .valid(let projection) = reading(record) else {
            return XCTFail("expected valid, got \(reading(record))")
        }
        XCTAssertEqual(projection.messageID, continuationID)
        XCTAssertEqual(
            projection.role, .user,
            "the fork ends on an unanswered user turn, and the wrist must not "
                + "read that as an unseen reply"
        )
    }

    func testACloneOfAnEmptySourceCarriesNoEnvelope() async throws {
        let store = makeStore()
        let source = try await store.createConversation(backend: "openclaw")

        let clone = try await store.cloneConversation(id: source.id, toBackend: "hermes")
        XCTAssertNil(clone.conversation.tailProjection)
        let record = try await reload(clone.conversation.id, store: store)
        XCTAssertNil(record.tailProjection)
        XCTAssertEqual(reading(record), .stale)
        assertCanonical(record.lastActivityAt, "an empty clone's lastActivityAt")
    }

    // MARK: - Repair

    func testRepairLeavesAValidEnvelopeAloneAndAnnouncesNothing() async throws {
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        _ = try await store.appendMessage(
            role: "agent", text: "answer", conversationID: convo.id, sourceDevice: "phone"
        )
        let before = try await reload(convo.id, store: store)

        let counter = RepairChangeCounter()
        let token = NotificationCenter.default.addObserver(
            forName: .conversationsDidChange, object: nil, queue: nil
        ) { _ in MainActor.assumeIsolated { counter.count += 1 } }
        defer { NotificationCenter.default.removeObserver(token) }

        let wrote = await store.repairTailProjection(conversationID: convo.id)
        XCTAssertFalse(wrote, "nothing to fix")
        let posts = await MainActor.run { counter.count }
        XCTAssertEqual(
            posts, 0,
            "posting would reload the lists, the reload would re-read the "
                + "envelope, and a row that still could not be made valid would "
                + "ask for a repair again — the loop this method must not have"
        )
        let after = try await reload(convo.id, store: store)
        XCTAssertEqual(after.tailProjection, before.tailProjection)
    }

    func testRepairWritesNothingForAConversationWithNoTailToDescribe() async throws {
        // Absent envelope reads `.stale` and so is repairable in principle, but
        // the correct envelope for a conversation with no messages is no
        // envelope — which is what is already there.
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")

        let wrote = await store.repairTailProjection(conversationID: convo.id)
        XCTAssertFalse(wrote)
        let after = try await reload(convo.id, store: store)
        XCTAssertNil(after.tailProjection)
    }

    func testRepairRefusesToWriteAnEnvelopeItCouldOnlyMakeStale() async throws {
        // A tail whose role this build does not recognise — the shape a
        // partially-synced or foreign row takes. The row is stale (no envelope at
        // all) and the repair CAN see the real tail, but the only envelope it
        // could build would fail its own validity test, so it writes nothing
        // rather than exporting a CKRecord for a value no reader can use.
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        _ = try await store.appendMessage(
            role: "user", text: "hi", conversationID: convo.id, sourceDevice: "phone"
        )
        let foreign = try await store.appendMessage(
            role: "system", text: "from another build", conversationID: convo.id,
            sourceDevice: "phone"
        )

        let before = try await reload(convo.id, store: store)
        XCTAssertEqual(before.lastActivityAt, foreign.createdAt)
        XCTAssertNil(
            before.tailProjection,
            "an unknown role produces no envelope rather than an unusable one"
        )
        XCTAssertEqual(reading(before), .stale)

        let wrote = await store.repairTailProjection(conversationID: convo.id)
        XCTAssertFalse(wrote)
        let after = try await reload(convo.id, store: store)
        XCTAssertNil(after.tailProjection)
        XCTAssertEqual(
            after.lastActivityAt, before.lastActivityAt,
            "and the stamps are left alone too — the repair moves them only on "
                + "the branch that is also writing an envelope"
        )
    }

    func testRepairIsSafeForAConversationThatIsNotPresent() async throws {
        let store = makeStore()
        _ = try await store.createConversation(backend: "openclaw")
        let wrote = await store.repairTailProjection(conversationID: UUID())
        XCTAssertFalse(wrote)
    }

    func testRepairRewritesAStaleEnvelopeFromTheRealTail() async throws {
        // THE WRITE BRANCH, which is the only thing that closes the mixed-fleet
        // failure the column exists for: an older build appends, bumps
        // `lastActivityAt`, leaves the envelope describing the PREVIOUS tail, and
        // the wrist — which has no per-row fetch to fall back on — shows no mark
        // on that conversation forever. Reaching it needs the seam, because every
        // production writer writes both halves from one canonical stamp in one
        // transaction and so cannot produce the state.
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let reply = try await store.appendMessage(
            role: "agent", text: "answer", conversationID: convo.id, sourceDevice: "phone"
        )

        // What an old build leaves behind: a well-formed envelope describing the
        // turn from before the reply landed, at that turn's own stamp.
        await store._setTailProjectionForTesting(
            TailProjection.encoded(
                messageID: UUID(),
                createdAt: reply.createdAt.addingTimeInterval(-60),
                role: .user
            ),
            conversationID: convo.id
        )
        let before = try await reload(convo.id, store: store)
        XCTAssertEqual(reading(before), .stale, "only the stamp can expose a missed write")
        XCTAssertNil(reading(before).role, "and the wrist withholds its mark meanwhile")

        let wrote = await store.repairTailProjection(conversationID: convo.id)
        XCTAssertTrue(wrote, "the repair must actually write")

        let after = try await reload(convo.id, store: store)
        XCTAssertEqual(
            reading(after),
            .valid(TailProjection(messageID: reply.id, createdAt: reply.createdAt, role: .agent)),
            "rebuilt from the real tail, and valid against the conversation's own stamp"
        )
    }

    func testRepairNamesTheNewestTurnOutOfMany() async throws {
        // The tail pick is a fetch, not a memory of what was written, so it has
        // to sort. `fetchConversationTail` — the per-row fallback this envelope
        // stands in for on iOS and macOS — answers the same question in the same
        // direction, and the two must never name different tails for one row.
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        var written: [MessageRecord] = []
        for index in 0..<6 {
            written.append(
                try await store.appendMessage(
                    role: index.isMultiple(of: 2) ? "user" : "agent",
                    text: "turn \(index)",
                    conversationID: convo.id,
                    sourceDevice: "phone"
                )
            )
        }
        let newest = try XCTUnwrap(written.last)

        await store._setTailProjectionForTesting(
            TailProjection.encoded(
                messageID: written[0].id, createdAt: written[0].createdAt, role: .user
            ),
            conversationID: convo.id
        )
        let wrote = await store.repairTailProjection(conversationID: convo.id)
        XCTAssertTrue(wrote)

        let after = try await reload(convo.id, store: store)
        guard case .valid(let projection) = reading(after) else {
            return XCTFail("expected valid, got \(reading(after))")
        }
        XCTAssertEqual(projection.messageID, newest.id)
        XCTAssertEqual(projection.createdAt, newest.createdAt)
        XCTAssertEqual(projection.role, .agent)
    }

    func testRepairingARowThisBuildWroteLeavesItsStampsUntouched() async throws {
        // The repair snaps the tail's `createdAt` and the conversation's
        // `lastActivityAt` onto one canonical `Date`, because it is the ONE path
        // that describes a tail it did not write and so the one path that can be
        // handed an instant at an arbitrary offset inside its millisecond. For a
        // row this build wrote, both are already canonical and the snap must
        // change nothing — otherwise a pure envelope repair would export two
        // records instead of one, on every row, forever.
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let reply = try await store.appendMessage(
            role: "agent", text: "answer", conversationID: convo.id, sourceDevice: "phone"
        )
        let before = try await reload(convo.id, store: store)

        await store._setTailProjectionForTesting(
            TailProjection.encoded(
                messageID: UUID(),
                createdAt: reply.createdAt.addingTimeInterval(-60),
                role: .user
            ),
            conversationID: convo.id
        )
        let wrote = await store.repairTailProjection(conversationID: convo.id)
        XCTAssertTrue(wrote)

        let after = try await reload(convo.id, store: store)
        XCTAssertEqual(after.lastActivityAt, before.lastActivityAt)
        let copies = try await store.fetchMessages(for: convo.id)
        let tail = try XCTUnwrap(copies.last)
        XCTAssertEqual(tail.createdAt, reply.createdAt)
        assertCanonical(after.lastActivityAt, "a repaired conversation's lastActivityAt")
        assertCanonical(tail.createdAt, "a repaired tail's createdAt")
        XCTAssertEqual(reading(after).role, .agent)
    }

    func testRepairSnapsALegacyRowsTwoStampsOntoOneCanonicalDate() async throws {
        // THE MIGRATION THIS REPAIR REALLY IS. A row written before
        // `TailProjection.canonical` carries one bare `Date()` in both columns,
        // at an arbitrary offset inside its millisecond — the one value
        // CloudKit's DATE field is free to quantise in a direction Apple does
        // not document. Snapping BOTH halves onto the value both quantisations
        // agree about is what makes the row converge; moving one and not the
        // other would leave the envelope valid and silently retire the red mark
        // of a failed tail (`ConversationActivityResolver` step 1).
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let reply = try await store.appendMessage(
            role: "agent", text: "answer", conversationID: convo.id, sourceDevice: "phone"
        )

        let legacy = TailProjection.canonical(reply.createdAt).addingTimeInterval(0.0004)
        await store._setStampsForTesting(
            conversationID: convo.id, lastActivityAt: legacy, newestFirst: [legacy]
        )
        await store._setTailProjectionForTesting(nil, conversationID: convo.id)
        let before = try await reload(convo.id, store: store)
        XCTAssertEqual(reading(before), .stale)
        XCTAssertEqual(before.lastActivityAt, legacy)
        XCTAssertNotEqual(
            TailProjection.canonical(legacy), legacy,
            "the fixture has to be OFF a millisecond boundary or this case "
                + "passes without the canonicalising branch running at all"
        )

        let repaired = await store.repairTailProjection(conversationID: convo.id)
        XCTAssertTrue(repaired)

        let after = try await reload(convo.id, store: store)
        let rendered = try await store.fetchMessages(for: convo.id)
        let tail = try XCTUnwrap(rendered.last)
        assertCanonical(after.lastActivityAt, "a repaired conversation's lastActivityAt")
        assertCanonical(tail.createdAt, "a repaired tail's createdAt")
        XCTAssertEqual(after.lastActivityAt, tail.createdAt, "both halves or neither")
        XCTAssertEqual(after.lastActivityAt, TailProjection.canonical(legacy))
        XCTAssertEqual(
            reading(after),
            .valid(TailProjection(
                messageID: reply.id,
                createdAt: TailProjection.canonical(legacy),
                role: .agent
            ))
        )
    }

    func testARepairedLegacyFailureStillPaintsItsMarkAndCarriesAFreshIdentity() async throws {
        // Two properties of the same write, and each is a red mark that would
        // otherwise vanish for a message that never sent.
        //   • The resolver bounds a terminal failure by
        //     `createdAt >= lastActivityAt`, so the snap has to leave the pair
        //     comparing EQUAL.
        //   • The save republishes the whole `Message` record under
        //     record-level last-writer-wins, `status` and `deliveryAttemptID`
        //     included, from values this device may hold from before a retry it
        //     has not imported. Minting makes that export name an attempt no
        //     acknowledgement can match — see `mintDeliveryAttemptID`.
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let turn = try await store.appendMessage(
            role: "user", text: "hi", conversationID: convo.id,
            sourceDevice: "phone", status: "sending"
        )
        await store.failTurn(messageID: turn.id, classification: nil)
        let failedRows = try await store.fetchMessages(for: convo.id)
        let declared = try XCTUnwrap(failedRows.last?.deliveryAttemptID)

        let stored = try await reload(convo.id, store: store)
        let legacy = TailProjection.canonical(stored.lastActivityAt).addingTimeInterval(0.0006)
        await store._setStampsForTesting(
            conversationID: convo.id, lastActivityAt: legacy, newestFirst: [legacy]
        )
        await store._setTailProjectionForTesting(nil, conversationID: convo.id)

        let repaired = await store.repairTailProjection(conversationID: convo.id)
        XCTAssertTrue(repaired)

        let after = try await reload(convo.id, store: store)
        let repairedRows = try await store.fetchMessages(for: convo.id)
        let tail = try XCTUnwrap(repairedRows.last)
        XCTAssertEqual(after.lastActivityAt, tail.createdAt)
        XCTAssertNotEqual(
            tail.deliveryAttemptID, declared,
            "a republished failure declaration mints, or it re-declares an "
                + "identity a standing acknowledgement would silence"
        )
        let inputs = ConversationActivityInputs(
            lastActivityAt: after.lastActivityAt,
            newestSendingAt: nil,
            newestFailed: FailedTurnProjection(
                messageID: tail.id,
                createdAt: tail.createdAt,
                deliveryAttemptID: tail.deliveryAttemptID
            ),
            storedLastViewedAt: nil,
            storedFailureSeenAttemptID: declared,
            tailRole: reading(after).role
        )
        XCTAssertEqual(
            ConversationActivityResolver.resolve(
                inputs, locallyLiveSince: nil, lastViewedAt: nil, now: after.lastActivityAt
            ).activity,
            .failed,
            "the repaired pair must still report the failure that IS the tail, "
                + "and the old acknowledgement must no longer silence it"
        )
    }

    func testRepairDeclinesWhenTheSnapWouldCrossTheMessageBehindTheTail() async throws {
        // Rounding to nearest can move a stamp EARLIER, and `Message.createdAt`
        // is the only order a thread has. On a legacy pair sharing one
        // millisecond an unbounded snap would put the newest turn behind the one
        // it answered: the thread would render the user's turn above the reply
        // that preceded it, `fetchConversationTail` would return the other row
        // while the envelope named this one, and `lastActivityAt` would sit
        // behind its own newest message. A row this repair cannot improve is
        // left exactly as it is.
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        _ = try await store.appendMessage(
            role: "agent", text: "answer", conversationID: convo.id, sourceDevice: "phone"
        )
        let tailTurn = try await store.appendMessage(
            role: "user", text: "follow-up", conversationID: convo.id, sourceDevice: "phone"
        )

        let base = TailProjection.canonical(tailTurn.createdAt)
        let tailStamp = base.addingTimeInterval(0.0004)      // rounds DOWN to `base`
        let predecessor = base.addingTimeInterval(0.0002)    // and `base` is behind this
        await store._setStampsForTesting(
            conversationID: convo.id,
            lastActivityAt: tailStamp,
            newestFirst: [tailStamp, predecessor]
        )
        await store._setTailProjectionForTesting(nil, conversationID: convo.id)

        let repaired = await store.repairTailProjection(conversationID: convo.id)
        XCTAssertFalse(repaired)

        let after = try await reload(convo.id, store: store)
        XCTAssertEqual(after.lastActivityAt, tailStamp, "the stamps are left alone")
        XCTAssertNil(after.tailProjection, "and so is the envelope — both halves or neither")
        let stamps = try await store.fetchMessages(for: convo.id).map(\.createdAt)
        XCTAssertEqual(stamps, [predecessor, tailStamp], "the thread keeps its order")
    }

    func testTheTailAndTheRenderFetchPickTheSameRowOutOfATie() async throws {
        // Two devices settling one millisecond independently produce two turns
        // with one `createdAt`, and three sites then have to agree about which
        // is newer or an acknowledgement names a turn the list never painted:
        // `fetchMessages`'s LAST element (what the thread acknowledges off),
        // `fetchConversationTail` (the list's per-row fallback) and
        // `FailedTurnProjection.isNewer` (the aggregate). All three take the
        // LARGER id.
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let first = try await store.appendMessage(
            role: "user", text: "alpha", conversationID: convo.id, sourceDevice: "phone"
        )
        let second = try await store.appendMessage(
            role: "agent", text: "beta", conversationID: convo.id, sourceDevice: "phone"
        )

        let shared = TailProjection.canonical(second.createdAt)
        await store._setStampsForTesting(
            conversationID: convo.id, lastActivityAt: shared, newestFirst: [shared, shared]
        )
        let tied = try await store.fetchMessages(for: convo.id)
        XCTAssertEqual(
            Set(tied.map(\.createdAt)), [shared],
            "the fixture has to actually tie, or the pickers are never asked to break one"
        )

        let expected = [first, second].max { $0.id.uuidString < $1.id.uuidString }
        let winner = try XCTUnwrap(expected)
        let rendered = try await store.fetchMessages(for: convo.id)
        let picked = try await store.fetchConversationTail(id: convo.id)
        XCTAssertEqual(rendered.last?.id, winner.id)
        XCTAssertEqual(picked?.text, winner.text)
    }

    func testAnAppendNeverFollowsAMirroredStampBeyondTheSkewBudget() async throws {
        // `lastActivityAt` is a mirrored column written from ANOTHER device's
        // wall clock, so following it unconditionally makes a wrong clock
        // permanent: every later append into that conversation would inherit the
        // offset and add a millisecond. The launch sweep fetches
        // `createdAt < now - grace`, so a future-dated `sending` turn would
        // never be swept, and `ReadStateStore.clamped` caps a view marker at
        // `now + clockSkewGrace`, so a row further ahead than that could never
        // be marked read at all.
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        _ = try await store.appendMessage(
            role: "agent", text: "answer", conversationID: convo.id, sourceDevice: "phone"
        )
        let wrong = Date().addingTimeInterval(ReadStateStore.clockSkewGrace * 24)
        await store._setStampsForTesting(
            conversationID: convo.id, lastActivityAt: wrong, newestFirst: [wrong]
        )

        let now = Date()
        let written = try await store.appendMessage(
            role: "user", text: "hi", conversationID: convo.id, sourceDevice: "phone"
        )

        XCTAssertLessThan(written.createdAt, wrong, "the skew is declined, not inherited")
        XCTAssertLessThanOrEqual(
            written.createdAt,
            now.addingTimeInterval(ReadStateStore.clockSkewGrace + 1),
            "no stamp this store writes may land above the ceiling a view marker can reach"
        )
        let after = try await reload(convo.id, store: store)
        XCTAssertEqual(after.lastActivityAt, written.createdAt)
        XCTAssertEqual(reading(after).role, .user, "and the envelope still validates")
    }

    func testRepairIsAskedForAtMostOncePerConversationPerProcess() async throws {
        // The memo is what keeps a row from being re-attempted on every list
        // reload. Asserted on a genuinely REPAIRABLE row: on an empty
        // conversation both calls return false whether or not the memo exists,
        // which would pin nothing at all.
        let store = makeStore()
        let convo = try await store.createConversation(backend: "openclaw")
        let reply = try await store.appendMessage(
            role: "agent", text: "answer", conversationID: convo.id, sourceDevice: "phone"
        )
        let staleEnvelope = TailProjection.encoded(
            messageID: UUID(),
            createdAt: reply.createdAt.addingTimeInterval(-60),
            role: .user
        )

        await store._setTailProjectionForTesting(staleEnvelope, conversationID: convo.id)
        let first = await store.repairTailProjection(conversationID: convo.id)
        XCTAssertTrue(first)

        // Make it stale AGAIN. Without the memo this second call would find a
        // repairable row and write; with it, the store is never reached.
        await store._setTailProjectionForTesting(staleEnvelope, conversationID: convo.id)
        let second = await store.repairTailProjection(conversationID: convo.id)
        XCTAssertFalse(second, "one attempt per conversation per process")

        let after = try await reload(convo.id, store: store)
        XCTAssertEqual(reading(after), .stale, "and it really did not touch the row")
    }
}

/// See `ConversationStoreAttentionMarkerTests` for why this is `@MainActor`.
@MainActor
private final class RepairChangeCounter {
    var count = 0
}
