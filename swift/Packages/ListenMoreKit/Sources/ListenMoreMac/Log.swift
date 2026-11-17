import os

/// Unified logging only (never the app's file log). Messages carry state changes, counters, enums
/// and error codes; never audio, transcript text, window titles or the key. Public arguments are
/// checked by PrivacyGuardTests.
enum Log {
    static let subsystem = "com.slatz.meetingcard.swift.coach"
    static let coach = Logger(subsystem: subsystem, category: "coach")
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let trigger = Logger(subsystem: subsystem, category: "trigger")
}
