//
//  AutoPresetsSettingsView.swift
//  Trio
//
//  AutoPresets settings UI. Sections follow the Trio Form/section visual style:
//    1. Master toggle
//    2. Activities (motion-driven walking/running/cycling)
//    3. HealthKit Workouts (swimming/strength/yoga via HKWorkout)
//    4. Detection Signals (HR refinement)
//    5. Post-Activity (delayed-hypo window)
//    6. Timing (stop delay)
//    7. Recent Activity log
//

import CoreData
import SwiftUI

struct AutoPresetsSettingsView: View {
    @ObservedObject var coordinator: AutoPresetsCoordinator = .shared

    @State private var presets: [PresetRow] = []
    @State private var showingClearLogConfirm = false

    var body: some View {
        Form {
            masterSection
            activitiesSection
            healthKitWorkoutsSection
            detectionSignalsSection
            postActivitySection
            timingSection
            recentActivitySection
        }
        .navigationTitle(String(localized: "AutoPresets"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadPresets()
        }
    }

    // MARK: - Section: Master toggle

    private var masterSection: some View {
        Section(
            header: Text(String(localized: "AutoPresets")),
            footer: Text(String(localized: "Trio activates a Trio override preset automatically when sustained walking, running, or cycling is detected. Disable to stop motion monitoring."))
        ) {
            Toggle(isOn: enabledBinding) {
                Label(String(localized: "Enable AutoPresets"), systemImage: "figure.walk.motion")
            }
            if let error = coordinator.lastError {
                Text(error.localizedDescription)
                    .font(.caption)
                    .foregroundColor(.red)
            }
            if let active = coordinator.currentDetectedActivity {
                HStack {
                    Image(systemName: active.systemImageName)
                        .foregroundColor(.green)
                    Text(String(localized: "Currently detected: \(active.displayName)"))
                        .font(.caption)
                }
            }
        }
    }

    // MARK: - Section: Activities (motion-driven)

    private var motionActivities: [AutoPresetsActivityType] {
        AutoPresetsActivityType.allCases.filter { !$0.isHealthKitDriven }
    }

    private var healthKitActivities: [AutoPresetsActivityType] {
        AutoPresetsActivityType.allCases.filter(\.isHealthKitDriven)
    }

    private var activitiesSection: some View {
        Section(
            header: Text(String(localized: "Activities")),
            footer: Text(String(localized: "Motion-detected activities. Configure a preset and an optional sustained-time threshold per activity. Cycling defaults to a higher threshold to filter out short commute rides."))
        ) {
            ForEach(motionActivities, id: \.self) { activity in
                activityRow(for: activity, isHealthKitDriven: false)
            }
        }
    }

    // MARK: - Section: HealthKit workouts

    @ViewBuilder
    private var healthKitWorkoutsSection: some View {
        Section(
            header: Text(String(localized: "HealthKit Workouts")),
            footer: Text(String(localized: "Trigger presets from Apple Watch / Health workouts (swimming, strength training, yoga). HealthKit workouts arrive after the activity ends — Trio uses that signal to start the post-activity delayed-hypo window."))
        ) {
            Toggle(isOn: enableHealthKitBinding) {
                Label(String(localized: "Use HealthKit Workouts"), systemImage: "heart.text.square")
            }

            if coordinator.settings.enableHealthKitWorkouts {
                ForEach(healthKitActivities, id: \.self) { activity in
                    activityRow(for: activity, isHealthKitDriven: true)
                }
            }
        }
    }

    // MARK: - Section: Detection signals

    private var detectionSignalsSection: some View {
        Section(
            header: Text(String(localized: "Detection Signals")),
            footer: Text(String(localized: "Use HealthKit heart rate as a second signal. Elevated HR with low step activity suggests anaerobic effort (strength training) — useful because CoreMotion can't see it on its own."))
        ) {
            Toggle(isOn: heartRateSignalBinding) {
                Label(String(localized: "Use Heart Rate Signal"), systemImage: "heart.fill")
            }

            if coordinator.settings.useHeartRateSignal {
                Picker(
                    String(localized: "Elevated HR Threshold"),
                    selection: heartRateThresholdBinding
                ) {
                    Text("100 bpm").tag(Double(100))
                    Text("110 bpm").tag(Double(110))
                    Text("120 bpm").tag(Double(120))
                    Text("130 bpm").tag(Double(130))
                    Text("140 bpm").tag(Double(140))
                }
            }

            Toggle(isOn: requireHighConfidenceBinding) {
                Label(String(localized: "Require High Motion Confidence"), systemImage: "checkmark.shield")
            }
        }
    }

    // MARK: - Section: Post-activity (delayed-hypo)

    private var postActivitySection: some View {
        Section(
            header: Text(String(localized: "Post-Activity")),
            footer: Text(String(localized: "After aerobic activity stops, glycogen replenishment can drive glucose down for several hours. Schedule a softer override automatically to compensate."))
        ) {
            Toggle(isOn: delayedHypoEnabledBinding) {
                Label(String(localized: "Delayed-Hypo Window"), systemImage: "clock.badge.exclamationmark")
            }

            if coordinator.settings.enableDelayedHypoWindow {
                Picker(
                    String(localized: "Window Starts After"),
                    selection: delayedHypoDelayBinding
                ) {
                    Text(String(localized: "30 min")).tag(TimeInterval(30 * 60))
                    Text(String(localized: "60 min")).tag(TimeInterval(60 * 60))
                    Text(String(localized: "90 min")).tag(TimeInterval(90 * 60))
                    Text(String(localized: "2 h")).tag(TimeInterval(120 * 60))
                }

                Picker(
                    String(localized: "Window Duration"),
                    selection: delayedHypoPresetDurationBinding
                ) {
                    Text(String(localized: "30 min")).tag(TimeInterval(30 * 60))
                    Text(String(localized: "60 min")).tag(TimeInterval(60 * 60))
                    Text(String(localized: "90 min")).tag(TimeInterval(90 * 60))
                    Text(String(localized: "2 h")).tag(TimeInterval(120 * 60))
                }

                // Per-activity delayed-hypo preset picker (aerobic activities only).
                ForEach(AutoPresetsActivityType.allCases.filter { $0.primaryEffect == .aerobic }, id: \.self) { activity in
                    Picker(
                        String(localized: "Late-hypo preset for \(activity.displayName)"),
                        selection: delayedHypoPresetBinding(for: activity)
                    ) {
                        Text(String(localized: "None")).tag(Optional<String>.none)
                        ForEach(presets) { row in
                            Text(row.name).tag(Optional<String>.some(row.id))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Section: Timing

    private var timingSection: some View {
        Section(
            header: Text(String(localized: "Timing")),
            footer: Text(String(localized: "Stop Delay = how long Trio waits after motion stops before deactivating the preset. Per-activity sustained-time thresholds are configured inline above."))
        ) {
            Picker(
                String(localized: "Stop Delay"),
                selection: stopIntervalBinding
            ) {
                Text(String(localized: "1 min")).tag(TimeInterval(60))
                Text(String(localized: "3 min")).tag(TimeInterval(180))
                Text(String(localized: "5 min")).tag(TimeInterval(300))
                Text(String(localized: "10 min")).tag(TimeInterval(600))
            }
        }
    }

    // MARK: - Section: Recent activity

    private var recentActivitySection: some View {
        Section(header: Text(String(localized: "Recent Activity"))) {
            if coordinator.settings.recentActivityLog.isEmpty {
                Text(String(localized: "No events yet. Activate AutoPresets and start walking to see entries here."))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(coordinator.settings.recentActivityLog.prefix(20)) { entry in
                    HStack(alignment: .top) {
                        Image(systemName: entry.event.iconName)
                            .foregroundColor(.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(entry.event.displayName).font(.subheadline)
                                if let activity = entry.activityType {
                                    Text(activity.displayName)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            if let preset = entry.presetName {
                                Text(preset).font(.caption).foregroundColor(.secondary)
                            }
                            Text(Self.dateFormatter.string(from: entry.date))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Button(role: .destructive) {
                    showingClearLogConfirm = true
                } label: {
                    Text(String(localized: "Clear Activity Log"))
                }
                .alert(
                    String(localized: "Clear Activity Log?"),
                    isPresented: $showingClearLogConfirm
                ) {
                    Button(String(localized: "Cancel"), role: .cancel) {}
                    Button(String(localized: "Clear"), role: .destructive) {
                        coordinator.clearActivityLog()
                    }
                }
            }
        }
    }

    // MARK: - Activity row

    @ViewBuilder
    private func activityRow(for activity: AutoPresetsActivityType, isHealthKitDriven: Bool) -> some View {
        let isOn = Binding<Bool>(
            get: { coordinator.settings.supportedActivityTypes.contains(activity) },
            set: { newVal in
                coordinator.updateSettings { s in
                    if newVal {
                        s.supportedActivityTypes.insert(activity)
                    } else {
                        s.supportedActivityTypes.remove(activity)
                    }
                }
            }
        )

        Toggle(isOn: isOn) {
            Label(activity.displayName, systemImage: activity.systemImageName)
        }

        if isOn.wrappedValue {
            Picker(
                String(localized: "Preset for \(activity.displayName)"),
                selection: presetBinding(for: activity)
            ) {
                Text(String(localized: "None")).tag(Optional<String>.none)
                ForEach(presets) { row in
                    Text(row.name).tag(Optional<String>.some(row.id))
                }
            }

            // Motion-driven activities get a per-activity sustained-time picker.
            // HealthKit-driven activities are triggered by HKWorkout completion,
            // so a "how long before triggering" threshold doesn't apply.
            if !isHealthKitDriven {
                Picker(
                    String(localized: "Sustained time for \(activity.displayName)"),
                    selection: continuousTimeBinding(for: activity)
                ) {
                    Text(String(localized: "30 s")).tag(TimeInterval(30))
                    Text(String(localized: "1 min")).tag(TimeInterval(60))
                    Text(String(localized: "2 min")).tag(TimeInterval(120))
                    Text(String(localized: "5 min")).tag(TimeInterval(300))
                    Text(String(localized: "10 min")).tag(TimeInterval(600))
                    Text(String(localized: "15 min")).tag(TimeInterval(900))
                    Text(String(localized: "20 min")).tag(TimeInterval(1_200))
                }
            }
        }
    }

    // MARK: - Bindings

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { coordinator.isEnabled },
            set: { coordinator.isEnabled = $0 }
        )
    }

    private var stopIntervalBinding: Binding<TimeInterval> {
        Binding(
            get: { coordinator.settings.stopInterval },
            set: { newVal in coordinator.updateSettings { $0.stopInterval = newVal } }
        )
    }

    private var enableHealthKitBinding: Binding<Bool> {
        Binding(
            get: { coordinator.settings.enableHealthKitWorkouts },
            set: { newVal in coordinator.updateSettings { $0.enableHealthKitWorkouts = newVal } }
        )
    }

    private var heartRateSignalBinding: Binding<Bool> {
        Binding(
            get: { coordinator.settings.useHeartRateSignal },
            set: { newVal in coordinator.updateSettings { $0.useHeartRateSignal = newVal } }
        )
    }

    private var heartRateThresholdBinding: Binding<Double> {
        Binding(
            get: { coordinator.settings.heartRateThresholdBpm },
            set: { newVal in coordinator.updateSettings { $0.heartRateThresholdBpm = newVal } }
        )
    }

    private var requireHighConfidenceBinding: Binding<Bool> {
        Binding(
            get: { coordinator.settings.requireHighConfidence },
            set: { newVal in coordinator.updateSettings { $0.requireHighConfidence = newVal } }
        )
    }

    private var delayedHypoEnabledBinding: Binding<Bool> {
        Binding(
            get: { coordinator.settings.enableDelayedHypoWindow },
            set: { newVal in coordinator.updateSettings { $0.enableDelayedHypoWindow = newVal } }
        )
    }

    private var delayedHypoDelayBinding: Binding<TimeInterval> {
        Binding(
            get: { coordinator.settings.delayedHypoDuration },
            set: { newVal in coordinator.updateSettings { $0.delayedHypoDuration = newVal } }
        )
    }

    private var delayedHypoPresetDurationBinding: Binding<TimeInterval> {
        Binding(
            get: { coordinator.settings.delayedHypoPresetDuration },
            set: { newVal in coordinator.updateSettings { $0.delayedHypoPresetDuration = newVal } }
        )
    }

    private func presetBinding(for activity: AutoPresetsActivityType) -> Binding<String?> {
        Binding(
            get: { coordinator.settings.presetId(for: activity) },
            set: { newID in coordinator.setPresetID(newID, for: activity) }
        )
    }

    private func continuousTimeBinding(for activity: AutoPresetsActivityType) -> Binding<TimeInterval> {
        Binding(
            get: { coordinator.settings.continuousTime(for: activity) },
            set: { newVal in
                coordinator.updateSettings { s in
                    s.setContinuousTime(newVal, for: activity)
                }
            }
        )
    }

    private func delayedHypoPresetBinding(for activity: AutoPresetsActivityType) -> Binding<String?> {
        Binding(
            get: { coordinator.settings.delayedHypoPresetId(for: activity) },
            set: { newID in
                coordinator.updateSettings { s in
                    s.setDelayedHypoPresetId(newID, for: activity)
                }
            }
        )
    }

    // MARK: - Preset loader

    private struct PresetRow: Identifiable, Hashable {
        let id: String
        let name: String
    }

    @MainActor
    private func loadPresets() async {
        let context = CoreDataStack.shared.persistentContainer.viewContext
        let request: NSFetchRequest<OverrideStored> = OverrideStored.fetchRequest()
        request.predicate = NSPredicate(format: "isPreset == YES")
        request.sortDescriptors = [NSSortDescriptor(key: "orderPosition", ascending: true)]

        let results = (try? context.fetch(request)) ?? []
        presets = results.compactMap { o in
            guard let id = o.id, let name = o.name else { return nil }
            return PresetRow(id: id, name: name)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
}
