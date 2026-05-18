//
//  AutoPresetsCoordinator.swift
//  Trio
//
//  AutoPresets MVP — orchestrates motion detection → activate/deactivate Trio override preset.
//  Singleton; settings UI mutates via `updateSettings`. Persists in UserDefaults via AutoPresetsStorage.
//
//  Activation flow (mirrors Trio's Adjustments.StateModel.enactOverridePreset):
//    1. Lookup OverrideStored by id (UUID string from settings.activityPresets[activity])
//    2. Disable all currently-active overrides; create OverrideRunStored entry
//    3. Mark target override enabled=true, date=now, isUploadedToNS=false
//    4. Save context
//
//  Safety: refuses activation when a non-AutoPresets override is already active
//  (any active OverrideStored whose objectID URI we did not record).
//

import CoreData
import Foundation
import os.log

final class AutoPresetsCoordinator: ObservableObject, @unchecked Sendable {

    static let shared = AutoPresetsCoordinator()

    // MARK: - Published

    @Published private(set) var isMonitoring: Bool = false
    @Published private(set) var currentDetectedActivity: AutoPresetsActivityType?
    @Published private(set) var lastError: AutoPresetsDetectionError?

    // MARK: - Internals

    private let log = OSLog(subsystem: "Trio.AutoPresets", category: "Coordinator")
    private let storage = AutoPresetsStorage()
    private let detection = AutoPresetsActivityDetectionManager()

    /// URI string of OverrideStored.objectID that AutoPresets activated (so we can avoid
    /// deactivating something the user enabled by hand).
    private var activatedOverrideURI: String? {
        get { UserDefaults.standard.string(forKey: "AutoPresets_activatedOverrideURI") }
        set { UserDefaults.standard.set(newValue, forKey: "AutoPresets_activatedOverrideURI") }
    }

    private var pendingRestart: DispatchWorkItem?

    // MARK: - Public read-only

    var settings: AutoPresetsSettings { storage.settings }

    var isEnabled: Bool {
        get { storage.settings.isEnabled }
        set {
            guard newValue != storage.settings.isEnabled else { return }
            objectWillChange.send()
            storage.updateSettings { $0.isEnabled = newValue }
            storage.addLogEntry(event: newValue ? .featureEnabled : .featureDisabled)
            if newValue {
                startIfConfigured()
            } else {
                stop()
            }
        }
    }

    // MARK: - Init

    private init() {
        detection.delegate = self
    }

    // MARK: - Settings mutators

    func updateSettings(_ mutate: (inout AutoPresetsSettings) -> Void) {
        objectWillChange.send()
        storage.updateSettings(mutate)
        applySettingsToDetection()

        pendingRestart?.cancel()
        if isMonitoring {
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.stop()
                self.startIfConfigured()
            }
            pendingRestart = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
        }
    }

    func setPresetID(_ presetID: String?, for activity: AutoPresetsActivityType) {
        updateSettings { $0.setPresetId(presetID, for: activity) }
    }

    func clearActivityLog() {
        objectWillChange.send()
        storage.clearActivityLog()
    }

    // MARK: - Start / Stop

    func startIfConfigured() {
        guard !isMonitoring else { return }
        guard settings.isEnabled else { return }
        guard settings.hasConfiguredPresets else { return }

        applySettingsToDetection()
        detection.startMonitoring()
        isMonitoring = true
    }

    func stop() {
        detection.stopMonitoring()
        isMonitoring = false
        currentDetectedActivity = nil
    }

    func clearError() { lastError = nil }

    // MARK: - Internals

    private func applySettingsToDetection() {
        let s = settings
        detection.supportedActivities = s.supportedActivityTypes
        detection.activityStopInterval = s.stopInterval
        detection.continuousActivityTime = s.continuousActivityTime
        detection.requireHighConfidence = s.requireHighConfidence
    }

    // MARK: - Override activation (CoreData)

    private func activatePreset(for activity: AutoPresetsActivityType) {
        guard let presetIDString = settings.presetId(for: activity) else {
            os_log("No preset configured for %{public}@", log: log, type: .error, activity.displayName)
            return
        }

        Task { [weak self] in
            guard let self else { return }
            let context = CoreDataStack.shared.newTaskContext()
            await context.perform {
                let request: NSFetchRequest<OverrideStored> = OverrideStored.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@ AND isPreset == YES", presetIDString)
                request.fetchLimit = 1

                guard let preset = try? context.fetch(request).first else {
                    os_log("OverrideStored preset id=%{public}@ not found", log: self.log, type: .error, presetIDString)
                    return
                }

                // Refuse if a non-AutoPresets override is currently active
                let activeRequest: NSFetchRequest<OverrideStored> = OverrideStored.fetchRequest()
                activeRequest.predicate = NSPredicate(format: "enabled == YES")
                activeRequest.fetchLimit = 5
                let active = (try? context.fetch(activeRequest)) ?? []
                let ourURI = self.activatedOverrideURI
                let foreignActive = active.contains { $0.objectID.uriRepresentation().absoluteString != ourURI }
                if !active.isEmpty && foreignActive {
                    os_log("Foreign override active; AutoPresets skipping activation", log: self.log, type: .info)
                    return
                }

                // Disable all currently-active overrides and create a run entry per cancelled override
                for o in active {
                    let run = OverrideRunStored(context: context)
                    run.id = UUID()
                    run.name = o.name
                    run.startDate = o.date ?? .distantPast
                    run.endDate = Date()
                    run.target = NSDecimalNumber(value: o.target?.doubleValue ?? 0)
                    run.override = o
                    run.isUploadedToNS = false
                    o.enabled = false
                }

                preset.enabled = true
                preset.date = Date()
                preset.isUploadedToNS = false

                do {
                    if context.hasChanges {
                        try context.save()
                    }
                    self.activatedOverrideURI = preset.objectID.uriRepresentation().absoluteString
                    self.storage.addLogEntry(event: .presetActivated, activityType: activity, presetName: preset.name)
                    os_log("AutoPresets activated preset %{public}@ for %{public}@",
                           log: self.log, type: .info, preset.name ?? "?", activity.displayName)
                } catch {
                    os_log("AutoPresets save failed: %{public}@",
                           log: self.log, type: .error, error.localizedDescription)
                }
            }
        }
    }

    private func deactivatePreset(for activity: AutoPresetsActivityType) {
        guard let ourURIString = activatedOverrideURI,
              let url = URL(string: ourURIString),
              let objectID = CoreDataStack.shared.persistentContainer.persistentStoreCoordinator
                  .managedObjectID(forURIRepresentation: url)
        else {
            // Nothing tagged — likely user already cancelled or app restarted; just clear flag.
            activatedOverrideURI = nil
            return
        }

        Task { [weak self] in
            guard let self else { return }
            let context = CoreDataStack.shared.newTaskContext()
            await context.perform {
                guard let preset = try? context.existingObject(with: objectID) as? OverrideStored else {
                    self.activatedOverrideURI = nil
                    return
                }

                // Only deactivate if still enabled by us
                guard preset.enabled else {
                    self.activatedOverrideURI = nil
                    return
                }

                let run = OverrideRunStored(context: context)
                run.id = UUID()
                run.name = preset.name
                run.startDate = preset.date ?? .distantPast
                run.endDate = Date()
                run.target = NSDecimalNumber(value: preset.target?.doubleValue ?? 0)
                run.override = preset
                run.isUploadedToNS = false

                preset.enabled = false

                do {
                    if context.hasChanges {
                        try context.save()
                    }
                    self.storage.addLogEntry(event: .presetDeactivated, activityType: activity, presetName: preset.name)
                    self.activatedOverrideURI = nil
                    os_log("AutoPresets deactivated preset %{public}@ for %{public}@",
                           log: self.log, type: .info, preset.name ?? "?", activity.displayName)
                } catch {
                    os_log("AutoPresets deactivate save failed: %{public}@",
                           log: self.log, type: .error, error.localizedDescription)
                }
            }
        }
    }
}

// MARK: - Detection delegate

extension AutoPresetsCoordinator: AutoPresetsActivityDetectionDelegate {
    func activityDetectionDidConfirm(_ activity: AutoPresetsActivityType) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.currentDetectedActivity = activity
            self.activatePreset(for: activity)
        }
    }

    func activityDetectionDidStop(_ activity: AutoPresetsActivityType) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.currentDetectedActivity = nil
            self.deactivatePreset(for: activity)
        }
    }

    func activityDetectionDidEncounterError(_ error: AutoPresetsDetectionError) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lastError = error
            if case .permissionDenied = error {
                self.storage.addLogEntry(event: .permissionDenied)
            }
            os_log("Detection error: %{public}@", log: self.log, type: .error, error.localizedDescription)
        }
    }
}
