//
//  AIInsightsAlcoholLogView.swift
//  Trio
//
//  Alcohol logging UI mirroring caffeine tracker shape.
//

import HealthKit
import SwiftUI

private let alcoholAccent = Color(red: 0.8, green: 0.4, blue: 0.2)

struct AIInsightsAlcoholLogView: View {
    @ObservedObject var tracker: AIInsights_AlcoholTracker = .shared

    @State private var logTimestamp: Date = Date()
    @State private var customDrinks: String = ""
    @State private var customSource: String = ""
    @State private var showingCustomEntry = false
    @State private var editingEntry: AIInsightsAlcoholEntry?
    @State private var editDrinks: String = ""
    @State private var editSource: String = ""
    @State private var editTimestamp: Date = Date()
    @State private var showingClearConfirmation = false
    @State private var showGlucoseInfo = false
    @State private var healthKitAuthorized = false

    private var currentState: AIInsightsAlcoholState { tracker.currentState() }

    var body: some View {
        List {
            statusSection
            timestampSection
            quickAddSection
            if showingCustomEntry {
                customEntrySection
            }
            glucoseEffectSection
            healthKitSection
            recentEntriesSection
        }
        .navigationTitle(String(localized: "Alcohol Tracker", comment: "Alcohol tracker nav title"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingEntry) { entry in
            editEntrySheet(entry)
        }
        .task {
            await refreshHealthKit()
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(String(format: "%.1f", currentState.currentDrinks))
                        .font(.title.bold())
                        .foregroundColor(alcoholAccent)
                    Text(String(localized: "standard drinks in system", comment: "Alcohol current status"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if currentState.entriesLast24h > 0 {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(format: "%.1f", currentState.drinksLast24h))
                                .font(.caption.weight(.semibold))
                                .foregroundColor(alcoholAccent)
                            Text(String(localized: "24h total", comment: "Alcohol 24h total"))
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        if let lastTime = currentState.lastIntakeTime {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Self.timeFormatter.string(from: lastTime))
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(alcoholAccent)
                                Text(String(localized: "Last intake", comment: "Alcohol last intake"))
                                    .font(.caption2).foregroundColor(.secondary)
                            }
                        }
                    }
                }

                if currentState.lateHypoRiskActive {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                        Text(String(localized: "Late-hypo risk window active (next ~12h after last drink).", comment: "Alcohol late hypo warning"))
                            .font(.caption)
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.15))
                    .cornerRadius(8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Timestamp

    private var timestampSection: some View {
        Section(
            header: Text(String(localized: "Log Time", comment: "Alcohol log time section")),
            footer: Text(String(localized: "Time used when you tap a preset or add a custom entry. Resets to now after each log.", comment: "Alcohol log time footer"))
        ) {
            DatePicker(
                String(localized: "When", comment: "Alcohol entry timestamp label"),
                selection: $logTimestamp,
                in: ...Date(),
                displayedComponents: [.date, .hourAndMinute]
            )
            if abs(logTimestamp.timeIntervalSinceNow) > 60 {
                Button(action: { logTimestamp = Date() }) {
                    HStack {
                        Image(systemName: "arrow.uturn.backward.circle")
                        Text(String(localized: "Reset to Now", comment: "Reset alcohol log timestamp"))
                    }
                    .font(.caption)
                    .foregroundColor(alcoholAccent)
                }
            }
        }
    }

    // MARK: - Quick add

    private var quickAddSection: some View {
        Section(header: Text(String(localized: "Quick Add", comment: "Alcohol quick add section"))) {
            let presets = AIInsightsAlcoholPreset.defaults
            let columns = [GridItem(.flexible()), GridItem(.flexible())]

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(presets) { preset in
                    Button(action: {
                        tracker.logDrink(standardDrinks: preset.standardDrinks, source: preset.name, at: logTimestamp)
                        logTimestamp = Date()
                    }) {
                        HStack(spacing: 6) {
                            Text(preset.icon).font(.caption)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(preset.name)
                                    .font(.caption).fontWeight(.medium)
                                    .foregroundColor(.primary).lineLimit(1)
                                Text(String(format: "%.1f drinks", preset.standardDrinks))
                                    .font(.caption2).foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color(.secondarySystemGroupedBackground))
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))

            Button(action: { showingCustomEntry.toggle() }) {
                HStack {
                    Image(systemName: showingCustomEntry ? "minus.circle" : "plus.circle")
                    Text(String(localized: "Custom Entry", comment: "Toggle custom alcohol entry"))
                }
                .font(.subheadline)
                .foregroundColor(alcoholAccent)
            }
        }
    }

    // MARK: - Custom

    private var customEntrySection: some View {
        Section(header: Text(String(localized: "Custom Drink Entry", comment: "Custom alcohol entry section"))) {
            TextField(String(localized: "Standard drinks (e.g. 1.5)", comment: "Alcohol drinks field"), text: $customDrinks)
                .keyboardType(.decimalPad)
            TextField(String(localized: "Source (e.g. IPA)", comment: "Alcohol source field"), text: $customSource)

            Button(action: {
                if let drinks = Double(customDrinks.replacingOccurrences(of: ",", with: ".")), drinks > 0 {
                    let source = customSource.isEmpty ? String(localized: "Custom", comment: "Default custom source label") : customSource
                    tracker.logDrink(standardDrinks: drinks, source: source, at: logTimestamp)
                    customDrinks = ""
                    customSource = ""
                    showingCustomEntry = false
                    logTimestamp = Date()
                }
            }) {
                HStack {
                    Spacer()
                    Text(String(localized: "Add Entry", comment: "Add alcohol entry button"))
                        .fontWeight(.medium)
                    Spacer()
                }
                .foregroundColor(.white)
                .padding(.vertical, 8)
                .background((Double(customDrinks.replacingOccurrences(of: ",", with: ".")) ?? 0) > 0 ? alcoholAccent : Color.gray)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .disabled((Double(customDrinks.replacingOccurrences(of: ",", with: ".")) ?? 0) <= 0)
        }
    }

    // MARK: - Glucose effect

    private var glucoseEffectSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showGlucoseInfo) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "Alcohol blocks the liver's ability to release glucose (hepatic gluconeogenesis) for 4–12 hours. In Type 1 diabetes this dramatically raises the risk of hypoglycemia — especially overnight after evening drinking.", comment: "Alcohol glucose effect paragraph 1"))
                    Text(String(localized: "Beer and sweet cocktails carry carbs which can spike BG short-term, then drop low later. Spirits and dry wine carry little to no carbs but the late-hypo effect remains.", comment: "Alcohol glucose effect paragraph 2"))
                    Text(String(localized: "Practical impact: consider raising your overnight target, reducing basal, or eating slow carbs at bedtime when you've had 2+ drinks. The AI assistant flags this window automatically when you log drinks.", comment: "Alcohol glucose effect paragraph 3"))
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.vertical, 4)
            } label: {
                Label(
                    String(localized: "How alcohol affects your glucose", comment: "Alcohol glucose effect disclosure"),
                    systemImage: "drop.triangle"
                )
                .font(.subheadline)
            }
        }
    }

    // MARK: - HealthKit

    private var healthKitSection: some View {
        Section(
            header: Text(String(localized: "Apple Health", comment: "Apple Health section header")),
            footer: Text(String(localized: "Trio merges alcoholic beverages logged in Apple Health alongside your manual entries. Read-only.", comment: "Alcohol Apple Health footer"))
        ) {
            Button(action: {
                Task {
                    try? await AIInsightsAlcoholHealthKitBridge.shared.requestAuthorization()
                    await refreshHealthKit()
                }
            }) {
                HStack {
                    Image(systemName: "heart.text.square")
                        .foregroundColor(.red)
                    Text(String(localized: "Sync from Apple Health now", comment: "Alcohol HealthKit sync button"))
                    Spacer()
                    if healthKitAuthorized {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }
                }
            }
        }
    }

    @MainActor
    private func refreshHealthKit() async {
        let bridge = AIInsightsAlcoholHealthKitBridge.shared
        healthKitAuthorized = bridge.authorizationStatus() == .sharingAuthorized
        await tracker.syncFromHealthKit()
    }

    // MARK: - Recent

    private var recentEntriesSection: some View {
        Section(header: Text(String(localized: "Recent Entries", comment: "Alcohol recent entries section"))) {
            if tracker.entries.isEmpty {
                Text(String(localized: "No alcohol entries yet. Tap a preset above to log a drink.", comment: "Alcohol empty state"))
                    .font(.caption).foregroundColor(.secondary)
            } else {
                ForEach(tracker.entries.prefix(20)) { entry in
                    Button(action: {
                        guard !entry.isFromHealthKit else { return }
                        editDrinks = String(format: "%.1f", entry.standardDrinks)
                        editSource = entry.source
                        editTimestamp = entry.timestamp
                        editingEntry = entry
                    }) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(entry.source).font(.subheadline).foregroundColor(.primary)
                                    if entry.isFromHealthKit {
                                        Image(systemName: "heart.fill")
                                            .font(.caption2)
                                            .foregroundColor(.red)
                                    }
                                }
                                Text(Self.dateTimeFormatter.string(from: entry.timestamp))
                                    .font(.caption2).foregroundColor(.secondary)
                            }
                            Spacer()
                            Text(String(format: "%.1f", entry.standardDrinks))
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(alcoholAccent)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { indexSet in
                    let toDelete = indexSet.compactMap { idx -> AIInsightsAlcoholEntry? in
                        guard idx < tracker.entries.count else { return nil }
                        let entry = tracker.entries[idx]
                        return entry.isFromHealthKit ? nil : entry
                    }
                    for entry in toDelete { tracker.removeEntry(entry) }
                }

                Button(role: .destructive, action: { showingClearConfirmation = true }) {
                    HStack {
                        Spacer()
                        Text(String(localized: "Clear All Manual Entries", comment: "Clear all alcohol button"))
                        Spacer()
                    }
                }
                .alert(
                    String(localized: "Clear All Manual Entries?", comment: "Clear alcohol confirm title"),
                    isPresented: $showingClearConfirmation
                ) {
                    Button(String(localized: "Cancel", comment: "Cancel button"), role: .cancel) {}
                    Button(String(localized: "Clear All", comment: "Confirm clear all"), role: .destructive) {
                        tracker.clearAllManualEntries()
                    }
                } message: {
                    Text(String(localized: "This removes all manually logged drinks. Apple Health entries are not affected. This cannot be undone.", comment: "Clear alcohol confirm message"))
                }
            }
        }
    }

    // MARK: - Edit sheet

    private func editEntrySheet(_ entry: AIInsightsAlcoholEntry) -> some View {
        NavigationView {
            Form {
                Section(header: Text(String(localized: "Edit Entry", comment: "Edit alcohol entry section"))) {
                    TextField(String(localized: "Standard drinks", comment: "Alcohol drinks field"), text: $editDrinks)
                        .keyboardType(.decimalPad)
                    TextField(String(localized: "Source", comment: "Alcohol source field"), text: $editSource)
                    DatePicker(
                        String(localized: "Time", comment: "Alcohol time field"),
                        selection: $editTimestamp,
                        in: ...Date(),
                        displayedComponents: [.date, .hourAndMinute]
                    )
                }

                Section {
                    Button(action: {
                        if let drinks = Double(editDrinks.replacingOccurrences(of: ",", with: ".")), drinks > 0 {
                            tracker.updateEntry(
                                id: entry.id,
                                standardDrinks: drinks,
                                source: editSource.isEmpty ? String(localized: "Custom", comment: "Default custom source label") : editSource,
                                timestamp: editTimestamp
                            )
                            editingEntry = nil
                        }
                    }) {
                        HStack {
                            Spacer()
                            Text(String(localized: "Save Changes", comment: "Save alcohol edit"))
                                .fontWeight(.medium).foregroundColor(.white)
                            Spacer()
                        }
                        .padding(.vertical, 8)
                        .background((Double(editDrinks.replacingOccurrences(of: ",", with: ".")) ?? 0) > 0 ? alcoholAccent : Color.gray)
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .disabled((Double(editDrinks.replacingOccurrences(of: ",", with: ".")) ?? 0) <= 0)

                    Button(role: .destructive, action: {
                        tracker.removeEntry(entry)
                        editingEntry = nil
                    }) {
                        HStack {
                            Spacer()
                            Text(String(localized: "Delete Entry", comment: "Delete alcohol entry"))
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "Edit Drink", comment: "Edit alcohol nav title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(String(localized: "Cancel", comment: "Cancel button")) { editingEntry = nil }
                }
            }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
}
