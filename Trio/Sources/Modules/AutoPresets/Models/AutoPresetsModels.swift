//
//  AutoPresetsModels.swift
//  Trio
//
//  AutoPresets — Activity type, settings, log entries, error enum.
//  Trio MVP port of Loop PowerPack AutoPresets (motion-only; calendar/geofence omitted).
//

import Foundation

// MARK: - Activity Type

enum AutoPresetsActivityType: String, Codable, CaseIterable, Hashable {
    case walking
    case running
    case cycling
    case swimming
    case strengthTraining
    case yoga

    var displayName: String {
        switch self {
        case .walking: return String(localized: "Walking")
        case .running: return String(localized: "Running")
        case .cycling: return String(localized: "Cycling")
        case .swimming: return String(localized: "Swimming")
        case .strengthTraining: return String(localized: "Strength Training")
        case .yoga: return String(localized: "Yoga")
        }
    }

    var systemImageName: String {
        switch self {
        case .walking: return "figure.walk"
        case .running: return "figure.run"
        case .cycling: return "figure.outdoor.cycle"
        case .swimming: return "figure.pool.swim"
        case .strengthTraining: return "dumbbell.fill"
        case .yoga: return "figure.yoga"
        }
    }

    /// Default sustained-activity duration before the preset is activated.
    /// Cycling needs a much higher threshold than walking so short commutes
    /// don't trigger an exercise override.
    var defaultContinuousTime: TimeInterval {
        switch self {
        case .walking: return 30        // 30 s
        case .running: return 30        // 30 s
        case .cycling: return 15 * 60   // 15 min — filters out short rides
        case .swimming, .strengthTraining, .yoga: return 5 * 60 // HK workouts: 5 min
        }
    }

    /// True for activity types that are driven by HealthKit workout samples
    /// rather than by `CMMotionActivity` + pedometer. Detection plumbing is
    /// completely different.
    var isHealthKitDriven: Bool {
        switch self {
        case .walking, .running, .cycling: return false
        case .swimming, .strengthTraining, .yoga: return true
        }
    }

    /// Aerobic (drop-risk dominant) vs. anaerobic (rise-risk dominant) vs.
    /// mixed/neutral. Drives the choice of post-activity delayed-hypo handling
    /// and informs the AI chat when correlating activity with glucose.
    var primaryEffect: AerobicProfile {
        switch self {
        case .walking, .running, .cycling, .swimming: return .aerobic
        case .strengthTraining: return .anaerobic
        case .yoga: return .neutral
        }
    }

    enum AerobicProfile: String, Codable {
        case aerobic
        case anaerobic
        case neutral
    }
}

// MARK: - Log Event

enum AutoPresetsLogEvent: String, Codable {
    case featureEnabled
    case featureDisabled
    case presetActivated
    case presetDeactivated
    case permissionDenied
    case delayedHypoScheduled
    case delayedHypoActivated
    case delayedHypoExpired
    case caffeineOverrideActivated
    case caffeineOverrideRefreshed
    case caffeineOverrideExpired
    case alcoholOverrideScheduled
    case alcoholOverrideActivated
    case alcoholOverrideRefreshed
    case alcoholOverrideExpired

    var iconName: String {
        switch self {
        case .featureEnabled: return "power.circle.fill"
        case .featureDisabled: return "power.circle"
        case .presetActivated: return "play.circle.fill"
        case .presetDeactivated: return "stop.circle.fill"
        case .permissionDenied: return "exclamationmark.triangle.fill"
        case .delayedHypoScheduled: return "clock.badge.exclamationmark"
        case .delayedHypoActivated: return "shield.lefthalf.filled"
        case .delayedHypoExpired: return "shield"
        case .caffeineOverrideActivated: return "cup.and.saucer.fill"
        case .caffeineOverrideRefreshed: return "arrow.clockwise.circle.fill"
        case .caffeineOverrideExpired: return "cup.and.saucer"
        case .alcoholOverrideScheduled: return "wineglass"
        case .alcoholOverrideActivated: return "wineglass.fill"
        case .alcoholOverrideRefreshed: return "arrow.clockwise.circle.fill"
        case .alcoholOverrideExpired: return "wineglass"
        }
    }

    var displayName: String {
        switch self {
        case .featureEnabled: return String(localized: "Feature Enabled")
        case .featureDisabled: return String(localized: "Feature Disabled")
        case .presetActivated: return String(localized: "Preset Activated")
        case .presetDeactivated: return String(localized: "Preset Deactivated")
        case .permissionDenied: return String(localized: "Permission Denied")
        case .delayedHypoScheduled: return String(localized: "Delayed-Hypo Scheduled")
        case .delayedHypoActivated: return String(localized: "Delayed-Hypo Active")
        case .delayedHypoExpired: return String(localized: "Delayed-Hypo Ended")
        case .caffeineOverrideActivated: return String(localized: "Caffeine Override Active")
        case .caffeineOverrideRefreshed: return String(localized: "Caffeine Override Extended")
        case .caffeineOverrideExpired: return String(localized: "Caffeine Override Ended")
        case .alcoholOverrideScheduled: return String(localized: "Alcohol Override Scheduled")
        case .alcoholOverrideActivated: return String(localized: "Alcohol Override Active")
        case .alcoholOverrideRefreshed: return String(localized: "Alcohol Override Extended")
        case .alcoholOverrideExpired: return String(localized: "Alcohol Override Ended")
        }
    }
}

struct AutoPresetsLogEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let event: AutoPresetsLogEvent
    let activityType: AutoPresetsActivityType?
    let presetName: String?

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        event: AutoPresetsLogEvent,
        activityType: AutoPresetsActivityType? = nil,
        presetName: String? = nil
    ) {
        self.id = id
        self.date = date
        self.event = event
        self.activityType = activityType
        self.presetName = presetName
    }
}

// MARK: - Settings

struct AutoPresetsSettings: Codable, Equatable {
    var isEnabled: Bool
    var supportedActivityTypes: Set<AutoPresetsActivityType>
    /// `[activityRawValue: OverrideStored.id (UUID string)]`
    var activityPresets: [String: String]
    var stopInterval: TimeInterval
    var continuousActivityTime: TimeInterval
    var requireHighConfidence: Bool
    var recentActivityLog: [AutoPresetsLogEntry]

    /// Per-activity sustained-time override. Falls back to
    /// `AutoPresetsActivityType.defaultContinuousTime` if absent.
    var perActivityContinuousTime: [String: TimeInterval]

    /// Master toggle for the delayed-hypo override that fires N minutes after
    /// an aerobic activity stops to compensate for glycogen replenishment.
    var enableDelayedHypoWindow: Bool
    /// How long to wait after activity stops before triggering the delayed-hypo
    /// preset. Default: 90 min based on the diabetotech recommendation.
    var delayedHypoDuration: TimeInterval
    /// `[activityRawValue: OverrideStored.id]` for the *post-activity* preset.
    /// If absent for a given activity, the delayed-hypo override is skipped.
    var delayedHypoPresets: [String: String]
    /// How long the delayed-hypo preset stays on once activated. Default 60 min.
    var delayedHypoPresetDuration: TimeInterval

    /// Use HealthKit heart rate as a secondary signal. High HR with low step
    /// rate suggests strength/anaerobic activity even when CoreMotion doesn't
    /// classify it.
    var useHeartRateSignal: Bool
    /// Bpm threshold above which we consider the user is in elevated effort.
    var heartRateThresholdBpm: Double

    /// Observe HealthKit workout samples to trigger non-motion activities
    /// (swimming, strength, yoga).
    var enableHealthKitWorkouts: Bool

    // MARK: - Caffeine auto-override (Layer A)
    /// When true, logging a caffeine entry above the threshold immediately
    /// activates the configured override preset for `caffeineOverrideDuration`.
    /// Backed by Shi 2017 / Whitehead 2013: acute caffeine reduces insulin
    /// sensitivity in a 2-4h window post-ingestion.
    var caffeineOverrideEnabled: Bool
    /// `OverrideStored.id` of the preset to apply.
    var caffeineOverridePresetID: String?
    /// How long the caffeine-triggered preset stays active. Default 3h.
    var caffeineOverrideDuration: TimeInterval
    /// Minimum mg per entry that triggers an override (skip tiny doses).
    var caffeineOverrideThresholdMg: Double

    // MARK: - Alcohol auto-override (Layer A)
    /// When true, logging an alcohol entry schedules a delayed override to
    /// compensate for impaired gluconeogenesis (Turner 2001, Richardson 2005).
    var alcoholOverrideEnabled: Bool
    /// `OverrideStored.id` of the preset to apply.
    var alcoholOverridePresetID: String?
    /// Delay between logging and override activation. Default 90 min based on
    /// observed timing of delayed alcohol-induced hypoglycemia.
    var alcoholOverrideDelay: TimeInterval
    /// How long the alcohol-triggered preset stays active. Default 6h.
    var alcoholOverrideDuration: TimeInterval
    /// Minimum standard drinks that triggers an override.
    var alcoholOverrideThresholdUnits: Double

    init(
        isEnabled: Bool = false,
        supportedActivityTypes: Set<AutoPresetsActivityType> = [.walking],
        activityPresets: [String: String] = [:],
        stopInterval: TimeInterval = 300,
        continuousActivityTime: TimeInterval = 30,
        requireHighConfidence: Bool = false,
        recentActivityLog: [AutoPresetsLogEntry] = [],
        perActivityContinuousTime: [String: TimeInterval] = [:],
        enableDelayedHypoWindow: Bool = false,
        delayedHypoDuration: TimeInterval = 90 * 60,
        delayedHypoPresets: [String: String] = [:],
        delayedHypoPresetDuration: TimeInterval = 60 * 60,
        useHeartRateSignal: Bool = false,
        heartRateThresholdBpm: Double = 120,
        enableHealthKitWorkouts: Bool = false,
        caffeineOverrideEnabled: Bool = false,
        caffeineOverridePresetID: String? = nil,
        caffeineOverrideDuration: TimeInterval = 3 * 3600,
        caffeineOverrideThresholdMg: Double = 100,
        alcoholOverrideEnabled: Bool = false,
        alcoholOverridePresetID: String? = nil,
        alcoholOverrideDelay: TimeInterval = 90 * 60,
        alcoholOverrideDuration: TimeInterval = 6 * 3600,
        alcoholOverrideThresholdUnits: Double = 1.0
    ) {
        self.isEnabled = isEnabled
        self.supportedActivityTypes = supportedActivityTypes
        self.activityPresets = activityPresets
        self.stopInterval = stopInterval
        self.continuousActivityTime = continuousActivityTime
        self.requireHighConfidence = requireHighConfidence
        self.recentActivityLog = recentActivityLog
        self.perActivityContinuousTime = perActivityContinuousTime
        self.enableDelayedHypoWindow = enableDelayedHypoWindow
        self.delayedHypoDuration = delayedHypoDuration
        self.delayedHypoPresets = delayedHypoPresets
        self.delayedHypoPresetDuration = delayedHypoPresetDuration
        self.useHeartRateSignal = useHeartRateSignal
        self.heartRateThresholdBpm = heartRateThresholdBpm
        self.enableHealthKitWorkouts = enableHealthKitWorkouts
        self.caffeineOverrideEnabled = caffeineOverrideEnabled
        self.caffeineOverridePresetID = caffeineOverridePresetID
        self.caffeineOverrideDuration = caffeineOverrideDuration
        self.caffeineOverrideThresholdMg = caffeineOverrideThresholdMg
        self.alcoholOverrideEnabled = alcoholOverrideEnabled
        self.alcoholOverridePresetID = alcoholOverridePresetID
        self.alcoholOverrideDelay = alcoholOverrideDelay
        self.alcoholOverrideDuration = alcoholOverrideDuration
        self.alcoholOverrideThresholdUnits = alcoholOverrideThresholdUnits
    }

    // Custom decoder so older persisted settings (without the new fields)
    // still load with sensible defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        supportedActivityTypes = try c.decodeIfPresent(Set<AutoPresetsActivityType>.self, forKey: .supportedActivityTypes) ?? [.walking]
        activityPresets = try c.decodeIfPresent([String: String].self, forKey: .activityPresets) ?? [:]
        stopInterval = try c.decodeIfPresent(TimeInterval.self, forKey: .stopInterval) ?? 300
        continuousActivityTime = try c.decodeIfPresent(TimeInterval.self, forKey: .continuousActivityTime) ?? 30
        requireHighConfidence = try c.decodeIfPresent(Bool.self, forKey: .requireHighConfidence) ?? false
        recentActivityLog = try c.decodeIfPresent([AutoPresetsLogEntry].self, forKey: .recentActivityLog) ?? []
        perActivityContinuousTime = try c.decodeIfPresent([String: TimeInterval].self, forKey: .perActivityContinuousTime) ?? [:]
        enableDelayedHypoWindow = try c.decodeIfPresent(Bool.self, forKey: .enableDelayedHypoWindow) ?? false
        delayedHypoDuration = try c.decodeIfPresent(TimeInterval.self, forKey: .delayedHypoDuration) ?? (90 * 60)
        delayedHypoPresets = try c.decodeIfPresent([String: String].self, forKey: .delayedHypoPresets) ?? [:]
        delayedHypoPresetDuration = try c.decodeIfPresent(TimeInterval.self, forKey: .delayedHypoPresetDuration) ?? (60 * 60)
        useHeartRateSignal = try c.decodeIfPresent(Bool.self, forKey: .useHeartRateSignal) ?? false
        heartRateThresholdBpm = try c.decodeIfPresent(Double.self, forKey: .heartRateThresholdBpm) ?? 120
        enableHealthKitWorkouts = try c.decodeIfPresent(Bool.self, forKey: .enableHealthKitWorkouts) ?? false
        caffeineOverrideEnabled = try c.decodeIfPresent(Bool.self, forKey: .caffeineOverrideEnabled) ?? false
        caffeineOverridePresetID = try c.decodeIfPresent(String.self, forKey: .caffeineOverridePresetID)
        caffeineOverrideDuration = try c.decodeIfPresent(TimeInterval.self, forKey: .caffeineOverrideDuration) ?? (3 * 3600)
        caffeineOverrideThresholdMg = try c.decodeIfPresent(Double.self, forKey: .caffeineOverrideThresholdMg) ?? 100
        alcoholOverrideEnabled = try c.decodeIfPresent(Bool.self, forKey: .alcoholOverrideEnabled) ?? false
        alcoholOverridePresetID = try c.decodeIfPresent(String.self, forKey: .alcoholOverridePresetID)
        alcoholOverrideDelay = try c.decodeIfPresent(TimeInterval.self, forKey: .alcoholOverrideDelay) ?? (90 * 60)
        alcoholOverrideDuration = try c.decodeIfPresent(TimeInterval.self, forKey: .alcoholOverrideDuration) ?? (6 * 3600)
        alcoholOverrideThresholdUnits = try c.decodeIfPresent(Double.self, forKey: .alcoholOverrideThresholdUnits) ?? 1.0
    }

    func presetId(for activity: AutoPresetsActivityType) -> String? {
        activityPresets[activity.rawValue]
    }

    mutating func setPresetId(_ presetId: String?, for activity: AutoPresetsActivityType) {
        if let presetId, !presetId.isEmpty {
            activityPresets[activity.rawValue] = presetId
        } else {
            activityPresets.removeValue(forKey: activity.rawValue)
        }
    }

    func continuousTime(for activity: AutoPresetsActivityType) -> TimeInterval {
        if let perActivity = perActivityContinuousTime[activity.rawValue], perActivity > 0 {
            return perActivity
        }
        // Fall back to the per-activity default rather than the global so cycling
        // never gets the 30-second walking threshold by mistake.
        return activity.defaultContinuousTime
    }

    mutating func setContinuousTime(_ seconds: TimeInterval?, for activity: AutoPresetsActivityType) {
        if let seconds, seconds > 0 {
            perActivityContinuousTime[activity.rawValue] = seconds
        } else {
            perActivityContinuousTime.removeValue(forKey: activity.rawValue)
        }
    }

    func delayedHypoPresetId(for activity: AutoPresetsActivityType) -> String? {
        delayedHypoPresets[activity.rawValue]
    }

    mutating func setDelayedHypoPresetId(_ presetId: String?, for activity: AutoPresetsActivityType) {
        if let presetId, !presetId.isEmpty {
            delayedHypoPresets[activity.rawValue] = presetId
        } else {
            delayedHypoPresets.removeValue(forKey: activity.rawValue)
        }
    }

    var hasConfiguredPresets: Bool {
        supportedActivityTypes.contains { activityPresets[$0.rawValue] != nil }
    }
}

// MARK: - Errors

enum AutoPresetsDetectionError: Error, Equatable {
    case motionNotAvailable
    case permissionDenied
    case configurationError(String)

    var localizedDescription: String {
        switch self {
        case .motionNotAvailable:
            return String(localized: "Motion detection is not available on this device")
        case .permissionDenied:
            return String(localized: "Motion & Fitness permission is required for AutoPresets")
        case .configurationError(let message):
            return String(localized: "Configuration error: \(message)")
        }
    }
}
