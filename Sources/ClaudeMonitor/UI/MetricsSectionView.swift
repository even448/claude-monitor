import SwiftUI

struct MetricCardView: View {
    let kind: MetricKind
    let value: Double?
    let detail: String
    let history: MetricHistory
    let tint: Color
    let isFocused: Bool
    let isExpanded: Bool
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(tint.opacity(0.12))
                    Image(systemName: kind.symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(tint)
                }
                .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 0) {
                    Text(kind.title)
                        .font(.claudeLabel(10, weight: .semibold))
                        .foregroundColor(Palette.ink)
                    Text(kind.englishTitle)
                        .font(.claudeLabel(6.5, weight: .medium))
                        .foregroundColor(Palette.inkFaint)
                        .textCase(.uppercase)
                }
                Spacer(minLength: 2)
                Text(value.map { Fmt.percent($0) } ?? "—")
                    .font(.claudeNumber(17, weight: .semibold))
                    .foregroundColor(value == nil ? Palette.inkFaint : loadColor)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            }

            SparklineView(
                points: history.points,
                tint: tint,
                height: 31,
                valueFormatter: { Fmt.percent($0) }
            )

            VStack(spacing: 4) {
                SoftProgressBar(value: value ?? 0, tint: tint, height: 4)
                HStack(spacing: 3) {
                    Text(detail)
                        .font(.claudeLabel(7.5, weight: .medium))
                        .foregroundColor(Palette.inkFaint)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 6.5, weight: .bold))
                        .foregroundColor(Palette.inkFaint.opacity(0.7))
                }
            }
        }
        .padding(10)
        .frame(height: 116)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Palette.surfaceRaised, tint.opacity(hovering ? 0.075 : 0.035)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(
                            isFocused ? tint.opacity(0.65) : Palette.line.opacity(hovering ? 0.9 : 0.65),
                            lineWidth: isFocused ? 1.4 : 0.8
                        )
                )
        )
        .shadow(
            color: Palette.shadow.opacity(hovering ? 0.65 : 0.25),
            radius: hovering ? 11 : 5,
            x: 0,
            y: hovering ? 6 : 2
        )
        .offset(y: hovering ? -1.5 : 0)
        .scaleEffect(hovering ? 1.012 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.18)) { self.hovering = hovering }
        }
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .animation(.easeInOut(duration: 0.18), value: isFocused)
    }

    private var loadColor: Color {
        guard let value else { return Palette.inkFaint }
        switch value {
        case ..<60: return tint
        case ..<85: return Palette.honey
        default: return Palette.alert
        }
    }
}

// MARK: - Detail panel

struct MetricDetailView: View {
    let kind: MetricKind
    let snapshot: SystemSnapshot
    let processes: ProcessDetails
    let isLoadingProcesses: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch kind {
            case .cpu:
                cpuDetail
            case .gpu:
                gpuDetail
            case .memory:
                memoryDetail
            case .disk:
                diskDetail
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Palette.surfaceRaised.opacity(0.86))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Palette.line, lineWidth: 0.8)
                )
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var cpuDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            detailHeader("核心负载", trailing: "\(snapshot.cpu.perCore.count) 核")
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(Array(snapshot.cpu.perCore.enumerated()), id: \.offset) { index, value in
                    VStack(spacing: 3) {
                        GeometryReader { proxy in
                            ZStack(alignment: .bottom) {
                                Capsule().fill(Palette.coral.opacity(0.10))
                                Capsule()
                                    .fill(value > 85 ? Palette.alert : Palette.coral.opacity(0.78))
                                    .frame(height: max(3, proxy.size.height * value / 100))
                            }
                            .frame(width: 11)
                            .frame(maxWidth: .infinity)
                        }
                        .frame(height: 36)
                        .help("核心 \(index)：\(Fmt.percent(value, digits: 0))")
                        Text("\(index)")
                            .font(.claudeLabel(6.5, weight: .medium))
                            .foregroundColor(Palette.inkFaint)
                        Text("\(Int(value.rounded()))%")
                            .font(.claudeLabel(5.5, weight: .medium))
                            .foregroundColor(Palette.inkFaint.opacity(0.75))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            hairline
            processList(title: "CPU 占用 Top 3", rows: Array(processes.topCPU.prefix(3)), value: { Fmt.percent($0.cpuPercent, digits: 1) })
        }
    }

    private var gpuDetail: some View {
        VStack(alignment: .leading, spacing: 9) {
            detailHeader("图形处理器", trailing: snapshot.gpu.isAvailable ? "实时" : "不可用")
            HStack(spacing: 0) {
                statCell("使用率", Fmt.percent(snapshot.gpu.usage))
                divider
                statCell("显存占用", Fmt.bytes(snapshot.gpu.memoryBytes))
                divider
                statCell("设备", snapshot.gpu.name ?? "—")
            }
            Text("数据来自 IORegistry 的 IOAccelerator · PerformanceStatistics。若驱动未公开该字段，应用会如实显示不可用，不会猜测占用率。")
                .font(.claudeBody(8.5))
                .foregroundColor(Palette.inkFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var memoryDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            detailHeader("内存构成", trailing: "已用 " + Fmt.memory(snapshot.memory.usedBytes))
            GeometryReader { proxy in
                HStack(spacing: 1.5) {
                    segment(value: snapshot.memory.activeBytes, total: snapshot.memory.totalBytes, width: proxy.size.width, color: Palette.honey)
                    segment(value: snapshot.memory.wiredBytes, total: snapshot.memory.totalBytes, width: proxy.size.width, color: Palette.coral)
                    segment(value: snapshot.memory.compressedBytes, total: snapshot.memory.totalBytes, width: proxy.size.width, color: Palette.dustyBlue)
                    segment(value: snapshot.memory.cachedBytes, total: snapshot.memory.totalBytes, width: proxy.size.width, color: Palette.sage)
                }
            }
            .frame(height: 8)
            .clipShape(Capsule())

            HStack(spacing: 8) {
                legend("活跃", Palette.honey)
                legend("联动", Palette.coral)
                legend("压缩", Palette.dustyBlue)
                legend("缓存", Palette.sage)
                Spacer()
                Text("交换 \(Fmt.memory(snapshot.memory.swapUsedBytes))")
                    .font(.claudeLabel(7.5, weight: .medium))
                    .foregroundColor(Palette.inkFaint)
            }

            hairline
            processList(title: "内存占用 Top 3", rows: Array(processes.topMemory.prefix(3)), value: { Fmt.memory($0.memoryBytes) })
        }
    }

    private var diskDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            detailHeader("宗卷容量", trailing: "APFS")
            HStack(spacing: 0) {
                statCell("总容量", Fmt.bytes(snapshot.disk.totalBytes))
                divider
                statCell("已使用", Fmt.bytes(snapshot.disk.usedBytes))
                divider
                statCell("可用", Fmt.bytes(snapshot.disk.freeBytes))
            }
            SoftProgressBar(value: snapshot.disk.percent, tint: Palette.sage, height: 6)
            Text("异常检测会对比每日快照；系统索引空间在下方单独统计，可能受完全磁盘访问权限影响。")
                .font(.claudeBody(8.5))
                .foregroundColor(Palette.inkFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func detailHeader(_ title: String, trailing: String) -> some View {
        HStack {
            Text(title)
                .font(.claudeSerif(11.5, weight: .semibold))
                .foregroundColor(Palette.ink)
            Spacer()
            Text(trailing)
                .font(.claudeLabel(8, weight: .medium))
                .foregroundColor(Palette.inkFaint)
        }
    }

    private func processList(title: String, rows: [ProcessUsage], value: @escaping (ProcessUsage) -> String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .font(.claudeLabel(8, weight: .semibold))
                    .foregroundColor(Palette.inkFaint)
                Spacer()
                if isLoadingProcesses {
                    ProgressView().controlSize(.mini).scaleEffect(0.65)
                }
            }
            if rows.isEmpty {
                Text(processes.error ?? "展开片刻后读取进程信息…")
                    .font(.claudeBody(8.5))
                    .foregroundColor(Palette.inkFaint)
            } else {
                ForEach(rows) { row in
                    HStack(spacing: 5) {
                        Image(systemName: "circle.dashed")
                            .font(.system(size: 7.5, weight: .medium))
                            .foregroundColor(Palette.inkFaint.opacity(0.7))
                        Text(row.shortName)
                            .font(.claudeBody(9, weight: .medium))
                            .foregroundColor(Palette.inkSoft)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(value(row))
                            .font(.claudeNumber(8.5, weight: .semibold))
                            .foregroundColor(Palette.inkSoft)
                    }
                }
            }
        }
    }

    private func statCell(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.claudeLabel(7.5, weight: .medium))
                .foregroundColor(Palette.inkFaint)
            Text(value)
                .font(.claudeNumber(9.5, weight: .semibold))
                .foregroundColor(Palette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var divider: some View {
        Rectangle()
            .fill(Palette.line)
            .frame(width: 0.7, height: 20)
            .padding(.horizontal, 6)
    }

    private var hairline: some View {
        Rectangle()
            .fill(Palette.line.opacity(0.75))
            .frame(height: 0.7)
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 4, height: 4)
            Text(title)
                .font(.claudeLabel(7, weight: .medium))
                .foregroundColor(Palette.inkFaint)
        }
    }

    private func segment(value: Int64, total: Int64, width: CGFloat, color: Color) -> some View {
        let fraction = total > 0 ? CGFloat(value) / CGFloat(total) : 0
        return Rectangle()
            .fill(color.opacity(0.8))
            .frame(width: max(0, width * fraction))
    }
}

// MARK: - Section

struct MetricsSectionView: View {
    let engine: MonitorEngine
    let focusedKind: MetricKind?
    @Binding var expandedKind: MetricKind?
    var onFocus: (MetricKind) -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 9),
        GridItem(.flexible(), spacing: 9)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("实时负载")
                    .font(.claudeSerif(12.5, weight: .semibold))
                    .foregroundColor(Palette.ink)
                Spacer()
                Text("最近 60 秒")
                    .font(.claudeLabel(8, weight: .medium))
                    .foregroundColor(Palette.inkFaint)
            }

            LazyVGrid(columns: columns, spacing: 9) {
                ForEach(MetricKind.allCases) { kind in
                    MetricCardView(
                        kind: kind,
                        value: value(for: kind),
                        detail: detail(for: kind),
                        history: engine.history(for: kind),
                        tint: tint(for: kind),
                        isFocused: focusedKind == kind,
                        isExpanded: expandedKind == kind,
                        onTap: {
                            onFocus(kind)
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                                expandedKind = expandedKind == kind ? nil : kind
                            }
                            if expandedKind == kind, kind == .cpu || kind == .memory {
                                engine.loadProcessDetails(force: true)
                            }
                        }
                    )
                }
            }

            if let expandedKind {
                MetricDetailView(
                    kind: expandedKind,
                    snapshot: engine.snapshot,
                    processes: engine.processDetails,
                    isLoadingProcesses: engine.isProcessDetailsLoading
                )
                .onAppear {
                    if expandedKind == .cpu || expandedKind == .memory {
                        engine.loadProcessDetails(force: true)
                    }
                }
            }
        }
    }

    private func value(for kind: MetricKind) -> Double? {
        switch kind {
        case .cpu: return engine.snapshot.cpu.usage
        case .gpu: return engine.snapshot.gpu.usage
        case .memory: return engine.snapshot.memory.percent
        case .disk: return engine.snapshot.disk.percent
        }
    }

    private func detail(for kind: MetricKind) -> String {
        switch kind {
        case .cpu:
            return "\(engine.snapshot.cpu.perCore.count) 核 · 整体占用"
        case .gpu:
            if engine.snapshot.gpu.isAvailable {
                return engine.snapshot.gpu.name ?? "Apple GPU"
            }
            return "系统未提供指标"
        case .memory:
            return "\(Fmt.memory(engine.snapshot.memory.usedBytes)) / \(Fmt.memory(engine.snapshot.memory.totalBytes))"
        case .disk:
            return "\(Fmt.bytes(engine.snapshot.disk.usedBytes)) / \(Fmt.bytes(engine.snapshot.disk.totalBytes))"
        }
    }

    private func tint(for kind: MetricKind) -> Color {
        switch kind {
        case .cpu: return Palette.coral
        case .gpu: return Palette.dustyBlue
        case .memory: return Palette.honey
        case .disk: return Palette.sage
        }
    }
}
