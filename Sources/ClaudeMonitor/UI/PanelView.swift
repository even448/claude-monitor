import SwiftUI
import AppKit
import Combine

// MARK: - Panel state shared with the AppKit window controller

@MainActor
final class PanelState: ObservableObject {
    @Published var isVisible = false
    @Published var route: PanelDestination = .overview
    @Published var routeToken = 0
    var isPreview = false

    func navigate(to destination: PanelDestination) {
        route = destination
        routeToken += 1
    }
}

enum PanelKey {
    case escape
    case up
    case down
    case enter
}

extension Notification.Name {
    static let claudePanelKey = Notification.Name("com.claudemonitor.panelKey")
}

// MARK: - Focus model

private enum PanelFocus: Int, CaseIterable {
    case energy
    case cpu
    case gpu
    case memory
    case disk
    case storage
    case anomaly
    case detect
    case refresh
    case settings

    var next: PanelFocus {
        let all = PanelFocus.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }

    var previous: PanelFocus {
        let all = PanelFocus.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index - 1 + all.count) % all.count]
    }

    var metric: MetricKind? {
        switch self {
        case .cpu: return .cpu
        case .gpu: return .gpu
        case .memory: return .memory
        case .disk: return .disk
        default: return nil
        }
    }

    var isFooter: Bool {
        self == .detect || self == .refresh || self == .settings
    }

    var scrollAnchor: String? {
        switch self {
        case .energy: return "energy"
        case .cpu, .gpu, .memory, .disk: return "metrics"
        case .storage: return "storage"
        case .anomaly: return "anomaly"
        default: return nil
        }
    }
}

struct PanelActions {
    var close: () -> Void
    var openFullDiskAccess: () -> Void
    var openNotificationSettings: () -> Void
    var quit: () -> Void
}

// MARK: - Root panel

struct PanelView: View {
    @ObservedObject var engine: MonitorEngine
    @ObservedObject var storage: StorageAnomalyMonitor
    @ObservedObject var indexMonitor: IndexMonitor
    @ObservedObject var settings: AppSettings
    @ObservedObject var notifications: NotificationManager
    @ObservedObject var panelState: PanelState
    let actions: PanelActions

    @State private var showSettings = false
    @State private var energyMode: EnergyDisplayMode = .power
    @State private var expandedKind: MetricKind?
    @State private var showAllAnomalies = false
    @State private var focus: PanelFocus = .energy
    @State private var speech: String?
    @State private var speechTask: Task<Void, Never>?
    @State private var petReaction: PetMood?

    var body: some View {
        ZStack {
            panelBackground

            if showSettings {
                SettingsView(
                    settings: settings,
                    storageMonitor: storage,
                    indexMonitor: indexMonitor,
                    notificationManager: notifications,
                    petAnimated: settings.petAnimationsEnabled && !settings.reduceMotion && panelState.isVisible,
                    reduceMotion: settings.reduceMotion,
                    onBack: closeSettings,
                    onOpenFullDiskAccess: actions.openFullDiskAccess,
                    onOpenNotificationSettings: actions.openNotificationSettings,
                    onQuit: actions.quit
                )
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .trailing)),
                    removal: .opacity
                ))
            } else {
                overview
                    .transition(.opacity)
            }
        }
        .frame(width: 354)
        .padding(14)
        .frame(width: 382)
        .onAppear {
            if !panelState.isPreview { engine.refreshNow() }
            applyRoute()
            if let error = storage.lastError {
                showSpeech(error)
            }
        }
        .onChange(of: panelState.routeToken) { _ in
            applyRoute()
        }
        .onChange(of: panelState.isVisible) { visible in
            if visible {
                if !panelState.isPreview { engine.refreshNow() }
                speechTask?.cancel()
            } else {
                speechTask?.cancel()
            }
        }
        .onChange(of: storage.report.scannedAt) { _ in
            handleStorageReport()
        }
        .onReceive(NotificationCenter.default.publisher(for: .claudePanelKey)) { note in
            guard let key = note.object as? PanelKey else { return }
            handleKey(key)
        }
        .onDisappear {
            speechTask?.cancel()
        }
    }

    private var panelBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Palette.panelGradient)
                .overlay(
                    RadialGradient(
                        colors: [Color.white.opacity(0.34), Color.clear],
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: 280
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.white.opacity(0.65), lineWidth: 1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Palette.line.opacity(0.35), lineWidth: 0.8)
                        .padding(0.6)
                )
        }
        .shadow(color: Color(hex: 0x4B3826).opacity(0.22), radius: 24, x: 0, y: 14)
    }

    private var overview: some View {
        VStack(spacing: 0) {
            HeaderView(
                mood: visibleMood,
                health: engine.snapshot.healthLevel,
                petAnimated: settings.petAnimationsEnabled && !settings.reduceMotion && panelState.isVisible,
                reduceMotion: settings.reduceMotion,
                speech: speech,
                onPetTap: handlePetTap,
                onSettings: openSettings
            )
            .padding(.horizontal, 16)
            .padding(.top, 13)
            .padding(.bottom, 9)

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 11) {
                        EnergyCardView(
                            power: engine.snapshot.power,
                            alert: engine.powerAlert,
                            settings: settings,
                            isActive: panelState.isVisible,
                            mode: $energyMode
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(Palette.coral.opacity(focus == .energy ? 0.62 : 0), lineWidth: 1.4)
                        )
                        .id("energy")

                        MetricsSectionView(
                            engine: engine,
                            focusedKind: focus.metric,
                            expandedKind: $expandedKind,
                            onFocus: { kind in
                                focus = focusForMetric(kind)
                            }
                        )
                        .id("metrics")

                        StorageSectionView(
                            disk: engine.snapshot.disk,
                            indexMonitor: indexMonitor,
                            hasFullDiskAccess: storage.hasFullDiskAccess,
                            isFocused: focus == .storage,
                            onOpenFullDiskAccess: actions.openFullDiskAccess,
                            onCheckPermission: {
                                storage.refreshPermissionState()
                                indexMonitor.scan()
                            }
                        )
                        .id("storage")
                        .onTapGesture { focus = .storage }

                        AnomalySectionView(
                            monitor: storage,
                            isFocused: focus == .anomaly,
                            showAll: $showAllAnomalies,
                            onRun: runDetection,
                            onOpenFullDiskAccess: actions.openFullDiskAccess
                        )
                        .id("anomaly")
                        .onTapGesture { focus = .anomaly }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 2)
                    .padding(.bottom, 12)
                }
                .onChange(of: focus) { newFocus in
                    guard let anchor = newFocus.scrollAnchor else { return }
                    withAnimation(.easeInOut(duration: 0.22)) {
                        proxy.scrollTo(anchor, anchor: .top)
                    }
                }
            }
            .frame(maxHeight: .infinity)

            FooterView(
                isScanning: storage.isScanning,
                isFocused: footerFocus,
                onDetect: runDetection,
                onRefresh: {
                    focus = .refresh
                    engine.refreshNow()
                },
                onSettings: openSettings
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var footerFocus: FooterFocus? {
        switch focus {
        case .detect: return .detect
        case .refresh: return .refresh
        case .settings: return .settings
        default: return nil
        }
    }

    // MARK: Mood / speech

    private var computedMood: PetMood {
        if storage.isScanning || indexMonitor.isScanning { return .working }
        if storage.report.isToday && storage.report.hasFindings { return .surprised }
        if engine.powerAlert != nil { return .concerned }
        if engine.snapshot.healthLevel == .critical { return .concerned }
        if engine.snapshot.healthLevel == .elevated { return .curious }
        return .calm
    }

    private var visibleMood: PetMood {
        petReaction ?? computedMood
    }

    private func handlePetTap() {
        let message: String
        switch computedMood {
        case .calm:
            message = "今天也很稳，我会安静看着的。"
        case .curious:
            message = "有一点忙，但还在舒适区。要不要看看细节？"
        case .concerned:
            message = "负载有一点高，我会帮你留意。"
        case .surprised:
            message = "发现存储变化啦，往下翻翻看。"
        case .working:
            message = "正在低优先级工作，不会打扰你。"
        case .happy:
            message = "被你点到啦，今天也要轻轻松松。"
        }
        withAnimation(.easeInOut(duration: 0.18)) {
            petReaction = .happy
        }
        showSpeech(message, duration: 3.5)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            if petReaction == .happy {
                withAnimation(.easeInOut(duration: 0.2)) { petReaction = nil }
            }
        }
    }

    private func showSpeech(_ text: String, duration: Double = 4.5) {
        speechTask?.cancel()
        withAnimation(.easeInOut(duration: 0.18)) { speech = text }
        speechTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.22)) { speech = nil }
            }
        }
    }

    private func handleStorageReport() {
        guard storage.report.scannedAt != .distantPast else { return }
        if storage.report.isBaseline {
            showSpeech("我记住今天的样子了，明天再对比。", duration: 4)
        } else if storage.report.hasFindings {
            withAnimation(.easeInOut(duration: 0.2)) { petReaction = .surprised }
            showSpeech("咦，发现 \(storage.report.entries.count) 项体积变化，已经标出来了。", duration: 6)
            focus = .anomaly
            showAllAnomalies = storage.report.entries.count > 3
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                if petReaction == .surprised { withAnimation { petReaction = nil } }
            }
        } else {
            withAnimation(.easeInOut(duration: 0.2)) { petReaction = .happy }
            showSpeech("今天很干净，没有异常变化。", duration: 3.5)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
                if petReaction == .happy { withAnimation { petReaction = nil } }
            }
        }
    }

    // MARK: Actions

    private func runDetection() {
        focus = .detect
        engine.refreshNow()
        if storage.isScanning {
            showSpeech("还在扫描，请稍等一下下。", duration: 2.5)
        } else {
            showSpeech("开始检查存储空间，我会轻轻的。", duration: 3)
            storage.scanNow(trigger: .manual)
        }
    }

    private func openSettings() {
        withAnimation(.easeInOut(duration: 0.22)) {
            showSettings = true
        }
        panelState.route = .settings
    }

    private func closeSettings() {
        withAnimation(.easeInOut(duration: 0.22)) {
            showSettings = false
        }
        panelState.route = .overview
        focus = .energy
    }

    private func applyRoute() {
        switch panelState.route {
        case .settings:
            showSettings = true
        case .anomaly:
            showSettings = false
            focus = .anomaly
            showAllAnomalies = storage.report.entries.count > 3
        case .storage:
            showSettings = false
            focus = .storage
        case .energy:
            showSettings = false
            focus = .energy
        case .overview:
            if showSettings { showSettings = false }
        }
    }

    private func focusForMetric(_ kind: MetricKind) -> PanelFocus {
        switch kind {
        case .cpu: return .cpu
        case .gpu: return .gpu
        case .memory: return .memory
        case .disk: return .disk
        }
    }

    // MARK: Keyboard

    private func handleKey(_ key: PanelKey) {
        if showSettings {
            if key == .escape { closeSettings() }
            return
        }

        switch key {
        case .escape:
            actions.close()
        case .up:
            focus = focus.previous
        case .down:
            focus = focus.next
        case .enter:
            activateFocus()
        }
    }

    private func activateFocus() {
        switch focus {
        case .energy:
            withAnimation(.easeInOut(duration: 0.2)) { energyMode = energyMode.next }
        case .cpu, .gpu, .memory, .disk:
            guard let kind = focus.metric else { return }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                expandedKind = expandedKind == kind ? nil : kind
            }
            if expandedKind == .cpu || expandedKind == .memory {
                engine.loadProcessDetails(force: true)
            }
        case .storage:
            indexMonitor.scan()
        case .anomaly:
            withAnimation(.easeInOut(duration: 0.2)) { showAllAnomalies.toggle() }
        case .detect:
            runDetection()
        case .refresh:
            engine.refreshNow()
            showSpeech("指标已刷新。", duration: 2)
        case .settings:
            openSettings()
        }
    }
}
