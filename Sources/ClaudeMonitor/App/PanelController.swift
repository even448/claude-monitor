import AppKit
import SwiftUI

/// A borderless panel that can still become key so arrow/return/Escape handling
/// and SwiftUI controls work while the app runs as a menu-bar accessory.
final class PanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PanelController: NSObject {
    private let panel: PanelWindow
    private let hostingView: NSHostingView<PanelView>
    private let panelState: PanelState
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var isAnimating = false
    private var lastContentHeight: CGFloat = 0

    init(rootView: PanelView, panelState: PanelState) {
        self.panelState = panelState
        panel = PanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 382, height: 820),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        hostingView = NSHostingView(rootView: rootView)
        super.init()
        configurePanel()
        installEventMonitors()
    }

    private func configurePanel() {
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.contentView = hostingView
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.autoresizingMask = [.width, .height]
    }

    private func installEventMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isVisible, self.panel.isKeyWindow else { return event }
            return self.handleLocalKey(event)
        }

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    private func handleLocalKey(_ event: NSEvent) -> NSEvent? {
        let key: PanelKey?
        switch event.keyCode {
        case 53: key = .escape
        case 126: key = .up
        case 125: key = .down
        case 36, 76: key = .enter
        default: key = nil
        }
        guard let key else { return event }

        if panelState.route == .settings {
            guard key == .escape else { return event }
            post(key)
            return nil
        }
        post(key)
        return nil
    }

    private func post(_ key: PanelKey) {
        NotificationCenter.default.post(name: .claudePanelKey, object: key)
    }

    var isVisible: Bool { panel.isVisible }
    var isKey: Bool { panel.isKeyWindow }
    var windowNumber: Int { panel.windowNumber }

    func debugSnapshot(to url: URL) {
        guard let view = panel.contentView else { return }
        view.layoutSubtreeIfNeeded()
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width * scale),
            pixelsHigh: Int(view.bounds.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return }
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
        }
    }

    func toggle() {
        if panel.isVisible {
            close()
        } else {
            panelState.navigate(to: .overview)
            open()
        }
    }

    func show(destination: PanelDestination) {
        panelState.navigate(to: destination)
        if !panel.isVisible {
            open()
        } else {
            positionPanel()
        }
    }

    func open() {
        guard !panel.isVisible, !isAnimating else { return }
        positionPanel()
        panelState.isVisible = true
        isAnimating = true

        var finalFrame = panel.frame
        let finalY = finalFrame.origin.y
        finalFrame.origin.y = finalY + 9
        panel.setFrame(finalFrame, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(NSRect(
                x: finalFrame.origin.x,
                y: finalY,
                width: finalFrame.width,
                height: finalFrame.height
            ), display: true)
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                self?.isAnimating = false
                self?.panel.makeKey()
            }
        })
    }

    func close() {
        guard panel.isVisible, !isAnimating else { return }
        isAnimating = true
        panelState.isVisible = false
        let start = panel.frame
        var end = start
        end.origin.y -= 7
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(end, display: true)
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                self?.panel.orderOut(nil)
                self?.panel.alphaValue = 1
                self?.panel.setFrame(start, display: false)
                self?.isAnimating = false
            }
        })
    }

    private func positionPanel() {
        guard let button = statusItemButton() else { return }
        let visible = button.window?.convertToScreen(button.convert(button.bounds, to: nil))
            ?? NSRect(x: 0, y: 0, width: 18, height: 18)
        let screen = button.window?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let height = min(830, max(640, visibleFrame.height - 22))
        let width: CGFloat = 382

        var x = visible.midX - width / 2
        x = min(max(x, visibleFrame.minX + 8), visibleFrame.maxX - width - 8)
        var y = visible.minY - height - 6
        y = max(y, visibleFrame.minY + 8)

        if abs(height - lastContentHeight) > 0.5 {
            lastContentHeight = height
            hostingView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        }
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }

    private func statusItemButton() -> NSStatusBarButton? {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return nil }
        return appDelegate.statusButtonForPanelPositioning
    }

    deinit {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }
}
