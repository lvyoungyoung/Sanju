import Foundation
import UserNotifications

enum LearningReminderError: LocalizedError {
    case notificationsDenied
    case invalidTime

    var errorDescription: String? {
        switch self {
        case .notificationsDenied:
            return L10n.string("learning_reminder_error.notifications_denied", "通知权限没有开启，请在系统设置里允许通知后再试。")
        case .invalidTime:
            return L10n.string("learning_reminder_error.invalid_time", "提醒时间无效，请重新选择。")
        }
    }
}

enum LearningReminderScheduler {
    static let dailyReminderIdentifier = "sanju.learning.daily-reminder"
    static let notificationTypeUserInfoKey = "sanju.notification.type"
    static let learningReminderNotificationType = "learning-reminder"

    static func scheduleDailyReminder(hour: Int, minute: Int) async throws {
        guard (0...23).contains(hour), (0...59).contains(minute) else {
            throw LearningReminderError.invalidTime
        }

        let center = UNUserNotificationCenter.current()
        let settings = await notificationSettings(center)

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            break
        case .notDetermined:
            let granted = try await requestAuthorization(center)
            guard granted else {
                throw LearningReminderError.notificationsDenied
            }
        case .denied:
            throw LearningReminderError.notificationsDenied
        @unknown default:
            throw LearningReminderError.notificationsDenied
        }

        let content = UNMutableNotificationContent()
        content.title = L10n.string("learning_reminder.notification_title", "该学习啦")
        content.body = L10n.string("learning_reminder.notification_body", "今天也花 2 分钟，把收藏里的句子练一遍。")
        content.sound = .default
        content.userInfo = [
            notificationTypeUserInfoKey: learningReminderNotificationType
        ]

        var dateComponents = DateComponents()
        dateComponents.hour = hour
        dateComponents.minute = minute

        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
        let request = UNNotificationRequest(
            identifier: dailyReminderIdentifier,
            content: content,
            trigger: trigger
        )

        center.removePendingNotificationRequests(withIdentifiers: [dailyReminderIdentifier])
        try await add(request, to: center)
    }

    static func cancelDailyReminder() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [dailyReminderIdentifier])
    }

    private static func notificationSettings(_ center: UNUserNotificationCenter) async -> UNNotificationSettings {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings)
            }
        }
    }

    private static func requestAuthorization(_ center: UNUserNotificationCenter) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private static func add(_ request: UNNotificationRequest, to center: UNUserNotificationCenter) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            center.add(request) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
}

enum LearningReminderNotificationRoute {
    static let didRequestOpenFavorites = Notification.Name("sanju.learningReminder.openFavorites")

    private static let pendingOpenFavoritesKey = "sanju.learningReminder.pendingOpenFavorites"

    static func markOpenFavoritesRequested() {
        UserDefaults.standard.set(true, forKey: pendingOpenFavoritesKey)
        NotificationCenter.default.post(name: didRequestOpenFavorites, object: nil)
    }

    static func consumeOpenFavoritesRequest() -> Bool {
        guard UserDefaults.standard.bool(forKey: pendingOpenFavoritesKey) else {
            return false
        }

        UserDefaults.standard.removeObject(forKey: pendingOpenFavoritesKey)
        return true
    }

    static func clearOpenFavoritesRequest() {
        UserDefaults.standard.removeObject(forKey: pendingOpenFavoritesKey)
    }
}
