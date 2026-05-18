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

    var displayName: String {
        switch self {
        case .walking: return String(localized: "Walking")
        case .running: return String(localized: "Running")
        }
    }

    var systemImageName: String {
        switch self {
        case .walking: return "figure.walk"
        case .running: return "figure.run"
        }
    }
}

// MARK: - Log Event

enum AutoPresetsLogEvent: String, Codable {
    case featureEnabled
    case featureDisabled
    case presetActivated
    case presetDeactivated
    case permissionDenied

    var iconName: String {
        switch self {
        case .featureEnabled: return "power.circle.fill"
        case .featureDisabled: return "power.circle"
        case .presetActivated: return "play.circle.fill"
        case .presetDeactivated: return "stop.circle.fill"
        case .permissionDenied: return "exclamationmark.triangle.fill"
        }
    }

    var displayName: String {
        switch self {
        case .featureEnabled: return String(localized: "Feature Enabled")
        case .featureDisabled: return String(localized: "Feature Disabled")
        case .presetActivated: return String(localized: "Preset Activated")
        case .presetDeactivated: return String(localized: "Preset Deactivated")
        case .permissionDenied: return String(localized: "Permission Denied")
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

    init(
        isEnabled: Bool = false,
        supportedActivityTypes: Set<AutoPresetsActivityType> = [.walking],
        activityPresets: [String: String] = [:],
        stopInterval: TimeInterval = 300,
        continuousActivityTime: TimeInterval = 30,
        requireHighConfidence: Bool = false,
        recentActivityLog: [AutoPresetsLogEntry] = []
    ) {
        self.isEnabled = isEnabled
        self.supportedActivityTypes = supportedActivityTypes
        self.activityPresets = activityPresets
        self.stopInterval = stopInterval
        self.continuousActivityTime = continuousActivityTime
        self.requireHighConfidence = requireHighConfidence
        self.recentActivityLog = recentActivityLog
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
