import XCTest
@testable import MeetingCardCore

/// Send Feedback: a link to the public GitHub issue form, pre-filled with four values and nothing
/// else; the public-issue notice and its "Don't show again" flag per identity.
final class FeedbackTests: XCTestCase {
    static let swiftDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    static let fieldIds = ["app-version", "build-number", "macos-version", "build-type"]

    let info = Feedback.Info(appVersion: "2.0", buildNumber: "1", macOSVersion: "26.1.0", identity: .release)
    var suite = ""
    var defaults: UserDefaults!

    override func setUp() {
        suite = "feedback-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    func read(_ path: String) throws -> String {
        try String(contentsOf: Self.swiftDir.appendingPathComponent(path), encoding: .utf8)
    }

    func query(_ url: URL) -> [URLQueryItem] { URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] }

    // MARK: URL

    func testLinkIsTheIssueFormWithTheFourValues() {
        let url = Feedback.url(info)
        XCTAssertEqual(url.absoluteString,
                       "https://github.com/SLatz18/meeting-card/issues/new?template=feedback.yml"
                           + "&app-version=2.0&build-number=1&macos-version=26.1.0&build-type=Release")
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "github.com")
        XCTAssertEqual(url.path, "/SLatz18/meeting-card/issues/new")
    }

    func testEncodingOfSpacesNewlinesUnicodeAndQuerySyntax() {
        XCTAssertEqual(Feedback.encode("a b"), "a%20b")
        XCTAssertEqual(Feedback.encode("a\nb\r\nc"), "a%0Ab%0D%0Ac")
        XCTAssertEqual(Feedback.encode("caf\u{e9}"), "caf%C3%A9")
        XCTAssertEqual(Feedback.encode("\u{1D11E}"), "%F0%9D%84%9E")
        XCTAssertEqual(Feedback.encode("\u{65e5}\u{672c}"), "%E6%97%A5%E6%9C%AC")
        XCTAssertEqual(Feedback.encode("+&=#?/%"), "%2B%26%3D%23%3F%2F%25", "query syntax can't leak out of a value")
        XCTAssertEqual(Feedback.encode("AZaz09-._~"), "AZaz09-._~")

        // Through the URL: a value with spaces and non-ASCII decodes back to itself, a value with a
        // line break arrives as one line, and `&` / `=` / `+` in a value add no field.
        let odd = Feedback.Info(appVersion: "2.0 beta \u{e9}\u{1F600}", buildNumber: "7\nbody=injected",
                                macOSVersion: "26.1 &labels=bug+x", identity: .test)
        let url = Feedback.url(odd)
        XCTAssertTrue(url.absoluteString.unicodeScalars.allSatisfy { $0.isASCII }, url.absoluteString)
        XCTAssertFalse(url.absoluteString.contains(" "))
        XCTAssertFalse(url.absoluteString.contains("%0A"), "values are one line")
        let items = query(url)
        XCTAssertEqual(items.map(\.name), ["template"] + Self.fieldIds)
        XCTAssertEqual(items.map(\.value), ["feedback.yml", "2.0 beta \u{e9}\u{1F600}", "7 body=injected",
                                            "26.1 &labels=bug+x", "Test"])
    }

    func testValuesAreOneLineTrimmedAndCapped() {
        XCTAssertEqual(Feedback.clean("  2.0\n\tbeta\u{2028}x\u{0}  "), "2.0  beta x")
        XCTAssertEqual(Feedback.clean(""), FeedbackCopy.unknown)
        XCTAssertEqual(Feedback.clean(" \n "), FeedbackCopy.unknown)
        XCTAssertEqual(Feedback.clean(String(repeating: "9", count: 500)).unicodeScalars.count, Feedback.maxValueLength)
        // A single "character" of many scalars is capped too.
        let stacked = "e" + String(repeating: "\u{301}", count: 500)
        XCTAssertEqual(Feedback.clean(stacked).unicodeScalars.count, Feedback.maxValueLength)
    }

    func testURLStaysShortEvenWithWorstCaseValues() {
        XCTAssertLessThan(Feedback.url(info).absoluteString.count, 200, "the real link is short")
        // Every value at the cap, in 4-byte scalars (12 encoded characters each).
        let worst = String(repeating: "\u{1F600}", count: 1000)
        let big = Feedback.url(Feedback.Info(appVersion: worst, buildNumber: worst, macOSVersion: worst, identity: .test))
        XCTAssertLessThanOrEqual(big.absoluteString.count, Feedback.maxURLLength)
        XCTAssertLessThanOrEqual(Feedback.maxURLLength, 2048, "well under GitHub's 414 limit")
    }

    // MARK: only the allowed fields

    func testLinkHoldsOnlyTheAllowedFields() {
        for identity in [AppIdentity.release, .test] {
            let url = Feedback.url(Feedback.Info(appVersion: "2.0", buildNumber: "1", macOSVersion: "26.1.0", identity: identity))
            let items = query(url)
            XCTAssertEqual(items.map(\.name), ["template"] + Self.fieldIds, "no title, body, labels, assignees or anything else")
            XCTAssertEqual(Set(Feedback.Field.allCases.map(\.rawValue)), Set(Self.fieldIds))
            XCTAssertNil(url.fragment)
            let s = url.absoluteString
            XCTAssertFalse(s.contains(identity.bundleId), "only Release / Test, not the bundle id")
            XCTAssertFalse(s.contains("%2F"), "no file paths")
            let values = items.compactMap(\.value)
            XCTAssertEqual(values, ["feedback.yml", "2.0", "1", "26.1.0", identity.isRelease ? "Release" : "Test"])
            for personal in [NSHomeDirectory(), NSUserName(), NSFullUserName()] where !personal.isEmpty {
                XCTAssertFalse(values.contains { $0.contains(personal) }, "\(personal) in \(s)")
            }
        }
    }

    func testCurrentReadsOnlyVersionBuildAndOS() {
        let plist: [String: Any] = ["CFBundleShortVersionString": "2.0", "CFBundleVersion": "7",
                                    "CFBundleIdentifier": AppIdentity.test.bundleId, "CFBundleName": "MeetingCard (Test)",
                                    "NSHumanReadableCopyright": "someone"]
        let i = Feedback.Info.current(infoDictionary: plist,
                                      os: OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 2), identity: .test)
        XCTAssertEqual(i, Feedback.Info(appVersion: "2.0", buildNumber: "7", macOSVersion: "26.1.2", identity: .test))
        XCTAssertEqual(query(Feedback.url(i)).compactMap(\.value), ["feedback.yml", "2.0", "7", "26.1.2", "Test"])
        let empty = Feedback.Info.current(infoDictionary: nil, os: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0),
                                          identity: .release)
        XCTAssertEqual(query(Feedback.url(empty)).compactMap(\.value), ["feedback.yml", "Unknown", "Unknown", "15.0.0", "Release"])
    }

    func testBuildTypeIsTestOrRelease() {
        XCTAssertEqual(Feedback.Info(appVersion: "", buildNumber: "", macOSVersion: "", identity: .release).value(.buildType), "Release")
        XCTAssertEqual(Feedback.Info(appVersion: "", buildNumber: "", macOSVersion: "", identity: .test).value(.buildType), "Test")
    }

    /// The form the link opens has exactly the two free-text fields and the four pre-filled ones, its
    /// strings are FeedbackCopy's, and it has no labels, uploads or log blocks.
    func testIssueFormMatchesTheLinkAndTheCopy() throws {
        let form = try read("../.github/ISSUE_TEMPLATE/feedback.yml")
        let lines = form.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let ids = lines.filter { $0.hasPrefix("id: ") }.map { String($0.dropFirst(4)) }
        XCTAssertEqual(ids, ["what-happened", "what-expected"] + Self.fieldIds)
        let types = Set(lines.filter { $0.hasPrefix("- type: ") }.map { String($0.dropFirst(8)) })
        XCTAssertEqual(types, ["markdown", "textarea", "input"])
        let quoted = Set(lines.compactMap { line -> String? in
            guard !line.hasPrefix("#"), let a = line.firstIndex(of: "\""), let b = line.lastIndex(of: "\""), a < b else { return nil }
            return String(line[line.index(after: a)..<b])
        })
        XCTAssertEqual(quoted, Set(FeedbackCopy.Form.all), "the form's strings are exactly FeedbackCopy.Form")
        for key in ["labels:", "assignees:", "title:", "render:", "value: |"] {
            XCTAssertFalse(lines.contains { $0.hasPrefix(key) }, key)
        }
        XCTAssertFalse(lines.contains { $0.hasPrefix("value:") && !$0.contains(FeedbackCopy.Form.intro) }, "no pre-filled text")
    }

    // MARK: notice

    func testNoticeShowsUntilDontShowAgainOnOpen() {
        let n = FeedbackNotice(defaults: defaults, identity: .release)
        XCTAssertTrue(n.shouldShow, "shown the first time")
        XCTAssertTrue(n.resolve(.continue, dontShowAgain: false), "Open GitHub opens the link")
        XCTAssertTrue(n.shouldShow, "and the notice shows again")
        XCTAssertFalse(n.resolve(.cancel, dontShowAgain: false), "Cancel opens nothing")
        XCTAssertFalse(n.resolve(.cancel, dontShowAgain: true), "Cancel opens nothing, even with the box ticked")
        XCTAssertTrue(n.shouldShow, "Cancel never hides it")
        XCTAssertNil(defaults.object(forKey: n.key))
        XCTAssertTrue(n.resolve(.continue, dontShowAgain: true))
        XCTAssertFalse(n.shouldShow)
        XCTAssertEqual(defaults.object(forKey: n.key) as? Bool, true)
        XCTAssertFalse(FeedbackNotice(defaults: defaults, identity: .release).shouldShow, "persisted in defaults")
        XCTAssertFalse(FeedbackNotice(defaults: UserDefaults(suiteName: suite)!, identity: .release).shouldShow,
                       "read back through a new defaults object")
    }

    /// NSAlert's message is bold at a fixed width: past about 25 characters it wraps (seen in the
    /// feedback-notice snapshot).
    func testNoticeFitsOnOneLine() {
        XCTAssertLessThanOrEqual(FeedbackCopy.notice.count, 25, FeedbackCopy.notice)
        XCTAssertFalse(FeedbackCopy.notice.contains("\n"))
    }

    func testNoticeKeyIsPerIdentity() {
        XCTAssertEqual(FeedbackNotice.key(for: .release), "com.slatz.meetingcard.swift.feedback.hidePublicNotice")
        XCTAssertEqual(FeedbackNotice.key(for: .test), "com.slatz.meetingcard.swift.test.feedback.hidePublicNotice")
        XCTAssertEqual(FeedbackNotice.key(for: .release), AppIdentity.release.scoped("feedback.hidePublicNotice"))
        XCTAssertNotEqual(FeedbackNotice.key(for: .release).lowercased(), FeedbackNotice.key(for: .test).lowercased())

        // Even in one shared domain, hiding it in the test build leaves the shipping app's notice on.
        let test = FeedbackNotice(defaults: defaults, identity: .test)
        let release = FeedbackNotice(defaults: defaults, identity: .release)
        test.resolve(.continue, dontShowAgain: true)
        XCTAssertFalse(test.shouldShow)
        XCTAssertTrue(release.shouldShow)
        release.resolve(.continue, dontShowAgain: true)
        defaults.removeObject(forKey: test.key)
        XCTAssertTrue(test.shouldShow)
        XCTAssertFalse(release.shouldShow)
    }

    // MARK: app wiring

    /// The app only opens the URL: no network API, token, log, Keychain or file access in the
    /// feedback code, and both entry points go through the same action.
    func testAppOnlyOpensTheURL() throws {
        let action = try read("App/FeedbackAction.swift")
        XCTAssertTrue(action.contains("NSWorkspace.shared.open(Feedback.url(.current(identity: identity)))"))
        XCTAssertTrue(action.contains("FeedbackNotice(defaults: defaults, identity: identity)"))
        for path in ["App/FeedbackAction.swift", "Core/Feedback.swift", "Core/FeedbackCopy.swift"] {
            let code = try read(path)
            for api in ["URLSession", "URLRequest", "NSURLConnection", "import Network", "dataTask", "Keychain", "Logger",
                        "log(", "FileManager", "contentsOf", "AppPaths", "NSUserName", "NSFullUserName", "hostName",
                        "Authorization", "Bearer", "Transcript", "Caption"] {
                XCTAssertFalse(code.contains(api), "\(path) uses \(api)")
            }
        }
        let controller = try read("App/CoachController.swift")
        XCTAssertTrue(controller.contains("@objc func feedbackClicked(_ sender: Any?) { FeedbackAction.send(defaults: defaults) }"))
        XCTAssertTrue(controller.contains("menu.addItem(feedbackMenuItem())"))
        XCTAssertTrue(controller.contains("let title = FeedbackCopy.menuItem"))
        let settings = try read("App/CoachSettingsWindow.swift")
        XCTAssertTrue(settings.contains("coach.feedbackClicked(sender)"))
        XCTAssertTrue(settings.contains("FeedbackCopy.settingsButton"))
        XCTAssertTrue(settings.contains("return [section, g1, gControls, g2, gJudge, gSelfPivot, g3, transcriptGroup(), screenshotsGroup(), privacy, feedbackGroup()]"), "the row is last")
    }
}
