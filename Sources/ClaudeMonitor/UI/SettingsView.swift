import SwiftUI
import UserNotifications

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var storageMonitor: StorageAnomalyMonitor
    @ObservedObject var indexMonitor: IndexMonitor
    @ObservedObject var notificationManager: NotificationManager

    var petAnimated: Bool
    var reduceMotion: Bool
    var onBack: () -> Void
    var onOpenFullDiskAccess: () -> Void
    var onOpenNotificationSettings: () -> Void
    var onQuit: () -> Void

    @State private var showResetConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    refreshCard
                    anomalyCard
                    appearanceCard
                    permissionCard
                    aboutCard
                    Button(action: onBack) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 8, weight: .bold))
                            Text("返回概览")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(QuietButtonStyle())
                    .padding(.top, 2)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
        }
        .confirmationDialog(
            "重新建立存储基线？",
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("重新建立", role: .destructive) {
                storageMonitor.resetBaseline()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("当前基线与异常报告会被清除，下一次扫描会生成新的基线。")
        }
        .onAppear {
            notificationManager.refreshAuthorizationStatus()
            storageMonitor.refreshPermissionState()
        }
        .onChange(of: settings.notificationsEnabled) { enabled in
            if enabled {
                notificationManager.requestAuthorizationIfNeeded()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Palette.inkSoft)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Palette.surfaceRaised.opacity(0.8)))
                    .overlay(Circle().stroke(Palette.line, lineWidth: 0.8))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                Text("设置")
                    .font(.claudeSerif(18, weight: .semibold))
                    .foregroundColor(Palette.ink)
                Text("所有更改即时生效并自动保存")
                    .font(.claudeLabel(8, weight: .medium))
                    .foregroundColor(Palette.inkFaint)
            }

            Spacer()

            PetMascotView(
                mood: .curious,
                size: 38,
                animated: petAnimated,
                reduceMotion: reduceMotion
            )
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    // MARK: General

    private var refreshCard: some View {
        SettingsCard(title: "数据刷新", subtitle: "轻量采样，不阻塞界面") {
            SettingsRow(title: "指标刷新频率", subtitle: "CPU · GPU · 内存 · 磁盘") {
                ChoicePills(
                    options: settings.refreshOptions,
                    selection: Binding(
                        get: { settings.refreshInterval },
                        set: { settings.refreshInterval = $0 }
                    ),
                    formatter: { String(format: "%.0fs", $0) }
                )
            }
            SettingsDivider()
            SettingsRow(title: "功耗刷新频率", subtitle: "适配器与电池遥测独立采样") {
                ChoicePills(
                    options: settings.powerRefreshOptions,
                    selection: Binding(
                        get: { settings.powerRefreshInterval },
                        set: { settings.powerRefreshInterval = $0 }
                    ),
                    formatter: { String(format: "%.0fs", $0) }
                )
            }
            SettingsDivider()
            SettingsRow(title: "功率显示单位", subtitle: "瓦特或英热单位 / 小时") {
                ChoicePills(
                    options: PowerUnit.allCases.map(\.rawValue),
                    selection: Binding(
                        get: { settings.powerUnit.rawValue },
                        set: { if let unit = PowerUnit(rawValue: $0) { settings.powerUnit = unit } }
                    ),
                    formatter: { $0 == PowerUnit.watt.rawValue ? "W" : "BTU/h" }
                )
            }
        }
    }

    private var anomalyCard: some View {
        SettingsCard(title: "存储异常检测", subtitle: "每天对比一次文件系统快照") {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text("告警阈值")
                        .font(.claudeLabel(9.5, weight: .semibold))
                        .foregroundColor(Palette.inkSoft)
                    Spacer()
                    Text("\(settings.anomalyThresholdMB) MB")
                        .font(.claudeNumber(11, weight: .semibold))
                        .foregroundColor(Palette.coral)
                }
                WarmSlider(
                    value: Binding(
                        get: { Double(settings.anomalyThresholdMB) },
                        set: { settings.anomalyThresholdMB = Int($0.rounded()) }
                    ),
                    range: 100...5_000,
                    step: 50
                )
                HStack {
                    Text("单文件或单目录变化超过此值时告警")
                        .font(.claudeLabel(7.5, weight: .medium))
                        .foregroundColor(Palette.inkFaint)
                    Spacer()
                    Text("默认 500 MB")
                        .font(.claudeLabel(7, weight: .medium))
                        .foregroundColor(Palette.inkFaint.opacity(0.7))
                }
            }

            SettingsDivider()

            SettingsRow(title: "每日检测时间", subtitle: "错过时会在下次启动补跑") {
                TimeWheel(
                    hour: $settings.dailyHour,
                    minute: $settings.dailyMinute,
                    onChange: { storageMonitor.checkSchedule() }
                )
            }

            SettingsDivider()

            SettingsRow(title: "系统通知", subtitle: "存储异常与持续高功耗") {
                Toggle("", isOn: $settings.notificationsEnabled)
                    .labelsHidden()
                    .toggleStyle(WarmToggleStyle())
            }

            if settings.notificationsEnabled {
                SettingsRow(title: "通知声音", subtitle: "静音时仅显示横幅") {
                    Toggle("", isOn: $settings.notificationSoundEnabled)
                        .labelsHidden()
                        .toggleStyle(WarmToggleStyle())
                }
            }

            SettingsDivider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("存储基线")
                        .font(.claudeLabel(9, weight: .semibold))
                        .foregroundColor(Palette.inkSoft)
                    Text(storageMonitor.baselineDate.map { "建立于 \(Fmt.dateTime($0))" } ?? "尚未建立")
                        .font(.claudeLabel(7.5, weight: .medium))
                        .foregroundColor(Palette.inkFaint)
                }
                Spacer()
                Button("重新建立") { showResetConfirmation = true }
                    .buttonStyle(QuietButtonStyle(compact: true))
                    .disabled(storageMonitor.isScanning)
            }

            HStack {
                Text("下次自动检测")
                    .font(.claudeLabel(8, weight: .medium))
                    .foregroundColor(Palette.inkFaint)
                Spacer()
                Text(storageMonitor.nextScheduledScan.map { Fmt.dateTime($0) } ?? "—")
                    .font(.claudeLabel(8, weight: .semibold))
                    .foregroundColor(Palette.inkSoft)
            }
        }
    }

    private var appearanceCard: some View {
        SettingsCard(title: "外观与动效", subtitle: "把安静留给后台") {
            SettingsRow(title: "宠物动画", subtitle: "呼吸、眨眼与表情反馈") {
                Toggle("", isOn: $settings.petAnimationsEnabled)
                    .labelsHidden()
                    .toggleStyle(WarmToggleStyle())
            }
            SettingsDivider()
            SettingsRow(title: "减少动态效果", subtitle: "关闭流动粒子与呼吸动画") {
                Toggle("", isOn: $settings.reduceMotion)
                    .labelsHidden()
                    .toggleStyle(WarmToggleStyle())
            }
            SettingsDivider()
            SettingsRow(title: "功率分流动画", subtitle: "关闭后可进一步降低功耗") {
                Toggle("", isOn: $settings.powerFlowAnimationEnabled)
                    .labelsHidden()
                    .toggleStyle(WarmToggleStyle())
            }
        }
    }

    // MARK: Permissions

    private var permissionCard: some View {
        SettingsCard(title: "权限与通知", subtitle: "只申请完成功能所需的最小权限") {
            VStack(alignment: .leading, spacing: 7) {
                permissionRow(
                    icon: "lock.shield",
                    tint: Palette.sage,
                    title: "完全磁盘访问",
                    status: storageMonitor.hasFullDiskAccess ? "已授权" : "未授权",
                    active: storageMonitor.hasFullDiskAccess,
                    detail: "用于 FSEvents、用户数据与完整存储快照。macOS 26/27 的 Spotlight 索引另有系统保护，需管理员读取。"
                )
                HStack(spacing: 6) {
                    Button("打开系统设置") { onOpenFullDiskAccess() }
                        .buttonStyle(QuietButtonStyle(compact: true))
                    Button("重新检查") {
                        storageMonitor.refreshPermissionState()
                        indexMonitor.scan()
                    }
                    .buttonStyle(QuietButtonStyle(compact: true))
                    Button("管理员读取 Spotlight") {
                        indexMonitor.scanWithAdminPrivileges()
                    }
                    .buttonStyle(QuietButtonStyle(compact: true))
                    .disabled(indexMonitor.isScanning)
                }
                if indexMonitor.isWaitingForAdmin {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini).scaleEffect(0.6)
                        Text("等待管理员授权，密码由 macOS 处理")
                            .font(.claudeLabel(7.5, weight: .medium))
                            .foregroundColor(Palette.inkFaint)
                    }
                }
            }

            SettingsDivider()

            VStack(alignment: .leading, spacing: 7) {
                permissionRow(
                    icon: "bell.badge",
                    tint: Palette.coral,
                    title: "通知",
                    status: notificationStatusText,
                    active: notificationManager.authorizationStatus == .authorized || notificationManager.authorizationStatus == .provisional,
                    detail: "异常报告与持续高功耗提醒。点击通知会展开面板并定位到对应区域。"
                )
                HStack(spacing: 7) {
                    Button("请求通知权限") {
                        notificationManager.requestAuthorizationIfNeeded()
                    }
                    .buttonStyle(QuietButtonStyle(compact: true))
                    Button("打开通知设置") { onOpenNotificationSettings() }
                        .buttonStyle(QuietButtonStyle(compact: true))
                }
            }

            Text("应用不启用 App Sandbox，以便在获得完全磁盘访问后读取受保护目录。macOS 26/27 起 .Spotlight-V100 连完全磁盘访问也无法直接读取，只能通过用户明确触发的管理员授权调用 mdutil -L；密码由 macOS 处理，App 不接收、不保存。应用没有网络代码，也不会上传任何数据。")
                .font(.claudeBody(8))
                .foregroundColor(Palette.inkFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func permissionRow(
        icon: String,
        tint: Color,
        title: String,
        status: String,
        active: Bool,
        detail: String
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint.opacity(0.12))
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(tint)
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.claudeLabel(9.5, weight: .semibold))
                        .foregroundColor(Palette.inkSoft)
                    TinyBadge(text: status, tint: active ? Palette.sage : Palette.honey)
                }
                Text(detail)
                    .font(.claudeBody(8))
                    .foregroundColor(Palette.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var osVersionText: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private var notificationStatusText: String {
        switch notificationManager.authorizationStatus {
        case .authorized: return "已允许"
        case .provisional: return "临时"
        case .denied: return "已拒绝"
        case .notDetermined: return "未请求"
        @unknown default: return "未知"
        }
    }

    private var aboutCard: some View {
        SettingsCard(title: "关于", subtitle: "Claude Monitor 1.1") {
            VStack(alignment: .leading, spacing: 5) {
                Text("一款非官方、本地优先的 macOS 状态栏小工具。视觉灵感来自温暖的纸张与陶土色，所有宠物与分流动画均由 SwiftUI 矢量绘制。")
                    .font(.claudeBody(8.5))
                    .foregroundColor(Palette.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                Text("与 Anthropic 无关联。所有监控数据只在本机处理。")
                    .font(.claudeBody(8))
                    .foregroundColor(Palette.inkFaint)
                HStack {
                    Text("macOS \(osVersionText)")
                        .font(.claudeLabel(7.5, weight: .medium))
                        .foregroundColor(Palette.inkFaint)
                    Spacer()
                    Button("退出 Claude Monitor") { onQuit() }
                        .buttonStyle(QuietButtonStyle(compact: true))
                }
                .padding(.top, 3)
            }
        }
    }


}

struct WarmToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                configuration.isOn.toggle()
            }
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? Palette.coral : Palette.lineStrong.opacity(0.55))
                    .frame(width: 38, height: 22)
                Circle()
                    .fill(Palette.surfaceRaised)
                    .frame(width: 18, height: 18)
                    .padding(2)
                    .shadow(color: Palette.shadow.opacity(0.5), radius: 1.5, y: 1)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "开启" : "关闭")
    }
}

struct WarmSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let clamped = max(0, min(1, fraction))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Palette.line.opacity(0.55))
                    .frame(height: 6)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Palette.coral.opacity(0.72), Palette.coral],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(6, width * clamped), height: 6)
                Circle()
                    .fill(Palette.surfaceRaised)
                    .frame(width: 17, height: 17)
                    .overlay(Circle().stroke(Palette.coral.opacity(0.85), lineWidth: 1.5))
                    .shadow(color: Palette.shadow.opacity(0.55), radius: 2, y: 1)
                    .offset(x: max(0, min(width - 17, width * clamped - 8.5)))
            }
            .frame(height: 24)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let raw = range.lowerBound + (gesture.location.x / width) * (range.upperBound - range.lowerBound)
                        let stepped = (raw / step).rounded() * step
                        value = max(range.lowerBound, min(range.upperBound, stepped))
                    }
            )
        }
        .frame(height: 24)
    }
}

struct TimeWheel: View {
    @Binding var hour: Int
    @Binding var minute: Int
    var onChange: () -> Void

    var body: some View {
        HStack(spacing: 3) {
            wheel(value: $hour, range: 0...23, width: 31)
            Text(":")
                .font(.claudeNumber(14, weight: .semibold))
                .foregroundColor(Palette.inkSoft)
                .offset(y: -1)
            wheel(value: $minute, range: 0...59, width: 31)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Palette.surfaceRaised)
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Palette.line, lineWidth: 0.8)
                )
        )
    }

    private func wheel(value: Binding<Int>, range: ClosedRange<Int>, width: CGFloat) -> some View {
        VStack(spacing: 0) {
            Button {
                value.wrappedValue = value.wrappedValue >= range.upperBound ? range.lowerBound : value.wrappedValue + 1
                onChange()
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 6, weight: .bold))
                    .foregroundColor(Palette.inkFaint)
                    .frame(width: width, height: 8)
            }
            .buttonStyle(.plain)

            Text(String(format: "%02d", value.wrappedValue))
                .font(.claudeNumber(12, weight: .semibold))
                .foregroundColor(Palette.ink)
                .frame(width: width, height: 16)

            Button {
                value.wrappedValue = value.wrappedValue <= range.lowerBound ? range.upperBound : value.wrappedValue - 1
                onChange()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 6, weight: .bold))
                    .foregroundColor(Palette.inkFaint)
                    .frame(width: width, height: 8)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Shared settings components

struct SettingsCard<Content: View>: View {
    let title: String
    let subtitle: String
    let content: Content

    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.claudeSerif(12, weight: .semibold))
                    .foregroundColor(Palette.ink)
                Text(subtitle)
                    .font(.claudeLabel(7.5, weight: .medium))
                    .foregroundColor(Palette.inkFaint)
            }
            content
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Palette.surface.opacity(0.9))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Palette.line.opacity(0.8), lineWidth: 0.9)
                )
        )
        .shadow(color: Palette.shadow.opacity(0.24), radius: 6, y: 2)
    }
}

struct SettingsRow<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let content: Content

    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.claudeLabel(9.5, weight: .semibold))
                    .foregroundColor(Palette.inkSoft)
                if let subtitle {
                    Text(subtitle)
                        .font(.claudeLabel(7.2, weight: .medium))
                        .foregroundColor(Palette.inkFaint)
                }
            }
            Spacer(minLength: 6)
            content
        }
    }
}

struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(Palette.line.opacity(0.75))
            .frame(height: 0.7)
    }
}

struct ChoicePills<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let formatter: (Option) -> String

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options, id: \.self) { option in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { selection = option }
                } label: {
                    Text(formatter(option))
                        .font(.claudeLabel(8, weight: .semibold))
                        .foregroundColor(option == selection ? .white : Palette.inkSoft)
                        .padding(.horizontal, 7)
                        .frame(height: 22)
                        .background(
                            Capsule()
                                .fill(option == selection ? Palette.coral : Palette.surfaceRaised)
                                .overlay(Capsule().stroke(option == selection ? Color.clear : Palette.line, lineWidth: 0.7))
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}
