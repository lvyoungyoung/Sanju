import Foundation
import UserNotifications
import XCTest
@testable import 三句

@MainActor
final class InterfaceLanguageDependentsTests: XCTestCase {
    func testSelectionPropagatesResolvedWidgetLanguageAndOnlyReloadsForChanges() throws {
        let localName = "InterfaceLanguage.local.\(UUID())"
        let groupName = "InterfaceLanguage.group.\(UUID())"
        let local = try XCTUnwrap(UserDefaults(suiteName: localName))
        let group = try XCTUnwrap(UserDefaults(suiteName: groupName))
        defer { local.removePersistentDomain(forName: localName); group.removePersistentDomain(forName: groupName) }
        var reloads = 0
        let store = InterfaceLanguageStore(defaults: local, sharedDefaults: group,
            preferredLanguages: { ["ja-JP"] }, reloadWidgets: { reloads += 1 })
        XCTAssertEqual(group.string(forKey: InterfaceLanguageStore.widgetLocaleKey), "en")
        XCTAssertEqual(reloads, 1)
        store.select(.simplifiedChinese)
        XCTAssertEqual(local.string(forKey: InterfaceLanguageStore.preferenceKey), "zh-Hans")
        XCTAssertEqual(group.string(forKey: InterfaceLanguageStore.preferenceKey), "zh-Hans")
        XCTAssertEqual(group.string(forKey: InterfaceLanguageStore.widgetLocaleKey), "zh-Hans")
        XCTAssertEqual(store.locale.identifier, "zh-Hans")
        XCTAssertEqual(reloads, 2)
        store.syncWidgetLocale()
        store.select(.simplifiedChinese)
        XCTAssertEqual(reloads, 2)
        store.select(.english)
        XCTAssertEqual(group.string(forKey: InterfaceLanguageStore.widgetLocaleKey), "en")
        XCTAssertEqual(reloads, 3)
    }

    func testSystemLanguageRefreshUpdatesAppAndWidgetWithoutChangingSelection() throws {
        let localName = "InterfaceLanguage.local.\(UUID())"
        let groupName = "InterfaceLanguage.group.\(UUID())"
        let local = try XCTUnwrap(UserDefaults(suiteName: localName))
        let group = try XCTUnwrap(UserDefaults(suiteName: groupName))
        defer { local.removePersistentDomain(forName: localName); group.removePersistentDomain(forName: groupName) }
        var preferred = ["en-US"]
        let store = InterfaceLanguageStore(defaults: local, sharedDefaults: group,
                                           preferredLanguages: { preferred }, reloadWidgets: {})
        preferred = ["zh-Hans-CN"]
        store.syncWidgetLocale()
        XCTAssertEqual(store.selection, .system)
        XCTAssertEqual(store.resolvedLanguageCode, "zh-Hans")
        XCTAssertEqual(group.string(forKey: InterfaceLanguageStore.widgetLocaleKey), "zh-Hans")
        preferred = ["fr-FR"]
        store.syncWidgetLocale()
        XCTAssertEqual(store.resolvedLanguageCode, "en")
    }

    func testReminderRelocalizationPreservesTimeRepeatRouteAndSound() throws {
        let content = UNMutableNotificationContent()
        content.title = "Old title"
        content.body = "Old body"
        content.sound = .default
        content.userInfo = [LearningReminderScheduler.notificationTypeUserInfoKey: LearningReminderScheduler.learningReminderNotificationType]
        let trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: 21, minute: 35), repeats: true)
        let request = UNNotificationRequest(identifier: LearningReminderScheduler.dailyReminderIdentifier, content: content, trigger: trigger)
        let english = LearningReminderScheduler.localizedRequest(request, languageCode: "en")
        XCTAssertEqual(english.content.title, "Time to study")
        XCTAssertEqual(english.content.body, "Spend two minutes today practicing the sentences you saved.")
        XCTAssertEqual(english.identifier, request.identifier)
        XCTAssertEqual((english.trigger as? UNCalendarNotificationTrigger)?.dateComponents, trigger.dateComponents)
        XCTAssertEqual(english.trigger?.repeats, true)
        XCTAssertNotNil(english.content.sound)
        XCTAssertEqual(english.content.userInfo as NSDictionary, content.userInfo as NSDictionary)
        let chinese = LearningReminderScheduler.localizedRequest(english, languageCode: "zh-Hans")
        XCTAssertEqual(chinese.content.title, "该学习啦")
        XCTAssertEqual(chinese.content.body, "今天也花 2 分钟，把收藏里的句子练一遍。")
        XCTAssertEqual(request.content.title, "Old title")
    }
}
