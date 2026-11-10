import AppKit
import Combine

/// Draws the menu-bar mark with AppKit so the icon stays crisp and can carry
/// the load-state colour. The shape is a friendly six-ray asterisk — a tiny
/// relative of the in-panel pet.
enum StatusIconRenderer {
    static func image(load: Double, hovered: Bool, dimmed: Bool = false) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let color: NSColor
            if load >= 85 {
                color = NSColor(srgbRed: 0.72, green: 0.30, blue: 0.24, alpha: 1)
            } else if load >= 60 {
                color = NSColor(srgbRed: 0.86, green: 0.66, blue: 0.31, alpha: 1)
            } else {
                color = NSColor(srgbRed: 0.79, green: 0.39, blue: 0.26, alpha: 1)
            }
            let alpha: CGFloat = dimmed ? 0.42 : 1
            color.withAlphaComponent(alpha).setFill()

            let center = NSPoint(x: rect.midX, y: rect.midY)
            let scale: CGFloat = hovered ? 1.06 : 1.0

            NSGraphicsContext.saveGraphicsState()
            let outer = NSAffineTransform()
            outer.translateX(by: center.x, yBy: center.y)
            outer.scale(by: scale)
            outer.translateX(by: -center.x, yBy: -center.y)
            outer.concat()

            for index in 0..<6 {
                NSGraphicsContext.saveGraphicsState()
                let transform = NSAffineTransform()
                transform.translateX(by: center.x, yBy: center.y)
                transform.rotate(byDegrees: CGFloat(index) * 60)
                transform.translateX(by: 0, yBy: -4.4)
                transform.concat()

                let ray = NSBezierPath(
                    roundedRect: NSRect(x: -1.85, y: -3.7, width: 3.7, height: 7.5),
                    xRadius: 1.85,
                    yRadius: 1.85
                )
                ray.fill()
                NSGraphicsContext.restoreGraphicsState()
            }

            // Cream centre keeps the mark legible on both light and dark bars.
            NSColor(srgbRed: 0.98, green: 0.93, blue: 0.86, alpha: dimmed ? 0.5 : 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - 2.1, y: center.y - 2.1, width: 4.2, height: 4.2)).fill()
            NSGraphicsContext.restoreGraphicsState()

            return true
        }
        image.isTemplate = false
        return image
    }
}

@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let engine: MonitorEngine
    private let panelController: PanelController
    private var cancellables: Set<AnyCancellable> = []
    private var trackingArea: NSTrackingArea?
    private var hovered = false
    private var flashTimer: Timer?
    private var flashDimmed = false

    init(engine: MonitorEngine, panelController: PanelController) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.engine = engine
        self.panelController = panelController
        super.init()
        configureButton()
        observeEngine()
        updateIcon()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = StatusIconRenderer.image(load: 0, hovered: false)
        button.imageScaling = .scaleProportionallyDown
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(togglePanel(_:))
        button.toolTip = "Claude Monitor"
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.clear.cgColor

        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        button.addTrackingArea(area)
        trackingArea = area
    }

    var statusButton: NSStatusBarButton? { statusItem.button }

    private func observeEngine() {
        engine.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in
                self?.updateIcon(snapshot: snapshot)
            }
            .store(in: &cancellables)
    }

    private func updateIcon(snapshot: SystemSnapshot? = nil) {
        let snapshot = snapshot ?? engine.snapshot
        let load = snapshot.highestLoad
        statusItem.button?.image = StatusIconRenderer.image(
            load: load,
            hovered: hovered,
            dimmed: flashDimmed
        )
        statusItem.button?.toolTip = String(
            format: "Claude Monitor\nCPU %.0f%% · GPU %@ · 内存 %.0f%% · 磁盘 %.0f%%",
            snapshot.cpu.usage,
            snapshot.gpu.usage.map { String(format: "%.0f%%", $0) } ?? "—",
            snapshot.memory.percent,
            snapshot.disk.percent
        )
        updateFlash(for: load)
    }

    private func updateFlash(for load: Double) {
        if load >= 85 {
            guard flashTimer == nil else { return }
            flashTimer = Timer.scheduledTimer(withTimeInterval: 0.62, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.flashDimmed.toggle()
                    self.statusItem.button?.image = StatusIconRenderer.image(
                        load: self.engine.snapshot.highestLoad,
                        hovered: self.hovered,
                        dimmed: self.flashDimmed
                    )
                }
            }
            flashTimer?.tolerance = 0.12
        } else {
            flashTimer?.invalidate()
            flashTimer = nil
            flashDimmed = false
        }
    }

    @objc private func togglePanel(_ sender: Any?) {
        panelController.toggle()
    }

    func showPanel(destination: PanelDestination) {
        panelController.show(destination: destination)
    }

    // NSTrackingArea callbacks
    @objc func mouseEntered(with event: NSEvent) {
        hovered = true
        updateIcon()
    }

    @objc func mouseExited(with event: NSEvent) {
        hovered = false
        updateIcon()
    }

    deinit {
        flashTimer?.invalidate()
    }
}
