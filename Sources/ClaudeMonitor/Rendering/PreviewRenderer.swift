import AppKit
import SwiftUI

/// Development-only offscreen renderer used to verify the panel layout and to
/// produce the documentation screenshots. Set `CM_RENDER_DIR` to an output
/// directory and launch the app; it never creates a status item in this mode.
@MainActor
enum PreviewRenderer {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["CM_RENDER_DIR"] != nil
    }

    static func render(completion: @escaping () -> Void) {
        guard let outPath = ProcessInfo.processInfo.environment["CM_RENDER_DIR"] else {
            completion()
            return
        }
        let output = URL(fileURLWithPath: outPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        NSApp.appearance = NSAppearance(named: .aqua)

        let suiteName = "com.claudemonitor.preview"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let settings = AppSettings(defaults: defaults)
        settings.notificationsEnabled = true
        settings.refreshInterval = 2
        settings.powerRefreshInterval = 2

        let tempStore = SnapshotStore(
            directoryURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("ClaudeMonitorPreview", isDirectory: true)
        )
        let notifications = NotificationManager()
        let engine = MonitorEngine(settings: settings)
        engine.primeForPreview()

        let storage = StorageAnomalyMonitor(store: tempStore, settings: settings)
        storage.primeForPreview(report: DemoData.report, baselineDate: Date().addingTimeInterval(-86_400))

        let indexMonitor = IndexMonitor(store: tempStore)
        indexMonitor.primeForPreview(result: DemoData.indexResult)

        let panelState = PanelState()
        panelState.isPreview = true
        panelState.isVisible = true
        panelState.navigate(to: .overview)

        let actions = PanelActions(
            close: {},
            openFullDiskAccess: {},
            openNotificationSettings: {},
            quit: {}
        )

        let root = makeRoot(
            engine: engine,
            storage: storage,
            indexMonitor: indexMonitor,
            settings: settings,
            notifications: notifications,
            panelState: panelState,
            actions: actions,
            height: 830
        )
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 382, height: 830)
        hosting.appearance = NSAppearance(named: .aqua)
        hosting.layoutSubtreeIfNeeded()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            write(view: hosting, to: output.appendingPathComponent("panel-overview.png"), size: NSSize(width: 382, height: 830))

            panelState.navigate(to: .settings)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                write(view: hosting, to: output.appendingPathComponent("panel-settings.png"), size: NSSize(width: 382, height: 830))

                let tallState = PanelState()
                tallState.isPreview = true
                tallState.isVisible = true
                tallState.navigate(to: .overview)
                let tallRoot = makeRoot(
                    engine: engine,
                    storage: storage,
                    indexMonitor: indexMonitor,
                    settings: settings,
                    notifications: notifications,
                    panelState: tallState,
                    actions: actions,
                    height: 1240
                )
                let tallHost = NSHostingView(rootView: tallRoot)
                tallHost.frame = NSRect(x: 0, y: 0, width: 382, height: 1240)
                tallHost.appearance = NSAppearance(named: .aqua)
                tallHost.layoutSubtreeIfNeeded()

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    write(view: tallHost, to: output.appendingPathComponent("panel-overview-full.png"), size: NSSize(width: 382, height: 1240))
                    tallState.navigate(to: .settings)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        write(view: tallHost, to: output.appendingPathComponent("panel-settings-full.png"), size: NSSize(width: 382, height: 1240))

                        let petSheet = NSHostingView(rootView: PetExpressionSheet().frame(width: 620, height: 420))
                        petSheet.frame = NSRect(x: 0, y: 0, width: 620, height: 420)
                        petSheet.appearance = NSAppearance(named: .aqua)
                        petSheet.layoutSubtreeIfNeeded()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            write(view: petSheet, to: output.appendingPathComponent("pet-expressions.png"), size: NSSize(width: 620, height: 420))

                            let iconSheet = NSHostingView(rootView: StatusIconSheet().frame(width: 620, height: 240))
                            iconSheet.frame = NSRect(x: 0, y: 0, width: 620, height: 240)
                            iconSheet.appearance = NSAppearance(named: .aqua)
                            iconSheet.layoutSubtreeIfNeeded()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                write(view: iconSheet, to: output.appendingPathComponent("status-icons.png"), size: NSSize(width: 620, height: 240))
                                completion()
                            }
                        }
                    }
                }
            }
        }
    }

    private static func makeRoot(
        engine: MonitorEngine,
        storage: StorageAnomalyMonitor,
        indexMonitor: IndexMonitor,
        settings: AppSettings,
        notifications: NotificationManager,
        panelState: PanelState,
        actions: PanelActions,
        height: CGFloat
    ) -> some View {
        PanelView(
            engine: engine,
            storage: storage,
            indexMonitor: indexMonitor,
            settings: settings,
            notifications: notifications,
            panelState: panelState,
            actions: actions
        )
        .frame(width: 382, height: height)
    }

    private static func write(view: NSView, to url: URL, size: NSSize) {
        view.layoutSubtreeIfNeeded()
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return }
        rep.size = size
        view.cacheDisplay(in: NSRect(origin: .zero, size: size), to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }
}

private struct PetExpressionSheet: View {
    private let moods: [(PetMood, String, String)] = [
        (.calm, "平静", "一切平稳"),
        (.curious, "好奇", "有点忙，但还好"),
        (.concerned, "关心", "负载偏高"),
        (.surprised, "惊讶", "发现存储变化"),
        (.working, "工作中", "正在检测"),
        (.happy, "开心", "被点到啦")
    ]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: 0xF8F3EA), Color(hex: 0xEFE4D4)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 18) {
                ForEach(Array(moods.enumerated()), id: \.offset) { _, item in
                    VStack(spacing: 10) {
                        PetMascotView(mood: item.0, size: 104, animated: false, reduceMotion: true)
                        VStack(spacing: 2) {
                            Text(item.1)
                                .font(.claudeSerif(15, weight: .semibold))
                                .foregroundColor(Palette.ink)
                            Text(item.2)
                                .font(.claudeBody(10))
                                .foregroundColor(Palette.inkFaint)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(Palette.surface.opacity(0.88))
                            .overlay(
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .stroke(Palette.line, lineWidth: 0.9)
                            )
                    )
                    .shadow(color: Palette.shadow.opacity(0.3), radius: 8, y: 4)
                }
            }
            .padding(22)
        }
    }
}


private struct StatusIconSheet: View {
    private let states: [(Double, String)] = [(27, "正常 · 珊瑚"), (70, "偏高 · 琥珀"), (92, "过载 · 警示红")]

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 26) {
                ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                    VStack(spacing: 8) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(hex: 0xE7DED0))
                            Image(nsImage: StatusIconRenderer.image(load: state.0, hovered: false))
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 36, height: 36)
                        }
                        .frame(width: 68, height: 46)
                        VStack(spacing: 1) {
                            Text("负载 \(Int(state.0))%")
                                .font(.claudeLabel(10, weight: .semibold))
                                .foregroundColor(Palette.ink)
                            Text(state.1)
                                .font(.claudeLabel(8, weight: .medium))
                                .foregroundColor(Palette.inkFaint)
                        }
                    }
                }
            }

            HStack(spacing: 26) {
                ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(hex: 0x1E1B18))
                        Image(nsImage: StatusIconRenderer.image(load: state.0, hovered: false))
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 36, height: 36)
                    }
                    .frame(width: 68, height: 46)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [Color(hex: 0xF8F3EA), Color(hex: 0xEFE4D4)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }
}
