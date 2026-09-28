import Foundation
import LoopKit
import Testing

@testable import Trio

@Suite("Trio Alerts: single audible channel") struct TrioAlertAudiblePlanTests {
    @Test("Authorized critical alert uses the chosen caf and does not start the fallback")
    func authorizedCriticalIsNotificationOnly() {
        let plan = TrioAlertAudiblePlan.make(
            interruptionLevel: .critical,
            soundFilename: "trill.caf",
            muted: false,
            criticalAlertsAuthorized: true
        )
        #expect(plan.notificationSound == .named("trill.caf", critical: true))
        #expect(!plan.startFallback)
        #expect(!plan.silenceNotification)
    }

    @Test("Authorized critical alert still sounds when the global mute window is active")
    func authorizedCriticalIgnoresMute() {
        let plan = TrioAlertAudiblePlan.make(
            interruptionLevel: .critical,
            soundFilename: "urgent_low.caf",
            muted: true,
            criticalAlertsAuthorized: true
        )
        #expect(plan.notificationSound == .named("urgent_low.caf", critical: true))
        #expect(!plan.startFallback)
    }

    @Test("Denied critical alerts silence the notification and use the fallback")
    func deniedCriticalUsesFallbackOnly() {
        let plan = TrioAlertAudiblePlan.make(
            interruptionLevel: .critical,
            soundFilename: "trill.caf",
            muted: false,
            criticalAlertsAuthorized: false
        )
        #expect(plan.notificationSound == .none)
        #expect(plan.startFallback)
        #expect(plan.silenceNotification)
    }

    @Test("Critical with playsSound off stays a silent critical notification")
    func criticalWithoutToneDoesNotFallback() {
        let plan = TrioAlertAudiblePlan.make(
            interruptionLevel: .critical,
            soundFilename: nil,
            muted: false,
            criticalAlertsAuthorized: false
        )
        #expect(plan.notificationSound == .criticalSilent)
        #expect(!plan.startFallback)
    }

    @Test("Muted non-critical alerts stay silent and do not start the fallback")
    func mutedNonCriticalIsSilent() {
        let plan = TrioAlertAudiblePlan.make(
            interruptionLevel: .timeSensitive,
            soundFilename: "chime.caf",
            muted: true,
            criticalAlertsAuthorized: true
        )
        #expect(plan.notificationSound == .none)
        #expect(!plan.startFallback)
    }

    @Test("Non-critical alerts use a standard named sound")
    func nonCriticalNamedSound() {
        let plan = TrioAlertAudiblePlan.make(
            interruptionLevel: .timeSensitive,
            soundFilename: "chime.caf",
            muted: false,
            criticalAlertsAuthorized: false
        )
        #expect(plan.notificationSound == .named("chime.caf", critical: false))
        #expect(!plan.startFallback)
    }
}

@Suite("Trio Alerts: fallback ownership under home-bell snooze") struct FallbackAudioOwnershipTests {
    private func identifier(_ slug: String) -> Alert.Identifier {
        Alert.Identifier(managerIdentifier: "Trio", alertIdentifier: slug)
    }

    @Test("Cancel stops only the alert that owns the fallback")
    func cancelMatchesOwner() {
        let ownership = FallbackAudioOwnership()
        let low = identifier("glucose.low.\(UUID().uuidString)")
        let urgent = identifier("glucose.urgentLow.\(UUID().uuidString)")
        let ticket = ownership.begin(low)
        #expect(ownership.isCurrent(generation: ticket.generation, identifier: low))
        #expect(!ownership.cancel(urgent))
        #expect(ownership.isCurrent(generation: ticket.generation, identifier: low))
        #expect(ownership.cancel(low))
        #expect(!ownership.isCurrent(generation: ticket.generation, identifier: low))
        #expect(ownership.currentOwner == nil)
    }

    @Test("A newer alert replaces ownership so the old play cannot start late")
    func beginReplacesPreviousOwner() {
        let ownership = FallbackAudioOwnership()
        let low = identifier("glucose.low.\(UUID().uuidString)")
        let urgent = identifier("glucose.urgentLow.\(UUID().uuidString)")
        let first = ownership.begin(low)
        let second = ownership.begin(urgent)
        #expect(second.replaced == low)
        #expect(!ownership.isCurrent(generation: first.generation, identifier: low))
        #expect(ownership.isCurrent(generation: second.generation, identifier: urgent))
    }

    @Test("Home-bell bulk snooze stops glucose types other than urgent-low")
    func bulkSnoozeStopsSnoozedGlucoseTypesOnly() {
        let low = identifier("glucose.low.\(UUID().uuidString)")
        let urgent = identifier("glucose.urgentLow.\(UUID().uuidString)")
        let high = identifier("glucose.high.\(UUID().uuidString)")
        let pump = identifier("com.nightscout.medtrumkit.patch-empty")
        #expect(FallbackAudioOwnership.shouldStopForBulkSnooze(owner: low))
        #expect(FallbackAudioOwnership.shouldStopForBulkSnooze(owner: high))
        #expect(!FallbackAudioOwnership.shouldStopForBulkSnooze(owner: urgent))
        #expect(!FallbackAudioOwnership.shouldStopForBulkSnooze(owner: pump))
        #expect(!FallbackAudioOwnership.shouldStopForBulkSnooze(owner: nil))
    }
}

@Suite("Trio Alerts: Libre glucose notification suppression") struct LibreGlucoseAlarmSuppressionTests {
    private func makeDefaults() -> UserDefaults {
        let name = "LibreGlucoseAlarmSuppressionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("Always-notify and every-N glucose alerts are turned off")
    func clearsAlwaysNotifyKeys() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: LibreGlucoseAlarmSuppression.alwaysDisplayGlucoseKey)
        defaults.set(2, forKey: LibreGlucoseAlarmSuppression.notifyEveryXTimesKey)
        defaults.set(true, forKey: "com.loopkit.libreLowBatteryWarning")

        LibreGlucoseAlarmSuppression.apply(defaults: defaults, clearDeliveredGlucoseNotification: false)

        #expect(defaults.bool(forKey: LibreGlucoseAlarmSuppression.alwaysDisplayGlucoseKey) == false)
        #expect(defaults.integer(forKey: LibreGlucoseAlarmSuppression.notifyEveryXTimesKey) == 0)
        #expect(defaults.bool(forKey: "com.loopkit.libreLowBatteryWarning") == true)
    }

    @Test("Enabled Libre glucose schedules are disabled without dropping thresholds")
    func disablesSchedulesPreservingThresholds() throws {
        let defaults = makeDefaults()
        let original = """
        {"schedules":[{"enabled":true,"lowAlarm":70,"highAlarm":180,"from":{"hour":0,"minute":0}},{"enabled":false,"lowAlarm":80,"highAlarm":200}]}
        """
        defaults.set(Data(original.utf8), forKey: LibreGlucoseAlarmSuppression.glucoseSchedulesKey)

        #expect(LibreGlucoseAlarmSuppression.disableEnabledSchedules(in: defaults))

        let data = try #require(defaults.data(forKey: LibreGlucoseAlarmSuppression.glucoseSchedulesKey))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let schedules = try #require(root["schedules"] as? [[String: Any]])
        #expect(schedules.count == 2)
        #expect((schedules[0]["enabled"] as? Bool) == false)
        #expect((schedules[0]["lowAlarm"] as? Int) == 70 || (schedules[0]["lowAlarm"] as? Double) == 70)
        #expect((schedules[0]["highAlarm"] as? Int) == 180 || (schedules[0]["highAlarm"] as? Double) == 180)
        #expect((schedules[1]["enabled"] as? Bool) == false)
        #expect((schedules[1]["lowAlarm"] as? Int) == 80 || (schedules[1]["lowAlarm"] as? Double) == 80)
        let from = try #require(schedules[0]["from"] as? [String: Any])
        #expect((from["hour"] as? Int) == 0)
    }
}
