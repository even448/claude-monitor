import SwiftUI

struct FooterView: View {
    let isScanning: Bool
    let isFocused: FooterFocus?
    var onDetect: () -> Void
    var onRefresh: () -> Void
    var onSettings: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Button(action: onDetect) {
                HStack(spacing: 5) {
                    if isScanning {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.7)
                            .frame(width: 11, height: 11)
                    } else {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    Text(isScanning ? "检测中…" : "立即检测")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(CoralButtonStyle())
            .disabled(isScanning)
            .overlay(focusRing(FooterFocus.detect))
            .help("立即扫描存储异常变化")

            Button(action: onRefresh) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9, weight: .semibold))
                    Text("刷新")
                }
            }
            .buttonStyle(QuietButtonStyle())
            .overlay(focusRing(FooterFocus.refresh))
            .help("刷新全部实时指标")

            Button(action: onSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(IconButtonStyle(size: 34))
            .overlay(focusRing(FooterFocus.settings))
            .help("打开设置")
        }
        .padding(.top, 8)
        .overlay(
            Rectangle()
                .fill(Palette.line.opacity(0.72))
                .frame(height: 0.7)
                .offset(y: 0),
            alignment: .top
        )
    }

    @ViewBuilder
    private func focusRing(_ focus: FooterFocus) -> some View {
        if isFocused == focus {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Palette.coral.opacity(0.55), lineWidth: 1.4)
                .offset(x: -2, y: -2)
                .padding(-2)
        }
    }
}

enum FooterFocus: Hashable {
    case detect
    case refresh
    case settings
}
