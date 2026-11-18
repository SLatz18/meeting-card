#if DEBUG || MEETINGCARD_TEST_ID
import Foundation

// Cue timelines for the coaching-display prototype (test builds only, like CueDisplay.swift). Every
// line is synthetic, generic work talk: no real people, companies or recordings.
//
// "Harness" timelines were recorded from ListenMoreHarness (draft PR #30) run offline: the real
// CoachSession / LocalCoachEngine / GptLayer pipeline on synthetic voices, scripted transcription
// and a judge that always says "none". Line times are the harness's placed lines; cue times and
// onsets are what the session showed. Paced: the shipped cue policy. Before pacing: the same run
// with `cues.cooldown_s` and `cues.global_cooldown_s` at 0, to see what the rules raise.

public extension CueTimeline {
    static let all: [CueTimeline] = [harnessBusy, harnessBusyBeforePacing, harnessInterruption, harnessMissedQuestion,
                                     harnessMonologue, syntheticBurst]

    static func named(_ id: String) -> CueTimeline? { all.first { $0.id == id } }

    private static func line(_ own: Bool, _ start: TimeInterval, _ end: TimeInterval, _ text: String) -> CueCaptionLine {
        CueCaptionLine(own: own, start: start, end: end, text: text)
    }

    /// A cut-in, an unanswered question, a talk-over and a long run in under two minutes.
    private static let busyLines: [CueCaptionLine] = [
        line(false, 0.50, 10.50, "Let us go over the launch checklist, the first item is the data migration and the second item is the support docs for the new screens."),
        line(true, 6.50, 12.65, "Sorry, quick one, the support docs are already done so we can skip that part entirely."),
        line(false, 13.65, 16.73, "Okay. Which date works for the dry run?"),
        line(true, 17.73, 24.27, "I also want to look at the dashboard colours and the export button before anything else ships."),
        line(false, 26.27, 27.27, "Right, but the dry run"),
        line(true, 26.87, 27.87, "No wait"),
        line(false, 27.77, 28.57, "We need a date"),
        line(true, 28.37, 94.37, "Let me finish, the colours matter because people read the charts every morning and the export button is how they share the numbers with the rest of the team. If the colours are wrong the whole page looks broken, and if the export is slow they stop using it and go back to the old spreadsheet, which is what happened last time. So my plan is to fix the colours first, then the export, then look at the dry run once those two are solid, and I think that order saves us a week of back and forth. We can also ask the support team to try the new screens on the same day so the docs and the screens line up with each other. That way nothing ships half done and we do not have to explain the gaps to anyone afterwards."),
        line(false, 96.37, 97.52, "Thanks, that helps."),
    ]

    /// Harness, shipped policy: the missed question at 24.5 s was held (global cooldown, 16.8 s
    /// after the interrupt), so the display sees three cues at least 20 s apart.
    static let harnessBusy = CueTimeline(
        id: "harness-busy", title: "Harness: busy call (shipped pacing)", origin: .harness(paced: true), duration: 98,
        captions: busyLines,
        events: [
            CueEvent(t: 7.72, onset: 6.50, kind: .interrupt),
            CueEvent(t: 29.58, onset: 28.36, kind: .talkOver),
            CueEvent(t: 77.72, onset: 77.72, kind: .monologue, level: .soft),
        ],
        moments: [8.5, 14, 30.5, 78.5])

    /// Harness, cooldowns 0: the missed question comes through, 5.1 s before a talk-over that asks
    /// the opposite (answer, then stop talking).
    static let harnessBusyBeforePacing = CueTimeline(
        id: "harness-busy-raw", title: "Harness: busy call (before pacing)", origin: .harness(paced: false), duration: 98,
        captions: busyLines,
        events: [
            CueEvent(t: 7.72, onset: 6.50, kind: .interrupt),
            CueEvent(t: 24.50, onset: 24.30, kind: .missedQuestion, level: .soft),
            CueEvent(t: 29.58, onset: 28.36, kind: .talkOver),
            CueEvent(t: 77.72, onset: 77.72, kind: .monologue, level: .soft),
        ],
        moments: [8.5, 25.5, 30.5, 35])

    static let harnessInterruption = CueTimeline(
        id: "harness-interruption", title: "Harness: interruption", origin: .harness(paced: true), duration: 27,
        captions: [
            line(true, 0.50, 3.19, "Morning, thanks for making time for this."),
            line(false, 5.19, 16.73, "Sure. So the plan for the next sprint is to finish the import screen first, then spend the rest of the week on the settings page and the error states."),
            line(true, 7.19, 7.59, "Yeah."),
            line(true, 13.23, 20.92, "Sorry, can I jump in here, I think the settings page has to come first because it blocks the rest."),
            line(false, 22.92, 26.77, "Fair point, let us move the settings page up then."),
        ],
        events: [CueEvent(t: 14.44, onset: 13.22, kind: .interrupt)],
        moments: [8, 15, 21])

    static let harnessMissedQuestion = CueTimeline(
        id: "harness-missed-question", title: "Harness: missed question", origin: .harness(paced: true), duration: 41,
        captions: [
            line(false, 0.50, 4.35, "Did the build pass on the release branch this morning?"),
            line(true, 5.35, 7.65, "Yes, it passed, everything is green."),
            line(false, 22.65, 26.50, "Good. What date should we pick for the customer pilot?"),
            line(true, 27.50, 34.81, "I was thinking we should also tidy up the onboarding emails and move the team lunch to the afternoon."),
            line(false, 37.31, 40.38, "Okay, let us come back to that later."),
        ],
        events: [CueEvent(t: 35.04, onset: 34.84, kind: .missedQuestion, level: .soft)],
        moments: [8, 35.5, 40.5])

    static let harnessMonologue = CueTimeline(
        id: "harness-monologue", title: "Harness: monologue", origin: .harness(paced: true), duration: 86,
        captions: [
            line(false, 0.50, 5.88, "Please give me the full picture of the rollout plan for the new dashboard."),
            line(true, 7.38, 81.62, "So the rollout has three stages and I want to walk through each of them properly. The first stage is an internal preview, where the dashboard is turned on for our own team only, and we watch the error rates and the load times for about a week. During that week we also collect notes on anything confusing in the layout, because the first impression matters a lot for a tool people open every morning. The second stage is a small group of friendly accounts who have already asked for better reporting. They get the dashboard behind a flag, and we check in with them after a few days to see which charts they actually use and which ones they ignore. That feedback decides what we polish and what we cut before the wider launch. The third stage is the general release, which we would do in waves of about a quarter of the accounts at a time, so that support is never flooded on a single day. Each wave waits until the previous one has been quiet for at least two days, and the old reports stay available until nobody uses them."),
            line(false, 83.62, 85.54, "Thanks, that is really helpful."),
        ],
        events: [CueEvent(t: 67.40, onset: 67.38, kind: .monologue, level: .soft)],
        moments: [30, 68, 80])

    /// Synthetic: five cues in six seconds, more than the shipped policy ever lets through (it keeps
    /// cues 20 s apart), to show what each option does if a config or judge provider allows a burst.
    static let syntheticBurst = CueTimeline(
        id: "synthetic-burst", title: "Synthetic: burst of five cues in 6 s", origin: .synthetic, duration: 50,
        captions: [
            line(false, 0.50, 8.60, "Next on the list is the release checklist, we still need sign-off on the migration and on the support docs."),
            line(true, 7.60, 10.20, "Sorry, the docs are fine, I checked them yesterday."),
            line(false, 9.60, 11.00, "Wait, which docs do you mean?"),
            line(true, 10.00, 44.00, "The ones for the new screens, and honestly this always turns into a mess because nobody reads the checklist until the last day, so I would rather we ship it now and fix the gaps afterwards, the way we did on the last two releases, and then we can talk about the migration once the screens are out and people have actually used them for a week."),
            line(false, 46.00, 49.00, "Okay, let us take that offline."),
        ],
        events: [
            CueEvent(t: 9.0, onset: 7.6, kind: .interrupt),
            CueEvent(t: 10.6, onset: 10.0, kind: .talkOver),
            CueEvent(t: 12.0, onset: 11.8, kind: .missedQuestion, level: .soft),
            CueEvent(t: 13.5, onset: 13.3, kind: .aggressive),
            CueEvent(t: 15.0, onset: 14.8, kind: .notListening),
            CueEvent(t: 40.5, onset: 40.0, kind: .monologue, level: .soft),
        ],
        moments: [9.5, 12.5, 16, 19.5, 25])
}
#endif
