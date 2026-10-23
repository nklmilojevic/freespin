import Foundation
import FreespinCore
import UserNotifications

/// Posts the low-battery notification through Notification Center.
enum BatteryNotifier {
    static let enabledKey = "batteryNotificationsEnabled"

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error { NSLog("Freespin: notification authorization failed: \(error)") }
        }
    }

    static func post(device: DeviceSnapshot, alert: BatteryAlertPolicy.Alert) {
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        switch alert {
        case let .low(pct):
            content.title = "\(device.name) battery low"
            content.body = "\(pct)% remaining. Charge it soon."
        case let .critical(pct):
            content.title = "\(device.name) battery critically low"
            content.body = "Only \(pct)% left. Connect the charging cable."
            content.interruptionLevel = .timeSensitive
        }
        content.sound = .default
        let request = UNNotificationRequest(identifier: "battery-\(device.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
