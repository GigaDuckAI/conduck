// SPDX-License-Identifier: Apache-2.0

// Conduck
// PasteboardExpiryPlaceholderTests.swift
//
// Shape guard for `Pasteboard.expiredPlaceholder` — the string macOS leaves in
// the clipboard when a `copySensitive` copy expires.
//
// Why a test at all for one line of copy: the string's DESTINATION is unknown
// and hostile. It exists because a bare `clearContents()` makes a late ⌘V paste
// nothing, and an empty password silently breaks a server-side auth file
// (`htpasswd` / `rclone.conf` / a Caddyfile). The replacement therefore lands in
// those same files — so its shape is load-bearing, not cosmetic:
//
//   - ONE line: a trailing newline pasted into a terminal EXECUTES the line.
//   - No `:`: an htpasswd record is `user:hash`; an extra colon adds a field.
//   - No shell metacharacters: it can be pasted into an interactive shell.
//
// A translation is the realistic way any of those breaks, which is exactly the
// case a human re-reading the constant would not catch. Pure Foundation — no
// pasteboard is touched (writing to the real system clipboard from a test would
// clobber the developer's own clipboard).

import XCTest
@testable import Conduck

final class PasteboardExpiryPlaceholderTests: XCTestCase {

    private var placeholder: String { Pasteboard.expiredPlaceholder }

    func testPlaceholderIsNonEmptyAndSingleLine() {
        XCTAssertFalse(placeholder.isEmpty,
                       "An empty placeholder is the blank-clipboard failure it exists to replace.")
        XCTAssertEqual(placeholder.components(separatedBy: .newlines).count, 1,
                       "Newlines execute when pasted into an interactive shell.")
        XCTAssertEqual(placeholder, placeholder.trimmingCharacters(in: .whitespacesAndNewlines),
                       "Leading/trailing whitespace survives a paste into a config value.")
    }

    func testPlaceholderCarriesNoDelimiterOrShellMetacharacters() {
        XCTAssertFalse(placeholder.contains(":"),
                       "`:` splits an htpasswd `user:hash` record into extra fields.")
        let metacharacters = Set("$`;|&<>\\\"'\n\r\t")
        let offenders = placeholder.filter { metacharacters.contains($0) }
        XCTAssertTrue(offenders.isEmpty,
                      "Shell/quoting metacharacters found: \(Array(Set(offenders)).sorted())")
    }

    func testPlaceholderNamesConduckSoAStrayPasteIsAttributable() {
        // A user who finds this line inside their own server config must be able
        // to tell where it came from — otherwise it reads as file corruption.
        XCTAssertTrue(placeholder.contains("Conduck"),
                      "Placeholder must name the app that wrote it.")
    }
}
