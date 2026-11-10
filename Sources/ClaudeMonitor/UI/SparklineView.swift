import SwiftUI

struct SparklineView: View {
    let points: [HistoryPoint]
    var tint: Color
    var height: CGFloat = 34
    var showTooltip: Bool = true
    var valueFormatter: (Double) -> String = { "\(Int($0.rounded()))%" }

    @State private var hoverIndex: Int?

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                if points.count < 2 {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: size.height - 2))
                        path.addLine(to: CGPoint(x: size.width, y: size.height - 2))
                    }
                    .stroke(
                        tint.opacity(0.22),
                        style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [3, 4])
                    )
                } else {
                    areaPath(in: size)
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0.22), tint.opacity(0.01)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    linePath(in: size)
                        .stroke(
                            LinearGradient(
                                colors: [tint.opacity(0.55), tint],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)
                        )
                    if let last = points.last {
                        let point = CGPoint(
                            x: size.width - 1,
                            y: yPosition(for: last.value, height: size.height)
                        )
                        Circle()
                            .fill(Palette.surfaceRaised)
                            .frame(width: 5, height: 5)
                            .overlay(Circle().fill(tint).frame(width: 3, height: 3))
                            .position(point)
                    }
                }

                if let hoverIndex, points.indices.contains(hoverIndex), showTooltip {
                    chartTooltip(index: hoverIndex, size: size)
                }

                if showTooltip {
                    hoverTargets(size: size)
                }
            }
        }
        .frame(height: height)
    }

    private func linePath(in size: CGSize) -> Path {
        var path = Path()
        guard !points.isEmpty else { return path }
        for (index, point) in points.enumerated() {
            let x = points.count == 1 ? size.width / 2 : CGFloat(index) / CGFloat(points.count - 1) * size.width
            let y = yPosition(for: point.value, height: size.height)
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                let previousX = CGFloat(index - 1) / CGFloat(points.count - 1) * size.width
                let previousY = yPosition(for: points[index - 1].value, height: size.height)
                let midX = (previousX + x) / 2
                path.addCurve(
                    to: CGPoint(x: x, y: y),
                    control1: CGPoint(x: midX, y: previousY),
                    control2: CGPoint(x: midX, y: y)
                )
            }
        }
        return path
    }

    private func areaPath(in size: CGSize) -> Path {
        var path = linePath(in: size)
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.addLine(to: CGPoint(x: 0, y: size.height))
        path.closeSubpath()
        return path
    }

    private func yPosition(for value: Double, height: CGFloat) -> CGFloat {
        let clamped = max(0, min(100, value))
        return height - CGFloat(clamped / 100) * (height - 2) - 1
    }

    private func hoverTargets(size: CGSize) -> some View {
        HStack(spacing: 0) {
            ForEach(points.indices, id: \.self) { index in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering {
                            hoverIndex = index
                        } else if hoverIndex == index {
                            hoverIndex = nil
                        }
                    }
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func chartTooltip(index: Int, size: CGSize) -> some View {
        let point = points[index]
        let x = points.count == 1 ? size.width / 2 : CGFloat(index) / CGFloat(points.count - 1) * size.width
        let clampedX = min(max(x, 28), size.width - 28)
        return VStack(spacing: 1) {
            Text(valueFormatter(point.value))
                .font(.claudeNumber(9, weight: .bold))
                .foregroundColor(Palette.ink)
            Text(Fmt.time(point.time))
                .font(.claudeLabel(7, weight: .medium))
                .foregroundColor(Palette.inkFaint)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Palette.surfaceRaised)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Palette.line, lineWidth: 0.8)
                )
        )
        .shadow(color: Palette.shadow.opacity(0.4), radius: 3, y: 1)
        .position(x: clampedX, y: 10)
        .allowsHitTesting(false)
    }
}
