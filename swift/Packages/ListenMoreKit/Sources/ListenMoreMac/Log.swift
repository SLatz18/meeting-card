import os

/// Unified logging only (never a host's file log). Messages carry state changes, counters, enums and
/// error codes; never audio, transcript text, window titles or the key. Public arguments are checked
/// by PrivacyGuardTests.
enum Log {
    static let subsystem = "com.listenmore.kit"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let detect = Logger(subsystem: subsystem, category: "detect")
    static let trigger = Logger(subsystem: subsystem, category: "trigger")
    static let coach = Logger(subsystem: subsystem, category: "coach")
}
