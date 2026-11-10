import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: AppSettings!
    private var notifications: NotificationManager!
    private var engine: MonitorEngine!
    private var storage: StorageAnomalyMonitor!
    private var indexMonitor: IndexMonitor!
    private var panelState: PanelState!
    private var panelController: PanelController!
    private var menuBarController: MenuBarController!

    var statusButtonForPanelPositioning: NSStatusBarButton? {
        menuBarController?.statusButton
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if PreviewRenderer.isRequested {
            PreviewRenderer.render {
                NSApp.terminate(nil)
            }
            return
        }

        installMainMenu()
        buildApplication()
    }

    private func buildApplication() {
        let settings = AppSettings()
        let notifications = NotificationManager()
        let store = SnapshotStore()
        let engine = MonitorEngine(settings: settings)
        let panelState = PanelState()
        let storage = StorageAnomalyMonitor(store: store, settings: settings)
        let indexMonitor = IndexMonitor(store: store)

        engine.notificationManager = notifications
        notifications.notificationsEnabled = { settings.notificationsEnabled }
        notifications.soundEnabled = { settings.notificationSoundEnabled }
        storage.onFindings = { report in
            notifications.notifyStorage(report)
        }
        indexMonitor.onScanFinished = { [weak storage] in
            storage?.refreshPermissionState()
        }

        let actions = PanelActions(
            close: { [weak self] in self?.panelController?.close() },
            openFullDiskAccess: {
                SystemAccess.openFullDiskAccessSettings()
            },
            openNotificationSettings: {
                SystemAccess.openNotificationSettings()
            },
            quit: {
                NSApp.terminate(nil)
            }
        )

        let rootView = PanelView(
            engine: engine,
            storage: storage,
            indexMonitor: indexMonitor,
            settings: settings,
            notifications: notifications,
            panelState: panelState,
            actions: actions
        )
        let panelController = PanelController(rootView: rootView, panelState: panelState)
        notifications.onOpenDestination = { [weak panelController] destination in
            panelController?.show(destination: destination)
        }

        let menuBarController = MenuBarController(engine: engine, panelController: panelController)

        self.settings = settings
        self.notifications = notifications
        self.engine = engine
        self.storage = storage
        self.indexMonitor = indexMonitor
        self.panelState = panelState
        self.panelController = panelController
        self.menuBarController = menuBarController

        engine.start()
        storage.startIfNeeded()
        indexMonitor.startIfNeeded()
        notifications.refreshAuthorizationStatus()
        runDebugHooksIfNeeded()
    }

    private func runDebugHooksIfNeeded() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CM_AUTO_OPEN_PANEL"] == "1" else { return }
        let outputDirectory = environment["CM_DEBUG_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let outputDirectory {
            try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            self?.panelController.show(destination: .overview)
        }

        if environment["CM_TEST_KEYS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
                self?.postTestKey(125) // down -> CPU card
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.postTestKey(36) // return -> expand CPU detail
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.4) { [weak self] in
                guard let self, let outputDirectory else { return }
                self.panelController.debugSnapshot(to: outputDirectory.appendingPathComponent("live-panel-keyboard.png"))
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            guard let self else { return }
            if let outputDirectory {
                self.panelController.debugSnapshot(to: outputDirectory.appendingPathComponent("live-panel.png"))
                let snapshot = self.engine.snapshot
                let diagnostics = """
                cpu=\(snapshot.cpu.usage)
                gpu=\(snapshot.gpu.usage.map { String($0) } ?? "nil")
                memory=\(snapshot.memory.percent)
                disk=\(snapshot.disk.percent)
                powerSource=\(snapshot.power.source.rawValue)
                systemWatts=\(snapshot.power.systemWatts.map { String($0) } ?? "nil")
                inputWatts=\(snapshot.power.inputWatts.map { String($0) } ?? "nil")
                supplyWatts=\(snapshot.power.supplyWatts.map { String($0) } ?? "nil")
                chargeWatts=\(snapshot.power.chargeWatts.map { String($0) } ?? "nil")
                battery=\(snapshot.power.batteryPercent)
                panelVisible=\(self.panelController.isVisible)
                panelKey=\(self.panelController.isKey)
                statusItemButton=\(String(describing: self.menuBarController.statusButton?.window?.frame))
                fullDiskAccess=\(self.storage.hasFullDiskAccess)
                indexBytes=\(self.indexMonitor.result.totalBytes)
                reportEntries=\(self.storage.report.entries.count)
                speech=\(self.panelState.isVisible)
                """
                try? diagnostics.write(
                    to: outputDirectory.appendingPathComponent("diagnostics.txt"),
                    atomically: true,
                    encoding: .utf8
                )
            }
            if environment["CM_TEST_KEYS"] == "1" {
                self.postTestKey(53) // escape -> close
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    if let outputDirectory {
                        let closed = "visibleAfterEscape=\(self.panelController.isVisible)\n"
                        try? closed.write(
                            to: outputDirectory.appendingPathComponent("escape-result.txt"),
                            atomically: true,
                            encoding: .utf8
                        )
                    }
                    if environment["CM_AUTO_TERMINATE"] == "1" {
                        NSApp.terminate(nil)
                    }
                }
            } else if environment["CM_AUTO_TERMINATE"] == "1" {
                NSApp.terminate(nil)
            }
        }
    }

    private func postTestKey(_ keyCode: UInt16) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panelController.windowNumber,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        ) else { return }
        NSApp.postEvent(event, atStart: false)
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            panelController?.show(destination: .overview)
        }
        return true
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "Claude Monitor")
        appMenuItem.submenu = appMenu

        let about = NSMenuItem(title: "关于 Claude Monitor", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        appMenu.addItem(about)
        appMenu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())

        let hide = NSMenuItem(title: "隐藏 Claude Monitor", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(hide)
        appMenu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 Claude Monitor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.addItem(quit)

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Claude Monitor",
            .applicationVersion: "1.0",
            .credits: NSAttributedString(
                string: "本地优先的 macOS 状态栏系统监控。\n非官方概念应用，与 Anthropic 无关联。",
                attributes: [.font: NSFont.systemFont(ofSize: 11)]
            )
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openSettings() {
        panelController?.show(destination: .settings)
    }
}
