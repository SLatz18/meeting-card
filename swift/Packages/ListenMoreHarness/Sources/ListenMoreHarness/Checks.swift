import Foundation
import ListenMoreCore

public struct CheckResult: Sendable, Codable {
    public var name: String
    public var passed: Bool
    public var detail: String
}

/// One scenario's scores and assertions.
public struct ScenarioResult: Sendable {
    public var scenario: String
    public var summary: String
    public var mode: Mode
    public var transcription: [Speaker: StreamTranscription]
    public var speakers: SpeakerScore
    public var cues: CueMatch
    public var checks: [CheckResult]
    public var billedSeconds: Double
    public var lastMeter: CostReading?
    public var judgeCalls: Int
    /// For each missed or false interrupt, what the shadow local layer saw on the same audio; after each
    /// Unmute, You's and Them's longest pauses in the first words back.
    public var diagnostics: [String] = []

    public var passed: Bool { checks.allSatisfy(\.passed) }
    public var failures: [CheckResult] { checks.filter { !$0.passed } }
    public func check(_ name: String) -> CheckResult? { checks.first { $0.name == name } }

    public var totalErrors: WordErrors {
        (transcription[.me]?.errors ?? WordErrors()) + (transcription[.others]?.errors ?? WordErrors())
    }
}

public enum Checks {
    /// Live transcription passes under this WER (real speech recognition is not exact).
    public static let liveWerLimit = 0.35

    public static func evaluate(_ r: RunRecord) -> ScenarioResult {
        let s = r.scenario
        let live = r.mode == .live
        var checks: [CheckResult] = []
        func check(_ name: String, _ ok: Bool, _ detail: String) { checks.append(CheckResult(name: name, passed: ok, detail: detail)) }
        let mutes = r.appliedWindows(.mute, .unmute)
        let pauses = r.appliedWindows(.pause, .resume)
        let finals = r.captions.filter { $0.isFinal && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }

        // Coaching.
        let oracle = CueOracle.expected(r.timeline, config: r.config,
                                        facts: .init(keyless: s.keyless, gptStopT: r.gptStop?.t, mode: r.mode, judgeOn: r.judgeOn,
                                                     segmentedSpeech: r.segmentedSpeech, callVoiced: r.callVoiced,
                                                     micVoiced: r.micVoiced, frameS: r.config.frameS))
        let match = CueOracle.match(expected: oracle.cues, tolerated: oracle.tolerated, actual: r.cues)
        check("coaching", match.passed,
              "expected \(oracle.cues.filter { !$0.optional }.count), matched \(match.outcomes.filter { $0.actual != nil }.count), missed \(match.missed.count), false \(match.falseCues.count)"
                + (match.falseCues.isEmpty ? "" : " [" + match.falseCues.map { "\($0.type.rawValue)@\(fmt($0.t))" }.joined(separator: ", ") + "]"))
        let cuesInPause = r.cues.filter { c in pauses.contains { $0.contains(c.t) } }
        let userCuesInMute = r.cues.filter { c in c.type != .talkShare && mutes.contains { $0.contains(c.t) } }
        check("no-cues-paused-or-muted", cuesInPause.isEmpty && userCuesInMute.isEmpty,
              "paused \(cuesInPause.count), muted \(userCuesInMute.count)")

        // Transcription.
        let tx = Scoring.transcription(r, keyless: s.keyless)
        let total = (tx[.me]?.errors ?? WordErrors()) + (tx[.others]?.errors ?? WordErrors())
        let captioned = tx.values.reduce(0) { $0 + $1.linesCaptioned }, expectedLines = tx.values.reduce(0) { $0 + $1.linesExpected }
        if live {
            check("transcription", (total.rate ?? 0) <= liveWerLimit, "WER \(pct(total.rate)) (limit \(pct(liveWerLimit))), lines captioned \(captioned)/\(expectedLines)")
        } else {
            check("transcription", total.errors == 0 && captioned == expectedLines,
                  "stubbed text: WER \(pct(total.rate)), lines captioned \(captioned)/\(expectedLines)")
        }

        // Speaker identification.
        let sp = Scoring.speakers(r)
        check("speaker-id", sp.correct == sp.total && (live || sp.unmatched == 0),
              "\(sp.correct)/\(sp.total) attributed correctly (stream, caption speaker and label), \(sp.unmatched) unmatched, \(sp.uncaptioned) never captioned, multi-Them: \(sp.multiThem.rawValue)"
                + (sp.mismatches.isEmpty ? "" : "; wrong: " + sp.mismatches.joined(separator: "; ")))
        if let m = r.sockets.routingMismatches {
            check("stream-routing", m == 0, "\(m) loud appends on the wrong stream's transcriber")
        }

        // Captions in the card (X1): up to three lines, labelled by speaker, gone when the call ends.
        let labelsOK = r.captionViews.allSatisfy { v in
            v.rows.count <= 3 && v.rows.allSatisfy { $0.speaker == .me ? $0.label == "You" : ($0.label == "Them" || $0.label == "Guest") }
        }
        let goneAfter = r.visibleLinesAfterCall.map { $0 == 0 } ?? true
        check("caption-feed", labelsOK && goneAfter,
              "\(r.captionViews.count) caption updates, at most \(r.captionViews.map(\.rows.count).max() ?? 0) lines, cleared after the call: \(goneAfter)")

        // Persistence.
        let everFiles = r.transcripts.flatMap(\.files)
        if !s.saving {
            let untouched = r.storePrepared.isEmpty && r.storeWritten.isEmpty && r.recorderLastURL == nil
            check("keep-nothing", untouched && r.transcripts.allSatisfy { !$0.folderExists },
                  "saving off: transcript store asked to prepare \(r.storePrepared.count) folders and write \(r.storeWritten.count) files; folder never created: \(r.transcripts.allSatisfy { !$0.folderExists })")
        } else if s.checks.contains(.deleteMidCall) {
            let deleted = r.deleteResults.first?.deleted == true
            let afterDelete = r.transcripts.drop { $0.phase != "after-delete" }
            check("transcript-deleted-mid-call", deleted && afterDelete.allSatisfy { $0.files.isEmpty },
                  "deleted: \(deleted); no file in any later look: \(afterDelete.allSatisfy { $0.files.isEmpty })")
        } else {
            let atEnd = r.transcripts.last { $0.phase == "teardown" } ?? r.transcripts.last { $0.phase == "call-ended" }
            let files = atEnd?.files ?? []
            let f = files.first
            let named = f.map { $0.name.hasPrefix("Call ") && $0.name.hasSuffix(".md") } ?? false
            let labelled = f.map { $0.contents.contains("**[") && $0.contents.contains("You:**") } ?? false
            let after = r.transcripts.last { $0.phase == "after-teardown" }
            let wiped = r.transcriptDeletedAtTeardown && (after?.files.isEmpty ?? true)
            check("opt-in-transcript", files.count == 1 && named && f?.mode == 0o600 && labelled && wiped,
                  "files \(files.count), name ok \(named), mode \(f.map { String($0.mode, radix: 8) } ?? "-"), times+labels \(labelled), deleted at teardown \(wiped)")
        }
        if s.saving, let folder = r.transcriptsFolder?.standardizedFileURL.path {
            let outside = r.storeWritten.filter { !$0.standardizedFileURL.path.hasPrefix(folder + "/") }
            check("transcript stays in the run dir", !r.storeWritten.isEmpty && outside.isEmpty,
                  "\(r.storeWritten.count) writes, \(outside.count) outside the run's folder")
        }
        check("no-traffic-after-close", r.sockets.sendsAfterClose == 0, "\(r.sockets.sendsAfterClose) sends on a closed transcription socket")
        check("no-audio-on-disk", r.diskViolations.isEmpty && r.workDirWiped,
              "audio-like files outside the run dir: \(r.diskViolations.count); run dir wiped: \(r.workDirWiped)")
        if !live { check("lockstep", r.barrierTimeouts == 0, "\(r.barrierTimeouts) barrier timeouts") }
        if !r.judgeOn {
            check("judge off: 0 judge calls", r.judgeCalls == 0, "\(r.judgeCalls) judge calls (not_listening not exercised)")
        }
        let problems = r.problems.filter { $0 != "transcriberClearRejected" }
        check("session-problems", problems.isEmpty, problems.isEmpty ? "none reported" : problems.joined(separator: ", "))

        // Scenario-specific. Offline the windows are exact (lockstep). Live, frames already queued when a
        // control was applied still drain: engine frames count from when the engine handled the control,
        // transcriber traffic half a second after that; captions count from the control itself.
        func window(_ w: ClosedRange<Double>, from marks: [Double], slack: Double = 0) -> ClosedRange<Double> {
            let handled = live ? marks.first { $0 >= w.lowerBound - 0.05 && $0 <= w.upperBound } ?? w.lowerBound : w.lowerBound
            let lo = handled + (live ? slack : 0) + 1e-6
            return lo...max(lo, w.upperBound - 1e-6)
        }
        if s.checks.contains(.muteWindow) {
            let engineMutes = r.engineMicMutes.filter(\.muted).map(\.t)
            for w in mutes {
                let inner = (w.lowerBound + 1e-6)...(w.upperBound - 1e-6)
                let micFrames = r.samples(.mic, in: window(w, from: engineMutes))
                let sendWindow = window(w, from: engineMutes, slack: 0.5)
                let meAppends = r.sockets.appends.filter { $0.stream == .mic && sendWindow.contains($0.t) }.count
                let youLines = finals.filter { $0.speaker == .me && inner.contains($0.t) }.count
                let themLines = finals.filter { $0.speaker == .others && inner.contains($0.t) }.count
                check("muted: zero mic frames", micFrames == 0 && meAppends == 0,
                      "\(micFrames) mic samples reached the engine, \(meAppends) ME appends sent; device offered \(r.micOfferedWhileMuted) samples while muted")
                check("muted: no You lines, Them continue", youLines == 0 && themLines >= 1, "You lines \(youLines), Them lines \(themLines)")
            }
            let mutedText = r.timeline.lines.filter { p in p.line.voice == .you && mutes.contains { $0.contains(p.start) } }
            let leaked = mutedText.filter { p in
                finals.contains { $0.speaker == .me && Scoring.carries($0, p.line) }
                    || everFiles.contains { $0.contents.contains(p.line.text) }
            }
            check("muted: nothing of You kept", leaked.isEmpty, "muted You lines in captions or the transcript: \(leaked.map(\.line.id))")
            let indicatorOK = r.indicators.contains { $0.indicator == .micOff }
            check("muted: indicator", indicatorOK, "indicator showed micOff: \(indicatorOK)")
            let grace = r.config.local.unmuteGraceS
            for u in r.timeline.times(.unmute) {
                let early = r.cues.filter { c in c.t >= u && c.t <= u + grace + 4 && !oracle.tolerated.contains { $0.covers(c) } }
                check("unmute grace: no false cue", early.isEmpty,
                      "cues in the \(fmt(grace + 4)) s after unmute (local.unmute_grace_s = \(fmt(grace))): \(early.map { $0.type.rawValue })")
            }
        }
        if s.checks.contains(.pauseWindow) {
            for w in pauses {
                let frameWindow = window(w, from: r.engineStops)
                let frames = r.samples(.mic, in: frameWindow) + r.samples(.call, in: frameWindow)
                let sendWindow = window(w, from: r.engineStops, slack: 0.5)
                let appends = r.sockets.appends.filter { sendWindow.contains($0.t) }.count
                let caps = r.captions.filter { sendWindow.contains($0.t) }.count
                check("paused: no frames, traffic or captions", frames == 0 && appends == 0 && caps == 0,
                      "engine samples \(frames), transcriber appends \(appends), captions \(caps)")
                let near = live ? 0.5 : 0.1
                let stopped = r.engineStops.contains { abs($0 - w.lowerBound) < near }
                let restarted = r.engineStarts.contains { abs($0 - w.upperBound) < near }
                check("paused: engine stopped and restarted", stopped && restarted, "stopped at pause \(stopped), restarted at resume \(restarted)")
            }
            check("paused: indicator", r.indicators.contains { $0.indicator == .paused }, "indicator showed paused")
        }
        if s.checks.contains(.silenceStop), let callEnd = r.applied.first(where: { $0.kind == .callEnds })?.t {
            // The trigger sees the call app's audio off at its next poll (up to poll_s later) and stops at
            // the first poll at least stop_after_s after that. Offline the polls are exact. Live they run
            // on the paced loop's wall clock, so the poll stop_after_s later can measure a hair short and
            // the stop takes one more poll: up to 2 x poll_s, plus 0.25 s of scheduling slack.
            let stopAfter = r.config.trigger.stopAfterS, poll = r.config.trigger.pollS
            let upper = live ? stopAfter + 2 * poll + 0.25 : stopAfter + poll + 0.05
            let stopAt = r.sessionStops.first
            let delay = stopAt.map { $0 - callEnd }
            let onTime = delay.map { $0 >= stopAfter - 0.01 && $0 <= upper } ?? false
            check("silence: stops after stop_after_s", onTime,
                  "session stopped \(delay.map { String(format: "%.2f", $0) } ?? "never") s after the call audio stopped (allowed \(fmt(stopAfter))-\(String(format: "%.2f", upper)) s)")
            let lateCues = r.cues.filter { $0.t >= callEnd }
            let lastIndicator = r.indicators.last?.indicator
            check("silence: released and quiet", lateCues.isEmpty && goneAfter && lastIndicator == .hidden,
                  "cues after call end \(lateCues.count), captions cleared \(goneAfter), indicator \(lastIndicator?.rawValue ?? "-")")
        }
        if s.checks.contains(.twoThemVoices) {
            check("two Them voices", sp.multiThem == .mergedAsThem, "engine behaviour: \(sp.multiThem.rawValue)")
            let renameAt = r.timeline.times(.renameThem).first ?? .infinity
            let tagged = r.captionViews.filter { $0.t > renameAt }.flatMap(\.rows).filter { $0.speaker == .others }
            let file = (r.transcripts.last { $0.phase == "call-ended" })?.files.first?.contents ?? ""
            let ok = !tagged.isEmpty && tagged.allSatisfy { $0.label == "Guest" } && file.contains("Guest:**") && !file.contains("Them:**")
                && r.themLabelAfterCall == "Them"
            check("speaker name (X4)", ok, "tagged rows \(tagged.count), file relabelled \(file.contains("Guest:**") && !file.contains("Them:**")), next call label \(r.themLabelAfterCall ?? "-")")
        }
        if s.checks.contains(.noKey) {
            let unavailable = r.captionStates.allSatisfy { $0.state == .unavailable }
            check("no key (X3)", r.sockets.connections == 0 && r.judgeCalls == 0 && r.captions.isEmpty && unavailable,
                  "connections \(r.sockets.connections), judge calls \(r.judgeCalls), captions \(r.captions.count), captions unavailable \(unavailable)")
        }
        if s.checks.contains(.costCap) {
            let stop = r.gptStop
            let after = r.captions.filter { c in stop.map { c.t > $0.t } ?? false }
            let state = r.captionStates.first { $0.t >= (stop?.t ?? .infinity) }?.state
            let localAfter = r.cues.contains { c in c.source == .local && stop.map { c.t > $0.t } ?? false }
            check("cost cap (T5)", stop?.reason == .budgetCap && after.isEmpty && state == .stopped(.budgetCap) && localAfter,
                  "stopped \(stop.map { "\($0.reason) at \(fmt($0.t)) s" } ?? "no"), captions after \(after.count), caption state \(state == .stopped(.budgetCap) ? "stopped (budget cap)" : state.map { "\($0)" } ?? "-"), local cue after cap \(localAfter)")
        }

        var diagnostics: [String] = []
        if let shadow = r.shadow {
            for e in match.missed where e.type == .interrupt {
                diagnostics.append("missed interrupt (\(e.reason)): " + shadow.explainCutIn(around: e.window, config: r.config))
            }
            for c in match.falseCues where c.type == .interrupt {
                diagnostics.append(String(format: "false interrupt at %.2f s: ", c.t) + shadow.explainCutIn(around: (c.t - 1.5)...c.t, config: r.config))
            }
            for unmute in r.applied where unmute.kind == .unmute {
                diagnostics.append(shadow.explainFirstWordsBack(unmute: unmute.t, config: r.config))
            }
        }
        return ScenarioResult(scenario: s.name, summary: s.summary, mode: r.mode, transcription: tx, speakers: sp, cues: match,
                              checks: checks, billedSeconds: r.sockets.billedSeconds, lastMeter: r.meters.last, judgeCalls: r.judgeCalls,
                              diagnostics: diagnostics)
    }

    static func fmt(_ x: Double) -> String { String(format: "%.1f", x) }
    static func pct(_ x: Double?) -> String { x.map { String(format: "%.1f%%", $0 * 100) } ?? "n/a" }
}
