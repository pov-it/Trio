//
//  AutoPresetsStorage.swift
//  Trio
//
//  UserDefaults-backed JSON store for AutoPresets settings.
//

import Foundation

final class AutoPresetsStorage {
    private static let key = "AutoPresets_settings"
    private static let maxLogEntries = 20

    private(set) var settings: AutoPresetsSettings

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(AutoPresetsSettings.self, from: data)
        {
            settings = decoded
        } else {
            settings = AutoPresetsSettings()
        }
    }

    func updateSettings(_ mutate: (inout AutoPresetsSettings) -> Void) {
        var copy = settings
        mutate(&copy)
        settings = copy
        persist()
    }

    func addLogEntry(event: AutoPresetsLogEvent, activityType: AutoPresetsActivityType? = nil, presetName: String? = nil) {
        let entry = AutoPresetsLogEntry(event: event, activityType: activityType, presetName: presetName)
        updateSettings { s in
            s.recentActivityLog.insert(entry, at: 0)
            if s.recentActivityLog.count > Self.maxLogEntries {
                s.recentActivityLog = Array(s.recentActivityLog.prefix(Self.maxLogEntries))
            }
        }
    }

    func clearActivityLog() {
        updateSettings { $0.recentActivityLog = [] }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
