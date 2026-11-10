import Foundation
import Darwin

/// Process details are read through libproc (`proc_listallpids` +
/// `proc_pid_rusage`). This avoids spawning `/bin/ps`, works without extra
/// entitlements, and reports CPU deltas plus physical footprint.
final class ProcessSampler: @unchecked Sendable {
    private struct Sample {
        var cpuNanoseconds: UInt64
        var timestamp: Date
        var footprint: Int64
        var name: String
    }

    private var previous: [Int32: Sample] = [:]
    private let lock = NSLock()

    func sample() -> ProcessDetails {
        let wasWarm = lock.withLock { !previous.isEmpty }
        let first = collect()
        guard first.updatedAt != nil else { return first }
        guard !wasWarm else { return first }

        // A single rusage snapshot only gives a lifetime average. Wait briefly
        // and take a second snapshot so the expanded CPU list reflects current
        // activity, without spawning `ps`.
        Thread.sleep(forTimeInterval: 0.32)
        return collect()
    }

    private func collect() -> ProcessDetails {
        let listCount = Int(proc_listallpids(nil, 0))
        guard listCount > 0 else {
            return ProcessDetails(topCPU: [], topMemory: [], updatedAt: Date(), error: "无法读取进程列表")
        }

        var pids = [pid_t](repeating: 0, count: max(1_024, listCount + 64))
        let byteCount = Int32(pids.count * MemoryLayout<pid_t>.stride)
        let count = Int(proc_listallpids(&pids, byteCount))
        guard count > 0 else {
            return ProcessDetails(topCPU: [], topMemory: [], updatedAt: Date(), error: "无法读取进程列表")
        }

        let now = Date()
        var current: [Int32: Sample] = [:]
        var usages: [ProcessUsage] = []
        usages.reserveCapacity(count)

        lock.lock()
        let old = previous
        lock.unlock()

        for index in 0..<min(count, pids.count) {
            let pid = pids[index]
            guard pid > 0 else { continue }

            var info = rusage_info_v2()
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                    proc_pid_rusage(pid, RUSAGE_INFO_V2, rebound)
                }
            }
            guard result == 0 else { continue }

            var nameBuffer = [CChar](repeating: 0, count: 512)
            let nameLength = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
            let name = nameLength > 0 ? String(cString: nameBuffer) : "PID \(pid)"
            let cpuNanoseconds = info.ri_user_time + info.ri_system_time
            let footprint = Int64(info.ri_phys_footprint)

            let cpuPercent: Double
            if let oldSample = old[pid], now.timeIntervalSince(oldSample.timestamp) > 0.15 {
                let elapsed = now.timeIntervalSince(oldSample.timestamp) * 1_000_000_000
                let delta = Double(cpuNanoseconds >= oldSample.cpuNanoseconds ? cpuNanoseconds - oldSample.cpuNanoseconds : 0)
                cpuPercent = min(9_999, delta / elapsed * 100)
            } else {
                let elapsed = Self.processLifetime(pid: pid, now: now)
                cpuPercent = elapsed > 0.2 ? min(9_999, Double(cpuNanoseconds) / 1_000_000_000 / elapsed * 100) : 0
            }

            current[pid] = Sample(
                cpuNanoseconds: cpuNanoseconds,
                timestamp: now,
                footprint: footprint,
                name: name
            )
            usages.append(
                ProcessUsage(
                    id: pid,
                    name: name,
                    cpuPercent: cpuPercent,
                    memoryBytes: footprint
                )
            )
        }

        lock.lock()
        previous = current
        lock.unlock()

        let topCPU = usages.sorted { $0.cpuPercent > $1.cpuPercent }
        let topMemory = usages.sorted { $0.memoryBytes > $1.memoryBytes }
        return ProcessDetails(
            topCPU: Array(topCPU.prefix(5)),
            topMemory: Array(topMemory.prefix(5)),
            updatedAt: now,
            error: nil
        )
    }

    private static func processLifetime(pid: Int32, now: Date) -> TimeInterval {
        // `proc_pid_rusage` does not expose the exact start time in a simple
        // date form on every OS release. Use `proc_pidinfo` with BSD info.
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.stride
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size))
        guard result == size else { return 0 }
        let startSeconds = TimeInterval(info.pbi_start_tvsec)
        let startMicro = TimeInterval(info.pbi_start_tvusec) / 1_000_000
        return max(0, now.timeIntervalSince1970 - (startSeconds + startMicro))
    }
}
