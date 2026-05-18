//
//  AutoPresetsSettingsView.swift
//  Trio
//
//  AutoPresets settings UI: master toggle, per-activity preset selection,
//  timing knobs, recent activity log.
//

import CoreData
import SwiftUI

struct AutoPresetsSettingsView: View {
    @ObservedObject var coordinator: AutoPresetsCoordinator = .shared

    @State private var presets: [PresetRow] = []
    @State private var showingClearLogConfirm = false
    @State private var refreshTrigger = UUID()

    var body: some View {
        Form {
            // MARK: - Master toggle
            Section(
                header: Text(String(localized: "AutoPresets")),
                footer: Text(String(localized: "Trio activates a Trio override preset automatically when sustained walking or running is detected. Disable to stop motion monitoring."))
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

            // MARK: - Per-activity preset
            Section(
                header: Text(String(localized: "Preset Per Activity")),
                footer: Text(String(localized: "Pick the Trio override preset to activate for each tracked activity. Create presets first under Adjustments → Overrides."))
            ) {
                ForEach(AutoPresetsActivityType.allCases, id: \.self) { activity in
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
                    }
                }
            }

            // MARK: - Timing
            Section(
                header: Text(String(localized: "Timing")),
                footer: Text(String(localized: "Continuous Activity Time = how long sustained motion must continue after the step threshold before the preset activates. Stop Delay = how long Trio waits after motion stops before deactivating."))
            ) {
                Picker(
                    String(localized: "Continuous Activity Time"),
                    selection: continuousActivityTimeBinding
                ) {
                    Text(String(localized: "30 s")).tag(TimeInterval(30))
                    Text(String(localized: "1 min")).tag(TimeInterval(60))
                    Text(String(localized: "2 min")).tag(TimeInterval(120))
                    Text(String(localized: "5 min")).tag(TimeInterval(300))
                    Text(String(localized: "10 min")).tag(TimeInterval(600))
                }

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

            // MARK: - Recent log
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
        .id(refreshTrigger)
        .navigationTitle(String(localized: "AutoPresets"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadPresets()
        }
        .onReceive(coordinator.objectWillChange) { _ in
            refreshTrigger = UUID()
        }
    }

    // MARK: - Bindings

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { coordinator.isEnabled },
            set: { coordinator.isEnabled = $0 }
        )
    }

    private var continuousActivityTimeBinding: Binding<TimeInterval> {
        Binding(
            get: { coordinator.settings.continuousActivityTime },
            set: { newVal in coordinator.updateSettings { $0.continuousActivityTime = newVal } }
        )
    }

    private var stopIntervalBinding: Binding<TimeInterval> {
        Binding(
            get: { coordinator.settings.stopInterval },
            set: { newVal in coordinator.updateSettings { $0.stopInterval = newVal } }
        )
    }

    private func presetBinding(for activity: AutoPresetsActivityType) -> Binding<String?> {
        Binding(
            get: { coordinator.settings.presetId(for: activity) },
            set: { newID in coordinator.setPresetID(newID, for: activity) }
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
