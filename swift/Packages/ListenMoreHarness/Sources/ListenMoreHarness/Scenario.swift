import Foundation
import ListenMoreCore

/// Who says a line. You is the mic stream; every Them voice is on the call stream.
public enum Voice: String, CaseIterable, Sendable, Codable {
    case you
    case themA = "them_a"
    case themB = "them_b"

    public var stream: AudioStream { self == .you ? .mic : .call }
    public var speaker: Speaker { self == .you ? .me : .others }
}

/// When a line or control happens, in scenario seconds. Anchors refer to a line's voiced span, so a
/// script keeps its shape whether the audio is synthetic (offline) or a TTS clip (live).
public enum Anchor: Sendable {
    case at(Double)
    /// `gap` seconds after line `id` stops.
    case after(String, gap: Double)
    /// `offset` seconds after line `id` starts.
    case into(String, offset: Double)
    /// `lead` seconds before line `id` stops: an overlap of fixed length whatever the clip's length.
    case beforeEnd(String, lead: Double)
}

public struct Line: Sendable {
    public var id: String
    public var voice: Voice
    public var text: String
    public var start: Anchor
    /// Offline only: synthetic length in seconds (default: words at 2.6 words/s, the transcript rules' estimate).
    public var seconds: Double?

    public init(_ id: String, _ voice: Voice, _ text: String, _ start: Anchor, seconds: Double? = nil) {
        self.id = id
        self.voice = voice
        self.text = text
        self.start = start
        self.seconds = seconds
    }

    public var words: [String] { text.split(whereSeparator: \.isWhitespace).map(String.init) }
    public var syntheticSeconds: Double { seconds ?? Double(words.count) / 2.6 }
}

public enum ControlKind: String, Sendable, Codable {
    /// The coach's own Mute (`CoachSession.setMicMuted(true)`).
    case mute
    case unmute
    case pause
    case resume
    /// The call app stops running audio; both streams go silent.
    case callEnds = "call_ends"
    /// Tag Them for this call (Settings' speaker name).
    case renameThem = "rename_them"
    /// Settings → Delete Transcript.
    case deleteTranscript = "delete_transcript"
    /// Stop Coach for this call.
    case stopCoach = "stop_coach"
}

public struct Control: Sendable {
    public var kind: ControlKind
    public var at: Anchor
    public var tag: String?

    public init(_ kind: ControlKind, _ at: Anchor, tag: String? = nil) {
        self.kind = kind
        self.at = at
        self.tag = tag
    }
}

/// Scenario-specific assertions on top of the ones every scenario gets.
public enum ScenarioCheck: String, Sendable, Codable {
    case muteWindow = "mute_window"
    case pauseWindow = "pause_window"
    case silenceStop = "silence_stop"
    case twoThemVoices = "two_them_voices"
    case noKey = "no_key"
    case costCap = "cost_cap"
    case deleteMidCall = "delete_mid_call"
}

public struct Scenario: Sendable {
    public var name: String
    public var summary: String
    public var lines: [Line]
    public var controls: [Control]
    /// Save transcripts on (opt-in); off is keep-nothing.
    public var saving: Bool
    /// No OpenAI key: local cues only, no captions.
    public var keyless: Bool
    /// `gpt.budget_usd_per_call` override (the cost cap).
    public var budgetUsd: Double?
    public var checks: Set<ScenarioCheck>
    /// Seconds of audio after the last line or control.
    public var tail: Double

    public init(name: String, summary: String, lines: [Line], controls: [Control] = [], saving: Bool = false,
                keyless: Bool = false, budgetUsd: Double? = nil, checks: Set<ScenarioCheck> = [], tail: Double = 3) {
        self.name = name
        self.summary = summary
        self.lines = lines
        self.controls = controls
        self.saving = saving
        self.keyless = keyless
        self.budgetUsd = budgetUsd
        self.checks = checks
        self.tail = tail
    }

    public func line(_ id: String) -> Line? { lines.first { $0.id == id } }
}

/// One line placed on the scenario clock. `start`/`end` bound the voiced audio; `clipStart` is where
/// the clip's first sample goes (earlier than `start` by the clip's leading silence).
public struct PlacedLine: Sendable {
    public var line: Line
    public var start: Double
    public var end: Double
    public var clipStart: Double
}

public struct PlacedControl: Sendable {
    public var control: Control
    public var t: Double
}

/// How long one line's audio is: leading silence, voiced length and the whole clip.
public struct ClipShape: Sendable {
    public var lead: Double
    public var voiced: Double
    public var total: Double

    public init(lead: Double, voiced: Double, total: Double) {
        self.lead = lead
        self.voiced = voiced
        self.total = total
    }
}

public struct Timeline: Sendable {
    public var lines: [PlacedLine]
    public var controls: [PlacedControl]
    public var duration: Double

    public func line(_ id: String) -> PlacedLine? { lines.first { $0.line.id == id } }
    public func times(_ kind: ControlKind) -> [Double] { controls.filter { $0.control.kind == kind }.map(\.t) }

    /// Spans between each `open` control and the next `close` (or `end`).
    public func windows(_ open: ControlKind, _ close: ControlKind, end: Double) -> [ClosedRange<Double>] {
        var out: [ClosedRange<Double>] = []
        var from: Double?
        for c in controls.sorted(by: { $0.t < $1.t }) {
            if c.control.kind == open, from == nil { from = c.t }
            if c.control.kind == close, let f = from {
                out.append(f...max(f, c.t))
                from = nil
            }
        }
        if let f = from { out.append(f...max(f, end)) }
        return out
    }

    /// Places lines and controls. Anchors resolve in script order; an anchor naming a later line is a script error.
    public static func realize(_ scenario: Scenario, shapes: [String: ClipShape]) throws -> Timeline {
        var placed: [String: PlacedLine] = [:]
        var lines: [PlacedLine] = []
        func resolve(_ a: Anchor) throws -> Double {
            switch a {
            case .at(let t): return t
            case let .after(id, gap):
                guard let p = placed[id] else { throw HarnessError.script("anchor names an unplaced line \(id)") }
                return p.end + gap
            case let .into(id, offset):
                guard let p = placed[id] else { throw HarnessError.script("anchor names an unplaced line \(id)") }
                return p.start + offset
            case let .beforeEnd(id, lead):
                guard let p = placed[id] else { throw HarnessError.script("anchor names an unplaced line \(id)") }
                return p.end - lead
            }
        }
        for line in scenario.lines {
            guard let shape = shapes[line.id] else { throw HarnessError.script("no audio for line \(line.id)") }
            let start = try resolve(line.start)
            let p = PlacedLine(line: line, start: start, end: start + shape.voiced, clipStart: max(0, start - shape.lead))
            placed[line.id] = p
            lines.append(p)
        }
        let controls = try scenario.controls.map { PlacedControl(control: $0, t: try resolve($0.at)) }
        let last = max(lines.map(\.end).max() ?? 0, controls.map(\.t).max() ?? 0)
        return Timeline(lines: lines, controls: controls, duration: last + scenario.tail)
    }
}

public enum HarnessError: Error, CustomStringConvertible, Equatable {
    case script(String)
    case missingKey
    case unsafeArgument
    case tts(Int)
    case webSocket(String)
    case output(String)

    public var description: String {
        switch self {
        case .script(let m): return "scenario script: \(m)"
        case .missingKey: return "live mode needs \(Harness.keyVariable) in the environment"
        case .unsafeArgument: return "refusing an argument that looks like an API key; the key is read from \(Harness.keyVariable) only"
        case .tts(let status): return "TTS request failed: HTTP \(status)"
        case .webSocket(let m): return "websocket: \(m)"
        case .output(let m): return "output: \(m)"
        }
    }
}
