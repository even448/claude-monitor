import SwiftUI

enum EnergyDisplayMode: String, CaseIterable {
    case power
    case percentage
    case battery

    var label: String {
        switch self {
        case .power: return "功率"
        case .percentage: return "占比"
        case .battery: return "电池"
        }
    }

    var short: String {
        switch self {
        case .power: return "W"
        case .percentage: return "%"
        case .battery: return "BAT"
        }
    }

    var next: EnergyDisplayMode {
        switch self {
        case .power: return .percentage
        case .percentage: return .battery
        case .battery: return .power
        }
    }
}

/// A small 60 fps ticker for the energy flow. It is stopped whenever the panel
/// is hidden or the user disables the animation, so the app does not burn cycles
/// in the background.
final class FlowAnimator: ObservableObject {
    struct Frame {
        var time: Double = 0
        var input: Double = 0
        var supply: Double = 0
        var charge: Double = 0
        var discharge: Double = 0
    }

    @Published private(set) var frame = Frame()
    private var targets = Frame()
    private var timer: Timer?
    private var active = false

    func setTargets(input: Double, supply: Double, charge: Double, discharge: Double) {
        targets.input = max(0, input.isFinite ? input : 0)
        targets.supply = max(0, supply.isFinite ? supply : 0)
        targets.charge = max(0, charge.isFinite ? charge : 0)
        targets.discharge = max(0, discharge.isFinite ? discharge : 0)
        if !active {
            frame.input = targets.input
            frame.supply = targets.supply
            frame.charge = targets.charge
            frame.discharge = targets.discharge
        }
    }

    func setActive(_ shouldRun: Bool) {
        guard shouldRun != active else { return }
        active = shouldRun
        if shouldRun {
            start()
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    private func start() {
        timer?.invalidate()
        let newTimer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        newTimer.tolerance = 0.004
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    private func tick() {
        var next = frame
        next.time += 1.0 / 60.0
        if next.time > 10_000 { next.time = 0 }
        let ease = 0.11
        next.input += (targets.input - next.input) * ease
        next.supply += (targets.supply - next.supply) * ease
        next.charge += (targets.charge - next.charge) * ease
        next.discharge += (targets.discharge - next.discharge) * ease
        frame = next
    }

    deinit {
        timer?.invalidate()
    }
}

// MARK: - Flow diagram

struct PowerFlowDiagram: View {
    let power: PowerMetrics
    let mode: EnergyDisplayMode
    let unit: PowerUnit
    let isActive: Bool
    let animationEnabled: Bool
    let reduceMotion: Bool
    @Binding var batteryHovered: Bool
    var onCycleMode: () -> Void

    @StateObject private var animator = FlowAnimator()
    @State private var hoveredBranch: Branch?

    enum Branch: Equatable {
        case supply
        case charge
        case discharge
    }

    private var onAC: Bool { power.source.isOnAC }
    private var hasChargeBranch: Bool {
        power.hasBattery && onAC && (power.chargeWatts ?? 0) > 0.3 && !(power.isFullyCharged && (power.chargeWatts ?? 0) < 0.5)
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                Canvas { context, canvasSize in
                    draw(context: &context, size: canvasSize)
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: onCycleMode)

                sourceNode(size: size)

                if onAC {
                    branchLabel(
                        branch: .supply,
                        icon: "desktopcomputer",
                        title: mode == .battery ? "电脑供能" : "供能",
                        value: supplyText,
                        tint: Palette.coral,
                        width: 112
                    )
                    .position(x: size.width - 57, y: size.height * 0.27)

                    if power.hasBattery {
                        branchLabel(
                            branch: .charge,
                            icon: "battery.75",
                            title: hasChargeBranch ? "充电" : (power.isFullyCharged ? "已充满" : "充电"),
                            value: chargeText,
                            tint: hasChargeBranch ? Palette.honey : Palette.inkFaint,
                            width: 112
                        )
                        .position(x: size.width - 57, y: size.height * 0.73)
                        .onHover { hovering in
                            withAnimation(.easeInOut(duration: 0.16)) {
                                batteryHovered = hovering
                            }
                        }
                    }
                } else {
                    branchLabel(
                        branch: .discharge,
                        icon: "desktopcomputer",
                        title: "放电供能",
                        value: dischargeText,
                        tint: Palette.sage,
                        width: 126
                    )
                    .position(x: size.width - 64, y: size.height * 0.5)
                }
            }
        }
        .frame(height: 104)
        .onAppear(perform: updateAnimator)
        .onChange(of: power) { _ in updateAnimator() }
        .onChange(of: isActive) { _ in updateAnimator() }
        .onChange(of: animationEnabled) { _ in updateAnimator() }
        .onChange(of: reduceMotion) { _ in updateAnimator() }
        .onDisappear {
            animator.setActive(false)
        }
    }

    private func updateAnimator() {
        animator.setTargets(
            input: power.inputWatts ?? 0,
            supply: hasChargeBranch ? (power.supplyWatts ?? 0) : (power.inputWatts ?? power.supplyWatts ?? 0),
            charge: hasChargeBranch ? (power.chargeWatts ?? 0) : 0,
            discharge: power.dischargeWatts ?? 0
        )
        animator.setActive(isActive && animationEnabled && !reduceMotion)
    }

    private var supplyText: String {
        switch mode {
        case .power:
            return Fmt.watts(power.supplyWatts ?? power.inputWatts, unit: unit)
        case .percentage:
            let input = max(power.inputWatts ?? 0, 0.001)
            return Fmt.percent((power.supplyWatts ?? 0) / input * 100)
        case .battery:
            return Fmt.watts(power.supplyWatts ?? power.inputWatts, unit: unit)
        }
    }

    private var chargeText: String {
        switch mode {
        case .power:
            if hasChargeBranch { return Fmt.watts(power.chargeWatts, unit: unit) }
            return power.isFullyCharged ? "涓流" : "0 W"
        case .percentage:
            let input = max(power.inputWatts ?? 0, 0.001)
            return Fmt.percent((power.chargeWatts ?? 0) / input * 100)
        case .battery:
            return Fmt.watts(power.chargeWatts, unit: unit)
        }
    }

    private var dischargeText: String {
        switch mode {
        case .power:
            return Fmt.watts(power.dischargeWatts ?? power.systemWatts, unit: unit)
        case .percentage:
            return "100%"
        case .battery:
            return Fmt.watts(power.dischargeWatts ?? power.systemWatts, unit: unit)
        }
    }

    private var inputText: String {
        guard onAC else {
            return power.timeRemainingMinutes.map { Fmt.duration(minutes: $0) } ?? "电池供电"
        }
        return Fmt.watts(power.inputWatts, unit: unit)
    }

    // MARK: Drawing

    private func draw(context: inout GraphicsContext, size: CGSize) {
        let source = CGPoint(x: 26, y: size.height * 0.5)
        let split = CGPoint(x: 74, y: size.height * 0.5)
        let endpointX = size.width - 126
        let accent = onAC ? Palette.coral : Palette.sage

        let trunk = Path { path in
            path.move(to: source)
            path.addLine(to: split)
        }

        // Trunk thickness grows mildly with input power, but stays readable.
        let inputShare = min(1, (animator.frame.input / max(Double(power.adapterWatts ?? 65), 1)))
        let trunkWidth = 2.2 + CGFloat(inputShare) * 3.0
        context.stroke(trunk, with: .color(accent.opacity(0.16)), lineWidth: trunkWidth + 5)
        context.stroke(trunk, with: .color(accent.opacity(0.72)), lineWidth: trunkWidth)

        if onAC {
            let supplyEndpoint = CGPoint(x: endpointX, y: size.height * 0.27)
            let chargeEndpoint = CGPoint(x: endpointX, y: size.height * 0.73)
            let supplyPath = branchPath(from: split, to: supplyEndpoint)
            let chargePath = branchPath(from: split, to: chargeEndpoint)

            let supplyWatts = animator.frame.supply
            let chargeWatts = animator.frame.charge
            let total = max(supplyWatts + chargeWatts, 0.001)
            let supplyShare = supplyWatts / total
            let chargeShare = chargeWatts / total

            let supplyTint = Palette.coral
            let chargeTint = Palette.honey

            let supplyWidth = 1.5 + CGFloat(supplyShare) * 5.2
            let chargeWidth = 1.5 + CGFloat(chargeShare) * 5.2
            let supplyActive = hoveredBranch == .supply || hoveredBranch == nil
            let chargeActive = hoveredBranch == .charge || hoveredBranch == nil

            // supply branch
            context.stroke(
                supplyPath,
                with: .color(supplyTint.opacity(supplyActive ? 0.14 : 0.05)),
                lineWidth: supplyWidth + 6
            )
            context.stroke(
                supplyPath,
                with: .color(supplyTint.opacity(supplyActive ? 0.82 : 0.24)),
                lineWidth: supplyWidth
            )
            drawParticles(
                context: &context,
                path: supplyPath,
                share: supplyShare,
                tint: supplyTint,
                active: supplyActive && isActive && animationEnabled && !reduceMotion
            )

            // charge branch (hidden/faded when full)
            if hasChargeBranch {
                context.stroke(
                    chargePath,
                    with: .color(chargeTint.opacity(chargeActive ? 0.15 : 0.05)),
                    lineWidth: chargeWidth + 6
                )
                context.stroke(
                    chargePath,
                    with: .color(chargeTint.opacity(chargeActive ? 0.84 : 0.25)),
                    lineWidth: chargeWidth
                )
                drawParticles(
                    context: &context,
                    path: chargePath,
                    share: chargeShare,
                    tint: chargeTint,
                    active: chargeActive && isActive && animationEnabled && !reduceMotion
                )
            } else if power.hasBattery {
                context.stroke(
                    chargePath,
                    with: .color(Palette.inkFaint.opacity(0.25)),
                    style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [3, 4])
                )
            }

            // Split node
            let node = CGRect(x: split.x - 3.2, y: split.y - 3.2, width: 6.4, height: 6.4)
            context.fill(Path(ellipseIn: node), with: .color(Palette.surfaceRaised))
            context.stroke(Path(ellipseIn: node), with: .color(accent.opacity(0.7)), lineWidth: 1.2)

            // Trunk particles
            drawTrunkParticles(context: &context, from: source, to: split, tint: accent)
        } else {
            let endpoint = CGPoint(x: size.width - 132, y: size.height * 0.5)
            let path = branchPath(from: split, to: endpoint)
            let watts = animator.frame.discharge
            let share = min(1, watts / 45)
            let tint = Palette.sage
            let width = 2.2 + CGFloat(share) * 4.2

            context.stroke(path, with: .color(tint.opacity(0.14)), lineWidth: width + 6)
            context.stroke(path, with: .color(tint.opacity(0.82)), lineWidth: width)
            drawParticles(
                context: &context,
                path: path,
                share: max(0.25, share),
                tint: tint,
                active: isActive && animationEnabled && !reduceMotion
            )
            drawTrunkParticles(context: &context, from: source, to: split, tint: tint)
        }
    }

    private func branchPath(from start: CGPoint, to end: CGPoint) -> Path {
        Path { path in
            path.move(to: start)
            path.addCurve(
                to: end,
                control1: CGPoint(x: start.x + 38, y: start.y),
                control2: CGPoint(x: end.x - 38, y: end.y)
            )
        }
    }

    private func drawTrunkParticles(
        context: inout GraphicsContext,
        from start: CGPoint,
        to end: CGPoint,
        tint: Color
    ) {
        guard isActive && animationEnabled && !reduceMotion else { return }
        let count = 3
        for index in 0..<count {
            let phase = (animator.frame.time * 0.75 + Double(index) / Double(count))
                .truncatingRemainder(dividingBy: 1)
            let x = start.x + (end.x - start.x) * CGFloat(phase)
            let point = CGPoint(x: x, y: start.y)
            let glow = CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)
            context.fill(Path(ellipseIn: glow), with: .color(tint.opacity(0.18)))
            let rect = CGRect(x: point.x - 1.4, y: point.y - 1.4, width: 2.8, height: 2.8)
            context.fill(Path(ellipseIn: rect), with: .color(Color(hex: 0xFFF7EC).opacity(0.95)))
        }
    }

    private func drawParticles(
        context: inout GraphicsContext,
        path: Path,
        share: Double,
        tint: Color,
        active: Bool
    ) {
        let count = max(7, Int(6 + share * 14))
        let speed = 0.14 + share * 0.46
        let radius = 1.15 + CGFloat(min(1, share)) * 1.15

        guard let start = pathStart(path), let geometry = cubicPoints(path) else { return }
        for index in 0..<count {
            let base = Double(index) / Double(count)
            let phase: Double
            if active {
                phase = (animator.frame.time * speed + base).truncatingRemainder(dividingBy: 1)
            } else {
                phase = base
            }
            let point = bezier(
                t: CGFloat(phase),
                p0: start,
                c1: geometry.c1,
                c2: geometry.c2,
                p1: geometry.end
            )
            let glowRect = CGRect(
                x: point.x - radius * 2.4,
                y: point.y - radius * 2.4,
                width: radius * 4.8,
                height: radius * 4.8
            )
            context.fill(Path(ellipseIn: glowRect), with: .color(tint.opacity(active ? 0.24 : 0.12)))
            let rect = CGRect(
                x: point.x - radius,
                y: point.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            context.fill(
                Path(ellipseIn: rect),
                with: .color(Color(hex: 0xFFF7EC).opacity(active ? 0.96 : 0.72))
            )
        }
    }

    private func pathStart(_ path: Path) -> CGPoint? {
        var first: CGPoint?
        path.forEach { element in
            if case let .move(to) = element, first == nil {
                first = to
            }
        }
        return first ?? path.boundingRect.origin
    }

    private func cubicPoints(_ path: Path) -> (c1: CGPoint, c2: CGPoint, end: CGPoint)? {
        var result: (CGPoint, CGPoint, CGPoint)?
        path.forEach { element in
            if case let .curve(to, control1, control2) = element, result == nil {
                result = (control1, control2, to)
            }
        }
        return result
    }

    private func bezier(t: CGFloat, p0: CGPoint, c1: CGPoint, c2: CGPoint, p1: CGPoint) -> CGPoint {
        let mt = 1 - t
        let a = mt * mt * mt
        let b = 3 * mt * mt * t
        let c = 3 * mt * t * t
        let d = t * t * t
        return CGPoint(
            x: a * p0.x + b * c1.x + c * c2.x + d * p1.x,
            y: a * p0.y + b * c1.y + c * c2.y + d * p1.y
        )
    }

    // MARK: Nodes

    private func sourceNode(size: CGSize) -> some View {
        VStack(spacing: 3) {
            ZStack {
                Circle()
                    .fill(Palette.surfaceRaised)
                    .frame(width: 34, height: 34)
                    .overlay(Circle().stroke(Palette.line, lineWidth: 1))
                    .shadow(color: Palette.shadow.opacity(0.45), radius: 4, y: 2)
                Image(systemName: onAC ? "powerplug.fill" : "battery.75")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(onAC ? Palette.coral : Palette.sage)
            }
            Text(inputText)
                .font(.claudeLabel(7.5, weight: .semibold))
                .foregroundColor(Palette.inkFaint)
                .lineLimit(1)
                .fixedSize()
        }
        .position(x: 26, y: size.height * 0.5)
        .onHover { hovering in
            if !onAC {
                withAnimation(.easeInOut(duration: 0.15)) { batteryHovered = hovering }
            }
        }
        .help(onAC ? "电源适配器输入" : "电池放电")
    }

    private func branchLabel(
        branch: Branch,
        icon: String,
        title: String,
        value: String,
        tint: Color,
        width: CGFloat
    ) -> some View {
        let highlighted = hoveredBranch == branch
        return HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(tint)
                .frame(width: 15)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.claudeLabel(8, weight: .medium))
                    .foregroundColor(Palette.inkFaint)
                Text(value)
                    .font(.claudeNumber(highlighted ? 12 : 10.5, weight: .semibold))
                    .foregroundColor(highlighted ? tint : Palette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .frame(width: width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tint.opacity(highlighted ? 0.10 : 0.0))
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                hoveredBranch = hovering ? branch : nil
            }
        }
        .help(branch == .charge ? "电池充电功率" : "直接为电脑供电的功率")
    }
}

// MARK: - Energy card

struct EnergyCardView: View {
    let power: PowerMetrics
    let alert: String?
    let settings: AppSettings
    let isActive: Bool
    @Binding var mode: EnergyDisplayMode

    @State private var batteryHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(bigValue)
                            .font(.claudeNumber(28, weight: .semibold))
                            .foregroundColor(Palette.ink)
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)
                        Text(bigUnit)
                            .font(.claudeLabel(10, weight: .semibold))
                            .foregroundColor(Palette.inkFaint)
                    }
                    Text(bigCaption)
                        .font(.claudeBody(9.5, weight: .medium))
                        .foregroundColor(Palette.inkFaint)
                }

                Spacer(minLength: 4)

                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: power.source.isOnAC ? "powerplug" : "battery.75")
                            .font(.system(size: 9, weight: .semibold))
                        Text(power.source.isOnAC ? "适配器输入" : "电池剩余")
                            .font(.claudeLabel(8.5, weight: .medium))
                    }
                    .foregroundColor(Palette.inkFaint)

                    Text(rightValue)
                        .font(.claudeNumber(12, weight: .semibold))
                        .foregroundColor(Palette.inkSoft)
                    if let sub = rightSubvalue {
                        Text(sub)
                            .font(.claudeLabel(8, weight: .medium))
                            .foregroundColor(Palette.inkFaint)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: cycleMode)

            if let alert {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundColor(Palette.alert)
                    Text(alert)
                        .font(.claudeBody(9.5, weight: .medium))
                        .foregroundColor(Palette.inkSoft)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Palette.alertSoft.opacity(0.7))
                )
            }

            PowerFlowDiagram(
                power: power,
                mode: mode,
                unit: settings.powerUnit,
                isActive: isActive,
                animationEnabled: settings.powerFlowAnimationEnabled,
                reduceMotion: settings.reduceMotion,
                batteryHovered: $batteryHovered,
                onCycleMode: cycleMode
            )
            .frame(height: 104)

            metaStrip
                .frame(height: 24)
                .contentShape(Rectangle())
                .onTapGesture(perform: cycleMode)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Palette.surface, Palette.coralMist.opacity(0.34)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Palette.coral.opacity(0.13), lineWidth: 1)
                )
        )
        .shadow(color: Palette.shadow.opacity(0.42), radius: 10, y: 4)
        .help("数据源：\(power.dataSource)\n点击分支或模式按钮可切换功率 / 百分比 / 电池详情")
    }

    private var header: some View {
        HStack(spacing: 7) {
            Text("能量流")
                .font(.claudeSerif(13, weight: .semibold))
                .foregroundColor(Palette.ink)
            TinyBadge(
                text: power.source == .alternatingCurrent ? "AC" : (power.source == .battery ? "BATTERY" : "—"),
                tint: power.source.isOnAC ? Palette.coral : Palette.sage
            )
            if power.isSplitEstimated {
                TinyBadge(text: "估算", tint: Palette.honey)
            }

            Spacer(minLength: 4)

            Button(action: cycleMode) {
                HStack(spacing: 4) {
                    ForEach(EnergyDisplayMode.allCases, id: \.self) { item in
                        Circle()
                            .fill(item == mode ? Palette.coral : Palette.lineStrong)
                            .frame(width: 4.5, height: 4.5)
                    }
                    Text(mode.label)
                        .font(.claudeLabel(8.5, weight: .semibold))
                        .foregroundColor(Palette.inkSoft)
                }
                .padding(.horizontal, 7)
                .frame(height: 22)
                .background(
                    Capsule()
                        .fill(Palette.surfaceRaised.opacity(0.8))
                        .overlay(Capsule().stroke(Palette.line, lineWidth: 0.8))
                )
            }
            .buttonStyle(.plain)
            .help("切换功率 / 百分比 / 电池详情")
        }
    }

    private var metaStrip: some View {
        Group {
            if mode == .battery || batteryHovered {
                HStack(spacing: 0) {
                    metaCell("电池", "\(Fmt.percent(power.batteryPercent, digits: 0)) \(batteryStateText)")
                    metaDivider
                    metaCell("健康", power.batteryHealthPercent.map { Fmt.percent($0, digits: 1) } ?? "—")
                    metaDivider
                    metaCell("循环", power.cycleCount.map { "\($0) 次" } ?? "—")
                    metaDivider
                    metaCell("温度", power.temperatureCelsius.map { String(format: "%.1f °C", $0) } ?? "—")
                }
            } else if power.source.isOnAC {
                HStack(spacing: 0) {
                    metaCell("适配器", power.adapterWatts.map { "\($0) W" } ?? "—")
                    metaDivider
                    metaCell("电池", power.hasBattery ? Fmt.percent(power.batteryPercent, digits: 0) : "无电池")
                    metaDivider
                    metaCell("状态", power.hasBattery ? (power.isFullyCharged ? "已充满" : (power.isCharging ? "充电中" : "已接通")) : "桌面供电")
                }
            } else {
                HStack(spacing: 0) {
                    metaCell("剩余", power.timeRemainingMinutes.map { Fmt.duration(minutes: $0) } ?? "估算中")
                    metaDivider
                    metaCell("电池", Fmt.percent(power.batteryPercent, digits: 0))
                    metaDivider
                    metaCell("放电", Fmt.watts(power.dischargeWatts ?? power.systemWatts, unit: settings.powerUnit))
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Palette.surfaceRaised.opacity(0.46))
        )
        .animation(.easeInOut(duration: 0.18), value: batteryHovered)
        .animation(.easeInOut(duration: 0.18), value: mode)
    }

    private func metaCell(_ title: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(title)
                .font(.claudeLabel(7.5, weight: .medium))
                .foregroundColor(Palette.inkFaint)
            Text(value)
                .font(.claudeLabel(8, weight: .semibold))
                .foregroundColor(Palette.inkSoft)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity)
    }

    private var batteryStateText: String {
        if power.isCharging { return "充电中" }
        if power.isFullyCharged { return "已充满" }
        if power.source == .battery { return "放电中" }
        return "未充电"
    }

    private var metaDivider: some View {
        Rectangle()
            .fill(Palette.line.opacity(0.7))
            .frame(width: 0.7, height: 10)
    }

    private var bigValue: String {
        switch mode {
        case .power:
            return power.systemWatts.map { String(format: "%.1f", $0) } ?? "—"
        case .percentage:
            if power.source.isOnAC {
                let input = max(power.inputWatts ?? 0, 0.001)
                return Fmt.percent((power.supplyWatts ?? 0) / input * 100)
            }
            return Fmt.percent(power.batteryPercent, digits: 0)
        case .battery:
            return Fmt.percent(power.batteryPercent, digits: 0)
        }
    }

    private var bigUnit: String {
        switch mode {
        case .power: return settings.powerUnit.shortTitle
        case .percentage: return ""
        case .battery: return "电量"
        }
    }

    private var bigCaption: String {
        switch mode {
        case .power: return "整机功耗"
        case .percentage: return "供能占总输入比例"
        case .battery: return "电池剩余电量"
        }
    }

    private var rightValue: String {
        if power.source.isOnAC {
            return Fmt.watts(power.inputWatts, unit: settings.powerUnit)
        }
        return Fmt.percent(power.batteryPercent, digits: 0)
    }

    private var rightSubvalue: String? {
        if power.source.isOnAC {
            if let adapter = power.adapterWatts {
                return "适配器上限 \(adapter) W"
            }
            return power.isCharging ? "充电中" : nil
        }
        return power.timeRemainingMinutes.map { Fmt.duration(minutes: $0) }
    }

    private func cycleMode() {
        withAnimation(.easeInOut(duration: 0.2)) {
            mode = mode.next
        }
    }
}
