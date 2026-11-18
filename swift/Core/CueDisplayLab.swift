#if canImport(SwiftUI) && (DEBUG || MEETINGCARD_TEST_ID)
import Combine
import SwiftUI

/// The test build's lab: pick an option, a timeline, card or pill, light or dark, then play or
/// scrub the timeline and watch the card. Below it, what the display did with each cue. Shows only:
/// no call, no audio, nothing saved.
public struct CueDisplayLabView: View {
    public enum Appearance: String, CaseIterable, Sendable { case system, light, dark }

    @State private var option = CueDisplayOption.rotatingLine
    @State private var timelineID = CueTimeline.harnessBusy.id
    @State private var mode = CueDisplaySurface.Mode.card
    @State private var hover = false
    @State private var appearance = Appearance.system
    @State private var t: TimeInterval = 0
    @State private var playing = false
    @State private var speed: Double = 1
    @Environment(\.colorScheme) private var systemScheme

    private let timer = Timer.publish(every: CueDisplayLabPlayback.tick, on: .main, in: .common).autoconnect()

    public init() {}

    private var timeline: CueTimeline { CueTimeline.named(timelineID) ?? .harnessBusy }

    private var scheme: ColorScheme {
        switch appearance {
        case .system: systemScheme
        case .light: .light
        case .dark: .dark
        }
    }

    public var body: some View {
        let copy = CueDisplayCopy.Lab.self
        let d = Theme.CueDisplay.self
        let style = CardStyle.for(dark: scheme == .dark)
        let display = CueDisplayPacer.frame(at: t, events: timeline.events)
        VStack(alignment: .leading, spacing: Theme.Settings.groupSpacing) {
            Picker(copy.option, selection: $option) {
                ForEach(CueDisplayOption.allCases) { Text(copy.name($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker(copy.timeline, selection: $timelineID) {
                ForEach(CueTimeline.all) { Text($0.title).tag($0.id) }
            }
            HStack {
                Picker(copy.surface, selection: $mode) {
                    Text(copy.card).tag(CueDisplaySurface.Mode.card)
                    Text(copy.pill).tag(CueDisplaySurface.Mode.pill)
                }
                .pickerStyle(.segmented)
                Picker(copy.appearance, selection: $appearance) {
                    Text(copy.system).tag(Appearance.system)
                    Text(copy.light).tag(Appearance.light)
                    Text(copy.dark).tag(Appearance.dark)
                }
                .pickerStyle(.segmented)
            }
            Toggle(copy.hover, isOn: $hover)
            CueDisplaySurface(option: option, timeline: timeline, t: t, mode: mode, hover: hover)
                .padding(Theme.CueDisplay.snapshotPadding)
                .frame(maxWidth: .infinity, minHeight: Theme.CoachCard.height + 2 * Theme.CueDisplay.snapshotPadding)
                .background(Theme.CueDisplay.backdrop(style: style).swiftUI)
                .environment(\.colorScheme, scheme)
            HStack {
                Button(playing ? copy.pause : copy.play) {
                    if t >= timeline.duration { t = 0 }
                    playing.toggle()
                }
                Button(copy.restart) {
                    t = 0
                    playing = false
                }
                Slider(value: $t, in: 0...timeline.duration)
                    .accessibilityLabel(copy.position)
                    .accessibilityValue(copy.time(t))
                Text(copy.time(t)).monospacedDigit()
                Picker(copy.speed, selection: $speed) {
                    ForEach(CueDisplayLabPlayback.speeds, id: \.self) { Text(copy.speedValue($0)).tag($0) }
                }
                .fixedSize()
            }
            Text(copy.gap(CueDisplayPacing.minNewCueGap))
                .font(d.labHelpFont.swiftUI)
                .foregroundStyle(d.labHelpText.shapeStyle(style))
            Text(copy.log)
                .font(d.labHeadingFont.swiftUI)
                .foregroundStyle(d.labHeadingText.shapeStyle(style))
                .accessibilityAddTraits(.isHeader)
            ScrollView {
                VStack(alignment: .leading) {
                    ForEach(Array(display.decisions.enumerated()), id: \.offset) { _, d in
                        Text(copy.describe(d)).monospacedDigit()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: Theme.CoachCard.height)
            Text(copy.note)
                .font(d.labNoteFont.swiftUI)
                .foregroundStyle(d.labNoteText.shapeStyle(style))
        }
        .frame(minWidth: Theme.CoachCard.width + 2 * d.snapshotPadding)
        .padding(Theme.Settings.inset)
        .onReceive(timer) { _ in
            guard playing else { return }
            t = min(timeline.duration, t + CueDisplayLabPlayback.tick * speed)
            if t >= timeline.duration { playing = false }
        }
        .onChange(of: timelineID) {
            t = 0
            playing = false
        }
    }
}
#endif
