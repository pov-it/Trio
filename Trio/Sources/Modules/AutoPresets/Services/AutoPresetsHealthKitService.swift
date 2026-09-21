//
//  AutoPresetsHealthKitService.swift
//  Trio
//
//  Bridges HealthKit workout samples and heart-rate data into AutoPresets.
//
//  Workouts:
//    - HKObserverQuery + HKAnchoredObjectQuery listen for new HKWorkout samples.
//      When one is saved (typically by Apple Watch right after the workout ends,
//      or by Fitness app for indoor activities), we look at its activity type
//      and, if it maps to one of swimming/strength/yoga AND the workout's start
//      date is within the last 30 minutes, fire `onWorkoutStarted` so the
//      coordinator can activate the appropriate preset.
//    - This is RETROACTIVE on iPhone-only; truly real-time would need a watch
//      companion app. Still useful because Watch users get the sample within
//      seconds of finishing.
//
//  Heart rate:
//    - When the HR signal is enabled, HKObserverQuery fires on each new HR
//      sample. If HR exceeds the threshold with low recent step rate, we
//      assume strength/anaerobic effort and call `onElevatedHeartRate`.
//
//  Permissions: only HKObjectType read access is requested. The standard
//  Info.plist HealthKit usage description applies.
//

import Foundation
import HealthKit
import os.log

protocol AutoPresetsHealthKitDelegate: AnyObject {
    /// Called when a HealthKit workout sample is observed whose activity type
    /// maps to one of the AutoPresets HealthKit-driven types AND falls in the
    /// "recent" window.
    func healthKitWorkoutDidStart(_ activity: AutoPresetsActivityType, workoutEndDate: Date)
    /// Called when an elevated HR sample is observed while the HR signal is on.
    func healthKitElevatedHeartRateDetected(bpm: Double, at date: Date)
}

final class AutoPresetsHealthKitService {

    static let shared = AutoPresetsHealthKitService()

    weak var delegate: AutoPresetsHealthKitDelegate?

    private let log = OSLog(subsystem: "Trio.AutoPresets", category: "HealthKit")
    private let store = HKHealthStore()

    private var workoutObserver: HKObserverQuery?
    private var workoutAnchor: HKQueryAnchor?

    private var heartRateObserver: HKObserverQuery?
    private var heartRateAnchor: HKQueryAnchor?

    private(set) var workoutObservingEnabled = false
    private(set) var heartRateObservingEnabled = false

    /// Tracks the last activity we triggered to avoid duplicate triggers when
    /// HealthKit re-delivers the same sample (e.g. after an app relaunch).
    private var lastWorkoutTriggerUUIDs: Set<UUID> = []
    /// Throttle elevated-HR delegate calls to once per minute.
    private var lastElevatedHeartRateTrigger: Date?

    var heartRateThresholdBpm: Double = 120

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    // MARK: - Permissions

    func requestAuthorization() async throws {
        guard isAvailable else { return }
        var types: Set<HKObjectType> = [HKObjectType.workoutType()]
        if let hr = HKObjectType.quantityType(forIdentifier: .heartRate) {
            types.insert(hr)
        }
        try await store.requestAuthorization(toShare: [], read: types)
    }

    // MARK: - Workout observation

    func startWorkoutObservation() {
        guard isAvailable, !workoutObservingEnabled else { return }
        workoutObservingEnabled = true

        let workoutType = HKObjectType.workoutType()
        let observer = HKObserverQuery(sampleType: workoutType, predicate: nil) { [weak self] _, completion, error in
            defer { completion() }
            if let error {
                os_log("Workout observer error: %{public}@", log: self?.log ?? .default, type: .error, error.localizedDescription)
                return
            }
            self?.queryRecentWorkouts()
        }
        store.execute(observer)
        workoutObserver = observer

        // Background delivery so the OS wakes us when a workout is saved.
        store.enableBackgroundDelivery(for: workoutType, frequency: .immediate) { [weak self] success, error in
            if let error {
                os_log("Background delivery (workouts) failed: %{public}@",
                       log: self?.log ?? .default, type: .error, error.localizedDescription)
            } else if success {
                os_log("Background delivery (workouts) enabled", log: self?.log ?? .default, type: .info)
            }
        }

        // Catch up on anything saved while we weren't observing.
        queryRecentWorkouts()
    }

    func stopWorkoutObservation() {
        guard workoutObservingEnabled else { return }
        workoutObservingEnabled = false
        if let observer = workoutObserver {
            store.stop(observer)
            workoutObserver = nil
        }
        store.disableBackgroundDelivery(for: HKObjectType.workoutType()) { _, _ in }
    }

    private func queryRecentWorkouts() {
        let workoutType = HKObjectType.workoutType()
        // Look back 30 minutes — workouts saved by Apple Watch typically land
        // within seconds. Anything older we treat as historical and ignore for
        // AutoPresets activation.
        let cutoff = Date().addingTimeInterval(-30 * 60)
        let predicate = HKQuery.predicateForSamples(withStart: cutoff, end: nil, options: .strictStartDate)

        let query = HKAnchoredObjectQuery(
            type: workoutType,
            predicate: predicate,
            anchor: workoutAnchor,
            limit: HKObjectQueryNoLimit
        ) { [weak self] _, samples, _, newAnchor, error in
            if let error {
                os_log("Workout anchor query error: %{public}@",
                       log: self?.log ?? .default, type: .error, error.localizedDescription)
                return
            }
            self?.workoutAnchor = newAnchor
            self?.processWorkoutSamples(samples)
        }
        store.execute(query)
    }

    private func processWorkoutSamples(_ samples: [HKSample]?) {
        guard let workouts = samples as? [HKWorkout], !workouts.isEmpty else { return }
        for workout in workouts where !lastWorkoutTriggerUUIDs.contains(workout.uuid) {
            guard let activity = mapHealthKitActivity(workout.workoutActivityType) else { continue }
            lastWorkoutTriggerUUIDs.insert(workout.uuid)
            // Keep the set bounded.
            if lastWorkoutTriggerUUIDs.count > 100 {
                lastWorkoutTriggerUUIDs.removeFirst()
            }
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.healthKitWorkoutDidStart(activity, workoutEndDate: workout.endDate)
            }
        }
    }

    private func mapHealthKitActivity(_ type: HKWorkoutActivityType) -> AutoPresetsActivityType? {
        switch type {
        case .swimming, .swimBikeRun, .waterFitness, .waterSports:
            return .swimming
        case .traditionalStrengthTraining,
             .functionalStrengthTraining,
             .crossTraining,
             .highIntensityIntervalTraining:
            return .strengthTraining
        case .yoga, .mindAndBody, .pilates, .flexibility:
            return .yoga
        default:
            return nil
        }
    }

    // MARK: - Heart-rate observation

    func startHeartRateObservation(threshold: Double) {
        guard isAvailable, !heartRateObservingEnabled,
              let hrType = HKObjectType.quantityType(forIdentifier: .heartRate)
        else { return }
        heartRateThresholdBpm = threshold
        heartRateObservingEnabled = true

        let observer = HKObserverQuery(sampleType: hrType, predicate: nil) { [weak self] _, completion, error in
            defer { completion() }
            if let error {
                os_log("HR observer error: %{public}@",
                       log: self?.log ?? .default, type: .error, error.localizedDescription)
                return
            }
            self?.queryRecentHeartRate()
        }
        store.execute(observer)
        heartRateObserver = observer

        store.enableBackgroundDelivery(for: hrType, frequency: .immediate) { [weak self] _, error in
            if let error {
                os_log("Background delivery (HR) failed: %{public}@",
                       log: self?.log ?? .default, type: .error, error.localizedDescription)
            }
        }
    }

    func stopHeartRateObservation() {
        guard heartRateObservingEnabled else { return }
        heartRateObservingEnabled = false
        if let observer = heartRateObserver {
            store.stop(observer)
            heartRateObserver = nil
        }
        if let hrType = HKObjectType.quantityType(forIdentifier: .heartRate) {
            store.disableBackgroundDelivery(for: hrType) { _, _ in }
        }
    }

    private func queryRecentHeartRate() {
        guard let hrType = HKObjectType.quantityType(forIdentifier: .heartRate) else { return }
        let cutoff = Date().addingTimeInterval(-5 * 60)
        let predicate = HKQuery.predicateForSamples(withStart: cutoff, end: nil, options: .strictStartDate)
        let query = HKAnchoredObjectQuery(
            type: hrType,
            predicate: predicate,
            anchor: heartRateAnchor,
            limit: HKObjectQueryNoLimit
        ) { [weak self] _, samples, _, newAnchor, _ in
            self?.heartRateAnchor = newAnchor
            self?.processHeartRateSamples(samples)
        }
        store.execute(query)
    }

    private func processHeartRateSamples(_ samples: [HKSample]?) {
        guard let quantitySamples = samples as? [HKQuantitySample], !quantitySamples.isEmpty else { return }
        let bpmUnit = HKUnit.count().unitDivided(by: .minute())
        // Find the most recent sample above threshold.
        let elevated = quantitySamples
            .map { ($0.endDate, $0.quantity.doubleValue(for: bpmUnit)) }
            .filter { $0.1 >= heartRateThresholdBpm }
            .sorted { $0.0 > $1.0 }
            .first
        guard let (date, bpm) = elevated else { return }
        // Throttle to once per minute to avoid spamming the coordinator.
        if let last = lastElevatedHeartRateTrigger, date.timeIntervalSince(last) < 60 {
            return
        }
        lastElevatedHeartRateTrigger = date
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.healthKitElevatedHeartRateDetected(bpm: bpm, at: date)
        }
    }
}
