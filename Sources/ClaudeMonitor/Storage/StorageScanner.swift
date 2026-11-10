import Foundation

// MARK: - Snapshot models

struct StorageFileRecord: Codable, Equatable {
    let size: Int64
    let modifiedAt: Date
}

struct StorageBaseline: Codable, Equatable {
    var createdAt: Date
    var roots: [String]
    var files: [String: StorageFileRecord]
    var directories: [String: Int64]
    var totalBytes: Int64
    var scannedFiles: Int
    var permissionLimited: Bool
}

struct StorageScanOutput {
    let baseline: StorageBaseline
    let scannedFiles: Int
    let permissionLimited: Bool
}

// MARK: - Scanner

/// Daily anomaly scan.
///
/// Walking every file on a large volume is expensive, so the scanner:
///  * enumerates a curated set of user-facing roots,
///  * skips caches/containers/iCloud/redundant hidden indexes,
///  * stores individual files >= 10 MB,
///  * stores directory aggregates only to depth 2 and only above 20 MB,
///  * yields progress off the main thread.
///
/// Directory aggregates catch growth made of many small files while the
/// per-file records provide precise paths for large-file anomalies.
final class StorageScanner: @unchecked Sendable {
    private let bridge = CStorageScanBridge()
    static let fileRecordMinimum: Int64 = 10 * 1_048_576
    static let directoryRecordMinimum: Int64 = 20 * 1_048_576

    static var defaultRoots: [String] {
        let home = NSHomeDirectory()
        return [home, "/Applications", "/Library", "/private/var/db", "/private/var/log"]
    }

    private var excludedPrefixes: [String] = {
        let home = NSHomeDirectory()
        return [
            home + "/Library/Caches",
            home + "/Library/Containers",
            home + "/Library/Group Containers",
            home + "/Library/CloudStorage",
            home + "/Library/Mobile Documents",
            home + "/Library/Application Support/ClaudeMonitor",
            home + "/.Trash",
            "/Library/Caches",
            "/private/var/vm",
            "/private/var/folders",
            "/private/var/db/Spotlight",
            "/private/var/db/diagnostics",
            "/private/var/db/uuidtext",
            "/private/tmp",
            "/private/var/tmp",
            "/System/Volumes/Data/.Spotlight-V100",
            "/System/Volumes/Data/.fseventsd",
            "/System/Volumes/Data/.DocumentRevisions-V100"
        ]
    }()

    private var excludedNames: Set<String> = [
        ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100",
        ".Trashes", ".TemporaryItems"
    ]

    func scan(
        roots: [String] = StorageScanner.defaultRoots,
        progress: @escaping (Int, String) -> Void
    ) -> StorageScanOutput {
        let output = bridge.scan(
            roots: roots,
            excludedPrefixes: excludedPrefixes,
            excludedNames: Array(excludedNames),
            minFileSize: Self.fileRecordMinimum,
            minDirectorySize: Self.directoryRecordMinimum,
            progress: progress
        )

        let baseline = StorageBaseline(
            createdAt: Date(),
            roots: roots,
            files: output.files,
            directories: output.directories,
            totalBytes: output.totalBytes,
            scannedFiles: output.scannedFiles,
            permissionLimited: output.permissionLimited || output.errorMessage != nil
        )
        return StorageScanOutput(
            baseline: baseline,
            scannedFiles: output.scannedFiles,
            permissionLimited: baseline.permissionLimited
        )
    }


    // MARK: Comparison

    func compare(
        previous: StorageBaseline,
        current: StorageBaseline,
        threshold: Int64,
        scannedAt: Date
    ) -> AnomalyReport {
        let threshold = max(1, threshold)
        var fileChanges: [StorageChange] = []
        var directoryChanges: [StorageChange] = []

        for (path, record) in current.files {
            let before = previous.files[path]?.size ?? 0
            let delta = record.size - before
            guard abs(delta) >= threshold else { continue }
            fileChanges.append(
                StorageChange(
                    path: path,
                    isDirectory: false,
                    beforeBytes: before,
                    afterBytes: record.size,
                    changedAt: record.modifiedAt,
                    detectionNote: before == 0 ? "新增大文件" : (delta >= 0 ? "文件体积增加" : "文件体积减少")
                )
            )
        }

        for (path, before) in previous.files where current.files[path] == nil {
            guard before.size >= threshold else { continue }
            fileChanges.append(
                StorageChange(
                    path: path,
                    isDirectory: false,
                    beforeBytes: before.size,
                    afterBytes: 0,
                    changedAt: scannedAt,
                    detectionNote: "文件被移除或缩小至记录阈值以下"
                )
            )
        }

        for (path, after) in current.directories {
            let before = previous.directories[path] ?? 0
            let delta = after - before
            guard abs(delta) >= threshold else { continue }
            directoryChanges.append(
                StorageChange(
                    path: path,
                    isDirectory: true,
                    beforeBytes: before,
                    afterBytes: after,
                    changedAt: scannedAt,
                    detectionNote: before == 0 ? "目录增长" : (delta >= 0 ? "目录占用增加" : "目录占用减少")
                )
            )
        }

        for (path, before) in previous.directories where current.directories[path] == nil {
            guard before >= threshold else { continue }
            directoryChanges.append(
                StorageChange(
                    path: path,
                    isDirectory: true,
                    beforeBytes: before,
                    afterBytes: 0,
                    changedAt: scannedAt,
                    detectionNote: "目录占用减少"
                )
            )
        }

        fileChanges.sort { abs($0.deltaBytes) > abs($1.deltaBytes) }
        directoryChanges.sort { abs($0.deltaBytes) > abs($1.deltaBytes) }

        var selected: [StorageChange] = []
        // Individual files first: more actionable than a parent folder.
        selected.append(contentsOf: fileChanges.prefix(24))

        let selectedFiles = selected
        for candidate in directoryChanges {
            let descendantDeltas = selectedFiles
                .filter { $0.path.hasPrefix(candidate.path + "/") }
                .map { abs($0.deltaBytes) }
                .reduce(Int64(0), +)
            if descendantDeltas >= Int64(Double(abs(candidate.deltaBytes)) * 0.68) {
                continue
            }
            let coveredBySelectedDirectory = selected.contains { existing in
                existing.isDirectory &&
                    existing.path.hasPrefix(candidate.path + "/") &&
                    abs(existing.deltaBytes) >= Int64(Double(abs(candidate.deltaBytes)) * 0.68)
            }
            if coveredBySelectedDirectory { continue }
            selected.append(candidate)
        }

        selected.sort { abs($0.deltaBytes) > abs($1.deltaBytes) }
        let entries = Array(selected.prefix(40))
        let increase = entries.filter { $0.deltaBytes > 0 }.map(\.deltaBytes).reduce(0, +)
        let decrease = entries.filter { $0.deltaBytes < 0 }.map { -$0.deltaBytes }.reduce(0, +)

        return AnomalyReport(
            scannedAt: scannedAt,
            previousScanAt: previous.createdAt,
            thresholdBytes: threshold,
            entries: entries,
            totalIncreaseBytes: increase,
            totalDecreaseBytes: decrease,
            scannedFiles: current.scannedFiles,
            permissionLimited: current.permissionLimited,
            isBaseline: false
        )
    }
}

// MARK: - Persistence

final class SnapshotStore: @unchecked Sendable {
    private let directoryURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()

    init(
        directoryURL: URL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("ClaudeMonitor", isDirectory: true)
    ) {
        self.directoryURL = directoryURL
        encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    private var baselineURL: URL { directoryURL.appendingPathComponent("storage-baseline.json") }
    private var reportURL: URL { directoryURL.appendingPathComponent("anomaly-report.json") }

    func loadBaseline() -> StorageBaseline? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: baselineURL) else { return nil }
        return try? decoder.decode(StorageBaseline.self, from: data)
    }

    func saveBaseline(_ baseline: StorageBaseline) throws {
        lock.lock()
        defer { lock.unlock() }
        try ensureDirectory()
        let data = try encoder.encode(baseline)
        try data.write(to: baselineURL, options: .atomic)
    }

    func loadReport() -> AnomalyReport? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: reportURL) else { return nil }
        return try? decoder.decode(AnomalyReport.self, from: data)
    }

    func saveReport(_ report: AnomalyReport) throws {
        lock.lock()
        defer { lock.unlock() }
        try ensureDirectory()
        let data = try encoder.encode(report)
        try data.write(to: reportURL, options: .atomic)
    }

    func resetBaseline() throws {
        lock.lock()
        defer { lock.unlock() }
        if fileManager.fileExists(atPath: baselineURL.path) {
            try fileManager.removeItem(at: baselineURL)
        }
        if fileManager.fileExists(atPath: reportURL.path) {
            try fileManager.removeItem(at: reportURL)
        }
    }

    private var indexURL: URL { directoryURL.appendingPathComponent("index-result.json") }

    func loadIndexResult() -> IndexScanResult? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: indexURL) else { return nil }
        return try? decoder.decode(IndexScanResult.self, from: data)
    }

    func saveIndexResult(_ result: IndexScanResult) throws {
        lock.lock()
        defer { lock.unlock() }
        try ensureDirectory()
        let data = try encoder.encode(result)
        try data.write(to: indexURL, options: .atomic)
    }

    private var fileManager: FileManager { FileManager.default }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }
}
