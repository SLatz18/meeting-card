import Foundation

/// The coach's look, owned by the host: colors, band shape and timing. MeetingCard passes its theme;
/// the standalone listen-more app builds one from its config (`mac_app_style`). The Kit never invents
/// colors or timing.
public struct CoachStyle: Equatable, Sendable {
    public struct RGBA: Equatable, Sendable {
        public var red: Double
        public var green: Double
        public var blue: Double
        public var alpha: Double

        public init(red: Double, green: Double, blue: Double, alpha: Double) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }

        /// `#RRGGBB` or `#RRGGBBAA`.
        public init?(hex: String) {
            var s = hex.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("#") { s.removeFirst() }
            guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
            let full = s.count == 6 ? (v << 8) | 0xFF : v
            red = Double((full >> 24) & 0xFF) / 255
            green = Double((full >> 16) & 0xFF) / 255
            blue = Double((full >> 8) & 0xFF) / 255
            alpha = Double(full & 0xFF) / 255
        }
    }

    /// How the host shows that a cue type is cooling down (the 20 s per-type cooldown is behaviour and
    /// stays in config; only its presentation is themed).
    public enum CooldownDisplay: String, Equatable, Sendable {
        /// Not shown.
        case hidden
        /// The host shows remaining seconds (standalone app: a menu line). Read `CoachSession.cooldowns()`.
        case menu
    }

    /// Glow color per cue tone (red = cut-in / talk-over / aggressive, amber = the softer cues).
    public var colors: [CueColor: RGBA]
    /// Band shape and motion (rise, hold, fade, Reduce Motion variant).
    public var profile: GlowProfile
    public var cooldownDisplay: CooldownDisplay

    public init(colors: [CueColor: RGBA], profile: GlowProfile, cooldownDisplay: CooldownDisplay) {
        self.colors = colors
        self.profile = profile
        self.cooldownDisplay = cooldownDisplay
    }

    /// A plain band: full color at the edge fading linearly to clear over `bandWidth`, fading in over
    /// `fadeIn` and out over `fadeOut` (Reduce Motion: appear at peak, same fade-out).
    public init(colors: [CueColor: RGBA], fadeIn: TimeInterval, fadeOut: TimeInterval, bandWidth: Double,
                cooldownDisplay: CooldownDisplay) {
        let motion = GlowProfile.Motion(rise: fadeIn, hold: 0, fade: fadeOut, appearFactor: 0, easeRise: true, easeFade: true)
        let reduce = GlowProfile.Motion(rise: 0, hold: 0, fade: fadeOut, appearFactor: 1, easeRise: false, easeFade: false)
        self.init(colors: colors,
                  profile: GlowProfile(width: bandWidth, peakOpacity: 1, cornerRadius: 0,
                                       stops: [.init(0, 1), .init(1, 0)], motion: motion, reduceMotion: reduce),
                  cooldownDisplay: cooldownDisplay)
    }

    public var fadeIn: TimeInterval { profile.motion.rise }
    /// The slow fade-out after a cue (~3 s).
    public var fadeOut: TimeInterval { profile.motion.fade }
    /// Width of the glow band along each screen edge, in points.
    public var bandWidth: Double { profile.width }

    /// Color for a tone; a host theme missing one falls back to the other tone, never to a Kit color.
    public func color(for tone: CueColor) -> RGBA? {
        colors[tone] ?? colors.values.first
    }
}
