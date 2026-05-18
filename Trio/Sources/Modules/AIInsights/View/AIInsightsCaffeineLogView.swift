//
//  AIInsightsCaffeineLogView.swift
//  Trio
//
//  Caffeine logging UI: current-level gauge, time picker, quick-add presets,
//  custom entry, recent entries, glucose-effect info, HealthKit sync.
//

import HealthKit
import SwiftUI

private let caffeineGreen = Color.green

private enum AIInsightsCaffeineInfoTip: String, Identifiable {
    case estimatedLevel, totalLast24h, todaysPeak, lastIntake

    var id: String { rawValue }

    var title: String {
        switch self {
        case .estimatedLevel: return String(localized: "Estimated Caffeine Level", comment: "Caffeine info tip title")
        case .totalLast24h: return String(localized: "24h Total", comment: "Caffeine info tip title")
        case .todaysPeak: return String(localized: "Today's Peak", comment: "Caffeine info tip title")
        case .lastIntake: return String(localized: "Last Intake", comment: "Caffeine info tip title")
        }
    }

    var message: String {
        switch self {
        case .estimatedLevel:
            return String(
                localized: "Estimated milligrams of caffeine currently in your system. Caffeine has a half-life of about 5.7 hours: half of what you drink is gone in roughly 6 hours.",
                comment: "Caffeine info tip body"
            )
        case .totalLast24h:
            return String(
                localized: "Total milligrams of caffeine consumed in the last 24 hours from all sources. The FDA considers 400 mg/day safe for most adults.",
                comment: "Caffeine info tip body"
            )
        case .todaysPeak:
            return String(
                localized: "Highest caffeine level your body reached today. High peaks amplify effects on blood sugar, heart rate, and sleep.",
                comment: "Caffeine info tip body"
            )
        case .lastIntake:
            return String(
                localized: "When you last consumed caffeine. Caffeine within 6 hours of bedtime can disrupt sleep and affect overnight glucose.",
                comment: "Caffeine info tip body"
            )
        }
    }
}

struct AIInsightsCaffeineLogView: View {
    @ObservedObject var tracker: AIInsights_CaffeineTracker = .shared

    @State private var logTimestamp: Date = Date()
    @State private var customMg: String = ""
    @State private var customSource: String = ""
    @State private var showingCustomEntry = false
    @State private var editingEntry: AIInsightsCaffeineEntry?
    @State private var editMg: String = ""
    @State private var editSource: String = ""
    @State private var editTimestamp: Date = Date()
    @State private var showingClearConfirmation = false
    @State private var activeInfo: AIInsightsCaffeineInfoTip?
    @State private var showGlucoseInfo = false

    @Environment(\.dismiss) private var dismiss

    private var currentState: AIInsightsCaffeineState { tracker.currentState() }

    var body: some View {
        List {
            currentLevelSection
            logEntrySection
            recentEntriesSection
        }
        .navigationTitle(String(localized: "Caffeine Tracker", comment: "Caffeine tracker nav title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showGlucoseInfo = true
                } label: {
                    Image(systemName: "info.circle")
                }
                .accessibilityLabel(String(localized: "How caffeine affects glucose", comment: "Caffeine info button"))
            }
        }
        .sheet(item: $editingEntry) { entry in
            editEntrySheet(entry)
        }
        .sheet(isPresented: $showGlucoseInfo) {
            AIInsightsGlucoseEffectSheet(
                title: String(localized: "Caffeine & Glucose", comment: "Caffeine info sheet title"),
                paragraphs: [
                    String(localized: "Caffeine raises cortisol and adrenaline. In Type 1 diabetes this can reduce insulin sensitivity by roughly 15–30% for a few hours, producing slow post-meal glucose rises 30–90 minutes after intake — even without carbs.", comment: "Caffeine info paragraph 1"),
                    String(localized: "Effect is dose-dependent and most noticeable above ~200 mg in one sitting (≈ 2 cups of brewed coffee). Tolerance lowers the effect somewhat for daily drinkers.", comment: "Caffeine info paragraph 2"),
                    String(localized: "Practical impact: morning coffee can blunt your breakfast bolus; an energy drink mid-afternoon can drift you upward into dinner. The AI assistant uses your logged caffeine to flag these patterns.", comment: "Caffeine info paragraph 3")
                ]
            )
        }
        .onAppear {
            logTimestamp = Date()
        }
    }

    // MARK: - Current Level

    private var currentLevelSection: some View {
        Section {
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .stroke(gaugeColor(currentState.currentLevelMg).opacity(0.2), lineWidth: 8)
                        .frame(width: 100, height: 100)

                    let level = min(currentState.currentLevelMg, 400)
                    Circle()
                        .trim(from: 0, to: level / 400)
                        .stroke(gaugeColor(level), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .frame(width: 100, height: 100)
                        .rotationEffect(.degrees(-90))

                    VStack(spacing: 0) {
                        Text(String(format: "%.0f", currentState.currentLevelMg))
                            .font(.title2.weight(.bold))
                            .foregroundColor(gaugeColor(currentState.currentLevelMg))
                        Text(String(localized: "mg", comment: "Milligrams short"))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                infoLabel(String(localized: "Estimated Caffeine Level", comment: "Caffeine current label"), tip: .estimatedLevel)

                if currentState.entriesLast24h > 0 {
                    HStack(spacing: 16) {
                        VStack(spacing: 2) {
                            Text(String(format: "%.0f mg", currentState.totalMgLast24h))
                                .font(.caption.weight(.semibold))
                                .foregroundColor(caffeineGreen)
                            infoLabel(String(localized: "24h Total", comment: "Caffeine 24h total"), tip: .totalLast24h)
                        }
                        VStack(spacing: 2) {
                            Text(String(format: "%.0f mg", currentState.peakLevelToday))
                                .font(.caption.weight(.semibold))
                                .foregroundColor(caffeineGreen)
                            infoLabel(String(localized: "Today's Peak", comment: "Caffeine today peak"), tip: .todaysPeak)
                        }
                        if let lastTime = currentState.lastIntakeTime {
                            VStack(spacing: 2) {
                                Text(Self.timeFormatter.string(from: lastTime))
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(caffeineGreen)
                                infoLabel(String(localized: "Last Intake", comment: "Caffeine last intake"), tip: .lastIntake)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .alert(item: $activeInfo) { tip in
                Alert(
                    title: Text(tip.title),
                    message: Text(tip.message),
                    dismissButton: .default(Text(String(localized: "OK", comment: "OK alert button")))
                )
            }
        }
    }

    private func infoLabel(_ text: String, tip: AIInsightsCaffeineInfoTip) -> some View {
        Button(action: { activeInfo = tip }) {
            HStack(spacing: 3) {
                Text(text).font(.caption2).foregroundColor(.secondary)
                Image(systemName: "info.circle").font(.system(size: 10)).foregroundColor(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Log Entry

    private var logEntrySection: some View {
        Section(header: Text(String(localized: "Log Caffeine", comment: "Caffeine log section"))) {
            AIInsightsLogTimeRow(timestamp: $logTimestamp)

            let presets = AIInsightsCaffeinePreset.defaults
            let columns = [GridItem(.flexible()), GridItem(.flexible())]

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(presets) { preset in
                    Button(action: {
                        tracker.logCaffeine(milligrams: preset.milligrams, source: preset.name, at: logTimestamp)
                        logTimestamp = Date()
                    }) {
                        HStack(spacing: 6) {
                            Text(preset.icon).font(.caption)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(preset.name)
                                    .font(.caption).fontWeight(.medium)
                                    .foregroundColor(.primary).lineLimit(1)
                                Text(String(format: "%.0f mg", preset.milligrams))
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
                    Text(String(localized: "Custom Entry", comment: "Toggle custom caffeine entry"))
                }
                .font(.subheadline)
                .foregroundColor(caffeineGreen)
            }

            if showingCustomEntry {
                TextField(String(localized: "Amount (mg)", comment: "Caffeine amount field"), text: $customMg)
                    .keyboardType(.decimalPad)
                TextField(String(localized: "Source (e.g. Matcha Latte)", comment: "Caffeine source field"), text: $customSource)

                Button(action: {
                    if let mg = Double(customMg.replacingOccurrences(of: ",", with: ".")), mg > 0 {
                        let source = customSource.isEmpty ? String(localized: "Custom", comment: "Default custom source label") : customSource
                        tracker.logCaffeine(milligrams: mg, source: source, at: logTimestamp)
                        customMg = ""
                        customSource = ""
                        showingCustomEntry = false
                        logTimestamp = Date()
                    }
                }) {
                    HStack {
                        Spacer()
                        Text(String(localized: "Add Entry", comment: "Add caffeine entry button")).fontWeight(.medium)
                        Spacer()
                    }
                    .foregroundColor(.white)
                    .padding(.vertical, 8)
                    .background((Double(customMg.replacingOccurrences(of: ",", with: ".")) ?? 0) > 0 ? caffeineGreen : Color.gray)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .disabled((Double(customMg.replacingOccurrences(of: ",", with: ".")) ?? 0) <= 0)
            }
        }
    }

    // MARK: - Recent Entries

    private var recentEntriesSection: some View {
        Section(header: Text(String(localized: "Recent Entries", comment: "Caffeine recent entries section"))) {
            if tracker.entries.isEmpty {
                Text(String(localized: "No caffeine entries yet. Tap a preset above to log intake.", comment: "Caffeine empty state"))
                    .font(.caption).foregroundColor(.secondary)
            } else {
                ForEach(tracker.entries.prefix(20)) { entry in
                    Button(action: {
                        guard !entry.isFromHealthKit else { return }
                        editMg = String(format: "%.0f", entry.milligrams)
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
                            Text(String(format: "%.0f mg", entry.milligrams))
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(caffeineGreen)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { indexSet in
                    let toDelete = indexSet.compactMap { idx -> AIInsightsCaffeineEntry? in
                        guard idx < tracker.entries.count else { return nil }
                        let entry = tracker.entries[idx]
                        return entry.isFromHealthKit ? nil : entry
                    }
                    for entry in toDelete { tracker.removeEntry(entry) }
                }

                Button(role: .destructive, action: { showingClearConfirmation = true }) {
                    HStack {
                        Spacer()
                        Text(String(localized: "Clear All Manual Entries", comment: "Clear all caffeine button"))
                        Spacer()
                    }
                }
                .alert(
                    String(localized: "Clear All Manual Entries?", comment: "Clear caffeine confirm title"),
                    isPresented: $showingClearConfirmation
                ) {
                    Button(String(localized: "Cancel", comment: "Cancel button"), role: .cancel) {}
                    Button(String(localized: "Clear All", comment: "Confirm clear all"), role: .destructive) {
                        tracker.clearAllManualEntries()
                    }
                } message: {
                    Text(String(localized: "This removes all manually logged caffeine. Apple Health entries are not affected. This cannot be undone.", comment: "Clear caffeine confirm message"))
                }
            }
        }
    }

    // MARK: - Edit Sheet

    private func editEntrySheet(_ entry: AIInsightsCaffeineEntry) -> some View {
        NavigationView {
            Form {
                Section(header: Text(String(localized: "Edit Entry", comment: "Edit caffeine entry section"))) {
                    TextField(String(localized: "Amount (mg)", comment: "Caffeine amount field"), text: $editMg)
                        .keyboardType(.decimalPad)
                    TextField(String(localized: "Source", comment: "Caffeine source field"), text: $editSource)
                    DatePicker(
                        String(localized: "Time", comment: "Caffeine time field"),
                        selection: $editTimestamp,
                        in: ...Date(),
                        displayedComponents: [.date, .hourAndMinute]
                    )
                }

                Section {
                    Button(action: {
                        if let mg = Double(editMg.replacingOccurrences(of: ",", with: ".")), mg > 0 {
                            tracker.updateEntry(
                                id: entry.id,
                                milligrams: mg,
                                source: editSource.isEmpty ? String(localized: "Custom", comment: "Default custom source label") : editSource,
                                timestamp: editTimestamp
                            )
                            editingEntry = nil
                        }
                    }) {
                        HStack {
                            Spacer()
                            Text(String(localized: "Save Changes", comment: "Save caffeine edit"))
                                .fontWeight(.medium).foregroundColor(.white)
                            Spacer()
                        }
                        .padding(.vertical, 8)
                        .background((Double(editMg.replacingOccurrences(of: ",", with: ".")) ?? 0) > 0 ? caffeineGreen : Color.gray)
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .disabled((Double(editMg.replacingOccurrences(of: ",", with: ".")) ?? 0) <= 0)

                    Button(role: .destructive, action: {
                        tracker.removeEntry(entry)
                        editingEntry = nil
                    }) {
                        HStack {
                            Spacer()
                            Text(String(localized: "Delete Entry", comment: "Delete caffeine entry"))
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "Edit Caffeine", comment: "Edit caffeine nav title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(String(localized: "Cancel", comment: "Cancel button")) { editingEntry = nil }
                }
            }
        }
    }

    // MARK: - Helpers

    private func gaugeColor(_ mg: Double) -> Color {
        if mg < 100 { return .green }
        if mg < 200 { return .yellow }
        if mg < 300 { return .orange }
        if mg < 400 { return .red }
        return Color(red: 0.7, green: 0.0, blue: 0.0)
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
