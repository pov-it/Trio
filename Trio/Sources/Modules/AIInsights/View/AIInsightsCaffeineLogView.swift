//
//  AIInsightsCaffeineLogView.swift
//  Trio
//
//  Caffeine logging UI: current-level gauge, quick-add presets, entry log.
//  Ported from Loop PowerPack (LoopInsights_CaffeineLogView.swift), adapted to Trio.
//

import SwiftUI

private let caffeineGreen = Color.green

private enum AIInsightsCaffeineInfoTip: String, Identifiable {
    case estimatedLevel, totalLast24h, todaysPeak, lastIntake

    var id: String { rawValue }

    var title: String {
        switch self {
        case .estimatedLevel: return String(localized: "Estimated Caffeine Level")
        case .totalLast24h: return String(localized: "24h Total")
        case .todaysPeak: return String(localized: "Today's Peak")
        case .lastIntake: return String(localized: "Last Intake")
        }
    }

    var message: String {
        switch self {
        case .estimatedLevel:
            return String(localized: "The estimated milligrams of caffeine currently in your system. Caffeine has a half-life of about 5.7 hours, meaning half of what you consume is eliminated roughly every 6 hours.")
        case .totalLast24h:
            return String(localized: "The total milligrams of caffeine consumed in the last 24 hours from all sources. The FDA considers 400 mg/day a safe amount for most adults.")
        case .todaysPeak:
            return String(localized: "The highest caffeine level your body reached today. High peak levels can amplify effects on blood sugar, heart rate, and sleep quality.")
        case .lastIntake:
            return String(localized: "When you last consumed caffeine. Caffeine consumed within 6 hours of bedtime can disrupt sleep and affect overnight glucose control.")
        }
    }
}

struct AIInsightsCaffeineLogView: View {
    @ObservedObject var tracker: AIInsights_CaffeineTracker = .shared

    @State private var customMg: String = ""
    @State private var customSource: String = ""
    @State private var showingCustomEntry = false
    @State private var editingEntry: AIInsightsCaffeineEntry?
    @State private var editMg: String = ""
    @State private var editSource: String = ""
    @State private var editTimestamp: Date = Date()
    @State private var showingClearConfirmation = false
    @State private var activeInfo: AIInsightsCaffeineInfoTip?

    @Environment(\.dismiss) private var dismiss

    private var currentState: AIInsightsCaffeineState { tracker.currentState() }

    var body: some View {
        List {
            currentLevelSection
            quickAddSection
            if showingCustomEntry {
                customEntrySection
            }
            recentEntriesSection
        }
        .navigationTitle(String(localized: "Caffeine Tracker"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingEntry) { entry in
            editEntrySheet(entry)
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
                        Text("mg")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                infoLabel(String(localized: "Estimated Caffeine Level"), tip: .estimatedLevel)

                if currentState.entriesLast24h > 0 {
                    HStack(spacing: 16) {
                        VStack(spacing: 2) {
                            Text(String(format: "%.0f mg", currentState.totalMgLast24h))
                                .font(.caption.weight(.semibold))
                                .foregroundColor(caffeineGreen)
                            infoLabel(String(localized: "24h Total"), tip: .totalLast24h)
                        }
                        VStack(spacing: 2) {
                            Text(String(format: "%.0f mg", currentState.peakLevelToday))
                                .font(.caption.weight(.semibold))
                                .foregroundColor(caffeineGreen)
                            infoLabel(String(localized: "Today's Peak"), tip: .todaysPeak)
                        }
                        if let lastTime = currentState.lastIntakeTime {
                            VStack(spacing: 2) {
                                Text(Self.timeFormatter.string(from: lastTime))
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(caffeineGreen)
                                infoLabel(String(localized: "Last Intake"), tip: .lastIntake)
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
                    dismissButton: .default(Text(String(localized: "OK")))
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

    // MARK: - Quick Add

    private var quickAddSection: some View {
        Section(header: Text(String(localized: "Quick Add"))) {
            let presets = AIInsightsCaffeinePreset.defaults
            let columns = [GridItem(.flexible()), GridItem(.flexible())]

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(presets) { preset in
                    Button(action: {
                        tracker.logCaffeine(milligrams: preset.milligrams, source: preset.name)
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
                    Text(String(localized: "Custom Entry"))
                }
                .font(.subheadline)
                .foregroundColor(caffeineGreen)
            }
        }
    }

    // MARK: - Custom Entry

    private var customEntrySection: some View {
        Section(header: Text(String(localized: "Custom Caffeine Entry"))) {
            TextField(String(localized: "Amount (mg)"), text: $customMg)
                .keyboardType(.decimalPad)
            TextField(String(localized: "Source (e.g. Matcha Latte)"), text: $customSource)

            Button(action: {
                if let mg = Double(customMg.replacingOccurrences(of: ",", with: ".")), mg > 0 {
                    let source = customSource.isEmpty ? String(localized: "Custom") : customSource
                    tracker.logCaffeine(milligrams: mg, source: source)
                    customMg = ""
                    customSource = ""
                    showingCustomEntry = false
                }
            }) {
                HStack {
                    Spacer()
                    Text(String(localized: "Add Entry")).fontWeight(.medium)
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

    // MARK: - Recent Entries

    private var recentEntriesSection: some View {
        Section(header: Text(String(localized: "Recent Entries"))) {
            if tracker.entries.isEmpty {
                Text(String(localized: "No caffeine entries yet. Tap a preset above to log intake."))
                    .font(.caption).foregroundColor(.secondary)
            } else {
                ForEach(tracker.entries.prefix(20)) { entry in
                    Button(action: {
                        editMg = String(format: "%.0f", entry.milligrams)
                        editSource = entry.source
                        editTimestamp = entry.timestamp
                        editingEntry = entry
                    }) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.source).font(.subheadline).foregroundColor(.primary)
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
                        return tracker.entries[idx]
                    }
                    for entry in toDelete { tracker.removeEntry(entry) }
                }

                Button(role: .destructive, action: { showingClearConfirmation = true }) {
                    HStack {
                        Spacer()
                        Text(String(localized: "Clear All Entries"))
                        Spacer()
                    }
                }
                .alert(
                    String(localized: "Clear All Entries?"),
                    isPresented: $showingClearConfirmation
                ) {
                    Button(String(localized: "Cancel"), role: .cancel) {}
                    Button(String(localized: "Clear All"), role: .destructive) {
                        tracker.clearAllEntries()
                    }
                } message: {
                    Text(String(localized: "This will remove all caffeine entries. This cannot be undone."))
                }
            }
        }
    }

    // MARK: - Edit Sheet

    private func editEntrySheet(_ entry: AIInsightsCaffeineEntry) -> some View {
        NavigationView {
            Form {
                Section(header: Text(String(localized: "Edit Entry"))) {
                    TextField(String(localized: "Amount (mg)"), text: $editMg)
                        .keyboardType(.decimalPad)
                    TextField(String(localized: "Source"), text: $editSource)
                    DatePicker(
                        String(localized: "Time"),
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
                                source: editSource.isEmpty ? String(localized: "Custom") : editSource,
                                timestamp: editTimestamp
                            )
                            editingEntry = nil
                        }
                    }) {
                        HStack {
                            Spacer()
                            Text(String(localized: "Save Changes"))
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
                            Text(String(localized: "Delete Entry"))
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "Edit Caffeine"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(String(localized: "Cancel")) { editingEntry = nil }
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
