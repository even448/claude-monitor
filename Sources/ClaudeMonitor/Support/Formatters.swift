import Foundation

enum Fmt {
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.isAdaptive = true
        formatter.includesUnit = true
        formatter.zeroPadsFractionDigits = false
        return formatter
    }()

    private static let memoryFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.isAdaptive = true
        formatter.zeroPadsFractionDigits = false
        return formatter
    }()

    static func bytes(_ value: Int64?) -> String {
        guard let value else { return "—" }
        if value == 0 { return "0 B" }
        return byteFormatter.string(fromByteCount: value)
    }

    static func memory(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return memoryFormatter.string(fromByteCount: value)
    }

    static func percent(_ value: Double?, digits: Int = 0) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.\(digits)f%%", max(0, min(100, value)))
    }

    static func watts(_ value: Double?, unit: PowerUnit = .watt) -> String {
        guard let value, value.isFinite else { return "—" }
        switch unit {
        case .watt:
            return String(format: value >= 100 ? "%.0f W" : "%.1f W", value)
        case .btu:
            return String(format: "%.0f BTU/h", value * 3.412142)
        }
    }

    static func signedBytes(_ value: Int64) -> String {
        let prefix = value >= 0 ? "+" : "−"
        return prefix + byteFormatter.string(fromByteCount: abs(value))
    }

    static func duration(minutes: Int?) -> String {
        guard let minutes, minutes > 0, minutes < 24 * 60 else { return "—" }
        let h = minutes / 60
        let m = minutes % 60
        if h == 0 { return "\(m) 分钟" }
        return "\(h) 小时 \(m) 分"
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func relativeTime(_ date: Date?) -> String {
        guard let date else { return "尚未检测" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func dateHeading(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 · EEEE"
        return formatter.string(from: date)
    }

    static func dateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }
}
