//
//  AutoPresetsActivityDetectionManager.swift
//  Trio
//
//  CoreMotion-based activity detection (CMPedometer + CMMotionActivityManager).
//  Ported from Loop PowerPack AutoPresets_ActivityDetectionManager (Taylor Patterson / Claude Code).
//  File-based debug log dropped; uses os_log only.
//

import CoreMotion
import Foundation
import os.log

protocol AutoPresetsActivityDetectionDelegate: AnyObject {
    func activityDetectionDidConfirm(_ activity: AutoPresetsActivityType)
    func activityDetectionDidStop(_ activity: AutoPresetsActivityType)
    func activityDetectionDidEncounterError(_ error: AutoPresetsDetectionError)
}

final class AutoPresetsActivityDetectionManager {

    // MARK: - Constants

    private let stepThreshold = 20

    // MARK: - Properties

    private let log = OSLog(subsystem: "Trio.AutoPresets", category: "ActivityDetection")
    private let stateQueue = DispatchQueue(label: "Trio.AutoPresets.ActivityDetection.state", qos: .utility)

    weak var delegate: AutoPresetsActivityDetectionDelegate?

    private let pedometer = CMPedometer()
    private let motionActivityManager = CMMotionActivityManager()

    private var _isMonitoring = false
    private var _currentActivity: AutoPresetsActivityType?
    private var _detectedActivityType: AutoPresetsActivityType?
    private var _stepThresholdReachedTime: Date?
    private var _pedometerStartTime: Date?
    private var _totalSteps: Int = 0
    private var _lastStepChangeTime: Date?
    private var _lastClassifierTime: Date?
    private var _pedometerGeneration: UInt64 = 0

    private var isMonitoring: Bool {
        get { stateQueue.sync { _isMonitoring } }
        set { stateQueue.sync { _isMonitoring = newValue } }
    }

    private var currentActivity: AutoPresetsActivityType? {
        get { stateQueue.sync { _currentActivity } }
        set { stateQueue.sync { _currentActivity = newValue } }
    }

    // MARK: - Configuration

    var supportedActivities: Set<AutoPresetsActivityType> = [.walking]
    var activityStopInterval: TimeInterval = 300
    var continuousActivityTime: TimeInterval = 30
    var requireHighConfidence: Bool = false

    private var _continuousActivityTimer: Timer?
    private var _activityStopTimer: Timer?

    // MARK: - Lifecycle

    deinit {
        stopMonitoring()
        cleanupTimers()
    }

    // MARK: - Public

    func startMonitoring() {
        guard !isMonitoring else { return }

        guard CMPedometer.isStepCountingAvailable(), CMMotionActivityManager.isActivityAvailable() else {
            os_log("Motion detection not available", log: log, type: .error)
            delegate?.activityDetectionDidEncounterError(.motionNotAvailable)
            return
        }

        switch CMMotionActivityManager.authorizationStatus() {
        case .notDetermined, .authorized:
            break
        case .denied, .restricted:
            os_log("Motion & Fitness permission denied or restricted", log: log, type: .error)
            delegate?.activityDetectionDidEncounterError(.permissionDenied)
            return
        @unknown default:
            delegate?.activityDetectionDidEncounterError(.permissionDenied)
            return
        }

        isMonitoring = true
        startPedometerUpdates()
        startMotionActivityUpdates()
    }

    func stopMonitoring() {
        guard isMonitoring else { return }

        isMonitoring = false
        pedometer.stopUpdates()
        motionActivityManager.stopActivityUpdates()
        cleanupTimers()

        if let activity = currentActivity {
            currentActivity = nil
            delegate?.activityDetectionDidStop(activity)
        }

        stateQueue.sync {
            _detectedActivityType = nil
            _stepThresholdReachedTime = nil
            _pedometerStartTime = nil
            _totalSteps = 0
            _lastStepChangeTime = nil
            _lastClassifierTime = nil
        }
    }

    // MARK: - Pedometer (Phase 1)

    private func startPedometerUpdates() {
        let startDate = Date()
        let generation = stateQueue.sync { () -> UInt64 in
            _pedometerGeneration += 1
            _pedometerStartTime = startDate
            _totalSteps = 0
            _stepThresholdReachedTime = nil
            _lastStepChangeTime = nil
            return _pedometerGeneration
        }

        pedometer.startUpdates(from: startDate) { [weak self] data, error in
            guard let self, self.isMonitoring else { return }
            let currentGen = self.stateQueue.sync { self._pedometerGeneration }
            guard generation == currentGen else { return }
            if let error {
                os_log("Pedometer error: %{public}@", log: self.log, type: .error, error.localizedDescription)
                return
            }
            guard let data else { return }
            let steps = data.numberOfSteps.intValue
            DispatchQueue.main.async { [weak self] in
                self?.processPedometerUpdate(totalSteps: steps)
            }
        }
    }

    private func processPedometerUpdate(totalSteps: Int) {
        let (shouldStartTimer, alreadyConfirmed, stepsChanged) = stateQueue.sync { () -> (Bool, Bool, Bool) in
            let previous = _totalSteps
            _totalSteps = totalSteps
            let changed = totalSteps != previous
            if changed {
                _lastStepChangeTime = Date()
            }
            guard _currentActivity == nil else {
                return (false, true, changed)
            }
            if totalSteps >= stepThreshold && _stepThresholdReachedTime == nil {
                _stepThresholdReachedTime = Date()
                return (true, false, changed)
            }
            return (false, false, changed)
        }

        if alreadyConfirmed {
            if stepsChanged {
                startActivityStopTimer()
            }
            return
        }

        if shouldStartTimer {
            let activityType = stateQueue.sync { _detectedActivityType } ?? .walking
            startContinuousActivityTimer(for: activityType)
        }
    }

    // MARK: - Classifier

    private func startMotionActivityUpdates() {
        let queue = OperationQueue()
        queue.name = "AutoPresetsActivityClassifierQueue"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 1

        motionActivityManager.startActivityUpdates(to: queue) { [weak self] activity in
            guard let self, self.isMonitoring, let activity else { return }
            guard Date().timeIntervalSince(activity.startDate) < 300 else { return }

            let acceptable: Bool
            if self.requireHighConfidence {
                acceptable = activity.confidence == .high
            } else {
                acceptable = activity.confidence == .high || activity.confidence == .medium
            }
            guard acceptable else { return }

            var type: AutoPresetsActivityType?
            if self.supportedActivities.contains(.walking), activity.walking,
               !activity.automotive, !activity.cycling
            {
                type = .walking
            } else if self.supportedActivities.contains(.running), activity.running,
                      !activity.automotive, !activity.cycling
            {
                type = .running
            }

            if let type {
                self.stateQueue.sync {
                    self._detectedActivityType = type
                    self._lastClassifierTime = Date()
                }
            } else {
                let shouldStop = activity.confidence != .low && (activity.automotive || activity.cycling)
                if shouldStop {
                    DispatchQueue.main.async { [weak self] in
                        self?.handleNonTargetActivity()
                    }
                }
            }
        }
    }

    private func handleNonTargetActivity() {
        let shouldStart = stateQueue.sync { () -> Bool in
            _currentActivity != nil && _activityStopTimer == nil
        }
        if shouldStart { startActivityStopTimer() }
    }

    // MARK: - Continuous Activity Timer (Phase 2)

    private func startContinuousActivityTimer(for activity: AutoPresetsActivityType) {
        stateQueue.sync {
            _continuousActivityTimer?.invalidate()
            _continuousActivityTimer = nil
        }

        let stepsAtThreshold = stateQueue.sync { _totalSteps }
        let timerInterval = continuousActivityTime
        let timerStartTime = Date()

        let newTimer = Timer(timeInterval: timerInterval, repeats: false) { [weak self] timer in
            guard let self else { timer.invalidate(); return }

            let elapsed = Date().timeIntervalSince(timerStartTime)
            guard self.isMonitoring else { timer.invalidate(); return }

            let (currentSteps, _, lastStepTime, classifierType, classifierTime) = self.stateQueue.sync {
                () -> (Int, Date?, Date?, AutoPresetsActivityType?, Date?) in
                (
                    self._totalSteps,
                    self._stepThresholdReachedTime,
                    self._lastStepChangeTime,
                    self._detectedActivityType,
                    self._lastClassifierTime
                )
            }

            let additionalSteps = currentSteps >= stepsAtThreshold
                ? currentSteps - stepsAtThreshold
                : currentSteps

            let minAdditionalSteps = max(15, Int(elapsed / 60.0 * 30.0))

            let stepRecencyLimit: TimeInterval = 60
            let now = Date()
            let stepIsRecent: Bool
            if let lastStep = lastStepTime {
                stepIsRecent = now.timeIntervalSince(lastStep) <= stepRecencyLimit
            } else {
                stepIsRecent = false
            }

            let classifierConfirmed: Bool
            if self.requireHighConfidence {
                if let cTime = classifierType.flatMap({ _ in classifierTime }) {
                    classifierConfirmed = now.timeIntervalSince(cTime) <= 60
                } else {
                    classifierConfirmed = false
                }
            } else {
                classifierConfirmed = true
            }

            let pedometerSufficient = stepIsRecent && additionalSteps >= minAdditionalSteps
            let classifierBoost = stepIsRecent && classifierConfirmed && additionalSteps >= 15

            if pedometerSufficient || classifierBoost {
                let activityType = classifierType ?? activity
                self.stateQueue.sync {
                    self._currentActivity = activityType
                    self._continuousActivityTimer = nil
                }
                os_log(
                    "%{public}@ confirmed after %.1fs - %d steps (+%d)",
                    log: self.log,
                    type: .info,
                    activityType.displayName,
                    elapsed,
                    currentSteps,
                    additionalSteps
                )
                self.delegate?.activityDetectionDidConfirm(activityType)
                self.startActivityStopTimer()
            } else {
                self.stateQueue.sync {
                    self._stepThresholdReachedTime = nil
                    self._continuousActivityTimer = nil
                }
                self.resetPedometer()
            }

            timer.invalidate()
        }

        stateQueue.sync { _continuousActivityTimer = newTimer }
        RunLoop.main.add(newTimer, forMode: .common)
    }

    // MARK: - Stop Timer (Phase 3)

    private func startActivityStopTimer() {
        stateQueue.sync {
            _activityStopTimer?.invalidate()
            _activityStopTimer = nil
        }

        let newTimer = Timer(timeInterval: activityStopInterval, repeats: false) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard self.isMonitoring else { timer.invalidate(); return }

            let activityToStop = self.stateQueue.sync { () -> AutoPresetsActivityType? in
                let activity = self._currentActivity
                self._currentActivity = nil
                self._stepThresholdReachedTime = nil
                self._activityStopTimer = nil
                return activity
            }

            if let activity = activityToStop {
                self.delegate?.activityDetectionDidStop(activity)
            }
            self.resetPedometer()
            timer.invalidate()
        }

        stateQueue.sync { _activityStopTimer = newTimer }
        RunLoop.main.add(newTimer, forMode: .common)
    }

    // MARK: - Helpers

    private func cleanupTimers() {
        stateQueue.sync {
            _continuousActivityTimer?.invalidate()
            _continuousActivityTimer = nil
            _activityStopTimer?.invalidate()
            _activityStopTimer = nil
        }
    }

    private func resetPedometer() {
        pedometer.stopUpdates()
        stateQueue.sync {
            _totalSteps = 0
            _stepThresholdReachedTime = nil
            _pedometerStartTime = nil
            _lastStepChangeTime = nil
        }
        if isMonitoring {
            startPedometerUpdates()
        }
    }
}
