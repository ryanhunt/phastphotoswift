import Darwin
import Foundation
import os

/// The app's memory as the system counts it: `phys_footprint` is what Xcode's memory gauge shows and what the
/// jetsam limit is checked against.
enum MemoryMeter {
    private static func vmInfo() -> task_vm_info_data_t? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info : nil
    }

    /// Current physical footprint in bytes.
    static func footprint() -> UInt64 { vmInfo()?.phys_footprint ?? 0 }

    /// Highest footprint since launch, in bytes.
    static func lifetimePeak() -> UInt64 { UInt64(max(0, vmInfo()?.ledger_phys_footprint_peak ?? 0)) }

    /// The most the app may use before iOS ends it (0 on the simulator and macOS).
    static func available() -> UInt64 { UInt64(os_proc_available_memory()) }

    static func megabytes(_ bytes: UInt64) -> String { String(format: "%.0f MB", Double(bytes) / 1_048_576) }
}

/// Samples the footprint on its own thread every few milliseconds until stopped, and keeps the highest
/// reading. A thread rather than a task, so it keeps sampling while the pipeline's synchronous pixel loops
/// hold the cooperative pool.
final class PeakSampler: Sendable {
    private struct State {
        var running = true
        var peak: UInt64 = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    let start: UInt64

    init(interval: TimeInterval = 0.005) {
        start = MemoryMeter.footprint()
        state.withLock { $0.peak = start }
        let state = self.state
        let thread = Thread {
            while true {
                let now = MemoryMeter.footprint()
                let running = state.withLock { s in
                    s.peak = max(s.peak, now)
                    return s.running
                }
                guard running else { return }
                Thread.sleep(forTimeInterval: interval)
            }
        }
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Stops sampling and returns the peak, including one last reading.
    func stop() -> UInt64 {
        let now = MemoryMeter.footprint()
        return state.withLock { s in
            s.running = false
            s.peak = max(s.peak, now)
            return s.peak
        }
    }
}
