import Foundation

// MARK: - Metric identity

enum MetricKind: String, CaseIterable, Identifiable, Codable {
    case cpu
    case gpu
    case memory
    case disk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .memory: return "内存"
        case .disk: return "磁盘"
        }
    }

    var englishTitle: String {
        switch self {
        case .cpu: return "Processor"
        case .gpu: return "Graphics"
        case .memory: return "Memory"
        case .disk: return "Storage"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: return "cpu"
        case .gpu: return "square.stack.3d.up"
        case .memory: return "memorychip"
        case .disk: return "internaldrive"
        }
    }
}

struct HistoryPoint: Identifiable, Equatable {
    let id = UUID()
    let time: Date
    let value: Double

    static func == (lhs: HistoryPoint, rhs: HistoryPoint) -> Bool {
        lhs.time == rhs.time && lhs.value == rhs.value
    }
}

struct MetricHistory {
    private(set) var points: [HistoryPoint] = []
    var capacity: Int = 120
    var window: TimeInterval = 60

    mutating func append(_ value: Double, at time: Date = Date()) {
        guard value.isFinite else { return }
        points.append(HistoryPoint(time: time, value: max(0, min(100, value))))
        let cutoff = time.addingTimeInterval(-window)
        while let first = points.first, first.time < cutoff {
            points.removeFirst()
        }
        if points.count > capacity {
            points.removeFirst(points.count - capacity)
        }
    }

    var latest: Double? { points.last?.value }

    var average: Double? {
        guard !points.isEmpty else { return nil }
        return points.map(\.value).reduce(0, +) / Double(points.count)
    }

    var peak: Double? {
        points.map(\.value).max()
    }
}

// MARK: - Snapshot

struct MemoryMetrics {
    var totalBytes: Int64
    var usedBytes: Int64
    var activeBytes: Int64
    var inactiveBytes: Int64
    var wiredBytes: Int64
    var compressedBytes: Int64
    var cachedBytes: Int64
    var freeBytes: Int64
    var swapUsedBytes: Int64
    var swapTotalBytes: Int64

    var percent: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes) * 100
    }

    static let empty = MemoryMetrics(
        totalBytes: 0, usedBytes: 0, activeBytes: 0, inactiveBytes: 0,
        wiredBytes: 0, compressedBytes: 0, cachedBytes: 0, freeBytes: 0,
        swapUsedBytes: 0, swapTotalBytes: 0
    )
}

struct DiskMetrics {
    var totalBytes: Int64
    var usedBytes: Int64
    var freeBytes: Int64

    var percent: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes) * 100
    }

    static let empty = DiskMetrics(totalBytes: 0, usedBytes: 0, freeBytes: 0)
}

struct CPUMetrics {
    var usage: Double
    var perCore: [Double]

    static let empty = CPUMetrics(usage: 0, perCore: [])
}

struct GPUMetrics {
    var usage: Double?
    var memoryBytes: Int64?
    var name: String?
    var isAvailable: Bool

    static let empty = GPUMetrics(usage: nil, memoryBytes: nil, name: nil, isAvailable: false)
}

enum PowerUnit: String, CaseIterable, Identifiable {
    case watt
    case btu

    var id: String { rawValue }
    var title: String {
        switch self {
        case .watt: return "瓦特 (W)"
        case .btu: return "BTU/h"
        }
    }
    var shortTitle: String {
        switch self {
        case .watt: return "W"
        case .btu: return "BTU/h"
        }
    }
}
enum PowerSource: String, Codable {
    case alternatingCurrent
    case battery
    case unknown

    var isOnAC: Bool { self == .alternatingCurrent }
}

struct PowerMetrics: Equatable {
    var source: PowerSource
    /// Total power the computer is consuming right now, in watts.
    var systemWatts: Double?
    /// Power arriving from the adapter / wall supply, in watts.
    var inputWatts: Double?
    /// Part of the input that directly powers the computer, in watts.
    var supplyWatts: Double?
    /// Part of the input that is charging the battery, in watts.
    var chargeWatts: Double?
    /// Battery-only discharge power, in watts.
    var dischargeWatts: Double?
    var batteryPercent: Double
    var isCharging: Bool
    var isFullyCharged: Bool
    var timeRemainingMinutes: Int?
    var timeToFullMinutes: Int?
    var adapterWatts: Int?
    var batteryHealthPercent: Double?
    var cycleCount: Int?
    var temperatureCelsius: Double?
    var voltageVolts: Double?
    var amperageAmps: Double?
    var isSplitEstimated: Bool
    var dataSource: String
    var hasBattery: Bool = true

    var isPowerWarning: Bool {
        if let temperatureCelsius, temperatureCelsius >= 42 { return true }
        if source == .battery, let systemWatts, systemWatts >= 35 { return true }
        return false
    }

    static let empty = PowerMetrics(
        source: .unknown,
        systemWatts: nil,
        inputWatts: nil,
        supplyWatts: nil,
        chargeWatts: nil,
        dischargeWatts: nil,
        batteryPercent: 0,
        isCharging: false,
        isFullyCharged: false,
        timeRemainingMinutes: nil,
        timeToFullMinutes: nil,
        adapterWatts: nil,
        batteryHealthPercent: nil,
        cycleCount: nil,
        temperatureCelsius: nil,
        voltageVolts: nil,
        amperageAmps: nil,
        isSplitEstimated: true,
        dataSource: "—"
    )
}

struct SystemSnapshot {
    var cpu: CPUMetrics = .empty
    var gpu: GPUMetrics = .empty
    var memory: MemoryMetrics = .empty
    var disk: DiskMetrics = .empty
    var power: PowerMetrics = .empty
    var uptime: TimeInterval = 0
    var timestamp: Date = Date()

    var highestLoad: Double {
        // Disk capacity is a long-lived state, not momentary load. Keep it out
        // of the menu-bar colour/health calculation so an always-67%-full disk
        // does not permanently paint the icon amber.
        [cpu.usage, memory.percent, gpu.usage ?? 0].max() ?? 0
    }

    var healthLevel: HealthLevel {
        let value = highestLoad
        if value >= 85 { return .critical }
        if value >= 60 { return .elevated }
        return .calm
    }
}

enum HealthLevel {
    case calm
    case elevated
    case critical

    var label: String {
        switch self {
        case .calm: return "一切平稳"
        case .elevated: return "有点忙"
        case .critical: return "需要留意"
        }
    }
}

// MARK: - Process details

struct ProcessUsage: Identifiable, Equatable {
    let id: Int32
    let name: String
    let cpuPercent: Double
    let memoryBytes: Int64

    var shortName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ProcessDetails {
    var topCPU: [ProcessUsage] = []
    var topMemory: [ProcessUsage] = []
    var updatedAt: Date?
    var error: String?
}

// MARK: - Index scanning

struct IndexCategory: Identifiable, Codable, Equatable {
    var id: String { path }
    let name: String
    let path: String
    var bytes: Int64
    var fileCount: Int
    var accessible: Bool
    var note: String?
}

struct IndexScanResult: Codable, Equatable {
    var totalBytes: Int64
    var categories: [IndexCategory]
    var scannedFiles: Int
    var completedAt: Date
    var permissionLimited: Bool
    var errorMessage: String?
    /// Whether the Spotlight index was measured through a user-approved
    /// administrator call to `mdutil -L`.
    var adminSpotlightUsed: Bool? = nil
    /// macOS 26/27 protect `.Spotlight-V100` even from Full Disk Access; the
    /// UI offers a separate administrator-assisted read.
    var spotlightNeedsAdmin: Bool? = nil
    var adminErrorMessage: String? = nil

    static let empty = IndexScanResult(
        totalBytes: 0,
        categories: [],
        scannedFiles: 0,
        completedAt: .distantPast,
        permissionLimited: false,
        errorMessage: nil
    )

    var hasData: Bool { completedAt != .distantPast && (totalBytes > 0 || !permissionLimited) }
}

// MARK: - Storage anomalies

enum StorageChangeDirection: String, Codable {
    case increase
    case decrease
}

struct StorageChange: Identifiable, Codable, Equatable {
    var id: String { "\(path)-\(changedAt.timeIntervalSince1970)" }
    let path: String
    let isDirectory: Bool
    let beforeBytes: Int64
    let afterBytes: Int64
    let changedAt: Date
    let detectionNote: String?

    var deltaBytes: Int64 { afterBytes - beforeBytes }
    var direction: StorageChangeDirection { deltaBytes >= 0 ? .increase : .decrease }
    var displayName: String { (path as NSString).lastPathComponent }
    var parentPath: String { (path as NSString).deletingLastPathComponent }
}

struct AnomalyReport: Codable, Equatable {
    var scannedAt: Date
    var previousScanAt: Date?
    var thresholdBytes: Int64
    var entries: [StorageChange]
    var totalIncreaseBytes: Int64
    var totalDecreaseBytes: Int64
    var scannedFiles: Int
    var permissionLimited: Bool
    var isBaseline: Bool

    static let empty = AnomalyReport(
        scannedAt: .distantPast,
        previousScanAt: nil,
        thresholdBytes: 500 * 1024 * 1024,
        entries: [],
        totalIncreaseBytes: 0,
        totalDecreaseBytes: 0,
        scannedFiles: 0,
        permissionLimited: false,
        isBaseline: false
    )

    var hasFindings: Bool { !entries.isEmpty }
    var isToday: Bool { Calendar.current.isDateInToday(scannedAt) }

    var notificationSummary: String {
        let increases = entries.filter { $0.direction == .increase }.count
        let decreases = entries.count - increases
        var pieces: [String] = []
        if increases > 0 { pieces.append("\(increases) 个增加") }
        if decreases > 0 { pieces.append("\(decreases) 个减少") }
        let net = totalIncreaseBytes - totalDecreaseBytes
        let direction = net >= 0 ? "共增加" : "共减少"
        return "检测到 \(entries.count) 个文件或目录导致存储空间异常变化，\(direction) \(Fmt.bytes(abs(net)))（\(pieces.joined(separator: "、"))）"
    }
}

struct StorageScanProgress {
    var phase: Phase
    var scannedFiles: Int
    var currentPath: String?

    enum Phase: Equatable {
        case idle
        case scanning
        case comparing
        case finished
    }

    static let idle = StorageScanProgress(phase: .idle, scannedFiles: 0, currentPath: nil)
}

// MARK: - Mock data

enum DemoData {
    static let now = Date()

    static func history(base: Double, spread: Double, count: Int = 31) -> MetricHistory {
        var result = MetricHistory()
        for i in 0..<count {
            let wave = sin(Double(i) * 0.52) * spread + cos(Double(i) * 0.17) * spread * 0.45
            result.append(max(2, min(99, base + wave)), at: now.addingTimeInterval(Double(i - count) * 2))
        }
        return result
    }

    static var snapshot: SystemSnapshot {
        SystemSnapshot(
            cpu: CPUMetrics(usage: 27, perCore: [18, 31, 44, 22, 17, 35, 28, 12]),
            gpu: GPUMetrics(usage: 18, memoryBytes: 1_450_000_000, name: "Apple M2", isAvailable: true),
            memory: MemoryMetrics(
                totalBytes: 8 * 1_073_741_824,
                usedBytes: 5_100_000_000,
                activeBytes: 2_900_000_000,
                inactiveBytes: 1_300_000_000,
                wiredBytes: 1_500_000_000,
                compressedBytes: 700_000_000,
                cachedBytes: 2_100_000_000,
                freeBytes: 1_600_000_000,
                swapUsedBytes: 120_000_000,
                swapTotalBytes: 1_073_741_824
            ),
            disk: DiskMetrics(
                totalBytes: 245_107_000_000,
                usedBytes: 130_200_000_000,
                freeBytes: 114_900_000_000
            ),
            power: PowerMetrics(
                source: .alternatingCurrent,
                systemWatts: 12.4,
                inputWatts: 21.8,
                supplyWatts: 12.4,
                chargeWatts: 9.4,
                dischargeWatts: nil,
                batteryPercent: 78,
                isCharging: true,
                isFullyCharged: false,
                timeRemainingMinutes: nil,
                timeToFullMinutes: 64,
                adapterWatts: 65,
                batteryHealthPercent: 87.2,
                cycleCount: 175,
                temperatureCelsius: 30.6,
                voltageVolts: 12.9,
                amperageAmps: 0.73,
                isSplitEstimated: false,
                dataSource: "AppleSmartBattery · PowerTelemetry"
            ),
            uptime: 86_400 * 3 + 7_200,
            timestamp: now
        )
    }

    static var indexResult: IndexScanResult {
        IndexScanResult(
            totalBytes: 3_450_000_000,
            categories: [
                IndexCategory(name: "Spotlight 索引", path: "/System/Volumes/Data/.Spotlight-V100", bytes: 2_600_000_000, fileCount: 1_624, accessible: true, note: nil),
                IndexCategory(name: "FSEvents 日志", path: "/System/Volumes/Data/.fseventsd", bytes: 620_000_000, fileCount: 3_802, accessible: true, note: nil),
                IndexCategory(name: "Spotlight 数据库", path: "/private/var/db/Spotlight", bytes: 230_000_000, fileCount: 94, accessible: true, note: nil)
            ],
            scannedFiles: 5_520,
            completedAt: now.addingTimeInterval(-220),
            permissionLimited: false,
            errorMessage: nil
        )
    }

    static var report: AnomalyReport {
        let entries = [
            StorageChange(path: "/Users/example/Downloads/Xcode_16.2.xip", isDirectory: false, beforeBytes: 0, afterBytes: 3_400_000_000, changedAt: now.addingTimeInterval(-1_620), detectionNote: "新增大文件"),
            StorageChange(path: "/Users/example/Library/Caches/com.apple.Photos", isDirectory: true, beforeBytes: 4_800_000_000, afterBytes: 5_650_000_000, changedAt: now.addingTimeInterval(-2_040), detectionNote: "目录体积增加"),
            StorageChange(path: "/Users/example/Movies/screen-recording.mov", isDirectory: false, beforeBytes: 900_000_000, afterBytes: 210_000_000, changedAt: now.addingTimeInterval(-3_800), detectionNote: "文件缩小"),
            StorageChange(path: "/Users/example/Library/Application Support/Comet/cache.db", isDirectory: false, beforeBytes: 1_200_000_000, afterBytes: 2_300_000_000, changedAt: now.addingTimeInterval(-4_500), detectionNote: "文件体积增加")
        ]
        return AnomalyReport(
            scannedAt: now.addingTimeInterval(-2_400),
            previousScanAt: now.addingTimeInterval(-86_400 - 2_400),
            thresholdBytes: 500 * 1024 * 1024,
            entries: entries,
            totalIncreaseBytes: 5_350_000_000,
            totalDecreaseBytes: 690_000_000,
            scannedFiles: 183_420,
            permissionLimited: false,
            isBaseline: false
        )
    }

    static var processes: ProcessDetails {
        ProcessDetails(
            topCPU: [
                ProcessUsage(id: 721, name: "Xcode", cpuPercent: 38.2, memoryBytes: 1_400_000_000),
                ProcessUsage(id: 982, name: "Cursor", cpuPercent: 21.8, memoryBytes: 980_000_000),
                ProcessUsage(id: 427, name: "WindowServer", cpuPercent: 9.4, memoryBytes: 420_000_000),
                ProcessUsage(id: 1002, name: "ClaudeMonitor", cpuPercent: 2.6, memoryBytes: 68_000_000),
                ProcessUsage(id: 311, name: "Spotlight", cpuPercent: 1.9, memoryBytes: 130_000_000)
            ],
            topMemory: [
                ProcessUsage(id: 721, name: "Xcode", cpuPercent: 38.2, memoryBytes: 1_400_000_000),
                ProcessUsage(id: 982, name: "Cursor", cpuPercent: 21.8, memoryBytes: 980_000_000),
                ProcessUsage(id: 427, name: "WindowServer", cpuPercent: 9.4, memoryBytes: 420_000_000),
                ProcessUsage(id: 154, name: "Safari", cpuPercent: 1.1, memoryBytes: 310_000_000),
                ProcessUsage(id: 1002, name: "ClaudeMonitor", cpuPercent: 2.6, memoryBytes: 68_000_000)
            ],
            updatedAt: now,
            error: nil
        )
    }
}
