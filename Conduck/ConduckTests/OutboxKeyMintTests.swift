// SPDX-License-Identifier: Apache-2.0

//
//  OutboxKeyMintTests.swift
//  ConduckTests
//
//  `OutboxKey` — the per-dispatch output folder Conduck NAMES and never
//  creates. Everything downstream (the wire line, the persisted row, the
//  listing) reads a string this type produced, so the shape, the alphabet and
//  the freshness are pinned here rather than inferred from the places that
//  consume them.
//

import XCTest
@testable import Conduck

final class OutboxKeyMintTests: XCTestCase {

    // MARK: - Shape

    /// `<conversationID>/out-<32 hex>` — exactly, and with the conversation's
    /// own identifier as the first segment. The first segment is what makes the
    /// box attributable to a conversation without a second lookup, and the
    /// listing's direct-parent rule depends on there being exactly one `/`.
    func testShapeIsConversationSlashOutPrefixedNonce() {
        let cid = UUID()
        let key = OutboxKey.mint(conversationID: cid)

        let parts = key.split(separator: "/", omittingEmptySubsequences: false)
        XCTAssertEqual(parts.count, 2, "exactly one separator — two segments. Got: \(key)")
        XCTAssertEqual(String(parts[0]), cid.uuidString,
                       "the first segment is the conversation's own identifier")
        XCTAssertTrue(String(parts[1]).hasPrefix(OutboxKey.componentPrefix),
                      "the leaf carries the frozen `out-` prefix the connector's cleanup guard whitelists")
    }

    /// The nonce is `nonceHexCharacters` long and is LOWERCASE HEX. The length
    /// is the entropy budget: with nothing creating the folder, randomness is
    /// the only thing separating this dispatch's box from any other.
    func testNonceIsExactlyTheDeclaredLengthOfLowercaseHex() {
        for _ in 0..<64 {
            let key = OutboxKey.mint(conversationID: UUID())
            let leaf = String(key.split(separator: "/")[1])
            let nonce = String(leaf.dropFirst(OutboxKey.componentPrefix.count))
            XCTAssertEqual(nonce.count, OutboxKey.nonceHexCharacters,
                           "the nonce is exactly `nonceHexCharacters` long. Got: \(nonce)")
            XCTAssertTrue(nonce.allSatisfy { "0123456789abcdef".contains($0) },
                          "the nonce is lowercase hex only. Got: \(nonce)")
        }
    }

    /// 32 hex characters IS the declared 128 bits — a guard against the nonce
    /// quietly being narrowed to a UUID (122 bits) or to half the draws.
    func testDeclaredNonceLengthCarriesOneHundredTwentyEightBits() {
        XCTAssertEqual(OutboxKey.nonceHexCharacters * 4, 128,
                       "`nonceHexCharacters` is the 128-bit budget expressed in hex digits")
    }

    // MARK: - Alphabet

    /// Every character of the key is inside `makeStoredKey`'s safe set (plus the
    /// single `/`). This is what lets the wire render the path BARE: no
    /// newline, space, quote, backtick or bracket can appear, so the path can
    /// neither add a line to the turn text nor forge a `[Conduck …]` marker.
    func testEveryCharacterIsInTheStoredKeySafeSet() {
        let safe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-/")
        for _ in 0..<64 {
            let key = OutboxKey.mint(conversationID: UUID())
            XCTAssertTrue(key.unicodeScalars.allSatisfy { safe.contains($0) },
                          "the whole key stays in the inert alphabet. Got: \(key)")
        }
    }

    /// No component starts with `.` or `-`. A leading dot hides the folder from
    /// an agent that must `ls` it, and a leading dash reads as an option to
    /// every shell tool an agent might reach for.
    func testNoComponentStartsWithADotOrADash() {
        for _ in 0..<64 {
            let key = OutboxKey.mint(conversationID: UUID())
            for component in key.split(separator: "/") {
                XCTAssertFalse(component.hasPrefix("."), "no hidden component. Got: \(key)")
                XCTAssertFalse(component.hasPrefix("-"), "no option-shaped component. Got: \(key)")
                XCTAssertNotEqual(component, "..", "no traversal component. Got: \(key)")
            }
        }
    }

    // MARK: - Freshness

    /// Two mints for the SAME conversation are different. This is the property a
    /// retry depends on: re-dispatching a stored turn must name a new folder, or
    /// a file written late by the abandoned attempt lands as this turn's output.
    func testEveryMintIsFreshEvenForTheSameConversation() {
        let cid = UUID()
        var seen = Set<String>()
        for _ in 0..<512 {
            seen.insert(OutboxKey.mint(conversationID: cid))
        }
        XCTAssertEqual(seen.count, 512, "every mint is distinct — no reuse, no counter")
    }

    /// The nonce actually varies at both ends of its range. A generator that
    /// filled only one half (a single draw duplicated, a truncated format) would
    /// still pass the length and alphabet checks while halving the entropy.
    func testBothHalvesOfTheNonceVary() {
        var firstHalves = Set<String>()
        var secondHalves = Set<String>()
        for _ in 0..<64 {
            let leaf = String(OutboxKey.mint(conversationID: UUID()).split(separator: "/")[1])
            let nonce = String(leaf.dropFirst(OutboxKey.componentPrefix.count))
            firstHalves.insert(String(nonce.prefix(16)))
            secondHalves.insert(String(nonce.suffix(16)))
        }
        XCTAssertGreaterThan(firstHalves.count, 60, "the leading 64 bits vary")
        XCTAssertGreaterThan(secondHalves.count, 60, "the trailing 64 bits vary")
    }

    // MARK: - There is exactly one mint, and it is ungated

    /// The mint is TOTAL: it never withholds a key, so every surface names a box
    /// the same way. It carries no capability parameter at all, because the only
    /// candidate — the lane's willingness to accept a nested PUT from the client
    /// — measures the wrong thing: Conduck neither creates the box nor writes
    /// into it, so the only client operation it ever sees is a PROPFIND. Where a
    /// gate IS wanted it lives one layer out, as the measured absence witness
    /// (`FileServerClientTests.testTheMintIsGatedOnTheWitnessNotOnNestedPutCapability`).
    func testTheMintIsTotalAndTakesNoCapabilityArgument() {
        // A compile-time statement as much as a runtime one: the only mint there
        // is takes an identifier and returns a String, never an Optional.
        let key: String = OutboxKey.mint(conversationID: UUID())
        XCTAssertFalse(key.isEmpty)
    }

    // MARK: - Wire rendering

    /// The location line is the FROZEN string, byte for byte, with the path
    /// rendered BARE. It is published in the public adapter contract and
    /// mirrored in the connector's golden text, so a drift here is a silent
    /// three-way divergence.
    func testLocationLineIsTheFrozenStringWithABarePath() {
        let key = OutboxKey.mint(conversationID: UUID())
        XCTAssertEqual(
            ConverseRequest.outboxLocationLine(key),
            "[Conduck file transfer] Files you produce for this reply go in: \(key)",
            "the wire line is frozen — it is published contract text")
    }

    /// The path must NOT pass through `wireDisplayName`. That helper's FIRST act
    /// is to keep only the last `/`-delimited segment — correct for a filename,
    /// destructive for a path — so routing the box through it would hand the
    /// agent `out-<hex>` with no conversation folder and no way to find it.
    func testLocationLinePathIsNotRunThroughTheDisplayNameHelper() throws {
        let cid = UUID()
        let key = OutboxKey.mint(conversationID: cid)
        let line = ConverseRequest.outboxLocationLine(key)

        let rendered = try XCTUnwrap(line.components(separatedBy: "go in: ").last)
        XCTAssertEqual(rendered, key, "what rides IS the key, whole and bare")
        XCTAssertNotEqual(rendered, ConverseRequest.wireDisplayName(key),
                          "the display-name form drops the conversation segment and must never be what rides")
        XCTAssertTrue(rendered.hasPrefix(cid.uuidString + "/"),
                      "the separator and the conversation segment both survive")
    }

    /// The line is exactly ONE line, and the splice joins it with the same
    /// blank-line idiom every other splice uses. A two-line location would let
    /// the reply-side scoping rule match half a directive.
    func testSpliceAppendsExactlyOneLineAndHandlesAnEmptyBase() {
        let key = OutboxKey.mint(conversationID: UUID())
        let line = ConverseRequest.outboxLocationLine(key)
        XCTAssertFalse(line.contains("\n"), "the location is one line")

        XCTAssertEqual(ConverseRequest.spliceOutboxLocation("", key: key), line,
                       "an empty base yields the line alone — no leading separator")
        XCTAssertEqual(ConverseRequest.spliceOutboxLocation("base", key: key),
                       "base\n\n" + line,
                       "a non-empty base is joined with the shared blank-line idiom")
    }
}
