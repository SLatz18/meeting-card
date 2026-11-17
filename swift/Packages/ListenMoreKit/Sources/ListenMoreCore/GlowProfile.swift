import Foundation

/// Shape and motion of the edge glow. Values come from the app's Theme; this type only does math.
public struct GlowProfile: Equatable, Sendable {
    public struct Stop: Equatable, Sendable {
        /// Distance from the outer screen edge as a fraction of `width`.
        public var at: Double
        public var opacityFactor: Double
        public init(_ at: Double, _ opacityFactor: Double) { self.at = at; self.opacityFactor = opacityFactor }
    }

    public struct Motion: Equatable, Sendable {
        public var rise: Double
        public var hold: Double
        public var fade: Double
        /// Opacity (as a fraction of peak) the glow appears at; 0 means it rises from nothing.
        public var appearFactor: Double
        public var easeRise: Bool
        public var easeFade: Bool
        public var total: Double { rise + hold + fade }

        public init(rise: Double, hold: Double, fade: Double, appearFactor: Double, easeRise: Bool, easeFade: Bool) {
            self.rise = rise
            self.hold = hold
            self.fade = fade
            self.appearFactor = appearFactor
            self.easeRise = easeRise
            self.easeFade = easeFade
        }
    }

    public var width: Double
    public var peakOpacity: Double
    /// Peak opacity while the system's Increase Contrast is on; nil = `peakOpacity`.
    public var increasedContrastPeakOpacity: Double?
    public var cornerRadius: Double
    public var stops: [Stop]
    public var motion: Motion
    public var reduceMotion: Motion

    public init(width: Double, peakOpacity: Double, increasedContrastPeakOpacity: Double? = nil, cornerRadius: Double,
                stops: [Stop], motion: Motion, reduceMotion: Motion) {
        self.width = width
        self.peakOpacity = peakOpacity
        self.increasedContrastPeakOpacity = increasedContrastPeakOpacity
        self.cornerRadius = cornerRadius
        self.stops = stops
        self.motion = motion
        self.reduceMotion = reduceMotion
    }

    /// Opacity factor at `fraction` of the band width (piecewise linear between stops).
    public func factor(at fraction: Double) -> Double {
        guard let first = stops.first, let last = stops.last else { return 0 }
        if fraction <= first.at { return first.opacityFactor }
        if fraction >= last.at { return last.opacityFactor }
        for (a, b) in zip(stops, stops.dropFirst()) where fraction <= b.at {
            let t = (fraction - a.at) / max(b.at - a.at, 1e-9)
            return a.opacityFactor + (b.opacityFactor - a.opacityFactor) * t
        }
        return last.opacityFactor
    }

    public func motion(reduce: Bool) -> Motion { reduce ? reduceMotion : motion }

    public func peak(increaseContrast: Bool) -> Double {
        increaseContrast ? increasedContrastPeakOpacity ?? peakOpacity : peakOpacity
    }

    /// Panel opacity `t` seconds into a cue (for tests and snapshots; the panel animates with the
    /// same timings). Ease-in = cubic-bezier(0.42,0,1,1), ease-out = (0,0,0.58,1), approximated.
    public func opacity(at t: Double, reduce: Bool, increaseContrast: Bool = false) -> Double {
        let m = motion(reduce: reduce)
        let peak = peak(increaseContrast: increaseContrast)
        if t < 0 { return 0 }
        if t < m.rise {
            let x = t / m.rise
            return peak * (m.appearFactor + (1 - m.appearFactor) * (m.easeRise ? x * x : x))
        }
        let start = m.rise == 0 ? peak * m.appearFactor : peak
        if t < m.rise + m.hold { return start }
        if t < m.total {
            let x = (t - m.rise - m.hold) / m.fade
            let k = m.easeFade ? 1 - (1 - x) * (1 - x) : x
            return start * (1 - k)
        }
        return 0
    }
}
