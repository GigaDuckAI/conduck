// Conduck
// LoggingPrivacyDriftGuardTests.swift
//
// SOURCE DRIFT GUARD for the logging privacy invariant: Conduck never logs
// gateway URLs, bearer tokens, transcripts, replies, or file names.
//
// Why a guard and not review: the invariant is one line in the spec, and today
// it holds by discipline alone — every `print` sits inside `#if DEBUG` and no
// secret is interpolated anywhere. Nothing stops the NEXT one from landing
// outside a `#if DEBUG`, and nothing stops `privacy: .public` from being stamped
// on a hostname. Both mistakes compile, both look like debugging improvements in
// a diff, and neither breaks a test. That is exactly the kind of rule that decays
// once a repository accepts outside contributions.
//
// What makes a gateway URL sensitive: it names the user's own machine — a home
// LAN host or a tailnet name like `box.tail9f2c.ts.net`. `.notice`/`.error`
// entries persist to the unified log, so they land in any sysdiagnose the user
// later attaches to a public issue. On Apple platforms `os_log` string
// interpolations default to `<private>`, but NON-string types are public by
// default and an explicit `privacy: .public` overrides the default either way —
// so the invariant is easy to break by accident and hard to spot by eye.
//
// ─────────────────────────────────────────────────────────────────────────────
// WHAT THIS GUARD CHECKS (on comment-stripped, release-only source)
//
//   Rule 1 — no `print(` / `debugPrint(` / `dump(` outside a `#if DEBUG` region.
//     Structural, not numeric: there is deliberately NO pinned call-site count,
//     because a count makes every unrelated PR fail with a magic-number mismatch
//     and teaches contributors to bump the number instead of reading the rule.
//     `NSLog(` is EXEMPT here — six always-compiled sites exist on purpose (App
//     Group / share-extension diagnostics that must be visible in Release,
//     interpolating only `Constants.appGroupID` and `NSError.domain`/`code`).
//     NSLog has no `privacy:` model at all, so it is covered by Rule 2 instead,
//     where every one of its interpolations counts as public.
//
//   Rule 2 — no sensitive-SHAPED value in an always-compiled log statement,
//     unless the interpolation carries an explicit non-public privacy
//     annotation. Covers both the explicit `privacy: .public` case and the
//     non-string-defaults-to-public case, and the fix for a legitimate hit is a
//     one-word annotation that also documents the intent.
//
//   Rule 3 — no sensitive-shaped key or value at a `WatchLog.*` CALL SITE.
//     `WatchLog.emit` marks the WHOLE composed line `privacy: .public`
//     (WatchLog.swift), so the Watch spine is fail-OPEN: the literal text
//     `privacy: .public` never appears at the ~100 call sites that actually
//     choose what gets logged. Rule 2 alone would therefore pass the single most
//     likely regression — `WatchLog.error(.stt, "stt.transport", ["url": …])` —
//     so the call sites are scanned directly.
//
// ─────────────────────────────────────────────────────────────────────────────
// THE MATCHER, AND WHY IT IS DRAWN WHERE IT IS
//
// An expression is "sensitive-shaped" when its lowercased text CONTAINS one of
// `sensitiveWords`. Substring matching (rather than identifier splitting) is
// deliberate: it catches `gatewayHost`, `endpointURL`, `bearerToken` and
// `attachment.fileName` without enumerating naming conventions.
//
// Four escape hatches keep false positives near zero, each because the shape is
// PROVABLY incapable of carrying user data:
//   • ends in a scalar reducer (`.count`, `.rawValue`, `.code`, …) → a number,
//     so `response.text.count` is fine;
//   • contains a comparison operator → a `Bool`;
//   • is one whole string literal → a compile-time constant;
//   • is listed in `vettedExpressions` → hand-audited, with the reason inline.
// A guard that cries wolf gets deleted, so the bar for adding an escape hatch is
// "the value cannot be user data", not "this call site looks fine".
//
// KNOWN FALSE NEGATIVES — the line is drawn here on purpose:
//   • Reply/transcript TEXT is only caught under obvious names (`transcript`,
//     `utterance`, `prompt`, `replyText`). Catching `text`, `body`, `message`
//     or `content` generically would fire on dozens of benign counters and
//     labels, so the reply-text half of the invariant stays review-enforced.
//   • `localizedDescription` / `errorDescription` are caught EVERYWHERE, with no
//     per-file exemption (a cert-class `URLError` embeds the server hostname in
//     that text, which is the whole hazard). Reaching that state took work: five
//     always-compiled sites in the CarPlay and VAD code logged error text at
//     `privacy: .public`, all of them audited-benign, and each was reduced to
//     `(error as NSError).domain`/`.code` — the shape both share extensions
//     already used. So this is a rule with no escape hatch rather than a rule
//     with a list, which is why it is no longer listed as a gap.
//   • Line-scoped: a log statement whose interpolation is split across a line
//     break is not seen (this codebase writes them on one line). `WatchLog`
//     call sites DO get joined across lines, because those wrap routinely.
//   • Comment stripping is line-based (same as the sibling guards), so `print(`
//     inside a multi-line `"""` literal would be a false positive. The two test
//     bundles — the only place that occurs — are excluded from the scan.
//   • `#if` conditions are read textually. Anything ambiguous (`!DEBUG`, or a
//     `||` with DEBUG on one side) is treated as SHIPPING code, i.e. the guard
//     errs strict, never lax.
//
// Paths come from `#filePath`, so the scan is independent of the test runner's
// working directory — same derivation as `MarkdownAttachmentPolicyDriftGuardTests`
// and `RelayWireSourceDriftGuardTests`. Both test bundles are excluded: test code
// never ships, and this file's own denylist literals would otherwise self-trigger.

import XCTest

final class LoggingPrivacyDriftGuardTests: XCTestCase {

    // MARK: - The invariant, as data

    /// Stdout sinks that must never survive into a Release build. `NSLog(` is
    /// deliberately absent — see Rule 1 in the header.
    private static let stdoutSinks = ["print(", "debugPrint(", "dump("]

    /// Lowercased substrings that mark a value as URL-, host-, credential-,
    /// transcript- or file-name-shaped.
    private static let sensitiveWords: Set<String> = [
        "absolutestring", "url", "host", "hostname", "endpoint",
        "token", "bearer", "credential", "secret", "apikey", "password",
        "transcript", "utterance", "prompt", "replytext",
        "filename", "filepath", "path",
        // A wrapped error's own text: a cert-class `URLError` names the server it
        // expected, so this shape leaks a hostname without ever mentioning a URL.
        // No file is exempt from these two — the handful of audited-benign
        // AVFoundation / CarPlay-template sites that once needed an exemption were
        // all reduced to `(error as NSError).domain`/`.code` instead.
        "localizeddescription", "errordescription",
    ]

    /// Suffixes that reduce an expression to a number, so no string can escape.
    private static let benignReducers = [
        ".count", ".rawValue", ".code", ".domain", ".isEmpty",
        ".length", ".sampleRate", ".channelCount", ".frameLength",
    ]

    /// Hand-audited expressions that trip the substring matcher but provably
    /// carry no user data. Keep this list SHORT and give every entry a reason.
    private static let vettedExpressions: Set<String> = [
        // `WatchLog` field key whose value is `URLError.Code.rawValue` — an Int.
        "urlError",
    ]

    /// An interpolation carrying any of these is explicitly redacted, so the
    /// value's shape no longer matters.
    private static let nonPublicPrivacyAnnotations = [
        "privacy: .private", "privacy: .sensitive", "privacy: .auto", "privacy: .hash",
    ]

    private static let comparisonOperators = ["==", "!=", "<=", ">=", " < ", " > "]

    /// Test bundles never ship, and this file's own denylist would self-trigger.
    private static let excludedDirectoryNames: Set<String> = ["ConduckTests", "ConduckWatchTests"]

    // MARK: - Source access

    /// `.../Conduck/Conduck` — the Xcode project container holding all seven
    /// targets' sources. Derived from this test file's compile-time absolute path
    /// (#filePath → .../Conduck/Conduck/ConduckTests/<thisFile>), so it is
    /// independent of the test runner's working directory.
    private func projectContainerURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // .../ConduckTests
            .deletingLastPathComponent()   // .../Conduck/Conduck
    }

    /// Every `.swift` file that COMPILES INTO A SHIPPING TARGET, i.e. the whole
    /// container minus the two test bundles.
    private func shippingSwiftFiles() throws -> [URL] {
        let container = projectContainerURL()
        guard let walker = FileManager.default.enumerator(
            at: container,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            throw XCTSkip("Could not enumerate \(container.path) — update this guard's path derivation.")
        }
        var files: [URL] = []
        for case let url as URL in walker {
            guard url.pathExtension == "swift" else { continue }
            let components = Set(url.pathComponents)
            guard components.isDisjoint(with: Self.excludedDirectoryNames) else { continue }
            files.append(url)
        }
        return files
    }

    private func relativePath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: projectContainerURL().path + "/", with: "")
    }

    // MARK: - Scanner

    /// Is this `#if` / `#elseif` directive line DEBUG-conditioned?
    ///
    /// Read textually. `!DEBUG` is a RELEASE-only branch and a `||` means the
    /// branch also compiles without DEBUG, so both resolve to "not DEBUG-only" —
    /// the strict direction, which can only ever add scrutiny.
    private func isDebugCondition(_ directiveLine: String) -> Bool {
        var condition = directiveLine
        if let commentStart = condition.range(of: "//") {
            condition = String(condition[..<commentStart.lowerBound])
        }
        guard condition.contains("DEBUG") else { return false }
        if condition.contains("!DEBUG") || condition.contains("! DEBUG") || condition.contains("||") {
            return false
        }
        return true
    }

    /// Comment-stripped source lines that are NOT inside a DEBUG-conditioned
    /// `#if` region — i.e. the code that actually ships.
    ///
    /// Comment handling mirrors `codeOnly` in the sibling drift guards: a line
    /// whose content starts with `//` is dropped, `/* … */` is tracked with a
    /// flag, and a trailing `// note` after real code keeps the code.
    private func releaseCodeLines(in source: String) -> [(number: Int, text: String)] {
        var result: [(number: Int, text: String)] = []
        var inBlockComment = false
        // One entry per open `#if`: whether this branch is DEBUG-only, and
        // whether its ENCLOSING region was (needed to resolve `#else`).
        var regions: [(isDebugOnly: Bool, parentIsDebugOnly: Bool)] = []

        for (offset, rawLine) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if inBlockComment {
                if trimmed.contains("*/") { inBlockComment = false }
                continue
            }
            if trimmed.hasPrefix("//") { continue }
            if trimmed.hasPrefix("/*") {
                if !trimmed.contains("*/") { inBlockComment = true }
                continue
            }

            // `#elseif` must be tested before `#else` — it shares that prefix.
            if trimmed.hasPrefix("#if") {
                let parent = regions.last?.isDebugOnly ?? false
                regions.append((isDebugOnly: parent || isDebugCondition(trimmed),
                                parentIsDebugOnly: parent))
                continue
            }
            if trimmed.hasPrefix("#elseif") {
                if let last = regions.last {
                    regions[regions.count - 1] = (isDebugOnly: last.parentIsDebugOnly || isDebugCondition(trimmed),
                                                  parentIsDebugOnly: last.parentIsDebugOnly)
                }
                continue
            }
            if trimmed.hasPrefix("#else") {
                // The `#else` of a `#if DEBUG` is the RELEASE branch.
                if let last = regions.last {
                    regions[regions.count - 1] = (isDebugOnly: last.parentIsDebugOnly,
                                                  parentIsDebugOnly: last.parentIsDebugOnly)
                }
                continue
            }
            if trimmed.hasPrefix("#endif") {
                if !regions.isEmpty { regions.removeLast() }
                continue
            }

            if regions.last?.isDebugOnly == true { continue }
            result.append((number: offset + 1, text: line))
        }
        return result
    }

    /// Occurrences of `needle` where the preceding character is not an
    /// identifier character or a dot, so `fingerprint(` / `axDump(` / a member
    /// call like `x.print(` do not match a bare `print(`.
    private func boundedOccurrenceCount(of needle: String, in line: String) -> Int {
        var count = 0
        var searchStart = line.startIndex
        while let found = line.range(of: needle, range: searchStart..<line.endIndex) {
            if found.lowerBound == line.startIndex {
                count += 1
            } else {
                let previous = line[line.index(before: found.lowerBound)]
                if !(previous.isLetter || previous.isNumber || previous == "_" || previous == ".") {
                    count += 1
                }
            }
            searchStart = line.index(after: found.lowerBound)
        }
        return count
    }

    /// The text inside each `\( … )` interpolation on a line, paren-balanced so
    /// a nested call such as `\(String(describing: x), privacy: .public)` comes
    /// back whole (privacy argument included).
    private func interpolations(in line: String) -> [String] {
        let characters = Array(line)
        var results: [String] = []
        var index = 0
        while index + 1 < characters.count {
            guard characters[index] == "\\", characters[index + 1] == "(" else {
                index += 1
                continue
            }
            var depth = 0
            var cursor = index + 1
            let start = index + 2
            var closed = false
            while cursor < characters.count {
                if characters[cursor] == "(" {
                    depth += 1
                } else if characters[cursor] == ")" {
                    depth -= 1
                    if depth == 0 {
                        results.append(String(characters[start..<cursor]))
                        index = cursor
                        closed = true
                        break
                    }
                }
                cursor += 1
            }
            if !closed { break }   // unbalanced — a wrapped statement; give up on this line
            index += 1
        }
        return results
    }

    /// Is this line an emit on an `os.Logger` handle, `os_log`, or `NSLog`?
    ///
    /// The receiver must be named `log`/`logger`/`Log`/`Logger` (optionally
    /// dotted, e.g. `Self.log`, `RemoteAgentDiagnostics.log`) at an identifier
    /// boundary, which keeps unrelated `.error(` calls out. `WatchLog.error(` is
    /// deliberately NOT matched here — the boundary fails on `hLog` — because its
    /// call sites are Rule 3's job.
    private func isLogEmit(_ line: String) -> Bool {
        if line.contains("NSLog(") || line.contains("os_log(") { return true }
        let pattern = #"(?:^|[^A-Za-z0-9_])(?:log|logger|Log|Logger)[A-Za-z0-9_.]*\.(?:debug|info|notice|log|error|warning|fault|critical|trace)\s*\("#
        return line.range(of: pattern, options: .regularExpression) != nil
    }

    /// Is the whole expression a single string literal (a compile-time constant,
    /// therefore never user data)?
    private func isWholeStringLiteral(_ expression: String) -> Bool {
        guard expression.count >= 2,
              expression.hasPrefix("\""),
              expression.hasSuffix("\"") else { return false }
        return !expression.dropFirst().dropLast().contains("\"")
    }

    /// The sensitive words this expression matches, after the four escape
    /// hatches. Empty means "provably not a leak, or not shaped like one".
    ///
    /// Deliberately NOT parameterised by file: the rule is the same everywhere.
    /// An earlier revision took a `fileName` to exempt a few audited call sites,
    /// and fixing those sites at the source retired both the parameter and the
    /// list. Re-adding a per-file escape hatch should feel like a regression.
    private func sensitiveMatches(in expression: String) -> [String] {
        let trimmed = expression.trimmingCharacters(in: .whitespaces)
        if Self.vettedExpressions.contains(trimmed) { return [] }
        if isWholeStringLiteral(trimmed) { return [] }
        if Self.comparisonOperators.contains(where: { trimmed.contains($0) }) { return [] }
        if Self.benignReducers.contains(where: { trimmed.hasSuffix($0) }) { return [] }

        let lowered = trimmed.lowercased()
        let hits: Set<String> = Self.sensitiveWords.filter { lowered.contains($0) }
        return hits.sorted()
    }

    /// Every `WatchLog.<level>( … )` call in release code, as (start line, call
    /// text). Once a call is seen, following release lines are appended until the
    /// parentheses balance — these calls wrap across lines routinely.
    private func watchLogCalls(in lines: [(number: Int, text: String)]) -> [(line: Int, text: String)] {
        let callPattern = #"WatchLog\.(?:note|error|info|debug)\s*\("#
        var calls: [(line: Int, text: String)] = []

        for (index, entry) in lines.enumerated() {
            guard entry.text.range(of: callPattern, options: .regularExpression) != nil else { continue }
            var text = entry.text
            var depth = netParenDepth(of: entry.text)
            var cursor = index
            while depth > 0, cursor + 1 < lines.count {
                cursor += 1
                text += "\n" + lines[cursor].text
                depth += netParenDepth(of: lines[cursor].text)
            }
            calls.append((line: entry.number, text: text))
        }
        return calls
    }

    private func netParenDepth(of line: String) -> Int {
        var depth = 0
        for character in line {
            if character == "(" { depth += 1 }
            if character == ")" { depth -= 1 }
        }
        return depth
    }

    /// `("key", "value expression")` pairs from a dictionary-literal-ish call text.
    private func fieldPairs(in callText: String) throws -> [(key: String, value: String)] {
        let regex = try NSRegularExpression(pattern: #""([A-Za-z0-9_.\-]+)"\s*:\s*([^,\]]+)"#)
        let ns = callText as NSString
        var pairs: [(key: String, value: String)] = []
        regex.enumerateMatches(in: callText, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match, match.numberOfRanges == 3 else { return }
            pairs.append((key: ns.substring(with: match.range(at: 1)),
                          value: ns.substring(with: match.range(at: 2))))
        }
        return pairs
    }

    // MARK: - Rule 0: the scanner can actually fail

    /// NEGATIVE CONTROL. A drift guard that cannot fire is worse than none — it
    /// reads as coverage. This drives every moving part with synthetic input
    /// where the answer is known, so a scanner broken by a source-layout change
    /// fails HERE rather than silently reporting "no drift".
    func testScannerFiresOnSyntheticViolationsAndStaysQuietOnSafeShapes() throws {
        // 1. `#if` region classification.
        let synthetic = """
        #if DEBUG
        somePrint("compiled out — must NOT be reported")
        #endif
        somePrint("ships — must be reported")
        #if DEBUG
        let debugOnly = 1
        #else
        somePrint("release branch of a DEBUG #if — must be reported")
        #endif
        #if os(iOS)
        somePrint("platform branch, still ships — must be reported")
        #endif
        """
        let release = releaseCodeLines(in: synthetic).map { $0.text }.joined(separator: "\n")
        XCTAssertFalse(release.contains("compiled out"),
                       "Scanner failed to drop a `#if DEBUG` region — Rule 1 would report false positives.")
        XCTAssertTrue(release.contains("ships — must be reported"),
                      "Scanner dropped always-compiled code — Rule 1 could not fire.")
        XCTAssertTrue(release.contains("release branch of a DEBUG #if"),
                      "Scanner treated the `#else` of `#if DEBUG` as debug-only; that branch is the RELEASE branch.")
        XCTAssertTrue(release.contains("platform branch, still ships"),
                      "Scanner treated a non-DEBUG `#if` as debug-only — most of the app would go unscanned.")

        // 2. Sink detection, including the identifier-boundary rule.
        XCTAssertEqual(boundedOccurrenceCount(of: "print(", in: #"print("x")"#), 1)
        XCTAssertEqual(boundedOccurrenceCount(of: "print(", in: #"let f = fingerprint(data)"#), 0,
                       "Boundary rule broken — `fingerprint(` must not read as `print(`.")

        // 3. The matcher fires on the shapes this guard exists to catch. The two
        //    error-text shapes are here because they used to be exempted per-file:
        //    they must now fire unconditionally, so a re-introduced escape hatch
        //    shows up as a failure here rather than as a quieter guard.
        for expression in [
            "urlRequest.url?.absoluteString", "gatewayHost", "settings.gatewayToken",
            "attachment.fileName", "resolvedEndpoint", "credentials.bearer",
            "clip.filePath", "turn.transcript",
            "error.localizedDescription", "error?.errorDescription ?? \"unknown\"",
        ] {
            XCTAssertFalse(
                sensitiveMatches(in: expression).isEmpty,
                "Matcher went blind to `\(expression)` — the denylist or an escape hatch is broken."
            )
        }

        // 4. …and stays quiet on the reduced / constant shapes that are provably
        //    safe — including the `(error as NSError).domain`/`.code` reduction the
        //    audited error-text sites were rewritten to use.
        for expression in [
            "response.text.count", "self.currentTurnToken == token", "\"relay-reply\"",
            "urlError", "state.rawValue", "(error as NSError).domain",
            "(error as NSError).code", "buffer.frameLength",
        ] {
            XCTAssertTrue(
                sensitiveMatches(in: expression).isEmpty,
                "Matcher false-positives on `\(expression)`; a guard that cries wolf gets deleted."
            )
        }

        // 6. Interpolation extraction and log-emit recognition.
        XCTAssertEqual(
            interpolations(in: #"Self.log.info("x \(String(describing: s), privacy: .public) y")"#),
            ["String(describing: s), privacy: .public"]
        )
        XCTAssertTrue(isLogEmit(#"Self.log.error("boom")"#))
        XCTAssertTrue(isLogEmit(#"NSLog("[X] boom")"#))
        XCTAssertFalse(isLogEmit("let sheet = dialog.error(reason)"),
                       "Log-emit detection is too loose — unrelated `.error(` calls would be scanned.")

        // 7. Rule 3's end-to-end path, on the exact regression it exists to stop.
        let regression = #"WatchLog.error(.stt, "stt.transport", ["url": request.url?.absoluteString ?? ""])"#
        let calls = watchLogCalls(in: [(number: 1, text: regression)])
        XCTAssertEqual(calls.count, 1, "WatchLog call extraction broke — Rule 3 could not fire.")
        let pairs = try fieldPairs(in: calls[0].text)
        XCTAssertFalse(pairs.isEmpty, "Field extraction broke — Rule 3 could not fire.")
        let flagged = pairs.contains { pair in
            !sensitiveMatches(in: pair.key).isEmpty || !sensitiveMatches(in: pair.value).isEmpty
        }
        XCTAssertTrue(flagged, "Rule 3 did not flag a gateway URL passed as a WatchLog field.")
    }

    // MARK: - Rule 1: stdout never ships

    func testNoStdoutLoggingOutsideDebugRegions() throws {
        var violations: [String] = []
        var totalSinkSites = 0
        var fileCount = 0

        for url in try shippingSwiftFiles() {
            fileCount += 1
            let source = try String(contentsOf: url, encoding: .utf8)

            // Sanity counter over the WHOLE file (DEBUG regions included), so a
            // scanner that silently stops seeing code trips the lower bound below.
            for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
                for sink in Self.stdoutSinks {
                    totalSinkSites += boundedOccurrenceCount(of: sink, in: String(line))
                }
            }

            for line in releaseCodeLines(in: source) {
                for sink in Self.stdoutSinks where boundedOccurrenceCount(of: sink, in: line.text) > 0 {
                    violations.append("\(relativePath(url)):\(line.number) — \(sink) \(line.text.trimmingCharacters(in: .whitespaces))")
                }
            }
        }

        // Extractor sanity: LOWER BOUNDS, never exact counts. If either trips,
        // the scanner or the source layout changed — fix the guard, and raise the
        // bound only if the tree genuinely shrank.
        XCTAssertGreaterThan(fileCount, 200,
                             "Only \(fileCount) Swift files scanned; expected the whole project container. Fix this guard's path derivation before trusting it.")
        XCTAssertGreaterThan(totalSinkSites, 30,
                             "Only \(totalSinkSites) print/debugPrint/dump sites found anywhere; the scanner is probably not reading source. Fix it before trusting a clean result.")

        XCTAssertTrue(
            violations.isEmpty,
            """
            Stdout logging reachable in a RELEASE build:
            \(violations.joined(separator: "\n"))

            `print`/`debugPrint`/`dump` write to stdout with no privacy model at \
            all, and Conduck must never log transcripts, replies, gateway URLs or \
            tokens. Wrap the call in `#if DEBUG` … `#endif`, or route it through \
            `os.Logger` with an explicit privacy annotation.
            """
        )
    }

    // MARK: - Rule 2: nothing sensitive-shaped in an always-compiled log

    func testNoSensitiveShapedValueInAlwaysCompiledLogStatements() throws {
        var violations: [String] = []
        var interpolationCount = 0

        for url in try shippingSwiftFiles() {
            let source = try String(contentsOf: url, encoding: .utf8)

            for line in releaseCodeLines(in: source) where isLogEmit(line.text) {
                for interpolation in interpolations(in: line.text) {
                    interpolationCount += 1
                    if Self.nonPublicPrivacyAnnotations.contains(where: { interpolation.contains($0) }) { continue }
                    // Drop the privacy argument; only the value expression is judged.
                    let expression = interpolation.components(separatedBy: ", privacy:").first ?? interpolation
                    let matches = sensitiveMatches(in: expression)
                    guard !matches.isEmpty else { continue }
                    violations.append("\(relativePath(url)):\(line.number) — \(matches.joined(separator: "/")) in `\(expression.trimmingCharacters(in: .whitespaces))`")
                }
            }
        }

        XCTAssertGreaterThan(interpolationCount, 50,
                             "Only \(interpolationCount) always-compiled log interpolations found; the scanner is probably not reading log statements. Fix it before trusting a clean result.")

        XCTAssertTrue(
            violations.isEmpty,
            """
            Sensitive-shaped value(s) in an always-compiled log statement:
            \(violations.joined(separator: "\n"))

            A gateway URL names the user's own machine (home LAN or tailnet host), \
            and `.notice`/`.error` entries persist to the unified log — straight \
            into any sysdiagnose the user later attaches to a public issue. Note \
            that `privacy: .public` is not required to leak: NON-string types are \
            public by DEFAULT in `os_log` interpolations, and `NSLog` has no \
            privacy model at all.

            Fix by logging a non-identifying reduction instead (a count, an enum \
            label, a status code, or `WatchLog.shortID`), or — if the value really \
            must be logged — annotate it explicitly `privacy: .private`. If the \
            expression is provably not user data, add it to `vettedExpressions` \
            with the reason.
            """
        )
    }

    // MARK: - Rule 3: the Watch spine's call sites

    func testWatchLogCallSitesCarryOnlyMetadataShapedFields() throws {
        var violations: [String] = []
        var fieldCount = 0

        for url in try shippingSwiftFiles() {
            let source = try String(contentsOf: url, encoding: .utf8)
            guard source.contains("WatchLog.") else { continue }

            for call in watchLogCalls(in: releaseCodeLines(in: source)) {
                for pair in try fieldPairs(in: call.text) {
                    fieldCount += 1
                    let keyMatches = sensitiveMatches(in: pair.key)
                    let valueMatches = sensitiveMatches(in: pair.value)
                    guard !keyMatches.isEmpty || !valueMatches.isEmpty else { continue }
                    let matches = (keyMatches + valueMatches).joined(separator: "/")
                    violations.append("\(relativePath(url)):\(call.line) — \(matches) in `\"\(pair.key)\": \(pair.value.trimmingCharacters(in: .whitespaces))`")
                }
            }
        }

        XCTAssertGreaterThan(fieldCount, 80,
                             "Only \(fieldCount) WatchLog fields found; the call-site scanner is probably broken. Fix it before trusting a clean result.")

        XCTAssertTrue(
            violations.isEmpty,
            """
            Sensitive-shaped field(s) at a WatchLog call site:
            \(violations.joined(separator: "\n"))

            `WatchLog.emit` stamps the ENTIRE composed line `privacy: .public`, so \
            os_log's default redaction is off for every field any call site passes \
            — the contract is held by the call sites alone (see WatchLog.swift). \
            Log a reduction instead: a count, an enum label, an error code, or \
            `WatchLog.shortID(_:)` for correlation. If the value provably cannot be \
            user data, add it to `vettedExpressions` with the reason.
            """
        )
    }
}
