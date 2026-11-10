import SwiftUI

enum PetMood: Equatable {
    case calm
    case curious
    case concerned
    case surprised
    case working
    case happy

    var accent: Color {
        switch self {
        case .calm, .curious, .happy, .working: return Palette.coral
        case .concerned: return Palette.honey
        case .surprised: return Palette.alert
        }
    }
}

/// The mascot is entirely vector-drawn: six soft terracotta rays around a warm
/// cream face, echoing a friendly asterisk. No bitmap or Lottie dependency is
/// required, so it scales cleanly and remains cheap to render.
struct PetMascotView: View {
    var mood: PetMood = .calm
    var size: CGFloat = 56
    var animated: Bool = true
    var reduceMotion: Bool = false
    var onTap: (() -> Void)?

    @State private var breathing = false
    @State private var blinking = false
    @State private var bouncing = false
    @State private var sparkleAngle: Double = 0
    @State private var blinkTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            if mood == .surprised {
                Circle()
                    .stroke(Palette.alert.opacity(0.22), lineWidth: 1)
                    .frame(width: size * 1.06, height: size * 1.06)
            }

            if mood == .working && animated && !reduceMotion {
                Image(systemName: "sparkle")
                    .font(.system(size: size * 0.2, weight: .semibold))
                    .foregroundColor(Palette.honey)
                    .offset(x: size * 0.48, y: -size * 0.38)
                    .rotationEffect(.degrees(sparkleAngle))
            }

            if mood == .surprised {
                Text("!")
                    .font(.claudeNumber(size * 0.22, weight: .bold))
                    .foregroundColor(Palette.alert)
                    .padding(3)
                    .background(Circle().fill(Palette.surfaceRaised))
                    .overlay(Circle().stroke(Palette.alert.opacity(0.25), lineWidth: 0.7))
                    .offset(x: size * 0.40, y: -size * 0.40)
                    .transition(.scale.combined(with: .opacity))
            }

            if mood == .curious {
                Text("?")
                    .font(.claudeNumber(size * 0.20, weight: .bold))
                    .foregroundColor(Palette.honey)
                    .padding(3)
                    .background(Circle().fill(Palette.surfaceRaised))
                    .overlay(Circle().stroke(Palette.honey.opacity(0.3), lineWidth: 0.7))
                    .offset(x: size * 0.40, y: -size * 0.40)
            }

            petals
                .shadow(color: Palette.coral.opacity(0.20), radius: 7, x: 0, y: 4)

            face
                .frame(width: size * 0.52, height: size * 0.48)
                .offset(y: size * 0.02)
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(mood == .curious ? -3 : 0))
        .scaleEffect(bouncing ? 0.92 : (breathing ? 1.035 : 0.985))
        .offset(y: breathing && animated && !reduceMotion ? -1.2 : 0.6)
        .contentShape(Circle())
        .onTapGesture {
            guard let onTap else { return }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.5)) {
                bouncing = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.58)) {
                    bouncing = false
                }
            }
            onTap()
        }
        .help("点一点小 Claude")
        .onAppear(perform: startAnimations)
        .onDisappear {
            blinkTask?.cancel()
            blinkTask = nil
        }
        .onChange(of: animated) { _ in startAnimations() }
        .onChange(of: reduceMotion) { _ in startAnimations() }
    }

    private var petals: some View {
        ZStack {
            ForEach(0..<6, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Palette.coralBright.opacity(0.98),
                                Palette.coral.opacity(0.95),
                                Color(hex: 0xB85335)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(0.14), lineWidth: 0.6)
                    )
                    .frame(width: size * 0.24, height: size * 0.56)
                    .offset(y: -size * 0.205)
                    .rotationEffect(.degrees(Double(index) * 60))
            }

            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(hex: 0xF9E8D8), Color(hex: 0xF1D4BD)],
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: size * 0.32
                    )
                )
                .frame(width: size * 0.58, height: size * 0.58)
                .overlay(
                    Circle().stroke(Color.white.opacity(0.35), lineWidth: 0.8)
                )
                .shadow(color: Color(hex: 0x8E3B25).opacity(0.12), radius: 2, y: 1)

            Circle()
                .fill(Color.white.opacity(0.2))
                .frame(width: size * 0.10, height: size * 0.10)
                .offset(x: -size * 0.18, y: -size * 0.18)
                .blur(radius: 0.4)
        }
    }

    private var face: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            let eyeY = h * 0.40

            ZStack {
                // Blush
                HStack(spacing: w * 0.30) {
                    Circle().fill(Palette.coral.opacity(0.15))
                    Circle().fill(Palette.coral.opacity(0.15))
                }
                .frame(width: w * 0.78, height: h * 0.18)
                .offset(y: eyeY + h * 0.16)

                // Eyes
                HStack(spacing: w * 0.25) {
                    eye(width: mood == .surprised ? w * 0.145 : w * 0.105, height: h * 0.17)
                    eye(width: mood == .surprised ? w * 0.145 : w * 0.105, height: h * 0.17)
                }
                .offset(y: eyeY - h * 0.10)

                // Brows for concern
                if mood == .concerned {
                    HStack(spacing: w * 0.17) {
                        Capsule()
                            .fill(Palette.ink.opacity(0.65))
                            .frame(width: w * 0.16, height: 1.5)
                            .rotationEffect(.degrees(-13))
                        Capsule()
                            .fill(Palette.ink.opacity(0.65))
                            .frame(width: w * 0.16, height: 1.5)
                            .rotationEffect(.degrees(13))
                    }
                    .offset(y: eyeY - h * 0.29)
                }

                mouth(width: w, height: h)
                    .offset(y: h * 0.23)
            }
            .frame(width: w, height: h)
        }
    }

    @ViewBuilder
    private func eye(width: CGFloat, height: CGFloat) -> some View {
        switch mood {
        case .happy, .working:
            Capsule()
                .stroke(Palette.ink.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .frame(width: width * 1.5, height: height * 0.65)
                .rotationEffect(.degrees(0))
                .clipShape(Rectangle().offset(y: -height * 0.12))
        default:
            Capsule()
                .fill(Palette.ink.opacity(0.86))
                .frame(width: width, height: blinking ? 1.8 : height)
                .animation(.easeInOut(duration: 0.08), value: blinking)
        }
    }

    @ViewBuilder
    private func mouth(width: CGFloat, height: CGFloat) -> some View {
        switch mood {
        case .surprised:
            Ellipse()
                .fill(Palette.ink.opacity(0.88))
                .frame(width: width * 0.13, height: width * 0.17)
        case .concerned:
            Capsule()
                .fill(Palette.ink.opacity(0.75))
                .frame(width: width * 0.22, height: 1.5)
                .rotationEffect(.degrees(-3))
        case .working:
            Capsule()
                .fill(Palette.ink.opacity(0.82))
                .frame(width: width * 0.20, height: 2)
        case .happy:
            SmileShape()
                .stroke(Palette.ink.opacity(0.82), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .frame(width: width * 0.28, height: height * 0.16)
        default:
            SmileShape()
                .stroke(Palette.ink.opacity(0.72), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                .frame(width: width * 0.24, height: height * 0.13)
        }
    }

    private func startAnimations() {
        blinkTask?.cancel()
        blinkTask = nil
        guard animated, !reduceMotion else {
            breathing = false
            blinking = false
            sparkleAngle = 0
            return
        }

        withAnimation(.easeInOut(duration: 2.8).repeatForever(autoreverses: true)) {
            breathing = true
        }
        withAnimation(.linear(duration: 3.0).repeatForever(autoreverses: false)) {
            sparkleAngle = 360
        }

        blinkTask = Task {
            while !Task.isCancelled {
                let delay = UInt64.random(in: 2_800...5_800)
                try? await Task.sleep(nanoseconds: delay * 1_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.08)) { blinking = true }
                }
                try? await Task.sleep(nanoseconds: 130_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.1)) { blinking = false }
                }
            }
        }
    }
}

private struct SmileShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.midY),
            control: CGPoint(x: rect.midX, y: rect.maxY + rect.height * 0.3)
        )
        return path
    }
}
