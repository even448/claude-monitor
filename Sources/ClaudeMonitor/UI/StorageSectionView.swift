import SwiftUI

struct StorageSectionView: View {
    let disk: DiskMetrics
    let indexMonitor: IndexMonitor
    let hasFullDiskAccess: Bool
    let isFocused: Bool
    var onOpenFullDiskAccess: () -> Void
    var onCheckPermission: () -> Void

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Text("存储与索引")
                    .font(.claudeSerif(12.5, weight: .semibold))
                    .foregroundColor(Palette.ink)
                Spacer()
                Button {
                    indexMonitor.scan()
                } label: {
                    HStack(spacing: 4) {
                        if indexMonitor.isScanning {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.65)
                                .frame(width: 10, height: 10)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 8.5, weight: .semibold))
                        }
                        Text(indexMonitor.isScanning ? "扫描中" : "重新扫描")
                    }
                }
                .buttonStyle(QuietButtonStyle(compact: true))
                .disabled(indexMonitor.isScanning)
            }

            diskRow

            Rectangle()
                .fill(Palette.line.opacity(0.7))
                .frame(height: 0.7)

            indexRow
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Palette.surface.opacity(0.88))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(isFocused ? Palette.sage.opacity(0.7) : Palette.line.opacity(0.8), lineWidth: isFocused ? 1.4 : 1)
                )
        )
        .shadow(color: Palette.shadow.opacity(0.3), radius: 7, y: 3)
        .animation(.easeInOut(duration: 0.2), value: expanded)
        .animation(.easeInOut(duration: 0.2), value: isFocused)
    }

    private var diskRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 5) {
                    Image(systemName: "internaldrive.fill")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(Palette.sage)
                    Text("磁盘")
                        .font(.claudeLabel(9.5, weight: .semibold))
                        .foregroundColor(Palette.inkSoft)
                }
                Spacer()
                Text("\(Fmt.bytes(disk.usedBytes)) / \(Fmt.bytes(disk.totalBytes))")
                    .font(.claudeLabel(8.5, weight: .medium))
                    .foregroundColor(Palette.inkFaint)
                Text(Fmt.percent(disk.percent))
                    .font(.claudeNumber(11, weight: .semibold))
                    .foregroundColor(Palette.sage)
                    .frame(width: 34, alignment: .trailing)
            }
            SoftProgressBar(value: disk.percent, tint: Palette.sage, height: 5)
            HStack {
                Text("可用 \(Fmt.bytes(disk.freeBytes))")
                    .font(.claudeLabel(7.5, weight: .medium))
                    .foregroundColor(Palette.inkFaint)
                Spacer()
                Text("APFS · 宗卷容量")
                    .font(.claudeLabel(7, weight: .medium))
                    .foregroundColor(Palette.inkFaint.opacity(0.75))
            }
        }
    }

    private var indexRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Palette.honey.opacity(0.13))
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Palette.honey)
                }
                .frame(width: 23, height: 23)

                VStack(alignment: .leading, spacing: 1) {
                    Text("系统索引")
                        .font(.claudeLabel(9.5, weight: .semibold))
                        .foregroundColor(Palette.inkSoft)
                    Text(indexSubtitle)
                        .font(.claudeLabel(7.5, weight: .medium))
                        .foregroundColor(Palette.inkFaint)
                }

                Spacer(minLength: 4)

                VStack(alignment: .trailing, spacing: 1) {
                    Text(Fmt.bytes(indexMonitor.result.totalBytes))
                        .font(.claudeNumber(11, weight: .semibold))
                        .foregroundColor(Palette.ink)
                    if disk.totalBytes > 0 {
                        Text(Fmt.percent(Double(indexMonitor.result.totalBytes) / Double(disk.totalBytes) * 100, digits: 1) + " 总容量")
                            .font(.claudeLabel(7, weight: .medium))
                            .foregroundColor(Palette.inkFaint)
                    }
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(Palette.inkFaint)
                        .frame(width: 16, height: 20)
                }
                .buttonStyle(.plain)
            }

            if indexMonitor.isWaitingForAdmin {
                indexBanner(
                    icon: "person.badge.key.fill",
                    tint: Palette.coral,
                    text: "等待管理员授权 · 密码由 macOS 处理，不会被 App 保存",
                    trailing: nil
                )
            } else if !hasFullDiskAccess {
                indexBanner(
                    icon: "lock.fill",
                    tint: Palette.honey,
                    text: "完全磁盘访问尚未生效；FSEvents 与完整扫描可能受限",
                    trailing: AnyView(
                        HStack(spacing: 5) {
                            Button("去授权") { onOpenFullDiskAccess() }
                                .buttonStyle(PlainLinkButtonStyle())
                            Button("重查") { onCheckPermission() }
                                .buttonStyle(PlainLinkButtonStyle())
                        }
                    )
                )
            }

            if needsAdmin && !indexMonitor.isWaitingForAdmin {
                indexBanner(
                    icon: "lock.shield.fill",
                    tint: Palette.honey,
                    text: "macOS 系统保护：Spotlight 索引需管理员读取",
                    trailing: AnyView(
                        Button("管理员读取") { indexMonitor.scanWithAdminPrivileges() }
                            .buttonStyle(PlainLinkButtonStyle())
                    )
                )
            } else if indexMonitor.result.adminSpotlightUsed == true {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 7.5))
                        .foregroundColor(Palette.sage)
                    Text("Spotlight 已通过管理员读取")
                        .font(.claudeLabel(7.5, weight: .medium))
                        .foregroundColor(Palette.inkFaint)
                    Spacer()
                    Button("刷新") { indexMonitor.scanWithAdminPrivileges() }
                        .buttonStyle(PlainLinkButtonStyle())
                }
                .padding(.horizontal, 7)
            }

            if let error = indexMonitor.lastError, !indexMonitor.isWaitingForAdmin {
                Text(error)
                    .font(.claudeBody(7.5))
                    .foregroundColor(Palette.alert.opacity(0.85))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if indexMonitor.isScanning {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini).scaleEffect(0.62)
                    Text(indexMonitor.isWaitingForAdmin
                         ? "等待管理员授权…"
                         : "正在扫描 · 已检查 \(indexMonitor.scannedFiles) 个文件")
                        .font(.claudeLabel(7.5, weight: .medium))
                        .foregroundColor(Palette.inkFaint)
                    Spacer()
                }
            }

            if expanded {
                VStack(spacing: 5) {
                    if indexMonitor.result.categories.isEmpty {
                        Text("尚无索引扫描结果")
                            .font(.claudeBody(8.5))
                            .foregroundColor(Palette.inkFaint)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(indexMonitor.result.categories) { category in
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(category.accessible ? Palette.honey : Palette.lineStrong)
                                    .frame(width: 4, height: 4)
                                Text(category.name)
                                    .font(.claudeBody(8.5, weight: .medium))
                                    .foregroundColor(Palette.inkSoft)
                                    .lineLimit(1)
                                Spacer()
                                Text(category.accessible ? Fmt.bytes(category.bytes) : "受限")
                                    .font(.claudeNumber(8, weight: .semibold))
                                    .foregroundColor(category.accessible ? Palette.inkFaint : Palette.inkFaint.opacity(0.6))
                            }
                            .help(category.path + (category.note.map { "\n" + $0 } ?? ""))
                        }
                    }
                    HStack {
                        Text(indexMonitor.lastScanDate.map { "上次扫描 \(Fmt.relativeTime($0))" } ?? "尚未扫描")
                            .font(.claudeLabel(7, weight: .medium))
                            .foregroundColor(Palette.inkFaint)
                        Spacer()
                        Text("每 6 小时自动更新")
                            .font(.claudeLabel(7, weight: .medium))
                            .foregroundColor(Palette.inkFaint.opacity(0.75))
                    }
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Palette.paperDeep.opacity(0.45))
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var indexSubtitle: String {
        if indexMonitor.isWaitingForAdmin {
            return "等待管理员授权…"
        }
        if indexMonitor.isScanning {
            return "Spotlight · FSEvents · 元数据"
        }
        if indexMonitor.result.adminSpotlightUsed == true {
            return "管理员读取 Spotlight · 其他索引自动更新"
        }
        if needsAdmin {
            return "macOS 系统保护 · 管理员读取"
        }
        if indexMonitor.result.permissionLimited {
            return "部分不可读 · 可授权后重扫"
        }
        return "Spotlight · FSEvents · 文稿版本"
    }

    private var needsAdmin: Bool {
        if let flag = indexMonitor.result.spotlightNeedsAdmin {
            return flag
        }
        let modernMac = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
        return modernMac && indexMonitor.result.categories.contains {
            $0.path == IndexScanner.spotlightPath && !$0.accessible
        }
    }

    private func indexBanner(
        icon: String,
        tint: Color,
        text: String,
        trailing: AnyView?
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 7.5))
                .foregroundColor(tint)
            Text(text)
                .font(.claudeBody(8))
                .foregroundColor(Palette.inkSoft)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 3)
            if let trailing { trailing }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tint.opacity(0.12))
        )
    }
}

private struct PlainLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.claudeLabel(8, weight: .semibold))
            .foregroundColor(Palette.coral.opacity(configuration.isPressed ? 0.7 : 1))
    }
}
