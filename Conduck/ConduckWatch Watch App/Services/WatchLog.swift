import Foundation
import os

/// Privacy-safe structured logging for the Conduck Watch app.
///
/// Extends the iOS app's `os.Logger` convention (subsystem
/// `Constants.identityNamespace`, one category per component) onto the Watch,
/// which until now used 47 raw,
/// `#if DEBUG`-only `print`s — invisible in TestFlight/Release. These emits are
/// ALWAYS compiled: `.notice`/`.error` form the durable forensic layer
/// (retrievable via Console / sysdiagnose); `.debug`/`.info` are dev-verbose.
///
/// PRIVACY (non-negotiable): callers interpolate ONLY vetted
/// metadata — `AppError.errorCode`, `NSError.domain`/`code`, `URLError.code`,
/// HTTP status, byte counts, elapsed seconds, queue depth, enum case names, and
/// `shortID(_:)` correlation prefixes. NEVER transcripts, replies, gateway URLs,
/// bearer tokens, audio, language hints, backend refs, or full IDs. The composed
/// line is marked `privacy: .public` ONLY because composition is guaranteed
/// metadata-only by this contract (the same discipline as the iOS call sites).
///
/// That makes this spine fail-OPEN: because the whole line is stamped once here,
/// a NEW field at a call site is public by default rather than redacted by
/// default. `ConduckTests/LoggingPrivacyDriftGuardTests` therefore scans the
/// `WatchLog.*` CALL SITES themselves (Rule 3) and fails on any key or value
/// shaped like a URL, host, credential, file name or transcript — so the
/// contract above is machine-checked, not comment-only.
enum WatchLog {

    enum Category: String {
        case capture  = "Capture"
        case stt      = "STT"
        case converse = "Converse"
        case session  = "Session"
        case queue    = "Queue"
        case nav      = "Nav"
        case state    = "State"
    }

    enum Level: String { case debug, info, notice, error }

    private static let subsystem = Constants.identityNamespace

    // MARK: - Correlation IDs

    /// Short, non-reversible correlation prefix (first 8 chars) for a turn /
    /// request UUID. Safe to log — an opaque fragment, never a full identity.
    static func shortID(_ id: UUID) -> String { String(id.uuidString.prefix(8)) }
    static func shortID(_ id: String) -> String { String(id.prefix(8)) }

    // MARK: - Emit

    /// Durable forensic event (default). Use for turn/session milestones and
    /// error causes you must recover after the fact.
    static func note(_ c: Category, _ event: String,
                     _ fields: KeyValuePairs<String, CustomStringConvertible> = [:]) {
        emit(c, .notice, event, fields)
    }

    /// Error-level forensic event (failures, mapped error codes before they
    /// become user strings).
    static func error(_ c: Category, _ event: String,
                      _ fields: KeyValuePairs<String, CustomStringConvertible> = [:]) {
        emit(c, .error, event, fields)
    }

    /// Coarse breadcrumb (e.g. screen pushes). Persisted to the ring buffer.
    static func info(_ c: Category, _ event: String,
                     _ fields: KeyValuePairs<String, CustomStringConvertible> = [:]) {
        emit(c, .info, event, fields)
    }

    /// Dev-only verbose. NOT mirrored to the on-wrist ring buffer (keeps the
    /// bounded buffer focused on milestones).
    static func debug(_ c: Category, _ event: String,
                      _ fields: KeyValuePairs<String, CustomStringConvertible> = [:]) {
        emit(c, .debug, event, fields)
    }

    private static func emit(_ c: Category, _ level: Level, _ event: String,
                             _ fields: KeyValuePairs<String, CustomStringConvertible>) {
        let line = compose(event, fields)
        // os.Logger is a cheap handle (not worth caching); build per-emit.
        let logger = Logger(subsystem: subsystem, category: c.rawValue)
        switch level {
        case .debug:  logger.debug("\(line, privacy: .public)")
        case .info:   logger.info("\(line, privacy: .public)")
        case .notice: logger.notice("\(line, privacy: .public)")
        case .error:  logger.error("\(line, privacy: .public)")
        }
    }

    /// `"<event> k=v k=v"` from vetted fields. Composition stays metadata-only
    /// by the privacy contract above.
    static func compose(_ event: String,
                        _ fields: KeyValuePairs<String, CustomStringConvertible>) -> String {
        guard !fields.isEmpty else { return event }
        let pairs = fields.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        return "\(event) \(pairs)"
    }
}
