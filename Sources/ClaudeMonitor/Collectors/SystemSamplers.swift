import Foundation
import Darwin
import MachO

/// Samples aggregate and per-core CPU load from Mach host statistics.
/// No privileges or helper processes are required.
final class CPUSampler: @unchecked Sendable {
    private var previousTicks: [CoreTicks] = []
    private let lock = NSLock()

    init() {
        // Establish a tick baseline so the first visible sample already has a
        // meaningful delta instead of a brief 0%.
        _ = sample()
    }

    struct CoreTicks {
        var user: UInt64 = 0
        var system: UInt64 = 0
        var idle: UInt64 = 0
        var nice: UInt64 = 0

        var total: UInt64 { user + system + idle + nice }
        var busy: UInt64 { user + system + nice }
    }

    func sample() -> CPUMetrics {
        var cpuInfo: processor_info_array_t?
        var cpuInfoCount: mach_msg_type_number_t = 0
        var cpuCount: natural_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &cpuCount,
            &cpuInfo,
            &cpuInfoCount
        )

        guard result == KERN_SUCCESS, let cpuInfo, cpuCount > 0 else {
            return .empty
        }
        defer {
            let size = vm_size_t(cpuInfoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo), size)
        }

        let stateCount = Int(CPU_STATE_MAX)
        var current: [CoreTicks] = []
        current.reserveCapacity(Int(cpuCount))

        for core in 0..<Int(cpuCount) {
            let offset = core * stateCount
            let user = UInt64(cpuInfo[offset + Int(CPU_STATE_USER)])
            let system = UInt64(cpuInfo[offset + Int(CPU_STATE_SYSTEM)])
            let idle = UInt64(cpuInfo[offset + Int(CPU_STATE_IDLE)])
            let nice = UInt64(cpuInfo[offset + Int(CPU_STATE_NICE)])
            current.append(CoreTicks(user: user, system: system, idle: idle, nice: nice))
        }

        lock.lock()
        let previous = previousTicks
        previousTicks = current
        lock.unlock()

        guard previous.count == current.count else {
            return CPUMetrics(usage: 0, perCore: Array(repeating: 0, count: current.count))
        }

        var perCore: [Double] = []
        var totalDelta: UInt64 = 0
        var busyDelta: UInt64 = 0

        for index in current.indices {
            let total = current[index].total >= previous[index].total
                ? current[index].total - previous[index].total : 0
            let busy = current[index].busy >= previous[index].busy
                ? current[index].busy - previous[index].busy : 0
            totalDelta += total
            busyDelta += busy
            perCore.append(total > 0 ? min(100, Double(busy) / Double(total) * 100) : 0)
        }

        let usage = totalDelta > 0 ? min(100, Double(busyDelta) / Double(totalDelta) * 100) : 0
        return CPUMetrics(usage: usage, perCore: perCore)
    }
}

/// Memory uses the same primitives as Activity Monitor's "Memory Used":
/// active + wired + compressed pages. Inactive pages remain reclaimable.
final class MemorySampler: @unchecked Sendable {
    func sample() -> MemoryMetrics {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )

        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }

        guard result == KERN_SUCCESS else { return .empty }

        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let page = Int64(pageSize)
        let total = Int64(ProcessInfo.processInfo.physicalMemory)

        let active = Int64(stats.active_count) * page
        let inactive = Int64(stats.inactive_count) * page
        let wired = Int64(stats.wire_count) * page
        let compressed = Int64(stats.compressor_page_count) * page
        let speculative = Int64(stats.speculative_count) * page
        let purgeable = Int64(stats.purgeable_count) * page

        let used = min(total, active + wired + compressed)
        let cached = inactive + speculative + purgeable
        let swap = Self.swapUsage()

        return MemoryMetrics(
            totalBytes: total,
            usedBytes: used,
            activeBytes: active,
            inactiveBytes: inactive,
            wiredBytes: wired,
            compressedBytes: compressed,
            cachedBytes: cached,
            freeBytes: max(0, total - used),
            swapUsedBytes: swap.used,
            swapTotalBytes: swap.total
        )
    }

    private static func swapUsage() -> (used: Int64, total: Int64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let result = sysctlbyname("vm.swapusage", &usage, &size, nil, 0)
        guard result == 0 else { return (0, 0) }
        return (Int64(usage.xsu_used), Int64(usage.xsu_total))
    }
}

/// Disk usage for the root volume. `volumeAvailableCapacityForImportantUsage`
/// is intentionally not used for the headline number because it includes
/// purgeable space and would under-report actual occupancy.
final class DiskSampler: @unchecked Sendable {
    func sample() -> DiskMetrics {
        let root = URL(fileURLWithPath: "/")
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey
        ]

        if let values = try? root.resourceValues(forKeys: keys),
           let total = values.volumeTotalCapacity,
           let available = values.volumeAvailableCapacity,
           total > 0 {
            let totalBytes = Int64(total)
            let freeBytes = Int64(max(0, available))
            return DiskMetrics(
                totalBytes: totalBytes,
                usedBytes: max(0, totalBytes - freeBytes),
                freeBytes: freeBytes
            )
        }

        if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: "/"),
           let total = attributes[.systemSize] as? NSNumber,
           let free = attributes[.systemFreeSize] as? NSNumber {
            let totalBytes = total.int64Value
            let freeBytes = free.int64Value
            return DiskMetrics(
                totalBytes: totalBytes,
                usedBytes: max(0, totalBytes - freeBytes),
                freeBytes: freeBytes
            )
        }

        return .empty
    }
}
