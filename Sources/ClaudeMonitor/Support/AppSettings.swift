import Foundation
import SwiftUI


@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults: UserDefaults

    @Published var refreshInterval: Double {
        didSet { defaults.set(refreshInterval, forKey: Keys.refreshInterval) }
    }
    @Published var powerRefreshInterval: Double {
        didSet { defaults.set(powerRefreshInterval, forKey: Keys.powerRefreshInterval) }
    }
    @Published var powerUnit: PowerUnit {
        didSet { defaults.set(powerUnit.rawValue, forKey: Keys.powerUnit) }
    }
    @Published var anomalyThresholdMB: Int {
        didSet { defaults.set(anomalyThresholdMB, forKey: Keys.anomalyThresholdMB) }
    }
    @Published var dailyHour: Int {
        didSet { defaults.set(dailyHour, forKey: Keys.dailyHour) }
    }
    @Published var dailyMinute: Int {
        didSet { defaults.set(dailyMinute, forKey: Keys.dailyMinute) }
    }
    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled) }
    }
    @Published var notificationSoundEnabled: Bool {
        didSet { defaults.set(notificationSoundEnabled, forKey: Keys.notificationSoundEnabled) }
    }
    @Published var petAnimationsEnabled: Bool {
        didSet { defaults.set(petAnimationsEnabled, forKey: Keys.petAnimationsEnabled) }
    }
    @Published var reduceMotion: Bool {
        didSet { defaults.set(reduceMotion, forKey: Keys.reduceMotion) }
    }
    @Published var powerFlowAnimationEnabled: Bool {
        didSet { defaults.set(powerFlowAnimationEnabled, forKey: Keys.powerFlowAnimationEnabled) }
    }

    // The four live metrics are always sampled at least once every two
    // seconds. 1s is offered for users who want a faster refresh.
    var refreshOptions: [Double] { [1, 2] }
    var powerRefreshOptions: [Double] { [2, 5, 10] }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedRefresh = defaults.object(forKey: Keys.refreshInterval) as? Double ?? 2
        self.refreshInterval = min(2, max(1, storedRefresh))
        self.powerRefreshInterval = defaults.object(forKey: Keys.powerRefreshInterval) as? Double ?? 2
        let unit = defaults.string(forKey: Keys.powerUnit).flatMap(PowerUnit.init(rawValue:)) ?? .watt
        self.powerUnit = unit
        self.anomalyThresholdMB = defaults.object(forKey: Keys.anomalyThresholdMB) as? Int ?? 500
        self.dailyHour = defaults.object(forKey: Keys.dailyHour) as? Int ?? 9
        self.dailyMinute = defaults.object(forKey: Keys.dailyMinute) as? Int ?? 30
        self.notificationsEnabled = defaults.object(forKey: Keys.notificationsEnabled) as? Bool ?? true
        self.notificationSoundEnabled = defaults.object(forKey: Keys.notificationSoundEnabled) as? Bool ?? true
        self.petAnimationsEnabled = defaults.object(forKey: Keys.petAnimationsEnabled) as? Bool ?? true
        self.reduceMotion = defaults.object(forKey: Keys.reduceMotion) as? Bool ?? false
        self.powerFlowAnimationEnabled = defaults.object(forKey: Keys.powerFlowAnimationEnabled) as? Bool ?? true
    }

    var anomalyThresholdBytes: Int64 {
        Int64(max(10, anomalyThresholdMB)) * 1_048_576
    }

    var dailyTimeText: String {
        String(format: "%02d:%02d", dailyHour, dailyMinute)
    }

    func dailyTimeToday(relativeTo now: Date = Date()) -> Date? {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: now)
        components.hour = dailyHour
        components.minute = dailyMinute
        components.second = 0
        return Calendar.current.date(from: components)
    }

    func nextDailyDate(after now: Date = Date()) -> Date {
        let today = dailyTimeToday(relativeTo: now) ?? now
        if today > now { return today }
        return Calendar.current.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
    }

    func resetDailyTime() {
        dailyHour = 9
        dailyMinute = 30
    }

    private enum Keys {
        static let refreshInterval = "cm.refreshInterval"
        static let powerRefreshInterval = "cm.powerRefreshInterval"
        static let powerUnit = "cm.powerUnit"
        static let anomalyThresholdMB = "cm.anomalyThresholdMB"
        static let dailyHour = "cm.dailyHour"
        static let dailyMinute = "cm.dailyMinute"
        static let notificationsEnabled = "cm.notificationsEnabled"
        static let notificationSoundEnabled = "cm.notificationSoundEnabled"
        static let petAnimationsEnabled = "cm.petAnimationsEnabled"
        static let reduceMotion = "cm.reduceMotion"
        static let powerFlowAnimationEnabled = "cm.powerFlowAnimationEnabled"
    }
}
