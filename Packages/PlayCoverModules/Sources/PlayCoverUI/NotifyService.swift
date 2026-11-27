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
        UNUserNotificationCenter.current().requestAuthorization(options: [.badge, .alert, .sound]) { _, error in
            if error != nil {
                print("Error Found, \(error?.localizedDescription ?? "")")
            } else {
                print("Authorized by the user")
            }
        }
    }

    public func notify(_ title: String, _ message: String) {
        guard !ProcessInfo.isRunningUnitTests else { return }
        let center = UNUserNotificationCenter.current()

        let content = UNMutableNotificationContent()
        content.title = title.localizedCapitalized
        content.body = message.localizedCapitalized
        content.categoryIdentifier = "alarm"
        content.sound = UNNotificationSound.default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1.0, repeats: false)

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        center.add(request)
    }

}
