import Foundation

@main
struct StorageScannerSmoke {
    static func main() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("build/test-temp", isDirectory: true)
            .appendingPathComponent("ClaudeMonitorStorageSmoke-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let scanner = StorageScanner()
        let threshold: Int64 = 5 * 1_048_576

        func write(_ relative: String, megabytes: Int) throws -> URL {
            let url = root.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: megabytes * 1_048_576).write(to: url)
            return url
        }

        let bigFile = try write("big.bin", megabytes: 12)
        _ = try write("small.bin", megabytes: 3)
        let baselineOutput = scanner.scan(roots: [root.path]) { _, _ in }
        precondition(baselineOutput.scannedFiles >= 2)

        // Grow an individual file, remove a small file, and add a new large one.
        try Data(repeating: 0x42, count: 22 * 1_048_576).write(to: bigFile)
        try fm.removeItem(at: root.appendingPathComponent("small.bin"))
        _ = try write("new-large.bin", megabytes: 12)

        let secondOutput = scanner.scan(roots: [root.path]) { _, _ in }
        let report = scanner.compare(
            previous: baselineOutput.baseline,
            current: secondOutput.baseline,
            threshold: threshold,
            scannedAt: Date()
        )
        precondition(report.entries.contains { $0.path.hasSuffix("big.bin") && $0.deltaBytes > 0 })
        precondition(report.entries.contains { $0.path.hasSuffix("new-large.bin") && $0.deltaBytes > 0 })
        precondition(report.totalIncreaseBytes > 0)
        precondition(!report.isBaseline)

        // Directory aggregate: 12 files x 2 MB = 24 MB, each below the per-file
        // snapshot minimum, so only a directory change can be observed.
        let dir = root.appendingPathComponent("many-small", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for index in 0..<12 {
            try Data(repeating: 0x43, count: 2 * 1_048_576)
                .write(to: dir.appendingPathComponent("part-\(index).bin"))
        }
        let thirdOutput = scanner.scan(roots: [root.path]) { _, _ in }
        let dirReport = scanner.compare(
            previous: secondOutput.baseline,
            current: thirdOutput.baseline,
            threshold: threshold,
            scannedAt: Date()
        )
        precondition(dirReport.entries.contains { $0.isDirectory && $0.path.hasSuffix("many-small") })
        precondition(dirReport.totalIncreaseBytes >= threshold)

        // Persistence round-trip.
        let storeURL = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("build/test-temp", isDirectory: true)
            .appendingPathComponent("ClaudeMonitorStoreSmoke-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: storeURL) }
        let store = SnapshotStore(directoryURL: storeURL)
        try store.saveBaseline(thirdOutput.baseline)
        try store.saveReport(dirReport)
        precondition(store.loadBaseline()?.files.count == thirdOutput.baseline.files.count)
        precondition(store.loadReport()?.entries.count == dirReport.entries.count)

        print("StorageScannerSmoke: PASS")
        print(" - file changes: \(report.entries.count)")
        print(" - directory changes: \(dirReport.entries.count)")
        print(" - scanned files: \(thirdOutput.scannedFiles)")
    }
}
