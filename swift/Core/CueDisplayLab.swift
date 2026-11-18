#if canImport(SwiftUI) && (DEBUG || MEETINGCARD_TEST_ID)
import Combine
import SwiftUI

/// The test build's lab: pick an option, a timeline, card or pill, light or dark, then play or
/// scrub the timeline and watch the card. Below it, what the display did with each cue. Shows only:
/// no call, no audio, nothing saved.
public struct CueDisplayLabView: View {
    public enum Appearance: String, CaseIterable, Sendable { case system, light, dark }

    /// Playback step, and the speeds offered.
    static let tick: TimeInterval = 0.1
    static let speeds: [Double] = [1, 2, 4]

    @State private var option = CueDisplayOption.rotatingLine
    @State private var timelineID = CueTimeline.harnessBusy.id
    @State private var mode = CueDisplaySurface.Mode.card
    @State private var hover = false
    @State private var appearance = Appearance.system
    @State private var t: TimeInterval = 0
    @State private var playing = false
    @State private var speed: Double = 1
    @Environment(\.colorScheme) private var systemScheme

    private let timer = Timer.publish(every: CueDisplayLabView.tick, on: .main, in: .common).autoconnect()

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
                Text(String(format: "%.1f s", t)).monospacedDigit()
                Picker(copy.speed, selection: $speed) {
                    ForEach(Self.speeds, id: \.self) { Text("\(Int($0))×").tag($0) }
                }
                .fixedSize()
            }
            Text(copy.gap(CueDisplayPacing.minNewCueGap)).foregroundStyle(.secondary)
            Text(copy.log).font(.headline)
            ScrollView {
                VStack(alignment: .leading) {
                    ForEach(Array(display.decisions.enumerated()), id: \.offset) { _, d in
                        Text(copy.describe(d)).monospacedDigit()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: Theme.CoachCard.height)
            Text(copy.note).font(.footnote).foregroundStyle(.tertiary)
        }
        .padding()
        .frame(minWidth: Theme.CoachPill.maxWidth + 2 * Theme.Settings.inset * 2)
        .onReceive(timer) { _ in
            guard playing else { return }
            t = min(timeline.duration, t + Self.tick * speed)
            if t >= timeline.duration { playing = false }
        }
        .onChange(of: timelineID) {
            t = 0
            playing = false
        }
    }
}
#endif
