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
    private let healthKit = AutoPresetsHealthKitService.shared

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
        healthKit.delegate = self
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

    // MARK: - Chat prompt context

    /// Build a chat prompt section describing recent AutoPresets activations.
    /// Helps the AI link sport/exercise moments to glucose patterns. Always
    /// emits a header so the AI knows this data source exists.
    func buildAutoPresetsPromptContext(at now: Date = Date(), lookbackHours: Double = 48) -> String {
        let cutoff = now.addingTimeInterval(-lookbackHours * 3600)
        let windowLabel = lookbackHours >= 48
            ? String(format: "last %.0f days", lookbackHours / 24)
            : String(format: "last %.0f hours", lookbackHours)
        let recent = settings.recentActivityLog
            .filter { $0.date >= cutoff }
            .sorted { $0.date > $1.date }

        var ctx = "## AutoPresets Activity Log\n"
        ctx += "- Feature: \(settings.isEnabled ? "enabled" : "disabled"); tracked activities: "
        if settings.supportedActivityTypes.isEmpty {
            ctx += "none configured"
        } else {
            ctx += settings.supportedActivityTypes
                .sorted { $0.rawValue < $1.rawValue }
                .map(\.displayName)
                .joined(separator: ", ")
        }
        ctx += "\n"

        guard !recent.isEmpty else {
            ctx += "- No activations in the \(windowLabel).\n"
            return ctx
        }

        let formatter = DateFormatter()
        formatter.dateStyle = lookbackHours > 48 ? .short : .none
        formatter.timeStyle = .short
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "EEE"

        // Pair activations with their corresponding deactivations to give the
        // AI an idea of activity duration, which matters for delayed-hypo risk.
        let activations = recent.filter { $0.event == .presetActivated }
        let deactivations = recent.filter { $0.event == .presetDeactivated }

        ctx += "- Recent activations (\(activations.count) in the \(windowLabel)):\n"
        for entry in activations.prefix(10) {
            let when = "\(dayFormatter.string(from: entry.date)) \(formatter.string(from: entry.date))"
            let activity = entry.activityType?.displayName ?? "Unknown"
            let preset = entry.presetName ?? "—"
            // Find a deactivation after this activation for the same activity
            let endpoint = deactivations.first {
                $0.activityType == entry.activityType && $0.date > entry.date
            }
            if let endpoint {
                let durationMin = Int(endpoint.date.timeIntervalSince(entry.date) / 60)
                ctx += "  • \(when) — \(activity) (preset: \(preset)), lasted ~\(durationMin) min\n"
            } else {
                ctx += "  • \(when) — \(activity) (preset: \(preset))\n"
            }
        }

        // Tracker-driven auto-override status — helps the AI know whether to
        // recommend enabling these features when patterns suggest they'd help.
        ctx += "- Caffeine auto-override: "
        if settings.caffeineOverrideEnabled {
            ctx += String(
                format: "enabled (threshold %.0f mg, duration %.0fh)\n",
                settings.caffeineOverrideThresholdMg,
                settings.caffeineOverrideDuration / 3600
            )
        } else {
            ctx += "disabled (configurable in Settings → Features → AutoPresets)\n"
        }
        ctx += "- Alcohol auto-override: "
        if settings.alcoholOverrideEnabled {
            ctx += String(
                format: "enabled (threshold %.1f drinks, delay %.0fmin, duration %.0fh)\n",
                settings.alcoholOverrideThresholdUnits,
                settings.alcoholOverrideDelay / 60,
                settings.alcoholOverrideDuration / 3600
            )
        } else {
            ctx += "disabled (configurable in Settings → Features → AutoPresets)\n"
        }
        // Also include the most-recent tracker-driven activations so the AI
        // can correlate them with glucose excursions in the period.
        let trackerEvents = recent.filter {
            $0.event == .caffeineOverrideActivated
                || $0.event == .alcoholOverrideActivated
                || $0.event == .alcoholOverrideScheduled
        }
        if !trackerEvents.isEmpty {
            ctx += "- Tracker-driven overrides in the \(windowLabel):\n"
            for entry in trackerEvents.prefix(8) {
                let when = "\(dayFormatter.string(from: entry.date)) \(formatter.string(from: entry.date))"
                ctx += "  • \(when) — \(entry.event.displayName) (preset: \(entry.presetName ?? "—"))\n"
            }
        }
        return ctx
    }

    // MARK: - Start / Stop

    func startIfConfigured() {
        guard !isMonitoring else { return }
        guard settings.isEnabled else { return }
        guard settings.hasConfiguredPresets else { return }

        applySettingsToDetection()
        detection.startMonitoring()
        applyHealthKitSettings()
        isMonitoring = true
    }

    func stop() {
        detection.stopMonitoring()
        healthKit.stopWorkoutObservation()
        healthKit.stopHeartRateObservation()
        cancelDelayedHypoSchedule()
        isMonitoring = false
        currentDetectedActivity = nil
    }

    private func applyHealthKitSettings() {
        if settings.enableHealthKitWorkouts {
            Task {
                try? await healthKit.requestAuthorization()
                await MainActor.run { self.healthKit.startWorkoutObservation() }
            }
        } else {
            healthKit.stopWorkoutObservation()
        }

        if settings.useHeartRateSignal {
            Task {
                try? await healthKit.requestAuthorization()
                await MainActor.run {
                    self.healthKit.startHeartRateObservation(threshold: self.settings.heartRateThresholdBpm)
                }
            }
        } else {
            healthKit.stopHeartRateObservation()
        }
    }

    func clearError() { lastError = nil }

    // MARK: - Internals

    private func applySettingsToDetection() {
        let s = settings
        detection.supportedActivities = s.supportedActivityTypes
        detection.activityStopInterval = s.stopInterval
        detection.continuousActivityTime = s.continuousActivityTime
        detection.requireHighConfidence = s.requireHighConfidence
        detection.perActivityContinuousTime = s.perActivityContinuousTime
    }

    // MARK: - Delayed-hypo window

    /// Schedule a softer override to fire `delayedHypoDuration` after an
    /// aerobic activity stops, compensating for glycogen-replenishment
    /// hypoglycemia risk (per the diabetotech blog).
    private var delayedHypoActivateTimer: Timer?
    private var delayedHypoDeactivateTimer: Timer?
    private var delayedHypoURI: String? {
        get { UserDefaults.standard.string(forKey: "AutoPresets_delayedHypoURI") }
        set { UserDefaults.standard.set(newValue, forKey: "AutoPresets_delayedHypoURI") }
    }

    private func scheduleDelayedHypoWindow(after activity: AutoPresetsActivityType) {
        guard settings.enableDelayedHypoWindow,
              let presetID = settings.delayedHypoPresetId(for: activity),
              !presetID.isEmpty,
              activity.primaryEffect == .aerobic
        else { return }

        delayedHypoActivateTimer?.invalidate()
        let delay = settings.delayedHypoDuration
        let presetDuration = settings.delayedHypoPresetDuration
        storage.addLogEntry(event: .delayedHypoScheduled, activityType: activity, presetName: nil)
        os_log("Scheduled delayed-hypo window in %.0fs for %{public}@",
               log: log, type: .info, delay, activity.displayName)

        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.activateDelayedHypoPreset(presetID: presetID, activity: activity, autoDeactivateAfter: presetDuration)
        }
        delayedHypoActivateTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func activateDelayedHypoPreset(
        presetID: String,
        activity: AutoPresetsActivityType,
        autoDeactivateAfter: TimeInterval
    ) {
        Task { [weak self] in
            guard let self else { return }
            let context = CoreDataStack.shared.newTaskContext()
            await context.perform {
                let request: NSFetchRequest<OverrideStored> = OverrideStored.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@ AND isPreset == YES", presetID)
                request.fetchLimit = 1
                guard let preset = try? context.fetch(request).first else {
                    os_log("Delayed-hypo preset id=%{public}@ not found", log: self.log, type: .error, presetID)
                    return
                }

                // Skip if any non-AutoPresets override is already active
                let activeRequest: NSFetchRequest<OverrideStored> = OverrideStored.fetchRequest()
                activeRequest.predicate = NSPredicate(format: "enabled == YES")
                let active = (try? context.fetch(activeRequest)) ?? []
                let ourURIs = [self.activatedOverrideURI, self.delayedHypoURI].compactMap { $0 }
                let foreignActive = active.contains { !ourURIs.contains($0.objectID.uriRepresentation().absoluteString) }
                guard !foreignActive else {
                    os_log("Skipping delayed-hypo: foreign override active", log: self.log, type: .info)
                    return
                }

                preset.enabled = true
                preset.date = Date()
                preset.isUploadedToNS = false

                do {
                    if context.hasChanges { try context.save() }
                    self.delayedHypoURI = preset.objectID.uriRepresentation().absoluteString
                    self.storage.addLogEntry(event: .delayedHypoActivated, activityType: activity, presetName: preset.name)
                    os_log("Delayed-hypo preset %{public}@ activated for %{public}@",
                           log: self.log, type: .info, preset.name ?? "?", activity.displayName)
                } catch {
                    os_log("Delayed-hypo activation failed: %{public}@",
                           log: self.log, type: .error, error.localizedDescription)
                    return
                }
            }

            // Schedule auto-deactivation on the main thread.
            await MainActor.run {
                let timer = Timer(timeInterval: autoDeactivateAfter, repeats: false) { [weak self] _ in
                    self?.deactivateDelayedHypoPreset(activity: activity)
                }
                self.delayedHypoDeactivateTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        }
    }

    private func deactivateDelayedHypoPreset(activity: AutoPresetsActivityType) {
        delayedHypoDeactivateTimer?.invalidate()
        delayedHypoDeactivateTimer = nil
        guard let uriString = delayedHypoURI,
              let url = URL(string: uriString),
              let objectID = CoreDataStack.shared.persistentContainer.persistentStoreCoordinator
                  .managedObjectID(forURIRepresentation: url)
        else {
            delayedHypoURI = nil
            return
        }

        Task { [weak self] in
            guard let self else { return }
            let context = CoreDataStack.shared.newTaskContext()
            await context.perform {
                guard let preset = try? context.existingObject(with: objectID) as? OverrideStored, preset.enabled else {
                    self.delayedHypoURI = nil
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
                    if context.hasChanges { try context.save() }
                    self.delayedHypoURI = nil
                    self.storage.addLogEntry(event: .delayedHypoExpired, activityType: activity, presetName: preset.name)
                } catch {
                    os_log("Delayed-hypo deactivation failed: %{public}@",
                           log: self.log, type: .error, error.localizedDescription)
                }
            }
        }
    }

    private func cancelDelayedHypoSchedule() {
        delayedHypoActivateTimer?.invalidate()
        delayedHypoActivateTimer = nil
    }

    // MARK: - Caffeine auto-override
    //
    // Activated immediately when a caffeine entry above the threshold is logged
    // — the literature (Shi 2017 meta-analysis; Whitehead 2013 systematic
    // review) shows insulin-sensitivity reduction in the 2-4h post-ingestion
    // window, with a ~14-37% drop in T2D and ~15% in healthy subjects, so a
    // 3h ON-window with a slightly-more-aggressive preset is a reasonable
    // first-cut compensation.

    private var caffeineActivateTimer: Timer?
    private var caffeineDeactivateTimer: Timer?
    private var caffeineURI: String? {
        get { UserDefaults.standard.string(forKey: "AutoPresets_caffeineURI") }
        set { UserDefaults.standard.set(newValue, forKey: "AutoPresets_caffeineURI") }
    }

    /// Called by `AIInsights_CaffeineTracker` after a new entry is logged.
    /// First-time: activates the configured preset and schedules a deactivate
    /// timer. Re-logged while already active: extends the active window from
    /// "now" by `caffeineOverrideDuration` so the override doesn't expire
    /// early — fixes the prior bug where the original deactivate timer cut
    /// a refreshed window short.
    func scheduleCaffeineOverride(mg: Double, at timestamp: Date = Date()) {
        guard settings.caffeineOverrideEnabled,
              let presetID = settings.caffeineOverridePresetID,
              !presetID.isEmpty,
              mg >= settings.caffeineOverrideThresholdMg
        else { return }

        let duration = settings.caffeineOverrideDuration

        // Fast path: we already have a live caffeine override. Extend the
        // deactivate timer instead of re-running the full activation. This
        // keeps the preset on continuously without a CoreData round-trip.
        if isOurOverrideStillActive(uri: caffeineURI) {
            refreshDeactivateTimer(
                for: \.caffeineDeactivateTimer,
                duration: duration,
                deactivate: { [weak self] in self?.deactivateCaffeineOverride() }
            )
            storage.addLogEntry(event: .caffeineOverrideRefreshed, activityType: nil, presetName: nil)
            os_log("Caffeine override extended for another %.0fs (mg=%.0f)",
                   log: log, type: .info, duration, mg)
            return
        }

        // Either first activation, or our URI is stale (preset disabled
        // externally). Clear stale URI before reactivating fresh.
        if caffeineURI != nil { caffeineURI = nil }
        activateTrackerPreset(
            presetID: presetID,
            uriKeyPath: \.caffeineURI,
            activateEvent: .caffeineOverrideActivated,
            duration: duration
        ) { [weak self] in
            self?.deactivateCaffeineOverride()
        }
    }

    private func deactivateCaffeineOverride() {
        caffeineDeactivateTimer?.invalidate()
        caffeineDeactivateTimer = nil
        deactivateTrackerPreset(
            uri: caffeineURI,
            event: .caffeineOverrideExpired
        ) { [weak self] in self?.caffeineURI = nil }
    }

    // MARK: - Alcohol auto-override
    //
    // Scheduled with a delay (default 90 min) because alcohol hypoglycemia
    // is delayed — Turner 2001 (ADA Diabetes Care) shows post-breakfast
    // hypo's the morning after evening drinking, Richardson 2005 documents
    // a 24h risk window. The mechanism is impaired gluconeogenesis (48g
    // alcohol ≈ 45% drop in hepatic glucose production), so the preset
    // should reduce insulin and raise target.

    private var alcoholActivateTimer: Timer?
    private var alcoholDeactivateTimer: Timer?
    private var alcoholURI: String? {
        get { UserDefaults.standard.string(forKey: "AutoPresets_alcoholURI") }
        set { UserDefaults.standard.set(newValue, forKey: "AutoPresets_alcoholURI") }
    }

    /// Called by `AIInsights_AlcoholTracker` after a new drink is logged.
    /// Three code paths:
    ///   1. Override already running → extend deactivate timer, no new delay.
    ///   2. Activation already scheduled but not yet fired → reset the delay
    ///      timer from the new drink time (latest drink defines onset).
    ///   3. Otherwise → schedule fresh with `alcoholOverrideDelay`.
    func scheduleAlcoholOverride(units: Double, at timestamp: Date = Date()) {
        guard settings.alcoholOverrideEnabled,
              let presetID = settings.alcoholOverridePresetID,
              !presetID.isEmpty,
              units >= settings.alcoholOverrideThresholdUnits
        else { return }

        let duration = settings.alcoholOverrideDuration

        // Case 1: override already running. Extend deactivate timer only.
        if isOurOverrideStillActive(uri: alcoholURI) {
            refreshDeactivateTimer(
                for: \.alcoholDeactivateTimer,
                duration: duration,
                deactivate: { [weak self] in self?.deactivateAlcoholOverride() }
            )
            storage.addLogEntry(event: .alcoholOverrideRefreshed, activityType: nil, presetName: nil)
            os_log("Alcohol override extended for another %.0fs (units=%.1f)",
                   log: log, type: .info, duration, units)
            return
        }

        // Cases 2 & 3: not running yet — (re)schedule with delay.
        if alcoholURI != nil { alcoholURI = nil }
        alcoholActivateTimer?.invalidate()
        alcoholDeactivateTimer?.invalidate()

        let delay = settings.alcoholOverrideDelay
        storage.addLogEntry(event: .alcoholOverrideScheduled, activityType: nil, presetName: nil)
        os_log("Scheduled alcohol override in %.0fs (units=%.1f, presetID=%{public}@)",
               log: log, type: .info, delay, units, presetID)

        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.activateTrackerPreset(
                presetID: presetID,
                uriKeyPath: \.alcoholURI,
                activateEvent: .alcoholOverrideActivated,
                duration: duration
            ) { [weak self] in
                self?.deactivateAlcoholOverride()
            }
        }
        alcoholActivateTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func deactivateAlcoholOverride() {
        alcoholDeactivateTimer?.invalidate()
        alcoholDeactivateTimer = nil
        deactivateTrackerPreset(
            uri: alcoholURI,
            event: .alcoholOverrideExpired
        ) { [weak self] in self?.alcoholURI = nil }
    }

    // MARK: - Refresh helpers

    /// True when the stored URI still points to an enabled `OverrideStored`
    /// preset. False when the URI is nil, points to a deleted/disabled
    /// object, or the preset has been turned off (e.g. user toggled another
    /// preset in the UI, which disables ours).
    private func isOurOverrideStillActive(uri uriString: String?) -> Bool {
        guard let uriString,
              let url = URL(string: uriString),
              let objectID = CoreDataStack.shared.persistentContainer
                  .persistentStoreCoordinator.managedObjectID(forURIRepresentation: url)
        else { return false }
        let ctx = CoreDataStack.shared.persistentContainer.viewContext
        guard let preset = try? ctx.existingObject(with: objectID) as? OverrideStored else {
            return false
        }
        return preset.enabled
    }

    /// Cancel the existing deactivate timer and schedule a fresh one
    /// `duration` seconds from now. Used when the same tracker (caffeine or
    /// alcohol) fires again while its override is still live — the prior
    /// timer would otherwise expire on its original deadline and cut the
    /// refreshed window short.
    private func refreshDeactivateTimer(
        for keyPath: ReferenceWritableKeyPath<AutoPresetsCoordinator, Timer?>,
        duration: TimeInterval,
        deactivate: @escaping () -> Void
    ) {
        self[keyPath: keyPath]?.invalidate()
        let timer = Timer(timeInterval: duration, repeats: false) { _ in deactivate() }
        self[keyPath: keyPath] = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: - Generic tracker-preset activation
    //
    // Used by both caffeine and alcohol code paths above. Same shape as the
    // delayed-hypo activator but parameterized so the two trackers can share
    // the CoreData plumbing.

    private func activateTrackerPreset(
        presetID: String,
        uriKeyPath: ReferenceWritableKeyPath<AutoPresetsCoordinator, String?>,
        activateEvent: AutoPresetsLogEvent,
        duration: TimeInterval,
        scheduleDeactivate: @escaping () -> Void
    ) {
        Task { [weak self] in
            guard let self else { return }
            let context = CoreDataStack.shared.newTaskContext()
            await context.perform {
                let request: NSFetchRequest<OverrideStored> = OverrideStored.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@ AND isPreset == YES", presetID)
                request.fetchLimit = 1
                guard let preset = try? context.fetch(request).first else {
                    os_log("Tracker preset id=%{public}@ not found", log: self.log, type: .error, presetID)
                    return
                }

                // Skip if a non-AutoPresets override is already active so we
                // never overwrite a user-initiated override.
                let activeRequest: NSFetchRequest<OverrideStored> = OverrideStored.fetchRequest()
                activeRequest.predicate = NSPredicate(format: "enabled == YES")
                let active = (try? context.fetch(activeRequest)) ?? []
                let ourURIs: [String] = [
                    self.activatedOverrideURI,
                    self.delayedHypoURI,
                    self.caffeineURI,
                    self.alcoholURI
                ].compactMap { $0 }
                let foreignActive = active.contains {
                    !ourURIs.contains($0.objectID.uriRepresentation().absoluteString)
                }
                guard !foreignActive else {
                    os_log("Skipping tracker preset: foreign override active",
                           log: self.log, type: .info)
                    return
                }

                preset.enabled = true
                preset.date = Date()
                preset.isUploadedToNS = false

                do {
                    if context.hasChanges { try context.save() }
                    self[keyPath: uriKeyPath] = preset.objectID.uriRepresentation().absoluteString
                    self.storage.addLogEntry(event: activateEvent, activityType: nil, presetName: preset.name)
                    os_log("Tracker preset %{public}@ activated (event=%{public}@)",
                           log: self.log, type: .info, preset.name ?? "?", activateEvent.rawValue)
                } catch {
                    os_log("Tracker preset activation failed: %{public}@",
                           log: self.log, type: .error, error.localizedDescription)
                    return
                }
            }

            await MainActor.run {
                // Invalidate any prior deactivate timer for this category so a
                // refreshed window doesn't get cut short by the old deadline.
                if activateEvent == .caffeineOverrideActivated {
                    self.caffeineDeactivateTimer?.invalidate()
                } else if activateEvent == .alcoholOverrideActivated {
                    self.alcoholDeactivateTimer?.invalidate()
                }

                let timer = Timer(timeInterval: duration, repeats: false) { _ in
                    scheduleDeactivate()
                }
                if activateEvent == .caffeineOverrideActivated {
                    self.caffeineDeactivateTimer = timer
                } else if activateEvent == .alcoholOverrideActivated {
                    self.alcoholDeactivateTimer = timer
                }
                RunLoop.main.add(timer, forMode: .common)
            }
        }
    }

    private func deactivateTrackerPreset(
        uri uriString: String?,
        event: AutoPresetsLogEvent,
        clearURI: @escaping () -> Void
    ) {
        guard let uriString,
              let url = URL(string: uriString),
              let objectID = CoreDataStack.shared.persistentContainer.persistentStoreCoordinator
                  .managedObjectID(forURIRepresentation: url)
        else {
            clearURI()
            return
        }

        Task { [weak self] in
            guard let self else { return }
            let context = CoreDataStack.shared.newTaskContext()
            await context.perform {
                guard let preset = try? context.existingObject(with: objectID) as? OverrideStored,
                      preset.enabled
                else {
                    clearURI()
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
                    if context.hasChanges { try context.save() }
                    clearURI()
                    self.storage.addLogEntry(event: event, activityType: nil, presetName: preset.name)
                } catch {
                    os_log("Tracker preset deactivation failed: %{public}@",
                           log: self.log, type: .error, error.localizedDescription)
                }
            }
        }
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
            // Cancel any pending delayed-hypo schedule from a previous bout —
            // we're active again, so the late-hypo clock resets on the next stop.
            self.cancelDelayedHypoSchedule()
            self.activatePreset(for: activity)
        }
    }

    func activityDetectionDidStop(_ activity: AutoPresetsActivityType) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.currentDetectedActivity = nil
            self.deactivatePreset(for: activity)
            // Schedule the post-activity delayed-hypo override (aerobic only).
            self.scheduleDelayedHypoWindow(after: activity)
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

// MARK: - HealthKit delegate

extension AutoPresetsCoordinator: AutoPresetsHealthKitDelegate {
    func healthKitWorkoutDidStart(_ activity: AutoPresetsActivityType, workoutEndDate: Date) {
        guard settings.isEnabled,
              settings.enableHealthKitWorkouts,
              settings.supportedActivityTypes.contains(activity)
        else { return }

        // If we already have an active preset for this activity, skip.
        if currentDetectedActivity == activity { return }

        currentDetectedActivity = activity
        cancelDelayedHypoSchedule()
        activatePreset(for: activity)

        // HealthKit workouts arrive AFTER the activity ended, so schedule the
        // delayed-hypo window starting now (the user is past the workout already).
        scheduleDelayedHypoWindow(after: activity)
    }

    func healthKitElevatedHeartRateDetected(bpm: Double, at date: Date) {
        // Only refine when HR-signal is on AND strength training is a supported
        // activity. We use elevated HR with no recent step changes as a hint
        // that the user is doing anaerobic effort (per the diabetotech blog).
        guard settings.useHeartRateSignal,
              settings.supportedActivityTypes.contains(.strengthTraining),
              currentDetectedActivity != .strengthTraining
        else { return }

        os_log("Elevated HR detected (%.0f bpm); checking for strength activation",
               log: log, type: .info, bpm)

        // Trigger only when no other activity is currently active (avoid
        // overriding a confirmed walking/running preset).
        if currentDetectedActivity == nil {
            currentDetectedActivity = .strengthTraining
            cancelDelayedHypoSchedule()
            activatePreset(for: .strengthTraining)
        }
    }
}
