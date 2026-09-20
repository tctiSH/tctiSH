//
//  LocalAlert.swift
//  Telling someone something when they aren't looking at the app.
//
//  Copyright © 2026 Ara Adkins.
//

import Foundation
import UserNotifications

/// Local notifications, for when nobody is watching the app.
///
/// The status pills cover everything that goes wrong in front of the user. This
/// is for the rest and is local only. Nothing here talks to a server, and no
/// entitlement is involved.
enum LocalAlert {

    /// Asks to be allowed to post, if that hasn't been settled already.
    ///
    /// Asked once the shell is up rather than at launch, so the prompt arrives
    /// when there is a session worth protecting instead of before the app has
    /// done anything at all.
    static func requestPermission() {
        guard !hasAsked else { return }
        hasAsked = true

        // Before anything can be posted. iOS hands a notification to the frontmost app's delegate
        // instead of showing it, and drops it if there is no delegate to ask. Without this the one
        // alert that fires while someone is looking at the app would go nowhere.
        UNUserNotificationCenter.current().delegate = presenter

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
            granted, error in

            if let error {
                Log.ui.warn("could not ask about notifications: \(error.localizedDescription)")
                return
            }

            Log.ui.note("notifications \(granted ? "allowed" : "refused")")
        }
    }

    private static var hasAsked = false

    /// Lets a notification through while the app is foregrounded.
    ///
    /// Everything here is worth seeing whether or not the app is on screen: a
    /// session save that failed, and a saved session that could not be
    /// restored. Neither has another surface.
    private final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification,
            withCompletionHandler completionHandler:
                @escaping (UNNotificationPresentationOptions) -> Void
        ) {
            completionHandler([.banner, .sound])
        }
    }

    private static let presenter = ForegroundPresenter()

    /// Posts one, now or shortly.
    ///
    /// Quietly does nothing if notifications were refused, which is an answer
    /// rather than a failure: someone who said no is not to be told by some
    /// other route.
    static func post(title: String, body: String, id: String, after delay: TimeInterval? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let trigger = delay.map {
            UNTimeIntervalNotificationTrigger(timeInterval: max($0, 1), repeats: false)
        }

        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { error in
            guard let error else { return }
            Log.ui.warn("could not post '\(id)': \(error.localizedDescription)")
        }
    }

    /// Takes one back, whether or not it has gone out yet.
    ///
    /// Both lists, because which of them it is in depends on timing this
    /// doesn't control. A notice that has become untrue is worth withdrawing
    /// from the shade as well as from the queue.
    static func withdraw(id: String) {
        let centre = UNUserNotificationCenter.current()

        centre.removePendingNotificationRequests(withIdentifiers: [id])
        centre.removeDeliveredNotifications(withIdentifiers: [id])
    }
}
