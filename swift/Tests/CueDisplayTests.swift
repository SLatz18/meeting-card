import XCTest
@testable import MeetingCardCore

/// The coaching-display prototype's logic (docs/COACHING_DISPLAY.md): one gate of N seconds for every
/// option, bursts, stale and conflicting cues, caption anchors, its copy and tokens, and that it
/// compiles into test builds only.
final class CueDisplayTests: XCTestCase {
    static let swiftDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    func read(_ path: String) throws -> String {
        try String(contentsOf: Self.swiftDir.appendingPathComponent(path), encoding: .utf8)
    }

    /// ListenMoreCore's built-in config, read from its source (the app tests don't link the Kit).
    func coachConfig() throws -> [String: Any] {
        let src = try read("Packages/ListenMoreKit/Sources/ListenMoreCore/DefaultConfig.swift")
        let json = try XCTUnwrap(src.components(separatedBy: "#\"\"\"").dropFirst().first?.components(separatedBy: "\"\"\"#").first)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    func shown(_ f: CueDisplayFrame) -> [(CoachNudge.Kind, TimeInterval)] {
        f.decisions.compactMap { if case let .shown(k, at, _) = $0 { (k, at) } else { nil } }
    }

    // MARK: pacing

    /// N gives every cue its whole hold and an equal rest, and never holds back a cue the shipped
    /// policy let through; the linger ends before the same cue type can come back.
    func testGapSitsBetweenTwiceTheHoldAndThePolicyCooldown() throws {
        let cues = try XCTUnwrap(try coachConfig()["cues"] as? [String: Any])
        let global = try XCTUnwrap(cues["global_cooldown_s"] as? Double)
        let perType = try XCTUnwrap(cues["cooldown_s"] as? Double)
        XCTAssertEqual(CueDisplayPacing.minNewCueGap, 10)
        XCTAssertGreaterThanOrEqual(CueDisplayPacing.minNewCueGap, 2 * CardStyle.Coach.nudgeHold)
        XCTAssertLessThanOrEqual(CueDisplayPacing.minNewCueGap, global)
        XCTAssertEqual(CueDisplayPacing.hold, CardStyle.Coach.nudgeHold, "the shipped nudge hold")
        XCTAssertEqual(CueDisplayPacing.linger, perType)
    }

    /// The prototype's priority order and tones are the coach's own.
    func testPriorityAndTonesMirrorTheCoachConfig() throws {
        let cues = try XCTUnwrap(try coachConfig()["cues"] as? [String: Any])
        XCTAssertEqual(CoachNudge.Kind.priorityOrder.map(\.rawValue), try XCTUnwrap(cues["priority"] as? [String]))
        let colors = try XCTUnwrap(cues["colors"] as? [String: String])
        XCTAssertEqual(Set(colors.keys), Set(CoachNudge.Kind.allCases.map(\.rawValue)), "every cue type, nothing else")
        for kind in CoachNudge.Kind.allCases {
            XCTAssertEqual(kind.tone, colors[kind.rawValue] == "red" ? .rose : .amber, kind.rawValue)
        }
        XCTAssertEqual(Set(CoachNudge.Kind.priorityOrder), Set(CoachNudge.Kind.allCases))
    }

    /// With the shipped policy (cues at least 20 s apart) the display shows every cue the moment it
    /// arrives: the recorded harness runs, and any spacing at or above the policy's.
    func testShippedPacingPassesEveryCueStraightThrough() {
        for timeline in CueTimeline.all where timeline.origin == .harness(paced: true) {
            let f = CueDisplayPacer.frame(at: timeline.duration, events: timeline.events)
            XCTAssertEqual(f.decisions, timeline.events.map { .shown($0.kind, at: $0.t, waited: 0) }, timeline.id)
        }
        let spaced = (0..<12).map { i in
            CueEvent(t: Double(i) * 20, onset: Double(i) * 20, kind: CoachNudge.Kind.allCases[i % CoachNudge.Kind.allCases.count])
        }
        let f = CueDisplayPacer.frame(at: 300, events: spaced)
        XCTAssertEqual(shown(f).count, spaced.count)
        XCTAssertNil(f.pending)
    }

    /// Every timeline, at every moment: never two new cues closer than N.
    func testAtMostOneNewCuePerGap() {
        for timeline in CueTimeline.all {
            let times = shown(CueDisplayPacer.frame(at: timeline.duration, events: timeline.events)).map(\.1)
            for (a, b) in zip(times, times.dropFirst()) {
                XCTAssertGreaterThanOrEqual(b - a, CueDisplayPacing.minNewCueGap - 1e-9, timeline.id)
            }
        }
    }

    /// Five cues in 6 s: the first shows; the talk-over waits, then gives way to the question that
    /// asks the opposite; heat and not-listening don't outrank the question; the question shows when
    /// the gap opens (still fresh), clearing the interrupt's linger, which asked the opposite.
    func testBurst() {
        let f = CueDisplayPacer.frame(at: 50, events: CueTimeline.syntheticBurst.events)
        XCTAssertEqual(f.decisions, [
            .shown(.interrupt, at: 9, waited: 0),
            .deferred(.talkOver, at: 10.6),
            .replaced(.talkOver, by: .missedQuestion, at: 12),
            .replaced(.aggressive, by: .missedQuestion, at: 13.5),
            .replaced(.notListening, by: .missedQuestion, at: 15),
            .superseded(.interrupt, by: .missedQuestion, at: 19),
            .shown(.missedQuestion, at: 19, waited: 7),
            .shown(.monologue, at: 40.5, waited: 0),
        ])
        let mid = CueDisplayPacer.frame(at: 16, events: CueTimeline.syntheticBurst.events)
        XCTAssertNil(mid.line, "the interrupt's hold is over; nothing new until the gap opens")
        XCTAssertEqual(mid.lingering?.kind, .interrupt)
        XCTAssertEqual(mid.pending?.kind, .missedQuestion)
    }

    /// The recorded run before pacing: the question clears the interrupt's linger (opposite advice);
    /// the talk-over arrives 5.1 s after the question, and when the gap opens its moment has passed
    /// (6 s shelf life), so it's dropped, not shown late.
    func testStaleCueIsDroppedNotShownLate() {
        let f = CueDisplayPacer.frame(at: 98, events: CueTimeline.harnessBusyBeforePacing.events)
        XCTAssertEqual(f.decisions, [
            .shown(.interrupt, at: 7.72, waited: 0),
            .superseded(.interrupt, by: .missedQuestion, at: 24.5),
            .shown(.missedQuestion, at: 24.5, waited: 0),
            .deferred(.talkOver, at: 29.58),
            .stale(.talkOver, at: 34.5),
            .shown(.monologue, at: 77.72, waited: 0),
        ])
    }

    /// A waiting cue keeps its place against a lower priority, and loses it to a higher one or to
    /// one that asks the opposite (the newer one wins then, whatever its priority).
    func testWaitingCueReplacement() {
        func decisions(_ kinds: [CoachNudge.Kind]) -> [CueDecision] {
            let events = kinds.enumerated().map { i, k in CueEvent(t: Double(i), onset: Double(i), kind: k) }
            return CueDisplayPacer.frame(at: 5, events: events).decisions
        }
        XCTAssertEqual(decisions([.aggressive, .interrupt, .talkShare]).last, .replaced(.talkShare, by: .interrupt, at: 2))
        XCTAssertEqual(decisions([.aggressive, .monologue, .talkOver]).last, .replaced(.monologue, by: .talkOver, at: 2))
        XCTAssertEqual(decisions([.aggressive, .talkOver, .notListening]).last, .replaced(.talkOver, by: .notListening, at: 2),
                       "opposite advice: the newer wins though it ranks lower")
        XCTAssertEqual(decisions([.aggressive, .talkOver, .interrupt]).last, .replaced(.interrupt, by: .talkOver, at: 2))
    }

    func testConflictsAreYieldAgainstEngage() {
        let yield = CoachNudge.Kind.allCases.filter { $0.direction == .yield }
        let engage = CoachNudge.Kind.allCases.filter { $0.direction == .engage }
        XCTAssertEqual(Set(yield), [.interrupt, .talkOver, .monologue, .talkShare])
        XCTAssertEqual(Set(engage), [.missedQuestion, .notListening, .selfPivot])
        XCTAssertEqual(CoachNudge.Kind.aggressive.direction, .tone)
        for a in CoachNudge.Kind.allCases {
            for b in CoachNudge.Kind.allCases {
                let expected = (yield.contains(a) && engage.contains(b)) || (engage.contains(a) && yield.contains(b))
                XCTAssertEqual(a.direction.conflicts(with: b.direction), expected, "\(a) \(b)")
            }
        }
    }

    /// The self-pivot cue: amber, engage, acted on at the next turn (not mid-sentence), 10 s from the end of the turn
    /// it follows, anchored on the user's own line, ranked right after not_listening.
    func testSelfPivotCueDisplayProperties() throws {
        let k = CoachNudge.Kind.selfPivot
        XCTAssertEqual(k.tone, .amber)
        XCTAssertEqual(k.direction, .engage)
        XCTAssertEqual(k.urgency, .nextTurn)
        XCTAssertFalse(k.actionableMidSentence)
        XCTAssertEqual(k.shelfLife, 10)
        XCTAssertEqual(k.anchor, .you)
        let order = CoachNudge.Kind.priorityOrder
        XCTAssertEqual(order.firstIndex(of: k), try XCTUnwrap(order.firstIndex(of: .notListening)) + 1)
        XCTAssertEqual(order.last, .talkShare)
        XCTAssertEqual(k.priority, order.firstIndex(of: k))
        XCTAssertTrue(k.direction.conflicts(with: CoachNudge.Kind.interrupt.direction), "it asks the user to talk: it conflicts with yielding")
        XCTAssertFalse(k.direction.conflicts(with: CoachNudge.Kind.missedQuestion.direction))

        // Held past its shelf life (measured from the turn's end, its onset) it is dropped, not shown late.
        let events = [CueEvent(t: 1, onset: 0, kind: .interrupt), CueEvent(t: 4, onset: 3, kind: k)]
        XCTAssertEqual(CueDisplayPacer.frame(at: 11, events: events).decisions.last, .shown(k, at: 11, waited: 7))
        let late = [CueEvent(t: 1, onset: 0, kind: .interrupt), CueEvent(t: 4, onset: 0.5, kind: k)]
        XCTAssertEqual(CueDisplayPacer.frame(at: 11, events: late).decisions.last, .stale(k, at: 11))
    }

    // MARK: scanning the sources for switches over the cue enums

    /// Where the cue enums are switched over: the app, its Core, and the Kit's sources (not its tests).
    static let sourceDirs = ["App", "Core", "Packages/ListenMoreKit/Sources/ListenMoreCore", "Packages/ListenMoreKit/Sources/ListenMoreMac"]

    /// Every Swift source file under `sourceDirs`, as paths relative to the swift directory.
    func sourceFiles() throws -> [String] {
        try Self.sourceDirs.flatMap { dir -> [String] in
            let root = Self.swiftDir.appendingPathComponent(dir).resolvingSymlinksInPath()
            let names = try XCTUnwrap(FileManager.default.enumerator(atPath: root.path), dir).compactMap { $0 as? String }
            return names.filter { $0.hasSuffix(".swift") }.sorted().map { "\(dir)/\($0)" }
        }
    }

    /// `src` with comments and string literals (raw and multi-line too) blanked, newlines kept, so a brace or a
    /// keyword inside one is never read as code.
    static func stripped(_ src: String) -> String {
        let c = Array(src), n = c.count
        var out: [Character] = []
        var i = 0
        func blank(_ ch: Character) { out.append(ch == "\n" ? "\n" : " ") }
        while i < n {
            if c[i] == "/", i + 1 < n, c[i + 1] == "/" {
                while i < n, c[i] != "\n" { blank(c[i]); i += 1 }
            } else if c[i] == "/", i + 1 < n, c[i + 1] == "*" {
                var depth = 0
                repeat {
                    if i + 1 < n, c[i] == "/", c[i + 1] == "*" { depth += 1; blank(c[i]); blank(c[i + 1]); i += 2 }
                    else if i + 1 < n, c[i] == "*", c[i + 1] == "/" { depth -= 1; blank(c[i]); blank(c[i + 1]); i += 2 }
                    else { blank(c[i]); i += 1 }
                } while depth > 0 && i < n
            } else if c[i] == "#" || c[i] == "\"" {
                var hashes = 0
                var j = i
                while j < n, c[j] == "#" { hashes += 1; j += 1 }
                guard j < n, c[j] == "\"" else { out.append(c[i]); i += 1; continue }
                let multi = j + 2 < n && c[j + 1] == "\"" && c[j + 2] == "\""
                let quote = String(repeating: "\"", count: multi ? 3 : 1) + String(repeating: "#", count: hashes)
                let close = Array(quote)
                var k = j + close.count - hashes
                while k < n {
                    if hashes == 0, c[k] == "\\" { k += 2; continue }
                    if k + close.count <= n, Array(c[k..<(k + close.count)]) == close { k += close.count; break }
                    k += 1
                }
                for idx in i..<min(k, n) { blank(c[idx]) }
                i = min(k, n)
            } else {
                out.append(c[i]); i += 1
            }
        }
        return String(out)
    }

    /// The bodies of the `switch` statements in `code` (already stripped), outermost and nested alike. A body holds
    /// only its own arms: the text of a switch nested inside it is blanked, so each switch is judged on its own.
    static func switchBodies(_ code: String) -> [String] {
        let chars = Array(code)
        let word = Array("switch")
        var ranges: [Range<Int>] = []
        var i = 0
        while i + word.count < chars.count {
            let before = i == 0 ? " " : chars[i - 1]
            let after = chars[i + word.count]
            guard Array(chars[i..<(i + word.count)]) == word, !(before.isLetter || before.isNumber || before == "_" || before == "."),
                  !(after.isLetter || after.isNumber || after == "_") else { i += 1; continue }
            guard let open = chars[i...].firstIndex(of: "{") else { break }
            var depth = 0, j = open
            while j < chars.count {
                if chars[j] == "{" { depth += 1 } else if chars[j] == "}" { depth -= 1; if depth == 0 { break } }
                j += 1
            }
            ranges.append((open + 1)..<min(j, chars.count))
            i += word.count
        }
        return ranges.map { r in
            var own = Array(chars[r])
            for inner in ranges where inner != r && inner.lowerBound >= r.lowerBound && inner.upperBound <= r.upperBound {
                for k in inner where own[k - r.lowerBound] != "\n" { own[k - r.lowerBound] = " " }
            }
            return String(own)
        }
    }

    /// The cases only `LocalEvent.Kind` has. It shares `interrupt`, `talkOver`, `monologue` and `talkShare` with the
    /// cue enums, so those four can't tell the two apart; these can.
    static let localEventOnlyCases = ["prosody", "meOnset", "meOffset", "othersOnset", "othersOffset"]

    /// The cue enums' case names (`CueType`, `CoachNudge.Kind`).
    static let cueCases = ["interrupt", "talkOver", "aggressive", "notListening", "selfPivot", "missedQuestion", "monologue", "talkShare"]

    /// A switch over a cue enum (`CueType`, `CoachNudge.Kind`): it names a cue case in an arm and none that only
    /// `LocalEvent.Kind` has. A switch naming only the four shared names is taken for a cue switch, so a new one
    /// with a `default:` can't hide behind `LocalEvent.Kind`; a real `LocalEvent.Kind` switch that names only
    /// those four must be exhaustive too.
    static func switchesOverCues(_ body: String) -> Bool {
        func names(_ cases: [String]) -> Bool {
            body.range(of: #"\bcase\b[^:]*\.(\#(cases.joined(separator: "|")))\b"#, options: .regularExpression) != nil
        }
        return names(cueCases) && !names(localEventOnlyCases)
    }

    /// A catch-all arm: `default:`, `case _:`, a wildcard in a list of patterns, or a bare binding.
    static func hasCatchAll(_ body: String) -> Bool {
        let patterns = [#"\bdefault\s*:"#,
                        #"\bcase\b[^:]*(?<![\w.])_(?![\w])[^:]*:"#,
                        #"\bcase\s+(let|var)\s+\w+\s*(where[^:]*)?:"#,
                        #"\bcase\s+[a-z_]\w*\s*(where[^:]*)?:"#]
        return patterns.contains { body.range(of: $0, options: .regularExpression) != nil }
    }

    /// The scanner itself: it finds a switch over the cue enums and every spelling of a catch-all, and passes a
    /// switch that names every case.
    func testScannerSpotsCatchAllArms() {
        func flagged(_ src: String) -> [Bool] {
            Self.switchBodies(Self.stripped(src)).filter(Self.switchesOverCues).map(Self.hasCatchAll)
        }
        XCTAssertEqual(flagged("switch k { case .aggressive: 1\n case .interrupt: 2 }"), [false])
        XCTAssertEqual(flagged("switch k { case .aggressive: 1\n default: 2 }"), [true])
        XCTAssertEqual(flagged("switch k { case .aggressive: 1\n case _: 2 }"), [true])
        XCTAssertEqual(flagged("switch k { case .aggressive: 1\n case .interrupt, _: 2 }"), [true])
        XCTAssertEqual(flagged("switch k { case .selfPivot: 1\n case let other: 2 }"), [true])
        XCTAssertEqual(flagged("switch k { case .selfPivot: 1\n case other: 2 }"), [true])
        XCTAssertEqual(flagged("switch k { case .selfPivot: 1\n case _ where x: 2 }"), [true])
        XCTAssertEqual(flagged("switch k { case .x: switch j { case .notListening: 1\n default: 2 } }"), [true], "a nested switch is judged on its own")
        XCTAssertEqual(flagged("switch k { case .notListening: switch j { case .a: 1\n default: 2 } }"), [false], "and so is the outer one")
        XCTAssertEqual(flagged("switch k { case .aggressive: switch j { case .prosody: 1\n case .meOnset: 2 }\n default: 3 }"), [true],
                       "a nested LocalEvent.Kind switch doesn't make the outer one a LocalEvent.Kind switch")
        XCTAssertEqual(flagged("switch k { case .missedQuestion: 1 } // default: _\nlet s = \"default:\""), [false], "comments and strings don't count")
        XCTAssertEqual(flagged("switch s { case \"not_listening\": 1\n default: 2 }"), [], "a switch over a String isn't one over the enums")
        XCTAssertEqual(flagged("switch e { case .prosody: 1\n case .interrupt: 2\n default: 3 }"), [], "LocalEvent.Kind: it has cases the cues don't")
        XCTAssertEqual(flagged("switch e { case .interrupt, .talkOver: 1\n case .monologue: 2\n default: 3 }"), [true],
                       "naming only the four names the two enums share still counts as a cue switch")
        XCTAssertEqual(flagged("switch e { case .talkShare: 1\n default: 2 }"), [true])
        XCTAssertEqual(flagged("switch e { case .interrupt: 1\n case .talkOver: 2\n case .monologue: 3\n case .talkShare: 4 }"), [false])
    }

    /// No `default:`, `case _:` or other catch-all in any switch over the cue enums, wherever it is: a new cue type
    /// fails to compile until every switch handles it. The files come from scanning the sources, not a list.
    func testCueSwitchesHaveNoCatchAll() throws {
        var checked = Set<String>()
        for file in try sourceFiles() {
            let switches = Self.switchBodies(Self.stripped(try read(file))).filter(Self.switchesOverCues)
            if !switches.isEmpty { checked.insert(file) }
            for body in switches { XCTAssertFalse(Self.hasCatchAll(body), "\(file): a switch over the cue enums has a catch-all arm") }
        }
        for file in ["Core/CoachCard.swift", "Core/CueDisplay.swift", "Core/Theme.swift", "Packages/ListenMoreKit/Sources/ListenMoreCore/Config.swift"] {
            XCTAssertTrue(checked.contains(file), "the scan finds the switches in \(file)")
        }
    }

    /// The self-pivot cue stays off in MeetingCard, and nothing in the code raises it yet. The files that may name
    /// it are the ones that define, colour, rank, draw or disable it; every other source file under `sourceDirs`
    /// is scanned (the judges, the engines, the rules, the session, the pipeline and the views included), so a new
    /// file that raises it fails here without anyone adding it to a list. PivotGate.swift (#39) is picked up
    /// the same way once this is restacked onto it: that PR's allowance for it belongs in `mayNameSelfPivot`.
    static let mayNameSelfPivot: Set<String> = [
        "App/CoachController.swift",
        "Core/CoachCard.swift", "Core/CueDisplay.swift", "Core/Theme.swift",
        "Packages/ListenMoreKit/Sources/ListenMoreCore/Config.swift",
        "Packages/ListenMoreKit/Sources/ListenMoreCore/CuePolicy.swift",
        "Packages/ListenMoreKit/Sources/ListenMoreCore/DefaultConfig.swift",
    ]

    func testSelfPivotIsDisabledAndNeverRaised() throws {
        let controller = try read("App/CoachController.swift")
        XCTAssertTrue(controller.contains("CueType.selfPivot.rawValue"))
        let files = try sourceFiles()
        for file in Self.mayNameSelfPivot { XCTAssertTrue(files.contains(file), "\(file) is a source file") }
        for file in ["LocalLayer", "TextRules", "GptLayer", "CoachPipeline", "EngineBridge", "CoachSession", "TypeSafeJudge", "JudgeProvider",
                     "LocalCoachEngine", "SystemOne"].map({ "Packages/ListenMoreKit/Sources/ListenMoreCore/\($0).swift" }) {
            XCTAssertTrue(files.contains(file), "the scan covers \(file)")
        }
        for file in files where !Self.mayNameSelfPivot.contains(file) {
            let code = try read(file)
            XCTAssertFalse(code.contains(".selfPivot") || code.contains("self_pivot"), "\(file) raises or shows the self-pivot cue")
        }
    }

    /// Words for the hold, then the linger (glyph, row mark) fading to nothing.
    func testHoldThenLinger() {
        let events = [CueEvent(t: 10, onset: 9, kind: .monologue)]
        let hold = CueDisplayPacing.hold, linger = CueDisplayPacing.linger
        let during = CueDisplayPacer.frame(at: 10 + hold - 0.01, events: events)
        XCTAssertEqual(during.words, CoachNudge(kind: .monologue, tone: .amber).words)
        XCTAssertEqual(during.strength, 1)
        let after = CueDisplayPacer.frame(at: 10 + hold + (linger - hold) / 2, events: events)
        XCTAssertNil(after.line)
        XCTAssertEqual(after.lingering?.kind, .monologue)
        XCTAssertEqual(after.strength, 0.5, accuracy: 1e-9)
        let gone = CueDisplayPacer.frame(at: 10 + linger, events: events)
        XCTAssertNil(gone.lingering)
        XCTAssertEqual(gone.strength, 0)
    }

    // MARK: anchors

    func testAnchorMarksTheLineThatTriggeredTheCue() throws {
        let busy = CueTimeline.harnessBusy
        func anchored(_ timeline: CueTimeline, _ t: TimeInterval) -> String? {
            let f = CueDisplayPacer.frame(at: t, events: timeline.events)
            return CueDisplayPacer.anchorRow(f, in: timeline).map { timeline.visibleCaptions(at: t)[$0].line.text }
        }
        XCTAssertEqual(anchored(busy, 8.5)?.hasPrefix("Let us go over the launch checklist"), true, "the cut-in: their line")
        XCTAssertEqual(anchored(busy, 30.5)?.hasPrefix("Let me finish"), true, "the talk-over: the user's line")
        XCTAssertEqual(anchored(CueTimeline.harnessBusyBeforePacing, 25.5), "Okay. Which date works for the dry run?",
                       "the missed question: their question")
        XCTAssertEqual(anchored(CueTimeline.harnessMissedQuestion, 35.5), "Good. What date should we pick for the customer pilot?")
        // Their line scrolls out of the three rows while the cue still lingers: no mark.
        let cut = CueTimeline.harnessInterruption
        XCTAssertNotNil(anchored(cut, 21))
        XCTAssertNil(anchored(cut, 23))
        XCTAssertNotNil(CueDisplayPacer.frame(at: 23, events: cut.events).lingering)
        XCTAssertNil(CoachNudge.Kind.talkShare.anchor, "a trend: no line")
    }

    func testCaptionsRevealWordByWordAndKeepThreeRows() {
        let l = CueCaptionLine(own: true, start: 10, end: 14, text: "one two three four")
        XCTAssertNil(l.text(at: 9.9))
        XCTAssertEqual(l.text(at: 10), "one")
        XCTAssertEqual(l.text(at: 12), "one two")
        XCTAssertEqual(l.text(at: 14), "one two three four")
        let rows = CueTimeline.harnessBusy.visibleCaptions(at: 30)
        XCTAssertEqual(rows.count, Theme.Captions.cardRows)
        XCTAssertEqual(rows.map(\.index), [5, 6, 7])
    }

    func testTimelinesAreWellFormed() {
        XCTAssertEqual(Set(CueTimeline.all.map(\.id)).count, CueTimeline.all.count)
        for timeline in CueTimeline.all {
            XCTAssertFalse(timeline.events.isEmpty, timeline.id)
            XCTAssertFalse(timeline.moments.isEmpty, timeline.id)
            for e in timeline.events {
                XCTAssertLessThanOrEqual(e.onset, e.t, timeline.id)
                XCTAssertLessThanOrEqual(e.t, timeline.duration, timeline.id)
            }
            for l in timeline.captions { XCTAssertLessThan(l.start, l.end, timeline.id) }
            XCTAssertTrue(timeline.moments.allSatisfy { $0 <= timeline.duration }, timeline.id)
        }
        // The synthetic burst is denser than the shipped policy ever allows.
        let burst = CueTimeline.syntheticBurst.events
        XCTAssertGreaterThanOrEqual(burst.filter { $0.t - burst[0].t <= 6 }.count, 5)
    }

    // MARK: copy and tokens

    /// New strings are placeholders until a writer replaces them; the ones that mirror shipped copy
    /// stay equal to it.
    func testCopyIsPlaceholderAndMirrorsApprovedStrings() throws {
        XCTAssertTrue(CueDisplayCopy.isPlaceholder)
        let copy = try read("App/CoachCopy.swift")
        XCTAssertTrue(copy.contains("static let coachListening = \"\(CueDisplayCopy.statusListening)\""))
        XCTAssertTrue(copy.contains("static let captionsYou = \"\(CueDisplayCopy.you)\""))
        XCTAssertTrue(copy.contains("static let captionsThem = \"\(CueDisplayCopy.them)\""))
        XCTAssertEqual(CueDisplayCopy.age(1), CueDisplayCopy.justNow)
        XCTAssertEqual(CueDisplayCopy.age(12.7), "12 s ago")
        let words = CoachNudge(kind: .interrupt, tone: .rose).words
        XCTAssertEqual(CueDisplayCopy.glyphLabel(status: "Coach on, listening", words: words, age: "Just now"),
                       "Coach on, listening. Last cue: Let them finish, Just now.")
        XCTAssertEqual(CueDisplayCopy.anchoredRowLabel(speaker: "Them", text: "Okay.", words: words), "Cue: Let them finish. Them: Okay.")
        XCTAssertEqual(CueDisplayCopy.Lab.describe(.stale(.talkOver, at: 34.5)), "34.5 s dropped talk_over: too late to act on")
        XCTAssertEqual(CueDisplayCopy.nudgeLabel(status: "Coach on, listening", words: words), "Coach on, listening. Let them finish")
        XCTAssertEqual(CueDisplayCopy.tooltip(words: words, age: "12 s ago"), "Let them finish · 12 s ago")
        XCTAssertEqual(CueDisplayCopy.stripTime(9.5), "t = 9.5 s")
        XCTAssertFalse(try read("Core/CueDisplayViews.swift").contains("Text(\""), "the surfaces' strings live in CueDisplayCopy")
    }

    /// Cue glyphs: one per type, all different, and never a mic (Mute in Zoom's), a waveform (the
    /// coach's hearing state) or an ear (the coach itself).
    func testCueGlyphsKeepTheGlyphRules() {
        let glyphs = CoachNudge.Kind.allCases.map(Theme.CueDisplay.glyph)
        XCTAssertEqual(glyphs, CoachNudge.Kind.allCases.map(Theme.CoachCard.Symbols.cue), "the prototype shows the shipped glyphs")
        XCTAssertEqual(Set(glyphs).count, glyphs.count)
        for g in glyphs {
            for reserved in ["mic", "waveform", "ear"] { XCTAssertFalse(g.hasPrefix(reserved), g) }
            XCTAssertNotEqual(g, Theme.CoachCard.Symbols.status)
        }
    }

    /// The surfaces and the lab take every size, radius, alpha, font and color from a token: no number
    /// in their code but 0, 1 and 2, no color literal and no system text style.
    func testViewsAndLabHaveNoLiteralValues() throws {
        let number = try NSRegularExpression(pattern: #"(?<![A-Za-z0-9_.])\d+(\.\d+)?(?![A-Za-z0-9_])"#)
        for file in ["Core/CueDisplayViews.swift", "Core/CueDisplayLab.swift"] {
            let code = try read(file).components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .map { $0.replacingOccurrences(of: #""(?:[^"\\]|\\.)*""#, with: "\"\"", options: .regularExpression) }
                .joined(separator: "\n")
            for m in number.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
                let n = (code as NSString).substring(with: m.range)
                XCTAssertTrue(["0", "1", "2"].contains(n), "\(file): literal \(n)")
            }
            for bad in ["Color.red", "Color.orange", "Color.blue", "Color.gray", "Color.black", "Color.white", "Color(red:", "Color(white:",
                        "Color(.sRGB", "NSColor", "srgbRed", ".system(size:", ".font(.", "foregroundStyle(.", ".padding()", "Text(\"",
                        "String(format:"] {
                XCTAssertFalse(code.contains(bad), "\(file): \(bad)")
            }
        }
    }

    /// Increase Contrast is the system's unless a snapshot asks, and live in the lab: the surface reads
    /// the environment's colorSchemeContrast (which redraws it) as well as NSWorkspace's setting.
    func testSurfacesFollowIncreaseContrastLive() throws {
        let views = try read("Core/CueDisplayViews.swift")
        XCTAssertTrue(views.contains("@Environment(\\.colorSchemeContrast) private var contrast"))
        XCTAssertTrue(views.contains("increasedContrast ?? (contrast == .increased || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)"))
        XCTAssertFalse(views.contains("increasedContrast: false)"), "no hard-coded standard contrast in the surfaces")
        XCTAssertFalse(try read("Core/CueDisplayLab.swift").contains("increasedContrast:"), "the lab leaves it to the system")
    }

    // MARK: test builds only

    /// The prototype compiles only into test builds: Debug (these tests) and `--test-id`. The
    /// shipping Release build defines neither flag; CI checks its binaries too.
    func testPrototypeCompilesOnlyInTestBuilds() throws {
        func lines(_ path: String) throws -> [String] {
            try read(path).components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        for file in ["Core/CueDisplay.swift", "Core/CueTimelines.swift"] {
            let l = try lines(file)
            XCTAssertEqual(l.first, "#if DEBUG || MEETINGCARD_TEST_ID", file)
            XCTAssertEqual(l.last, "#endif", file)
        }
        for file in ["Core/CueDisplayViews.swift", "Core/CueDisplayLab.swift"] {
            let l = try lines(file)
            XCTAssertEqual(l.first, "#if canImport(SwiftUI) && (DEBUG || MEETINGCARD_TEST_ID)", file)
            XCTAssertEqual(l.last, "#endif", file)
        }
        let lab = try lines("App/CoachCueDisplayLab.swift")
        XCTAssertEqual(lab.first, "#if MEETINGCARD_TEST_ID")
        XCTAssertEqual(lab.last, "#endif")
        let project = try read("project.yml")
        let release = try XCTUnwrap(project.components(separatedBy: "    Release:").dropFirst().first?.components(separatedBy: "# The call coach").first)
        XCTAssertFalse(release.contains("SWIFT_ACTIVE_COMPILATION_CONDITIONS"), "Release defines no DEBUG")
        XCTAssertTrue(project.contains("SWIFT_ACTIVE_COMPILATION_CONDITIONS: DEBUG"), "Debug does (the tests)")
    }

    /// Release doesn't compile the test-only files at all, so no object of theirs (which whole-module
    /// optimization can fill with other files' code) reaches the shipping binary's debug map; the
    /// `--test-id` build clears the list and compiles them.
    func testReleaseLeavesTheTestOnlyFilesOut() throws {
        let project = try read("project.yml")
        let release = try XCTUnwrap(project.components(separatedBy: "    Release:").dropFirst().first?.components(separatedBy: "# The call coach").first)
        XCTAssertTrue(release.contains("EXCLUDED_SOURCE_FILE_NAMES: \"$(MEETINGCARD_TEST_ONLY_SOURCES)\""))
        let line = try XCTUnwrap(release.components(separatedBy: "\n").first { $0.contains("MEETINGCARD_TEST_ONLY_SOURCES: ") })
        let listed = try XCTUnwrap(line.components(separatedBy: "\"").dropFirst().first).split(separator: " ").map(String.init)
        // The test-only files, found in the tree: their first #if mentions MEETINGCARD_TEST_ID and they end in #endif.
        var found: [String] = []
        for dir in ["App", "Core"] {
            let root = Self.swiftDir.appendingPathComponent(dir).resolvingSymlinksInPath()
            let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let url as URL in files where url.pathExtension == "swift" {
                let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                guard let firstIf = lines.first(where: { $0.hasPrefix("#if") }), firstIf.contains("MEETINGCARD_TEST_ID"),
                      lines.last == "#endif" else { continue }
                found.append(url.lastPathComponent)
            }
        }
        XCTAssertFalse(found.isEmpty)
        XCTAssertEqual(Set(listed), Set(found), "project.yml lists exactly the test-only files in App/ and Core/")
        XCTAssertEqual(listed.count, Set(listed).count, "no name listed twice")
        // Excluded by file name: no other source may share one.
        var names: [String: Int] = [:]
        for dir in ["App", "Core"] {
            let files = try XCTUnwrap(FileManager.default.enumerator(at: Self.swiftDir.appendingPathComponent(dir), includingPropertiesForKeys: nil))
            for case let url as URL in files where url.pathExtension == "swift" { names[url.lastPathComponent, default: 0] += 1 }
        }
        for name in listed { XCTAssertEqual(names[name], 1, "\(name): exactly one file by that name") }
        let script = try read("scripts/build.sh")
        XCTAssertTrue(script.contains("'MEETINGCARD_TEST_ONLY_SOURCES='"), "the test build compiles them")
    }

    /// Every App reference to the prototype sits inside `#if MEETINGCARD_TEST_ID`.
    func testEveryAppReferenceIsInsideTheTestIdFlag() throws {
        let app = Self.swiftDir.appendingPathComponent("App")
        let names = ["CoachCueDisplayLab", "CueDisplay", "CueTimeline"]
        var references = 0
        for file in try FileManager.default.contentsOfDirectory(atPath: app.path) where file.hasSuffix(".swift") && file != "CoachCueDisplayLab.swift" {
            var inside = false
            for line in try read("App/\(file)").components(separatedBy: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t == "#if MEETINGCARD_TEST_ID" { inside = true; continue }
                if t == "#endif" { inside = false; continue }
                if names.contains(where: line.contains) {
                    references += 1
                    XCTAssertTrue(inside, "\(file): \(t)")
                }
            }
        }
        XCTAssertEqual(references, 1, "the coach menu's item, next to the debug readout")
    }

    /// Plays fixed timelines; keeps nothing.
    func testPrototypeWritesNothing() throws {
        for file in ["Core/CueDisplay.swift", "Core/CueTimelines.swift", "Core/CueDisplayViews.swift", "Core/CueDisplayLab.swift",
                     "App/CoachCueDisplayLab.swift"] {
            let src = try read(file)
            for banned in ["write(to:", "FileManager", "UserDefaults", "@AppStorage", "Logger(", "os_log", "NSLog", "print(",
                           "createFile", "FileHandle", "NSPasteboard", "URLSession"] {
                XCTAssertFalse(src.contains(banned), "\(file): \(banned)")
            }
        }
    }
}
