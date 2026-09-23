import Foundation
import LoopKit
import UserNotifications

protocol TrioUserNotificationAlertResponder: AnyObject {
    func handleAcknowledgement(identifier: Alert.Identifier)
}

final class TrioUserNotificationAlertScheduler {
    weak var responder: TrioUserNotificationAlertResponder?

    private let notificationCenter: UNUserNotificationCenter

    init(notificationCenter: UNUserNotificationCenter) {
        self.notificationCenter = notificationCenter
    }

    /// `silenced` posts the notification without any sound. Used when another
    /// channel (AlarmKit) is already sounding this alert, so the two don't
    /// overlap into one very loud alarm.
    func schedule(_ alert: Alert, muted: Bool, soundURL: URL?, silenced: Bool = false) {
        let request = makeRequest(alert: alert, muted: muted, soundURL: soundURL, silenced: silenced)
        notificationCenter.add(request) { error in
            if let error = error {
                debug(.service, "UserNotificationAlertScheduler failed: \(error.localizedDescription)")
            }
        }
    }

    func unschedule(identifier: Alert.Identifier) {
        notificationCenter.removePendingNotificationRequests(withIdentifiers: [identifier.value])
        notificationCenter.removeDeliveredNotifications(withIdentifiers: [identifier.value])
    }

    private func makeRequest(alert: Alert, muted: Bool, soundURL: URL?, silenced: Bool) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = alert.backgroundContent.title
        content.body = alert.backgroundContent.body
        content.threadIdentifier = alert.identifier.managerIdentifier
        content.userInfo = [
            AlertUserInfoKey.managerIdentifier.rawValue: alert.identifier.managerIdentifier,
            AlertUserInfoKey.alertIdentifier.rawValue: alert.identifier.alertIdentifier
        ]
        content.interruptionLevel = alert.interruptionLevel.unNotificationLevel
        content.sound = silenced ? nil : sound(for: alert, muted: muted, soundURL: soundURL)
        // Surface the four quick-snooze actions (15 min / 1 h / 3 h / 6 h)
        // on both phone and watch lock-screen notifications. The category +
        // its actions are registered by `NotificationCategoryFactory` on
        // both the phone (`BaseUserNotificationsManager`) and watch
        // (`WatchNotificationHandler`) UN delegates.
        content.categoryIdentifier = NotificationCategoryIdentifier.trioAlert.rawValue

        return UNNotificationRequest(
            identifier: alert.identifier.value,
            content: content,
            trigger: alert.trigger.unTrigger
        )
    }

    private func sound(for alert: Alert, muted: Bool, soundURL: URL?) -> UNNotificationSound? {
        let isCritical = alert.interruptionLevel == .critical
        // Non-critical alerts stay quiet during a snooze window. Critical
        // alerts (Override Silence & Focus) must still make sound — volume 0
        // was silencing overnight hypos after the upstream alerting-fixes
        // merge, including when the user had only snoozed highs before bed.
        if muted, !isCritical {
            return nil
        }
        switch alert.sound {
        case .none,
             .vibrate:
            // Honor playsSound: false — still a critical UN, but silent.
            return isCritical ? .defaultCriticalSound(withAudioVolume: 0) : nil
        case let .sound(name):
            if isCritical {
                // Pre-merge main used the system critical sound for LOWALERT
                // so DND breakthrough did not depend on copying a bundled
                // .caf into Library/Sounds. Keep that UN sound; the
                // in-process player still loops the user-selected file.
                return .defaultCritical
            }
            if let filename = soundURL?.lastPathComponent {
                return UNNotificationSound(named: UNNotificationSoundName(rawValue: filename))
            }
            return UNNotificationSound(named: UNNotificationSoundName(name))
        }
    }
}

private extension Alert.InterruptionLevel {
    var unNotificationLevel: UNNotificationInterruptionLevel {
        switch self {
        case .active: return .active
        case .timeSensitive: return .timeSensitive
        case .critical: return .critical
        }
    }
}

private extension Alert.Trigger {
    var unTrigger: UNNotificationTrigger? {
        switch self {
        case .immediate:
            return nil
        case let .delayed(interval):
            return UNTimeIntervalNotificationTrigger(timeInterval: max(interval, 1), repeats: false)
        case let .repeating(interval):
            return UNTimeIntervalNotificationTrigger(timeInterval: max(interval, 60), repeats: true)
        }
    }
}
