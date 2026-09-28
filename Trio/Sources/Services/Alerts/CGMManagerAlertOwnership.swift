import CGMBLEKit
import Foundation
import G7SensorKit
import LoopKit
import UserNotifications

/// Trio-side stand-in for LoopKit next-dev's `CGMManager.providesOwnGlucoseAlerts`.
/// Collapses to `manager?.providesOwnGlucoseAlerts ?? false` once the fork bumps.
enum CGMManagerAlertOwnership {
    struct OwningApp {
        let name: String
        /// URL scheme registered by the companion app, if known. Schemes
        /// taken from the corresponding manager UI: `dexcomg6://` from
        /// CGMBLEKitUI's TransmitterSettingsViewController, `dexcomg7://`
        /// from G7SensorKitUI's G7SettingsView, `xdripswift://` from
        /// Trio's own CGMType.appURL. The manager protocol's `appURL`
        /// returns nil on our forks, so this table is the source of truth.
        let deepLink: URL?
    }

    static func providesOwnGlucoseAlerts(manager: CGMManager?, sourceType: CGMType) -> Bool {
        owningApp(manager: manager, sourceType: sourceType) != nil
    }

    static func owningApp(manager: CGMManager?, sourceType: CGMType) -> OwningApp? {
        // `.xdrip` runs without a CGMManager instance (App Group source),
        // so check the source type first.
        if sourceType == .xdrip {
            return OwningApp(name: "xDrip4iOS", deepLink: URL(string: "xdripswift://"))
        }
        switch manager {
        case is G5CGMManager:
            return OwningApp(name: "Dexcom G5", deepLink: nil)
        case is G6CGMManager:
            return OwningApp(name: "Dexcom G6 / One", deepLink: URL(string: "dexcomg6://"))
        case is G7CGMManager:
            return OwningApp(name: "Dexcom G7 / One+", deepLink: URL(string: "dexcomg7://"))
        // LibreTransmitter is in-process: glucose arrives through Trio, not a
        // companion app that can be relied on to wake the user overnight.
        // Treating it as an "owning" CGM (post-upstream-dev merge) silently
        // suppressed Trio hypo alarms. Do not add it back.
        default:
            return nil
        }
    }
}

/// Stops LibreTransmitter's own glucose notifications while Trio owns glucose alarms.
///
/// Libre is in-process. `NotificationHelper.sendGlucoseNotificationIfNeeded` posts a
/// separate glucose user notification when any of these are set:
/// - `com.loopkit.libreAlwaysDisplayGlucose` (defaults to true when missing)
/// - `com.loopkit.libreNotifyEveryXTimes` (every Nth reading)
/// - an enabled entry in `com.loopkit.libreglucoseschedules` (CGM-menu low/high alarm)
///
/// That path has its own snooze (`com.loopkit.libreSnoozedUntil`), so the home bell
/// does not silence it, and a hypo can play Libre's tone plus Trio's. Sensor, battery,
/// and transmitter notifications use other keys and are left alone.
///
/// Re-applied on launch, foreground, each glucose evaluation, and home-bell snooze.
/// A user who turns "Always Notify Glucose" or a Libre schedule alarm back on in the
/// CGM menu gets it turned off again the next time Trio evaluates glucose — Trio is
/// the glucose-alarm owner for Libre. Do not add Libre to `CGMManagerAlertOwnership`;
/// that previously suppressed overnight Trio hypos.
enum LibreGlucoseAlarmSuppression {
    static let alwaysDisplayGlucoseKey = "com.loopkit.libreAlwaysDisplayGlucose"
    static let notifyEveryXTimesKey = "com.loopkit.libreNotifyEveryXTimes"
    static let glucoseSchedulesKey = "com.loopkit.libreglucoseschedules"
    /// `NotificationHelper.Identifiers.glucocoseNotifications` (Libre's spelling).
    static let glucoseNotificationIdentifier = "com.loopkit.libremiaomiao.glucose-notification"

    static func apply(defaults: UserDefaults = .standard, clearDeliveredGlucoseNotification: Bool = true) {
        defaults.set(false, forKey: alwaysDisplayGlucoseKey)
        defaults.set(0, forKey: notifyEveryXTimesKey)
        disableEnabledSchedules(in: defaults)
        guard clearDeliveredGlucoseNotification else { return }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [glucoseNotificationIdentifier])
        center.removePendingNotificationRequests(withIdentifiers: [glucoseNotificationIdentifier])
    }

    /// Turns `enabled` off on stored Libre glucose schedules without dropping thresholds.
    /// Returns true when a schedule was changed.
    @discardableResult static func disableEnabledSchedules(in defaults: UserDefaults) -> Bool {
        guard let data = defaults.data(forKey: glucoseSchedulesKey),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var schedules = root["schedules"] as? [[String: Any]]
        else { return false }

        var changed = false
        for index in schedules.indices {
            let enabled = schedules[index]["enabled"]
            let isOn = (enabled as? Bool) == true || (enabled as? NSNumber)?.intValue == 1
            guard isOn else { continue }
            schedules[index]["enabled"] = false
            changed = true
        }
        guard changed else { return false }
        root["schedules"] = schedules
        guard let encoded = try? JSONSerialization.data(withJSONObject: root) else { return false }
        defaults.set(encoded, forKey: glucoseSchedulesKey)
        return true
    }
}
