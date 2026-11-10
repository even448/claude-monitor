import SwiftUI

struct HeaderView: View {
    var mood: PetMood
    var health: HealthLevel
    var petAnimated: Bool
    var reduceMotion: Bool
    var speech: String?
    var onPetTap: () -> Void
    var onSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 10) {
                PetMascotView(
                    mood: mood,
                    size: 56,
                    animated: petAnimated,
                    reduceMotion: reduceMotion,
                    onTap: onPetTap
                )

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Claude Monitor")
                            .font(.claudeSerif(18, weight: .semibold))
                            .foregroundColor(Palette.ink)
                        Circle()
                            .fill(healthColor)
                            .frame(width: 5, height: 5)
                            .overlay(
                                Circle()
                                    .stroke(healthColor.opacity(0.24), lineWidth: 3)
                            )
                    }

                    TimelineView(.periodic(from: Date(), by: 30)) { context in
                        Text("\(Fmt.dateHeading(context.date))  \(Fmt.time(context.date))")
                            .font(.claudeLabel(10.5, weight: .medium))
                            .foregroundColor(Palette.inkFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text(statusLine)
                        .font(.claudeBody(10, weight: .regular))
                        .foregroundColor(Palette.inkSoft.opacity(0.86))
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Button(action: onSettings) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(IconButtonStyle(size: 28))
                .help("设置")
            }

            if let speech {
                HStack(spacing: 5) {
                    Text("“")
                        .font(.claudeSerif(13, weight: .bold))
                        .foregroundColor(Palette.coral.opacity(0.75))
                    Text(speech)
                        .font(.claudeBody(10.5, weight: .medium))
                        .foregroundColor(Palette.inkSoft)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Palette.coralMist.opacity(0.75))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Palette.coral.opacity(0.12), lineWidth: 0.8)
                        )
                )
                .padding(.leading, 66)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: speech)
    }

    private var healthColor: Color {
        switch health {
        case .calm: return Palette.sage
        case .elevated: return Palette.honey
        case .critical: return Palette.alert
        }
    }

    private var statusLine: String {
        switch mood {
        case .calm: return "呼吸轻盈，系统一切平稳"
        case .curious: return "正在等你展开今天的细节"
        case .concerned: return "指标有点偏高，我会帮你留意"
        case .surprised: return "发现一处值得看看的变化"
        case .working: return "正在认真整理系统里的小线索"
        case .happy: return "今天也轻轻地陪着你"
        }
    }
}
