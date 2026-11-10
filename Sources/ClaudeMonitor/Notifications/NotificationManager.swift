import Foundation
import UserNotifications
import AppKit

enum PanelDestination: String {
    case overview
    case energy
    case storage
    case anomaly
    case settings
}

/// Wraps UserNotifications. The app is intentionally unsandboxed so it can
/// inspect local storage after the user grants Full Disk Access; notifications
/// still use the normal macOS authorization flow.
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate, ObservableObject {
    static let storageCategory = "CM_STORAGE_ANOMALY"
    static let powerCategory = "CM_POWER_ALERT"

    var onOpenDestination: ((PanelDestination) -> Void)?
    var soundEnabled: () -> Bool = { true }
    var notificationsEnabled: () -> Bool = { true }

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    private var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    override init() {
        super.init()
        guard let center else { return }
        center.delegate = self
        registerCategories()
        refreshAuthorizationStatus()
    }

    func requestAuthorizationIfNeeded(completion: ((Bool) -> Void)? = nil) {
        guard let center else {
            completion?(false)
            return
        }
        center.getNotificationSettings { [weak self] settings in
            guard let self else { return }
            DispatchQueue.main.async {
                self.authorizationStatus = settings.authorizationStatus
            }
            if settings.authorizationStatus == .notDetermined {
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    DispatchQueue.main.async {
                        self.authorizationStatus = granted ? .authorized : .denied
                        completion?(granted)
                    }
                }
            } else {
                DispatchQueue.main.async {
                    completion?(settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional)
                }
            }
        }
    }

    func refreshAuthorizationStatus() {
        center?.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                self?.authorizationStatus = settings.authorizationStatus
            }
        }
    }

    func notifyStorage(_ report: AnomalyReport) {
        guard notificationsEnabled() else { return }
        requestAuthorizationIfNeeded { [weak self] granted in
            guard granted, let self, let center = self.center else { return }
            let content = UNMutableNotificationContent()
            content.title = "存储空间有异常变化"
            content.body = report.notificationSummary
            content.categoryIdentifier = Self.storageCategory
            content.userInfo = ["destination": PanelDestination.anomaly.rawValue]
            if self.soundEnabled() {
                content.sound = .default
            }

            let request = UNNotificationRequest(
                identifier: "cm.storage.\(Int(report.scannedAt.timeIntervalSince1970))",
                content: content,
                trigger: nil
            )
            center.add(request)
        }
    }

    func notifyPowerAlert(_ message: String) {
        guard notificationsEnabled() else { return }
        requestAuthorizationIfNeeded { [weak self] granted in
            guard granted, let self, let center = self.center else { return }
            let content = UNMutableNotificationContent()
            content.title = "功耗提醒"
            content.body = message
            content.categoryIdentifier = Self.powerCategory
            content.userInfo = ["destination": PanelDestination.energy.rawValue]
            if self.soundEnabled() {
                content.sound = .default
            }
            let request = UNNotificationRequest(
                identifier: "cm.power.\(Int(Date().timeIntervalSince1970 / 3600))",
                content: content,
                trigger: nil
            )
            center.add(request)
        }
    }

    private func registerCategories() {
        guard let center else { return }
        let view = UNNotificationAction(
            identifier: "CM_VIEW",
            title: "查看详情",
            options: [.foreground]
        )
        let storage = UNNotificationCategory(
            identifier: Self.storageCategory,
            actions: [view],
            intentIdentifiers: [],
            options: []
        )
        let power = UNNotificationCategory(
            identifier: Self.powerCategory,
            actions: [view],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([storage, power])
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        var options: UNNotificationPresentationOptions = [.banner]
        if soundEnabled() { options.insert(.sound) }
        completionHandler(options)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let destinationRaw = response.notification.request.content.userInfo["destination"] as? String
        let destination = destinationRaw.flatMap(PanelDestination.init(rawValue:)) ?? .anomaly
        DispatchQueue.main.async { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.onOpenDestination?(destination)
            completionHandler()
        }
    }
}
