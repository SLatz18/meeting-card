import Foundation

/// Why the coach's Mute control can't act right now.
public enum MuteUnavailableReason: String, Equatable, Sendable {
    /// "Use Zoom/Meet controls" is off.
    case toggleOff
    /// Accessibility isn't granted (or was revoked).
    case permissionDenied
    /// Zoom isn't in a meeting.
    case noZoomCall
    /// The call is in Google Meet, which has no mute action here: mute from Meet.
    case meet
}

public enum MuteActionResult: Equatable, Sendable {
    /// Zoom's Mute/Unmute item was pressed once.
    case pressed
    /// The model queued that one press; the state follows the next Zoom reading.
    case requested
    case unavailable(MuteUnavailableReason)
    /// The press didn't go through (Zoom busy or changed its menu).
    case failed
}

/// What a host's Mute control shows and does (the card and pill host it; no UI here). The mute
/// state is Zoom's own reading (`CallState.muted`), read again right after a press. Muting is only
/// ever Zoom's own Mute/Unmute item, pressed once: never synthesized input, and never stopping
/// the coach's own audio capture. Meet has no mute action (`canMute` false, reason `.meet`).
public final class CallControlsModel {
    public let provider: CallControlsProvider
    private let zoom: ZoomControlsReader?
    private let sessionAppKey: () -> String?
    private let deliver: (@escaping () -> Void) -> Void
    /// Called (via `deliver`) after a press has been read back, and on `refresh()`.
    public var onChange: (() -> Void)?
    /// The last press's outcome, set (via `deliver`) once it has been read back.
    public private(set) var lastResult: MuteActionResult?

    static let meetAppKeys: Set<String> = ["com.google.chrome", "company.thebrowser.dia"]

    /// - Parameters:
    ///   - sessionAppKey: the coach session's call app (lowercased bundle ID), if any.
    ///   - deliver: where `onChange` runs (the main queue for a UI host; tests run it inline).
    public init(provider: CallControlsProvider, sessionAppKey: @escaping () -> String? = { nil },
                deliver: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
        self.provider = provider
        zoom = provider.readers.lazy.compactMap { $0 as? ZoomControlsReader }.first
        self.sessionAppKey = sessionAppKey
        self.deliver = deliver
    }

    /// Zoom reports its mic muted.
    public var isMuted: Bool { provider.currentStates[ZoomControlsReader.bundleId] == .muted }

    public var canMute: Bool { muteUnavailableReason == nil }

    public var muteUnavailableReason: MuteUnavailableReason? {
        guard provider.isEnabled, let zoom else { return .toggleOff }
        let states = provider.currentStates
        let zoomInCall = states[zoom.appKey] == .started || states[zoom.appKey] == .muted
        let callApp = sessionAppKey()?.lowercased()
            ?? (zoomInCall ? zoom.appKey : states.first { Self.meetAppKeys.contains($0.key) && $0.value != .ended }?.key)
        if let callApp, Self.meetAppKeys.contains(callApp) { return .meet }
        guard zoom.isTrusted else { return .permissionDenied }
        guard zoomInCall else { return .noZoomCall }
        return nil
    }

    /// One press on Zoom's Mute/Unmute item per call, when `canMute`; otherwise a no-op that says why.
    @discardableResult
    public func toggleMute() -> MuteActionResult {
        if let reason = muteUnavailableReason { return .unavailable(reason) }
        guard let zoom else { return .unavailable(.toggleOff) }
        let provider = provider
        provider.perform { [weak self] in
            let result = zoom.toggleMute()
            provider.refresh()
            self?.deliver {
                self?.lastResult = result
                self?.onChange?()
            }
        }
        return .requested
    }

    /// Tell the host to re-read the state (e.g. on its own refresh tick).
    public func refresh() {
        deliver { [weak self] in self?.onChange?() }
    }
}
