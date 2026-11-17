import Foundation

/// One row of the process table the shell builds from NSWorkspace + sysctl. `bundleId` is nil for
/// processes without a bundle.
public struct ProcessEntry: Equatable, Sendable {
    public var pid: Int32
    public var parentPid: Int32
    public var bundleId: String?

    public init(pid: Int32, parentPid: Int32, bundleId: String?) {
        self.pid = pid
        self.parentPid = parentPid
        self.bundleId = bundleId
    }
}

public enum BundleIds {
    /// True if `bundleId` is `parent` or a dotted child of it, case-insensitively (bundle IDs are
    /// case-insensitive on macOS). `com.google.Chrome.helper.renderer` belongs to `com.google.Chrome`;
    /// `com.google.ChromeX` does not.
    public static func belongs(_ bundleId: String, to parent: String) -> Bool {
        let b = bundleId.lowercased(), p = parent.lowercased()
        return b == p || b.hasPrefix(p + ".")
    }

    /// Map an app or helper bundle ID to its capture target.
    public static func resolveParent(_ bundleId: String, targets: [CaptureTarget]) -> CaptureTarget? {
        targets.first { belongs(bundleId, to: $0.bundleId) }
    }

    /// For apps outside the allowlist: drop a Chromium/Electron-style helper suffix so a helper groups
    /// with its app (`com.example.app.helper.renderer` -> `com.example.app`). Lowercased.
    public static func stripHelperSuffix(_ bundleId: String) -> String {
        let b = bundleId.lowercased()
        if let r = b.range(of: ".helper") { return String(b[..<r.lowerBound]) }
        return b
    }
}

/// Chromium helper-process fallback: Chrome and Dia render audio in helper processes. If capturing
/// the parent app misses their audio, find the helpers by bundle-ID prefix (`<parent>.helper*`, any
/// dotted suffix) or by walking parent PIDs up to the app's PID.
public enum HelperProcessMatcher {
    public static func helpers(of target: CaptureTarget, in table: [ProcessEntry], maxDepth: Int = 8) -> [ProcessEntry] {
        let parent = target.bundleId.lowercased()
        let byPid = Dictionary(table.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let appPids = Set(table.filter { $0.bundleId?.lowercased() == parent }.map(\.pid))

        func descendsFromApp(_ p: ProcessEntry) -> Bool {
            var cur = p.parentPid
            for _ in 0..<maxDepth {
                if appPids.contains(cur) { return true }
                guard cur > 1, let next = byPid[cur] else { return false }
                cur = next.parentPid
            }
            return false
        }

        return table.filter { p in
            if appPids.contains(p.pid) { return false }
            if let b = p.bundleId?.lowercased(), b.hasPrefix(parent + ".") { return true }
            return descendsFromApp(p)
        }
    }

    /// Nearest ancestor (or self) with a bundle ID, for processes Core Audio reports without one.
    public static func owningBundleId(pid: Int32, in table: [ProcessEntry], maxDepth: Int = 8) -> String? {
        let byPid = Dictionary(table.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var cur = pid
        for _ in 0...maxDepth {
            guard let e = byPid[cur] else { return nil }
            if let b = e.bundleId, !b.isEmpty { return b }
            guard e.parentPid > 1 else { return nil }
            cur = e.parentPid
        }
        return nil
    }
}
