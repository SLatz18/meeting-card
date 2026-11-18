import Foundation

/// The scripted calls. Every line is synthetic, generic work talk written for the harness: no real
/// people, companies or recordings. Each script triggers the cue rule it is named for and avoids
/// the others: turns start at least 4 s apart (no talk-over), Them asks a question only where the
/// missed-question rule is under test, and closing phrases appear only at the end of a call.
public enum Scenarios {
    public static let all: [Scenario] = [
        interruption, monologue, missedQuestion, muteUnmute, pause, silenceToStop, twoThemVoices, noKey, costCap,
    ]

    public static func named(_ name: String) -> Scenario? { all.first { $0.name == name } }

    /// A short backchannel over Them (no cue), then a real cut-in: Them keeps talking for 3.5 s after You start.
    public static let interruption = Scenario(
        name: "interruption",
        summary: "backchannel over Them gives no cue; a cut-in while Them keeps talking gives one interrupt",
        lines: interruptionLines)

    static let interruptionLines: [Line] = [
        Line("y1", .you, "Morning, thanks for making time for this.", .at(0.5)),
        Line("a1", .themA, "Sure. So the plan for the next sprint is to finish the import screen first, then spend the rest of the week on the settings page and the error states.", .after("y1", gap: 2.0)),
        Line("y2", .you, "Yeah.", .into("a1", offset: 2.0), seconds: 0.4),
        Line("y3", .you, "Sorry, can I jump in here, I think the settings page has to come first because it blocks the rest.", .beforeEnd("a1", lead: 3.5)),
        Line("a2", .themA, "Fair point, let us move the settings page up then.", .after("y3", gap: 2.0)),
    ]

    /// One long run by You after Them asks for the plan: the soft monologue cue at 60 s.
    public static let monologue = Scenario(
        name: "monologue",
        summary: "You hold the floor for over 60 s: one soft monologue cue at the 60 s mark",
        lines: [
            Line("a1", .themA, "Please give me the full picture of the rollout plan for the new dashboard.", .at(0.5)),
            Line("y1", .you, """
                So the rollout has three stages and I want to walk through each of them properly. \
                The first stage is an internal preview, where the dashboard is turned on for our own team only, and we watch the error rates and the load times for about a week. \
                During that week we also collect notes on anything confusing in the layout, because the first impression matters a lot for a tool people open every morning. \
                The second stage is a small group of friendly accounts who have already asked for better reporting. \
                They get the dashboard behind a flag, and we check in with them after a few days to see which charts they actually use and which ones they ignore. \
                That feedback decides what we polish and what we cut before the wider launch. \
                The third stage is the general release, which we would do in waves of about a quarter of the accounts at a time, so that support is never flooded on a single day. \
                Each wave waits until the previous one has been quiet for at least two days, and the old reports stay available until nobody uses them.
                """, .after("a1", gap: 1.5)),
            Line("a2", .themA, "Thanks, that is really helpful.", .after("y1", gap: 2.0)),
        ])

    /// A question You answer directly (no cue), then one You talk past (soft missed question). The
    /// transcript is saved and deleted mid-call (T4 during a call).
    public static let missedQuestion = Scenario(
        name: "missed-question",
        summary: "answered question gives no cue; an unanswered one gives one soft missed-question cue; transcript deleted mid-call",
        lines: [
            Line("a1", .themA, "Did the build pass on the release branch this morning?", .at(0.5)),
            Line("y1", .you, "Yes, it passed, everything is green.", .after("a1", gap: 1.0)),
            Line("a2", .themA, "Good. What date should we pick for the customer pilot?", .after("y1", gap: 15.0)),
            Line("y2", .you, "I was thinking we should also tidy up the onboarding emails and move the team lunch to the afternoon.", .after("a2", gap: 1.0)),
            Line("a3", .themA, "Okay, let us come back to that later.", .after("y2", gap: 2.5)),
        ],
        controls: [Control(.deleteTranscript, .after("y1", gap: 3.0))],
        saving: true,
        checks: [.deleteMidCall])

    /// The coach's Mute mid-call: You talk over Them and Them asks a question while muted (nothing),
    /// You speak 0.3 s after Unmute while Them talks (inside `local.unmute_grace_s`: nothing), then a
    /// real cut-in after the grace (one interrupt). Saved transcript on, deleted at teardown.
    public static let muteUnmute = Scenario(
        name: "mute-unmute",
        summary: "muted: no mic frames, no You lines, Them captions continue; no cue inside the unmute grace; one interrupt after it",
        lines: [
            Line("a1", .themA, "Let me share where the migration stands before we decide anything.", .at(0.5)),
            Line("y1", .you, "Sounds good, go ahead.", .after("a1", gap: 1.5)),
            Line("a2", .themA, "We moved the first two services last week and the third one is halfway done, the database is the risky part and needs another pass.", .after("y1", gap: 3.0)),
            Line("y2", .you, "Hold on, I want to argue with that because I am not sure the database is the risky part at all.", .beforeEnd("a2", lead: 6.0)),
            Line("a3", .themA, "What do you think about moving the demo to next week?", .after("a2", gap: 1.5)),
            Line("a4", .themA, "Either way we can settle it on the next call, I just want the whole picture written down first.", .after("a3", gap: 2.0)),
            Line("y4", .you, "Sorry, I was on mute, give me one second to find my notes on this.", .into("a4", offset: 2.3)),
            Line("a5", .themA, "No problem. While you look, the rollback steps are already written up in the shared folder and the team has reviewed them twice.", .after("y4", gap: 3.0)),
            Line("y5", .you, "Wait, before you go on, the rollback steps were written for the old setup and they need another review.", .beforeEnd("a5", lead: 4.0)),
        ],
        controls: [
            Control(.mute, .after("y1", gap: 2.0)),
            Control(.unmute, .into("a4", offset: 2.0)),
        ],
        saving: true,
        checks: [.muteWindow])

    /// Pause mid-call: a cut-in while paused gives nothing and no audio reaches the engine; after
    /// Resume a cut-in gives one interrupt.
    public static let pause = Scenario(
        name: "pause",
        summary: "paused: no frames, no traffic, no captions, no cues; one interrupt after Resume",
        lines: [
            Line("a1", .themA, "Quick update on the hiring loop, we have three candidates for the platform role.", .at(0.5)),
            Line("y1", .you, "Nice, that is more than I expected.", .after("a1", gap: 1.5)),
            Line("a2", .themA, "The first one has a strong background in data tooling and the second one comes from a small team that built a payments system.", .after("y1", gap: 3.0)),
            Line("y2", .you, "Hang on, I think we should talk about the third one first because the timing is tight.", .beforeEnd("a2", lead: 6.0)),
            Line("a3", .themA, "The third candidate can start soon, and the interviews would wrap up by the end of the month if we move quickly.", .after("a2", gap: 3.0)),
            Line("y3", .you, "Sorry to cut in, but if the third one can start soon we should book that interview first.", .beforeEnd("a3", lead: 4.0)),
        ],
        controls: [
            Control(.pause, .after("y1", gap: 2.0)),
            Control(.resume, .after("a2", gap: 1.5)),
        ],
        checks: [.pauseWindow])

    /// The call app stops running audio: the session ends `trigger.stop_after_s` (30 s) later, not
    /// sooner; captions go with it. Keep-nothing: saving off.
    public static let silenceToStop = Scenario(
        name: "silence-to-stop",
        summary: "call audio stops: session ends 30 s later (not sooner), captions cleared, nothing persisted",
        lines: [
            Line("a1", .themA, "That covers everything on my list for today.", .at(0.5)),
            Line("y1", .you, "Same here, thanks for the update.", .after("a1", gap: 1.5)),
            Line("a2", .themA, "Great, talk soon and take care.", .after("y1", gap: 1.5)),
        ],
        controls: [Control(.callEnds, .after("a2", gap: 1.0))],
        checks: [.silenceStop],
        tail: 33)

    /// Two distinct Them voices on the call stream, and a speaker tag for Them mid-call (X4).
    public static let twoThemVoices = Scenario(
        name: "two-them-voices",
        summary: "two Them voices on the call stream (engine: by stream, no diarization); Them renamed mid-call",
        lines: [
            Line("a1", .themA, "I can take the first part of the review and cover the test plan.", .at(0.5)),
            Line("b1", .themB, "And I will cover the release notes and the support handover after that.", .after("a1", gap: 1.5)),
            Line("y1", .you, "Great, that split works for me.", .after("b1", gap: 1.5)),
            Line("a2", .themA, "The test plan is mostly done, only the upgrade path is still open.", .after("y1", gap: 2.0)),
            Line("b2", .themB, "The release notes need one more pass before they go out.", .after("a2", gap: 1.5)),
            Line("y2", .you, "Sounds good, send them over when they are ready.", .after("b2", gap: 1.5)),
        ],
        controls: [
            Control(.renameThem, .after("y1", gap: 1.0), tag: "Guest"),
            Control(.stopCoach, .after("y2", gap: 2.0)),
        ],
        saving: true,
        checks: [.twoThemVoices],
        tail: 2)

    /// No key: the local layer alone (X3). The interruption script: one interrupt, no captions, no traffic.
    public static let noKey = Scenario(
        name: "no-key",
        summary: "no key: local cues only (one interrupt), captions unavailable, no network",
        lines: interruptionLines,
        keyless: true,
        checks: [.noKey])

    /// A tiny `budget_usd_per_call` (T5): transcription stops at the cap, captions say so, local cues continue.
    public static let costCap = Scenario(
        name: "cost-cap",
        summary: "budget cap reached: captions stop, the local interrupt still fires",
        lines: [
            Line("a1", .themA, "Here is the short version of the budget review for this quarter.", .at(0.5)),
            Line("y1", .you, "Okay, go on.", .after("a1", gap: 1.5)),
            Line("a2", .themA, "Most of the spend went to the hosting contract and the rest went to tooling and travel for the offsite.", .after("y1", gap: 1.5)),
            Line("y2", .you, "Sorry to jump in, the hosting number looks far too high for what we actually use.", .beforeEnd("a2", lead: 4.0)),
        ],
        saving: true,
        budgetUsd: 0.002,
        checks: [.costCap])
}
