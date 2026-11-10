import Foundation
import AppKit

// MARK: - Permissions

enum SystemAccess {
    static var hasFullDiskAccess: Bool {
        // The system index directories are root-only on macOS 26/27, so they
        // are NOT a valid proxy for TCC Full Disk Access: they return false
        // even when the app has been granted access. Probe user-owned,
        // TCC-protected databases instead.
        let home = NSHomeDirectory()
        let protectedPaths = [
            home + "/Library/Safari/History.db",
            home + "/Library/Messages/chat.db",
            home + "/Library/Mail",
            "/Library/Application Support/com.apple.TCC/TCC.db"
        ]
        return protectedPaths.contains { path in
            FileManager.default.fileExists(atPath: path)
                && FileManager.default.isReadableFile(atPath: path)
        }
    }

    static func openFullDiskAccessSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
        ]
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    static func openNotificationSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.notifications",
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        ]
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    static func revealInFinder(path: String) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    static func copyToPasteboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}

// MARK: - Index monitor

@MainActor
final class IndexMonitor: ObservableObject {
    @Published private(set) var result: IndexScanResult
    @Published private(set) var isScanning = false
    @Published private(set) var scannedFiles = 0
    @Published private(set) var currentPath: String?
    @Published private(set) var lastError: String?
    @Published private(set) var isWaitingForAdmin = false

    var onScanFinished: (() -> Void)?
    private let scanner = IndexScanner()
    private let store: SnapshotStore
    private let queue = DispatchQueue(label: "com.claudemonitor.index-scan", qos: .utility)
    private var timer: Timer?
    private var generation = UUID()

    init(store: SnapshotStore) {
        self.store = store
        self.result = store.loadIndexResult() ?? .empty
        scheduleAutoScan()
    }

    deinit {
        timer?.invalidate()
    }

    var lastScanDate: Date? {
        result.completedAt == .distantPast ? nil : result.completedAt
    }

    var needsScan: Bool {
        guard let date = lastScanDate else { return true }
        return Date().timeIntervalSince(date) > 6 * 3_600
    }

    func startIfNeeded() {
        let access = SystemAccess.hasFullDiskAccess
        // Older cached results predate the Spotlight/admin fields. Refresh
        // once so the UI can offer the macOS 26/27 administrator path.
        let needsSchemaRefresh = result.permissionLimited && result.spotlightNeedsAdmin == nil
        if needsScan
            || needsSchemaRefresh
            || (access && result.permissionLimited && result.spotlightNeedsAdmin != true) {
            scan()
        }
    }

    /// Explicit user action: macOS asks for an administrator password and the
    /// app reads the Spotlight store via `mdutil -L`. No password is retained.
    func scanWithAdminPrivileges() {
        scan(admin: true)
    }

    /// Preview/renderer hook only.
    func primeForPreview(result: IndexScanResult) {
        self.result = result
    }

    func scan() {
        scan(admin: false)
    }

    private func scan(admin: Bool) {
        guard !isScanning else { return }
        isScanning = true
        isWaitingForAdmin = admin
        lastError = nil
        scannedFiles = 0
        currentPath = nil
        let previous = result
        let scanner = self.scanner
        let store = self.store
        let token = UUID()
        generation = token

        queue.async { [weak self] in
            let rawOutput = scanner.scan(includeAdminSpotlight: admin) { count, path in
                DispatchQueue.main.async {
                    guard let self, self.generation == token, self.isScanning else { return }
                    self.scannedFiles = count
                    self.currentPath = path
                }
            }
            let output = Self.mergeAdminSpotlight(previous: previous, current: rawOutput, allowMerge: !admin)

            var saveError: String?
            do {
                try store.saveIndexResult(output)
            } catch {
                saveError = error.localizedDescription
            }
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.result = output
                self.isScanning = false
                self.isWaitingForAdmin = false
                self.currentPath = nil
                self.lastError = saveError ?? output.adminErrorMessage
                self.onScanFinished?()
            }
        }
    }

    /// A normal 6-hour refresh cannot read Spotlight on macOS 26/27. Keep the
    /// last administrator-read Spotlight measurement instead of replacing it
    /// with "unreadable"; other categories refresh normally.
    nonisolated private static func mergeAdminSpotlight(
        previous: IndexScanResult,
        current: IndexScanResult,
        allowMerge: Bool
    ) -> IndexScanResult {
        guard allowMerge,
              current.adminSpotlightUsed != true,
              current.spotlightNeedsAdmin == true,
              previous.adminSpotlightUsed == true,
              let oldSpotlight = previous.categories.first(where: {
                  $0.path == IndexScanner.spotlightPath && $0.accessible
              }) else {
            return current
        }

        var merged = current
        merged.categories.removeAll { $0.path == IndexScanner.spotlightPath }
        var category = oldSpotlight
        category.note = "上次管理员读取 · \(Fmt.dateTime(previous.completedAt))"
        merged.categories.insert(category, at: 0)
        merged.totalBytes &+= category.bytes
        merged.scannedFiles += category.fileCount
        merged.adminSpotlightUsed = true
        merged.spotlightNeedsAdmin = false
        merged.permissionLimited = merged.categories.contains { !$0.accessible }
        return merged
    }

    private func scheduleAutoScan() {
        timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.needsScan else { return }
                self.scan()
            }
        }
        timer?.tolerance = 60
    }
}

// MARK: - Storage anomaly monitor

@MainActor
final class StorageAnomalyMonitor: ObservableObject {
    enum Trigger {
        case manual
        case scheduled
        case initialBaseline
        case reset
    }

    @Published private(set) var report: AnomalyReport
    @Published private(set) var isScanning = false
    @Published private(set) var progress = StorageScanProgress.idle
    @Published private(set) var baselineDate: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var hasFullDiskAccess = SystemAccess.hasFullDiskAccess
    @Published private(set) var nextScheduledScan: Date?

    /// Called after a scan that produced findings. The app uses this for
    /// notifications and to move the pet into its alert state.
    var onFindings: ((AnomalyReport) -> Void)?
    var onScanFinished: ((AnomalyReport, Trigger) -> Void)?

    private let scanner = StorageScanner()
    private let store: SnapshotStore
    private let settings: AppSettings
    private let queue = DispatchQueue(label: "com.claudemonitor.storage-scan", qos: .utility)
    private var timer: Timer?
    private var generation = UUID()

    init(store: SnapshotStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        self.report = store.loadReport() ?? .empty
        self.baselineDate = store.loadBaseline()?.createdAt
        refreshSchedule()
        scheduleTimer()
    }

    deinit {
        timer?.invalidate()
    }

    func startIfNeeded() {
        hasFullDiskAccess = SystemAccess.hasFullDiskAccess
        if baselineDate == nil {
            scheduleInitialBaseline(after: 4)
        } else {
            checkSchedule()
        }
    }

    /// Preview/renderer hook only.
    func primeForPreview(report: AnomalyReport, baselineDate: Date) {
        self.report = report
        self.baselineDate = baselineDate
        self.hasFullDiskAccess = true
        self.progress = StorageScanProgress(phase: .idle, scannedFiles: 0, currentPath: nil)
    }

    func scanNow(trigger: Trigger = .manual) {
        guard !isScanning else { return }
        isScanning = true
        lastError = nil
        progress = StorageScanProgress(phase: .scanning, scannedFiles: 0, currentPath: nil)
        hasFullDiskAccess = SystemAccess.hasFullDiskAccess

        let scanner = self.scanner
        let store = self.store
        let previous = store.loadBaseline()
        let threshold = settings.anomalyThresholdBytes
        let token = UUID()
        generation = token

        queue.async { [weak self] in
            let output = scanner.scan { count, path in
                DispatchQueue.main.async {
                    guard let self, self.generation == token, self.isScanning else { return }
                    self.progress = StorageScanProgress(phase: .scanning, scannedFiles: count, currentPath: path)
                }
            }

            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.progress = StorageScanProgress(phase: .comparing, scannedFiles: output.scannedFiles, currentPath: nil)
            }

            let scannedAt = Date()
            let report: AnomalyReport
            if let previous {
                report = scanner.compare(
                    previous: previous,
                    current: output.baseline,
                    threshold: threshold,
                    scannedAt: scannedAt
                )
            } else {
                report = AnomalyReport(
                    scannedAt: scannedAt,
                    previousScanAt: nil,
                    thresholdBytes: threshold,
                    entries: [],
                    totalIncreaseBytes: 0,
                    totalDecreaseBytes: 0,
                    scannedFiles: output.scannedFiles,
                    permissionLimited: output.permissionLimited,
                    isBaseline: true
                )
            }

            var saveError: String?
            do {
                try store.saveBaseline(output.baseline)
                try store.saveReport(report)
            } catch {
                saveError = error.localizedDescription
            }

            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.isScanning = false
                self.progress = StorageScanProgress(phase: .finished, scannedFiles: output.scannedFiles, currentPath: nil)
                self.baselineDate = output.baseline.createdAt
                self.report = report
                self.lastError = saveError
                self.hasFullDiskAccess = SystemAccess.hasFullDiskAccess
                self.refreshSchedule()
                self.onScanFinished?(report, trigger)
                if trigger != .initialBaseline, report.hasFindings {
                    self.onFindings?(report)
                }
            }
        }
    }

    func resetBaseline() {
        guard !isScanning else { return }
        do {
            try store.resetBaseline()
            report = .empty
            baselineDate = nil
            progress = .idle
            refreshSchedule()
            scheduleInitialBaseline(after: 1.5)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refreshPermissionState() {
        hasFullDiskAccess = SystemAccess.hasFullDiskAccess
    }

    func nextScanDescription() -> String {
        guard let next = nextScheduledScan else { return "尚未安排" }
        return Fmt.dateTime(next)
    }

    private func scheduleInitialBaseline(after seconds: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, !self.isScanning, self.baselineDate == nil else { return }
            self.scanNow(trigger: .initialBaseline)
        }
    }

    private func scheduleTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkSchedule()
            }
        }
        timer?.tolerance = 10
    }

    func checkSchedule() {
        refreshSchedule()
        guard !isScanning else { return }
        guard baselineDate != nil else {
            if report.scannedAt == .distantPast {
                scheduleInitialBaseline(after: 1)
            }
            return
        }

        let now = Date()
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = settings.dailyHour
        components.minute = settings.dailyMinute
        guard let todayScheduled = calendar.date(from: components) else { return }

        let lastScan = report.scannedAt == .distantPast ? (baselineDate ?? .distantPast) : report.scannedAt
        let missedByMoreThanADay = now.timeIntervalSince(lastScan) > 26 * 3_600
        let dueToday = now >= todayScheduled && lastScan < todayScheduled

        if dueToday || missedByMoreThanADay {
            scanNow(trigger: .scheduled)
        }
    }

    private func refreshSchedule() {
        nextScheduledScan = settings.nextDailyDate()
    }
}
