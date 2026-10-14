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

@MainActor
enum LearningReminderScheduler {
    static let dailyReminderIdentifier = "sanju.learning.daily-reminder"
    static let notificationTypeUserInfoKey = "sanju.notification.type"
    static let learningReminderNotificationType = "learning-reminder"
    private static var revision = 0
    private static var configuringRevision: Int?
    private static var pendingWrite: Task<Void, Error>?

    static func scheduleDailyReminder(hour: Int, minute: Int) async throws {
        guard (0...23).contains(hour), (0...59).contains(minute) else {
            throw LearningReminderError.invalidTime
        }
        revision += 1
        let operation = revision
        configuringRevision = operation
        defer { if configuringRevision == operation { configuringRevision = nil } }

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

        guard revision == operation else { throw CancellationError() }
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

        try await enqueueWrite(request, revision: operation).value
        guard revision == operation else { throw CancellationError() }
        configuringRevision = nil
        // A language change while permission or scheduling was pending must not leave stale text.
        try? await refreshDailyReminderLanguage()
        guard revision == operation else { throw CancellationError() }
    }

    static func cancelDailyReminder() {
        revision += 1
        configuringRevision = nil
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [dailyReminderIdentifier])
        // Repeat the removal after any in-flight add completes so refresh cannot re-enable it.
        _ = enqueueWrite(nil, revision: revision)
    }

    static func refreshDailyReminderLanguage() async throws {
        guard configuringRevision == nil else { return }
        let operation = revision
        _ = try? await pendingWrite?.value
        let center = UNUserNotificationCenter.current()
        let requests = await center.pendingNotificationRequests()
        guard revision == operation, configuringRevision == nil else { throw CancellationError() }
        guard let existing = requests.first(where: { $0.identifier == dailyReminderIdentifier }) else { return }
        let updated = localizedRequest(existing, languageCode: InterfaceLanguageStore.resolvedCode)
        guard updated.content.title != existing.content.title || updated.content.body != existing.content.body else { return }
        try await enqueueWrite(updated, revision: operation).value
    }

    static func localizedRequest(_ existing: UNNotificationRequest, languageCode: String) -> UNNotificationRequest {
        guard let content = existing.content.mutableCopy() as? UNMutableNotificationContent else { return existing }
        let bundle = InterfaceLanguageStore.bundle(for: languageCode)
        content.title = bundle.localizedString(forKey: "learning_reminder.notification_title",
            value: languageCode == "en" ? "Time to study" : "该学习啦", table: nil)
        content.body = bundle.localizedString(forKey: "learning_reminder.notification_body",
            value: languageCode == "en" ? "Spend two minutes today practicing the sentences you saved." : "今天也花 2 分钟，把收藏里的句子练一遍。", table: nil)
        return UNNotificationRequest(identifier: existing.identifier, content: content, trigger: existing.trigger)
    }

    private static func enqueueWrite(_ request: UNNotificationRequest?, revision expected: Int) -> Task<Void, Error> {
        let previous = pendingWrite
        let task = Task { @MainActor in
            _ = try? await previous?.value
            guard revision == expected else { throw CancellationError() }
            let center = UNUserNotificationCenter.current()
            if let request {
                try await add(request, to: center)
            } else {
                center.removePendingNotificationRequests(withIdentifiers: [dailyReminderIdentifier])
            }
        }
        pendingWrite = task
        return task
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
