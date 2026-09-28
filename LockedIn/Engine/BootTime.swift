import Darwin
import Foundation

/// When the phone last booted. Used to spot a restart during a locked stretch, which
/// makes that stretch impossible to verify.
nonisolated enum BootTime {
    static func current() -> Date? {
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctl(&mib, 2, &bootTime, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(bootTime.tv_sec) + TimeInterval(bootTime.tv_usec) / 1_000_000)
    }
}
