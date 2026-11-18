import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Who is writing a spool, so recovery can tell a live call from a crashed one: the machine, the
/// boot, and the process with its start time (a PID alone is reused, often within a reboot).
public struct ProcessIdentity: Sendable {
    /// A hash of the machine's hardware UUID (`gethostuuid`) or `/etc/machine-id`: stable across
    /// networks and renames, different per machine, and not the ID itself. nil when unavailable.
    public var device: String?
    /// This boot (macOS `kern.bootsessionuuid`, Linux `boot_id`); nil when unavailable.
    public var boot: String?
    public var pid: Int32
    /// A process's start time, or nil when it isn't running.
    public var startTime: @Sendable (Int32) -> String?

    public init(device: String?, boot: String?, pid: Int32, startTime: @escaping @Sendable (Int32) -> String?) {
        self.device = device
        self.boot = boot
        self.pid = pid
        self.startTime = startTime
    }

    public static let current = ProcessIdentity(device: machineDevice(), boot: bootSession(), pid: getpid(), startTime: processStartTime)

    static func machineDevice() -> String? {
        #if canImport(Darwin)
        var id = [UInt8](repeating: 0, count: 16)
        var wait = timespec(tv_sec: 0, tv_nsec: 0)
        guard gethostuuid(&id, &wait) == 0, id.contains(where: { $0 != 0 }) else { return nil }
        let raw = id.map { String(format: "%02x", $0) }.joined()
        #else
        guard let raw = firstLine("/etc/machine-id"), !raw.isEmpty else { return nil }
        #endif
        return String(noteHash("meetingcard-device:" + raw).prefix(16))
    }

    static func bootSession() -> String? {
        #if canImport(Darwin)
        return sysctlString("kern.bootsessionuuid")
        #else
        return firstLine("/proc/sys/kernel/random/boot_id")
        #endif
    }

    @Sendable static func processStartTime(_ pid: Int32) -> String? {
        #if canImport(Darwin)
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let t = info.kp_proc.p_un.__p_starttime
        return "\(t.tv_sec).\(t.tv_usec)"
        #else
        // Field 22 (start time in clock ticks since boot), counted after the command name's ")".
        guard let stat = firstLine("/proc/\(pid)/stat"), let close = stat.lastIndex(of: ")") else { return nil }
        let fields = stat[stat.index(after: close)...].split(separator: " ")
        return fields.count > 19 ? String(fields[19]) : nil
        #endif
    }

    #if canImport(Darwin)
    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        let s = String(cString: buf)
        return s.isEmpty ? nil : s
    }
    #endif

    static func firstLine(_ path: String) -> String? {
        guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return s.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Whether a spool from this device may still be written by the process named in it: not after
    /// a reboot, not by this process (its recorder would have skipped it), and only by a process
    /// with that PID that started when the spool's writer did.
    func mayBeWriting(boot otherBoot: String?, pid: Int32?, startTime started: String?) -> Bool {
        if let otherBoot, let boot, otherBoot != boot { return false }
        guard let pid, pid != self.pid else { return false }
        if let started { return startTime(pid) == started }
        return startTime(pid) != nil
    }
}
