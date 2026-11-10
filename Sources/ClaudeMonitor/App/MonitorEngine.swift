import Foundation
import Combine
import AppKit

@MainActor
final class MonitorEngine: ObservableObject {
    @Published private(set) var snapshot: SystemSnapshot = .init()
    @Published private(set) var histories: [MetricKind: MetricHistory] = [:]
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var processDetails = ProcessDetails()
    @Published private(set) var isProcessDetailsLoading = false
    @Published private(set) var powerAlert: String?
    @Published private(set) var isSampling = false

    let settings: AppSettings
    private let cpuSampler = CPUSampler()
    private let memorySampler = MemorySampler()
    private let diskSampler = DiskSampler()
    private let gpuSampler = GPUSampler()
    private let powerSampler = PowerSampler()
    private let processSampler = ProcessSampler()

    private let queue = DispatchQueue(label: "com.claudemonitor.sampling", qos: .utility)
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var lastPowerSample = Date.distantPast
    private var lastMetricSample = Date.distantPast
    private var lastProcessRequest = Date.distantPast
    private var highPowerSince: Date?
    private var lastPowerNotification = Date.distantPast
    private var isRunning = false

    var notificationManager: NotificationManager?

    init(settings: AppSettings) {
        self.settings = settings
        for kind in MetricKind.allCases {
            histories[kind] = MetricHistory()
        }
        settings.$refreshInterval
            .combineLatest(settings.$powerRefreshInterval)
            .sink { [weak self] _, _ in
                Task { @MainActor in
                    if self?.isRunning == true { self?.rescheduleTimer() }
                }
            }
            .store(in: &cancellables)
    }

    deinit {
        timer?.invalidate()
    }

    func start() {
        guard timer == nil else { return }
        isRunning = true
        rescheduleTimer()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
            self?.tick(force: true)
        }
    }

    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
    }

    func refreshNow() {
        tick(force: true)
    }

    func history(for kind: MetricKind) -> MetricHistory {
        histories[kind] ?? MetricHistory()
    }

    /// Preview/renderer hook only. Never called in normal app flow.
    func primeForPreview() {
        snapshot = DemoData.snapshot
        lastUpdated = Date()
        histories[.cpu] = DemoData.history(base: 27, spread: 15)
        histories[.gpu] = DemoData.history(base: 18, spread: 11)
        histories[.memory] = DemoData.history(base: 62, spread: 5)
        histories[.disk] = DemoData.history(base: 53, spread: 1.6)
        processDetails = DemoData.processes
    }

    func loadProcessDetails(force: Bool = false) {
        let now = Date()
        guard !isProcessDetailsLoading else { return }
        guard force || now.timeIntervalSince(lastProcessRequest) > 3 else { return }
        lastProcessRequest = now
        isProcessDetailsLoading = true
        let sampler = processSampler
        queue.async { [weak self] in
            let details = sampler.sample()
            DispatchQueue.main.async {
                guard let self else { return }
                self.processDetails = details
                self.isProcessDetailsLoading = false
            }
        }
    }

    // MARK: Sampling

    private func rescheduleTimer() {
        timer?.invalidate()
        let interval = max(0.5, min(settings.refreshInterval, settings.powerRefreshInterval))
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick(force: false) }
        }
        timer?.tolerance = interval * 0.12
    }

    private func tick(force: Bool) {
        guard !isSampling else { return }
        let now = Date()
        let sampleMetrics = force || now.timeIntervalSince(lastMetricSample) >= settings.refreshInterval - 0.05
        let samplePower = force || now.timeIntervalSince(lastPowerSample) >= settings.powerRefreshInterval - 0.05
        guard sampleMetrics || samplePower else { return }

        isSampling = true
        if sampleMetrics { lastMetricSample = now }
        if samplePower { lastPowerSample = now }

        let currentPower = snapshot.power
        let cpuSampler = self.cpuSampler
        let memorySampler = self.memorySampler
        let diskSampler = self.diskSampler
        let gpuSampler = self.gpuSampler
        let powerSampler = self.powerSampler
        let uptime = ProcessInfo.processInfo.systemUptime

        queue.async { [weak self] in
            let cpu = sampleMetrics ? cpuSampler.sample() : nil
            let memory = sampleMetrics ? memorySampler.sample() : nil
            let disk = sampleMetrics ? diskSampler.sample() : nil
            let gpu = sampleMetrics ? gpuSampler.sample() : nil
            let power = samplePower ? powerSampler.sample() : nil

            DispatchQueue.main.async {
                guard let self else { return }
                var next = self.snapshot
                if let cpu { next.cpu = cpu }
                if let memory { next.memory = memory }
                if let disk { next.disk = disk }
                if let gpu { next.gpu = gpu }
                if let power { next.power = power } else { next.power = currentPower }
                next.uptime = uptime
                next.timestamp = Date()
                self.snapshot = next
                self.lastUpdated = Date()
                if sampleMetrics {
                    self.appendHistories(from: next)
                }
                self.evaluatePowerAlert(next.power)
                self.isSampling = false
            }
        }
    }

    private func appendHistories(from snapshot: SystemSnapshot) {
        let now = snapshot.timestamp
        var cpuHistory = histories[.cpu] ?? MetricHistory()
        cpuHistory.append(snapshot.cpu.usage, at: now)
        histories[.cpu] = cpuHistory

        var memoryHistory = histories[.memory] ?? MetricHistory()
        memoryHistory.append(snapshot.memory.percent, at: now)
        histories[.memory] = memoryHistory

        var diskHistory = histories[.disk] ?? MetricHistory()
        diskHistory.append(snapshot.disk.percent, at: now)
        histories[.disk] = diskHistory

        if let gpu = snapshot.gpu.usage {
            var gpuHistory = histories[.gpu] ?? MetricHistory()
            gpuHistory.append(gpu, at: now)
            histories[.gpu] = gpuHistory
        }
    }

    private func evaluatePowerAlert(_ power: PowerMetrics) {
        let temperatureHigh = (power.temperatureCelsius ?? 0) >= 42
        let batteryHigh = power.source == .battery && (power.systemWatts ?? 0) >= 35
        let adapterLimit = Double(power.adapterWatts ?? 0)
        let adapterHigh = adapterLimit > 0 && (power.inputWatts ?? 0) >= adapterLimit * 0.9
        let warning = temperatureHigh || batteryHigh || adapterHigh

        if warning {
            if highPowerSince == nil {
                highPowerSince = Date()
            }
            if let since = highPowerSince, Date().timeIntervalSince(since) >= 180,
               powerAlert == nil {
                let message: String
                if temperatureHigh {
                    message = "电池温度已持续偏高（\(String(format: "%.0f", power.temperatureCelsius ?? 0))°C），建议检查通风与充电状态。"
                } else if batteryHigh {
                    message = "电池供电功耗已持续偏高（\(Fmt.watts(power.systemWatts))），可以稍作休息。"
                } else {
                    message = "适配器输入功率接近上限（\(Fmt.watts(power.inputWatts))），请留意温度与充电器状态。"
                }
                powerAlert = message
                if Date().timeIntervalSince(lastPowerNotification) > 3_600 {
                    lastPowerNotification = Date()
                    notificationManager?.notifyPowerAlert(message)
                }
            }
        } else {
            highPowerSince = nil
            if powerAlert != nil { powerAlert = nil }
        }
    }
}
