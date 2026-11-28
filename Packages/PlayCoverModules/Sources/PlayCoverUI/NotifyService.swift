//
//  NotifyService.swift
//  PlayCover
//

import Foundation
import PlayCoverCore
import SwiftUI
import UserNotifications

public final class NotifyService: NSObject, UNUserNotificationCenterDelegate, Sendable {

    public override init() {
        super.init()
    }

    public func allowNotify() {
        guard !ProcessInfo.isRunningUnitTests else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    public func notify(_ title: String, _ message: String) {
        guard !ProcessInfo.isRunningUnitTests else { return }
        let normalizedTitle = title.localizedCapitalized
        let normalizedBody = message.localizedCapitalized
        Task { @MainActor [weak self] in
            guard let self else { return }
            let center = UNUserNotificationCenter.current()
            center.delegate = self

            let settings = await center.notificationSettings()
            let allowed: Bool
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                allowed = true
            case .notDetermined:
                allowed = (try? await center.requestAuthorization(options: [.badge, .alert, .sound])) ?? false
            default:
                allowed = false
            }
            guard allowed else { return }

            let content = UNMutableNotificationContent()
            content.title = normalizedTitle
            content.body = normalizedBody
            content.categoryIdentifier = "alarm"
            content.sound = UNNotificationSound.default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1.0, repeats: false)
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
            try? await center.add(request)
        }
    }

}
