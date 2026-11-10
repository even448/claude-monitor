import SwiftUI

struct AnomalySectionView: View {
    let monitor: StorageAnomalyMonitor
    let isFocused: Bool
    @Binding var showAll: Bool
    var onRun: () -> Void
    var onOpenFullDiskAccess: () -> Void

    @State private var copiedPath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            content
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Palette.surface.opacity(0.92),
                            monitor.report.hasFindings ? Palette.alertSoft.opacity(0.30) : Palette.surface.opacity(0.92)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(
                            isFocused ? Palette.coral.opacity(0.62) : (monitor.report.hasFindings ? Palette.alert.opacity(0.16) : Palette.line.opacity(0.8)),
                            lineWidth: isFocused ? 1.4 : 0.9
                        )
                )
        )
        .shadow(color: Palette.shadow.opacity(0.28), radius: 7, y: 3)
        .animation(.easeInOut(duration: 0.2), value: isFocused)
        .animation(.easeInOut(duration: 0.2), value: monitor.report.hasFindings)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("异常变化")
                .font(.claudeSerif(12.5, weight: .semibold))
                .foregroundColor(Palette.ink)
            if monitor.report.hasFindings {
                TinyBadge(text: "\(monitor.report.entries.count) 项", tint: Palette.alert)
            }
            Spacer()
            if monitor.isScanning {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini).scaleEffect(0.62)
                    Text("比对中")
                        .font(.claudeLabel(7.5, weight: .medium))
                        .foregroundColor(Palette.inkFaint)
                }
            } else if monitor.report.scannedAt != .distantPast {
                Text(monitor.report.isToday ? "今日" : Fmt.dateTime(monitor.report.scannedAt))
                    .font(.claudeLabel(7.5, weight: .medium))
                    .foregroundColor(Palette.inkFaint)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if monitor.isScanning {
            scanningState
        } else if monitor.report.scannedAt == .distantPast {
            emptyState(
                icon: "leaf.fill",
                tint: Palette.sage,
                title: "还没有检测记录",
                subtitle: "首次运行会先建立一份存储基线。"
            )
        } else if monitor.report.isBaseline {
            emptyState(
                icon: "flag.checkered",
                tint: Palette.sage,
                title: "存储基线已建立",
                subtitle: "下次检测起，会对比单文件或目录超过阈值的体积变化。"
            )
        } else if monitor.report.entries.isEmpty {
            emptyState(
                icon: "checkmark.seal.fill",
                tint: Palette.sage,
                title: "今日无异常变化",
                subtitle: monitor.report.permissionLimited
                    ? "扫描部分受限；建议授予完全磁盘访问后再检测。"
                    : "上次检测于 \(Fmt.relativeTime(monitor.report.scannedAt))，一切安静。"
            )
        } else {
            findings
        }
    }

    private var scanningState: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.72)
                VStack(alignment: .leading, spacing: 1) {
                    Text("正在扫描文件系统")
                        .font(.claudeLabel(9.5, weight: .semibold))
                        .foregroundColor(Palette.inkSoft)
                    Text("已检查 \(monitor.progress.scannedFiles) 个文件 · 低优先级运行")
                        .font(.claudeLabel(7.5, weight: .medium))
                        .foregroundColor(Palette.inkFaint)
                }
                Spacer()
            }
            if let path = monitor.progress.currentPath {
                Text(shortened(path, maxLength: 54))
                    .font(.claudeBody(7.5))
                    .foregroundColor(Palette.inkFaint.opacity(0.8))
                    .lineLimit(1)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Palette.paperDeep.opacity(0.38))
        )
    }

    private var findings: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(monitor.report.entries.count) 项变化")
                    .font(.claudeLabel(9, weight: .semibold))
                    .foregroundColor(Palette.inkSoft)
                Spacer()
                Text(netDescription)
                    .font(.claudeLabel(8, weight: .semibold))
                    .foregroundColor(monitor.report.totalIncreaseBytes >= monitor.report.totalDecreaseBytes ? Palette.alert : Palette.sage)
            }

            if monitor.report.permissionLimited {
                HStack(spacing: 5) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 7))
                    Text("扫描部分受限，结果可能不完整")
                        .font(.claudeBody(8))
                    Spacer(minLength: 2)
                    Button("去授权") { onOpenFullDiskAccess() }
                        .buttonStyle(.plain)
                        .font(.claudeLabel(8, weight: .semibold))
                        .foregroundColor(Palette.coral)
                }
                .foregroundColor(Palette.honey)
            }

            let visible = showAll ? monitor.report.entries : Array(monitor.report.entries.prefix(3))
            VStack(spacing: 3) {
                ForEach(visible) { change in
                    row(for: change)
                }
            }
            .if(showAll) { view in
                AnyView(
                    ScrollView(.vertical, showsIndicators: false) {
                        view
                    }
                    .frame(maxHeight: 150)
                )
            }

            HStack(spacing: 8) {
                if monitor.report.entries.count > 3 {
                    Button(showAll ? "收起列表" : "查看全部 \(monitor.report.entries.count) 项") {
                        withAnimation(.easeInOut(duration: 0.2)) { showAll.toggle() }
                    }
                    .buttonStyle(.plain)
                    .font(.claudeLabel(8, weight: .semibold))
                    .foregroundColor(Palette.coral)
                }
                Spacer()
                if let copiedPath {
                    Text("已复制 \(shortened(copiedPath, maxLength: 20))")
                        .font(.claudeLabel(7, weight: .medium))
                        .foregroundColor(Palette.sage)
                        .transition(.opacity)
                }
                Button("立即检测") { onRun() }
                    .buttonStyle(.plain)
                    .font(.claudeLabel(8, weight: .semibold))
                    .foregroundColor(Palette.inkSoft)
            }
            .padding(.top, 1)
        }
    }

    private func row(for change: StorageChange) -> some View {
        HStack(spacing: 5) {
            Image(systemName: change.isDirectory ? "folder.fill" : "doc.fill")
                .font(.system(size: 8, weight: .medium))
                .foregroundColor(change.direction == .increase ? Palette.honey : Palette.sage)
                .frame(width: 11)

            VStack(alignment: .leading, spacing: 1) {
                Text(displayPath(change.path))
                    .font(.claudeBody(8.5, weight: .medium))
                    .foregroundColor(Palette.inkSoft)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(Fmt.bytes(change.beforeBytes)) → \(Fmt.bytes(change.afterBytes)) · \(Fmt.relativeTime(change.changedAt))")
                    .font(.claudeLabel(6.8, weight: .medium))
                    .foregroundColor(Palette.inkFaint)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
            .onTapGesture { copy(path: change.path) }
            .help("\(change.path)\n点击复制路径")

            Spacer(minLength: 2)

            Text(Fmt.signedBytes(change.deltaBytes))
                .font(.claudeNumber(8.5, weight: .semibold))
                .foregroundColor(change.direction == .increase ? Palette.alert : Palette.sage)
                .lineLimit(1)

            Button {
                copy(path: change.path)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 6.5, weight: .semibold))
                    .foregroundColor(Palette.inkFaint)
                    .frame(width: 13, height: 13)
            }
            .buttonStyle(.plain)
            .help("点击复制路径")

            Button {
                SystemAccess.revealInFinder(path: change.path)
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 6.5, weight: .semibold))
                    .foregroundColor(Palette.inkFaint)
                    .frame(width: 13, height: 13)
            }
            .buttonStyle(.plain)
            .help("在 Finder 中显示")
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Palette.surfaceRaised.opacity(0.52))
        )
    }

    private func copy(path: String) {
        SystemAccess.copyToPasteboard(path)
        withAnimation(.easeOut(duration: 0.15)) { copiedPath = path }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if copiedPath == path {
                withAnimation(.easeIn(duration: 0.2)) { copiedPath = nil }
            }
        }
    }

    private func emptyState(icon: String, tint: Color, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ZStack {
                Circle().fill(tint.opacity(0.12)).frame(width: 28, height: 28)
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.claudeBody(10.5, weight: .semibold))
                    .foregroundColor(Palette.inkSoft)
                Text(subtitle)
                    .font(.claudeBody(8.5))
                    .foregroundColor(Palette.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private var netDescription: String {
        let net = monitor.report.totalIncreaseBytes - monitor.report.totalDecreaseBytes
        if net >= 0 { return "净增 \(Fmt.bytes(net))" }
        return "净减 \(Fmt.bytes(-net))"
    }

    private func displayPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home + "/") {
            return "~/" + path.dropFirst(home.count + 1)
        }
        return path
    }

    private func shortened(_ path: String, maxLength: Int) -> String {
        guard path.count > maxLength else { return path }
        return "…" + path.suffix(maxLength - 1)
    }
}
