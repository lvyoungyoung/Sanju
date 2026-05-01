//
//  __App.swift
//  三句
//
//  Created by 吕扬 on 2026/3/31.
//

import SwiftUI
import UIKit
import UserNotifications

@main
struct __App: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

private final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }

        guard isLearningReminderResponse(response) else {
            return
        }

        LearningReminderNotificationRoute.markOpenFavoritesRequested()
    }

    private func isLearningReminderResponse(_ response: UNNotificationResponse) -> Bool {
        let request = response.notification.request
        if request.identifier == LearningReminderScheduler.dailyReminderIdentifier {
            return true
        }

        return request.content.userInfo[LearningReminderScheduler.notificationTypeUserInfoKey] as? String
            == LearningReminderScheduler.learningReminderNotificationType
    }
}
