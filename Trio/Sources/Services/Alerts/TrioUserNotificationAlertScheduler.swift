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

    /// `silenced` posts the notification without any sound. Used when AlarmKit
    /// or `CriticalAlertAudioPlayer` is already the audible channel, so the
    /// two don't overlap into one very loud alarm.
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
        // alerts keep their tone here: home-bell snooze retracts the types it
        // covers, and urgent-low stays outside that bulk snooze so an
        // overnight hypo still breaks through Focus. Volume 0 was silencing
        // those hypos after the upstream alerting-fixes merge.
        //
        // When AlarmKit or `CriticalAlertAudioPlayer` owns the tone (Critical
        // Alerts not authorized), the caller passes `silenced: true` and this
        // method is not used — otherwise the notification and the fallback
        // would stack as two different sounds.
        let resolved = TrioAlertAudiblePlan.notificationSound(
            isCritical: isCritical,
            soundFilename: alert.sound?.filename,
            muted: muted
        )
        switch resolved {
        case .none:
            return nil
        case .criticalSilent:
            // Honor playsSound: false — still a critical UN, but silent.
            return .defaultCriticalSound(withAudioVolume: 0)
        case let .systemDefault(critical):
            return critical ? .defaultCritical : .default
        case let .named(name, critical):
            let soundName = UNNotificationSoundName(rawValue: soundURL?.lastPathComponent ?? name)
            if critical {
                // One audible channel: the chosen .caf as a critical sound.
                // Requires the critical-alerts entitlement and the user having
                // allowed Critical Alerts. Callers must not also start
                // AlarmKit or the in-process player for this alert.
                return .criticalSoundNamed(soundName)
            }
            return UNNotificationSound(named: soundName)
        }
    }
}

/// Decides the single audible channel for an alert.
///
/// Critical Alerts authorized → one critical user notification using the
/// chosen `.caf` (`criticalSoundNamed`). Not authorized → AlarmKit, or the
/// in-process player if AlarmKit is unavailable, and the notification is
/// posted silent so the two do not stack.
struct TrioAlertAudiblePlan: Equatable {
    enum NotificationSound: Equatable {
        case none
        /// Critical interruption with no tone (`playsSound` off).
        case criticalSilent
        /// `UNNotificationSound.default`, or `.defaultCritical` when critical.
        case systemDefault(critical: Bool)
        case named(String, critical: Bool)
    }

    var notificationSound: NotificationSound
    /// Start AlarmKit or `CriticalAlertAudioPlayer`. Never combined with an audible notification.
    var startFallback: Bool

    /// Post the user notification with `sound = nil` while the fallback is the audible channel.
    var silenceNotification: Bool { startFallback }

    static func make(
        interruptionLevel: Alert.InterruptionLevel,
        soundFilename: String?,
        muted: Bool,
        criticalAlertsAuthorized: Bool
    ) -> TrioAlertAudiblePlan {
        let isCritical = interruptionLevel == .critical
        let sound = notificationSound(isCritical: isCritical, soundFilename: soundFilename, muted: muted)
        // Critical + a chosen tone. Mute does not silence it: per-type snooze
        // retracts glucose alarms the home bell covers, and urgent-low is
        // left outside that bulk snooze.
        if isCritical, soundFilename != nil, !criticalAlertsAuthorized {
            return TrioAlertAudiblePlan(notificationSound: .none, startFallback: true)
        }
        return TrioAlertAudiblePlan(notificationSound: sound, startFallback: false)
    }

    /// The tone the user notification carries when it is the audible channel.
    /// `AlarmSoundCatalog.systemDefault` maps to the iOS default sounds instead
    /// of a named file.
    static func notificationSound(isCritical: Bool, soundFilename: String?, muted: Bool) -> NotificationSound {
        guard let filename = soundFilename else {
            return isCritical ? .criticalSilent : .none
        }
        if muted, !isCritical {
            return .none
        }
        if AlarmSoundCatalog.isSystemDefault(filename) {
            return .systemDefault(critical: isCritical)
        }
        return .named(filename, critical: isCritical)
    }

    /// The bundled file AlarmKit and `CriticalAlertAudioPlayer` play. Neither
    /// can play the iOS notification sound, so system default uses a soft
    /// bundled tone.
    static func fallbackSoundFilename(for soundFilename: String) -> String {
        AlarmSoundCatalog.bundledFilename(for: soundFilename)
    }
}

/// Tracks which alert currently owns AlarmKit / the looping audio player so a
/// home-bell snooze can stop that loop for the types it covers without cutting
/// off an urgent-low that is still supposed to sound.
final class FallbackAudioOwnership {
    private let lock = NSLock()
    private var generation = 0
    private var owner: Alert.Identifier?

    struct Ticket: Equatable {
        var generation: Int
        var replaced: Alert.Identifier?
    }

    func begin(_ identifier: Alert.Identifier) -> Ticket {
        lock.lock()
        defer { lock.unlock() }
        let replaced = (owner != nil && owner != identifier) ? owner : nil
        generation += 1
        owner = identifier
        return Ticket(generation: generation, replaced: replaced)
    }

    /// Drops ownership when `identifier` is the current owner. Returns false
    /// when a different alert owns the fallback, so callers leave that loop running.
    @discardableResult func cancel(_ identifier: Alert.Identifier) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard owner == identifier else { return false }
        generation += 1
        owner = nil
        return true
    }

    func isCurrent(generation: Int, identifier: Alert.Identifier) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return self.generation == generation && owner == identifier
    }

    var currentOwner: Alert.Identifier? {
        lock.lock()
        defer { lock.unlock() }
        return owner
    }

    /// Home-bell bulk snooze covers every glucose type except urgent-low.
    /// Device alarms are not glucose slugs and pierce or follow their own tier snooze.
    static func shouldStopForBulkSnooze(owner: Alert.Identifier?) -> Bool {
        guard let owner, let type = GlucoseAlertType(slug: owner.alertIdentifier) else { return false }
        return type != .urgentLow
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
