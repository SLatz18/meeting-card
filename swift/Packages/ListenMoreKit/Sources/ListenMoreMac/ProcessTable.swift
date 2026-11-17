import AppKit
import Darwin
import ListenMoreCore

/// Builds the pid / ppid / bundle-ID table `HelperProcessMatcher` works on. Bundle IDs come from
/// NSWorkspace (helpers are usually listed there too); parent PIDs come from sysctl(KERN_PROC_ALL).
enum ProcessTable {
    static func snapshot() -> [ProcessEntry] {
        var bundleByPid: [pid_t: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            if let b = app.bundleIdentifier { bundleByPid[app.processIdentifier] = b }
        }
        return parentPids().map { pid, ppid in
            ProcessEntry(pid: pid, parentPid: ppid, bundleId: bundleByPid[pid])
        }
    }

    static func parentPids() -> [(pid_t, pid_t)] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        // The table can grow between the two calls.
        size += size / 8
        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, UInt32(mib.count), &procs, &size, nil, 0) == 0 else { return [] }
        let n = size / MemoryLayout<kinfo_proc>.stride
        return procs.prefix(n).map { ($0.kp_proc.p_pid, $0.kp_eproc.e_ppid) }
    }
}
