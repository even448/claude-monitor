import SwiftUI

// MARK: - Palette
// A warm, paper-like palette inspired by editorial interfaces. It deliberately
// avoids pure white and pure black so the panel feels soft in both appearances.
enum Palette {
    static let paper = Color(hex: 0xF5EFE4)
    static let paperDeep = Color(hex: 0xEDE3D4)
    static let surface = Color(hex: 0xFFFBF5)
    static let surfaceRaised = Color(hex: 0xFFFDF9)
    static let ink = Color(hex: 0x39342A)
    static let inkSoft = Color(hex: 0x6F6658)
    static let inkFaint = Color(hex: 0x9A8F7E)
    static let line = Color(hex: 0xE3D8C7)
    static let lineStrong = Color(hex: 0xD3C4AF)

    static let coral = Color(hex: 0xC96442)
    static let coralBright = Color(hex: 0xD97757)
    static let coralSoft = Color(hex: 0xF0C7B4)
    static let coralMist = Color(hex: 0xF8E5DA)
    static let honey = Color(hex: 0xDCA84F)
    static let honeySoft = Color(hex: 0xF4E2B8)
    static let sage = Color(hex: 0x7F9270)
    static let sageSoft = Color(hex: 0xDCE6D5)
    static let dustyBlue = Color(hex: 0x6F8794)
    static let dustyBlueSoft = Color(hex: 0xDCE7EB)
    static let alert = Color(hex: 0xB84C3C)
    static let alertSoft = Color(hex: 0xF4D8D1)

    static let shadow = Color(hex: 0x594630).opacity(0.14)

    static func loadColor(_ percent: Double) -> Color {
        switch percent {
        case ..<60: return coral
        case ..<85: return honey
        default: return alert
        }
    }

    static let panelGradient = LinearGradient(
        colors: [Color(hex: 0xF8F3EA), Color(hex: 0xF2E9DC)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

// MARK: - Type
extension Font {
    static func claudeSerif(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    static func claudeNumber(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    static func claudeLabel(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    static func claudeBody(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
}

// MARK: - Surfaces
struct WarmCard: ViewModifier {
    var padding: CGFloat = 14
    var radius: CGFloat = 20
    var tint: Color = Palette.surface

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(tint)
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .stroke(Palette.line.opacity(0.8), lineWidth: 1)
                    )
            )
            .shadow(color: Palette.shadow.opacity(0.38), radius: 10, x: 0, y: 4)
    }
}

extension View {
    func warmCard(padding: CGFloat = 14, radius: CGFloat = 20, tint: Color = Palette.surface) -> some View {
        modifier(WarmCard(padding: padding, radius: radius, tint: tint))
    }

    func sectionLabel() -> some View {
        font(.claudeLabel(10, weight: .semibold))
            .foregroundColor(Palette.inkFaint)
            .textCase(.uppercase)
    }

    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition { transform(self) } else { self }
    }
}

// MARK: - Buttons
struct CoralButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.claudeLabel(compact ? 11 : 12, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, compact ? 10 : 14)
            .frame(height: compact ? 30 : 36)
            .background(
                RoundedRectangle(cornerRadius: compact ? 10 : 12, style: .continuous)
                    .fill(Palette.coral.opacity(configuration.isPressed ? 0.82 : 1))
                    .overlay(
                        RoundedRectangle(cornerRadius: compact ? 10 : 12, style: .continuous)
                            .stroke(Color.white.opacity(0.16), lineWidth: 1)
                    )
            )
            .shadow(color: Palette.coral.opacity(configuration.isPressed ? 0.1 : 0.24), radius: 6, y: 3)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

struct QuietButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.claudeLabel(compact ? 11 : 12, weight: .medium))
            .foregroundColor(Palette.inkSoft)
            .padding(.horizontal, compact ? 9 : 12)
            .frame(height: compact ? 28 : 34)
            .background(
                RoundedRectangle(cornerRadius: compact ? 9 : 11, style: .continuous)
                    .fill(Palette.surfaceRaised.opacity(configuration.isPressed ? 0.6 : 0.9))
                    .overlay(
                        RoundedRectangle(cornerRadius: compact ? 9 : 11, style: .continuous)
                            .stroke(Palette.line, lineWidth: 1)
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.43, weight: .semibold))
            .foregroundColor(Palette.inkSoft)
            .frame(width: size, height: size)
            .background(
                Circle()
                    .fill(Palette.surfaceRaised.opacity(configuration.isPressed ? 0.55 : 0.82))
                    .overlay(Circle().stroke(Palette.line, lineWidth: 1))
            )
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
    }
}

// MARK: - Helpers
struct Hairline: View {
    var color: Color = Palette.line

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(height: 1)
    }
}

struct SoftProgressBar: View {
    var value: Double
    var tint: Color
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.14))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.72), tint],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(height, proxy.size.width * clamped))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.65), value: clamped)
    }

    private var clamped: Double {
        max(0, min(1, value / 100))
    }
}

struct TinyBadge: View {
    var text: String
    var tint: Color = Palette.coral

    var body: some View {
        Text(text)
            .font(.claudeLabel(9, weight: .semibold))
            .foregroundColor(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(tint.opacity(0.10))
                    .overlay(Capsule().stroke(tint.opacity(0.18), lineWidth: 0.7))
            )
    }
}
