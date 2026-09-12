import Foundation
import UserNotifications

/// One weekly reminder, the evening before shopping day, asking whether anything
/// changed before the next week is planned. Nothing else. Permission is only
/// requested when the user turns this on.
enum NotificationManager {
    private static let id = "weekly-check-in"

    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func scheduleWeekly(shopWeekday: Int, name: String) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        let content = UNMutableNotificationContent()
        content.title = "Your week gets planned tomorrow"
        content.body = "Anything change? Update your answers or add a recipe and reScrolly will build around it."
        content.sound = .default
        var comps = DateComponents()
        comps.weekday = ((shopWeekday - 1 + 7) % 7) + 1   // the day before shopping, 1 = Sunday
        comps.hour = 18
        comps.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    static func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }
}
