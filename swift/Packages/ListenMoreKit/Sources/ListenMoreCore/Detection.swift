import Foundation

/// Swift mirror of `listen_more/detect.py`. Pure function, browser-agnostic: the shell feeds it the
/// visible window titles per owning bundle ID and Core Audio's per-process "is running output"
/// flags (keyed by bundle ID, which for Chromium browsers is usually a helper).
public struct WindowInfo: Equatable, Sendable {
    public var bundleId: String
    public var title: String

    public init(bundleId: String, title: String) {
        self.bundleId = bundleId
        self.title = title
    }
}

public struct Detection: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case zoom
        /// A native meeting app other than Zoom (Teams, Webex, FaceTime, Slack huddle).
        case app
        case meet
    }

    public var active: Bool
    public var kind: Kind?
    public var target: String?
    public var bundleId: String?

    public static let inactive = Detection(active: false)

    public init(active: Bool, kind: Kind? = nil, target: String? = nil, bundleId: String? = nil) {
        self.active = active
        self.kind = kind
        self.target = target
        self.bundleId = bundleId
    }
}

public enum MeetingDetector {
    /// Map an app or helper bundle ID to its capture target (see `BundleIds.resolveParent`).
    public static func resolveParent(_ bundleId: String, targets: [CaptureTarget]) -> CaptureTarget? {
        BundleIds.resolveParent(bundleId, targets: targets)
    }

    public static func detect(windows: [WindowInfo], audioActive: [String: Bool], targets: [CaptureTarget],
                              meetTitleRegex: String = #"\bMeet\b"#) -> Detection {
        let audible = Set(audioActive.filter { $0.value }.keys.compactMap { resolveParent($0, targets: targets)?.bundleId })
        let meetRegex = try? NSRegularExpression(pattern: meetTitleRegex)

        func ownedBy(_ w: WindowInfo, _ t: CaptureTarget) -> Bool {
            resolveParent(w.bundleId, targets: [t]) != nil
        }

        func titleMatches(_ t: CaptureTarget) -> Bool {
            let patterns = (t.meetingTitlePatterns ?? []).map { $0.lowercased() }
            return windows.contains { w in ownedBy(w, t) && patterns.contains { w.title.lowercased().contains($0) } }
        }

        // Zoom desktop first (it owns its audio directly), then other native meeting apps, then browsers.
        for t in targets where t.kind == .zoom && audible.contains(t.bundleId) && titleMatches(t) {
            return Detection(active: true, kind: .zoom, target: t.name, bundleId: t.bundleId)
        }
        for t in targets where t.kind == .native && audible.contains(t.bundleId) && titleMatches(t) {
            return Detection(active: true, kind: .app, target: t.name, bundleId: t.bundleId)
        }
        guard let meetRegex else { return .inactive }
        for t in targets where t.kind == .browser && audible.contains(t.bundleId) {
            if windows.contains(where: { w in ownedBy(w, t) && meetRegex.matches(w.title) }) {
                return Detection(active: true, kind: .meet, target: t.name, bundleId: t.bundleId)
            }
        }
        return .inactive
    }
}

extension NSRegularExpression {
    func matches(_ s: String) -> Bool {
        firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
}
