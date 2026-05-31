import Foundation
import Darwin

/// A point-in-time view of system memory used for the preload budget gate and
/// the transparency surfaces (Settings caption, web state).
struct SystemMemorySnapshot: Equatable {
    /// Bytes considered reclaimable/free right now (free + inactive + purgeable).
    let availableBytes: Int
    /// Total physical RAM.
    let totalBytes: Int
}

/// Injectable source of memory snapshots so tests stay deterministic.
protocol SystemMemoryProviding {
    func snapshot() -> SystemMemorySnapshot
}

/// Live provider backed by Mach `host_statistics64` and `ProcessInfo`.
struct HostSystemMemoryProvider: SystemMemoryProviding {
    func snapshot() -> SystemMemorySnapshot {
        let total = Int(ProcessInfo.processInfo.physicalMemory)

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let host = mach_host_self()
        let result = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(host, HOST_VM_INFO64, intPtr, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            // Conservative fallback: report no headroom so the gate skips
            // rather than risking an over-commit on a bad reading.
            return SystemMemorySnapshot(availableBytes: 0, totalBytes: total)
        }

        let pageSize = Int(vm_kernel_page_size)
        let freePages = Int(stats.free_count)
        let inactivePages = Int(stats.inactive_count)
        let purgeablePages = Int(stats.purgeable_count)
        let available = (freePages + inactivePages + purgeablePages) * pageSize

        return SystemMemorySnapshot(availableBytes: available, totalBytes: total)
    }
}
