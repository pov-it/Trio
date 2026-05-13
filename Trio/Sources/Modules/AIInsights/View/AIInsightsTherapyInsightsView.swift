import SwiftUI
import Swinject

extension AIInsights {
    struct TherapyInsightsView: BaseView {
        let resolver: Resolver
        @State var state = TherapyInsightsStateModel()
        @State private var therapySettingsDestination: Screen?

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        var body: some View {
            Form {
                Section {
                    periodSelector

                    if let score = state.settingsScore {
                        settingsScoreCard(score)
                    }

                    analyzeButton

                    if !state.suggestions.isEmpty || !state.suggestionHistory.isEmpty {
                        swipeActionsHint
                    }

                    if let error = state.errorMessage {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.orange.opacity(0.1))
                        )
                    }

                    if state.suggestions.isEmpty && !state.isAnalyzing && state.settingsScore == nil && state.suggestionHistory.isEmpty {
                        emptyStateView
                    }
                }
                .listRowBackground(Color.chart)

                if !state.suggestions.isEmpty {
                    suggestionsSection
                }

                if !state.suggestionHistory.isEmpty {
                    historySection
                }
            }
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .navigationTitle(String(localized: "Therapy Insights", comment: "Nav title"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $therapySettingsDestination) { screen in
                screen.view(resolver: resolver)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !state.suggestions.isEmpty {
                        Button {
                            state.clearSuggestions()
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
            .onChange(of: state.analysisPeriodDays) {
                state.saveAnalysisPeriod()
            }
            .onAppear(perform: configureView)
            .alert(
                String(localized: "Apply Suggestion?", comment: "Disclaimer alert title"),
                isPresented: $state.showApplyDisclaimer
            ) {
                Button(String(localized: "Cancel", comment: "Cancel button"), role: .cancel) {
                    state.cancelApply()
                }
                Button(String(localized: "I Understand, Apply", comment: "Apply button"), role: .destructive) {
                    Task { await state.confirmApply() }
                }
            } message: {
                Text(String(localized: "This AI suggestion is informational only and NOT medical advice. Always consult your healthcare provider before adjusting therapy settings. Incorrect settings can cause dangerous hypo- or hyperglycemia. By proceeding, you acknowledge that you take full responsibility for any changes.", comment: "Disclaimer message"))
            }
        }

        // MARK: - Period Selector

        private var periodSelector: some View {
            Picker(String(localized: "Analysis period", comment: "Therapy insights analysis period picker"), selection: $state.analysisPeriodDays) {
                ForEach([3, 7, 14, 30], id: \.self) { days in
                    Text("\(days)d").tag(days)
                }
            }
            .pickerStyle(.segmented)
            .disabled(state.isAnalyzing)
        }

        private var swipeActionsHint: some View {
            Label(
                String(localized: "Swipe rows for actions.", comment: "Therapy insights swipe action hint"),
                systemImage: "hand.draw"
            )
            .font(.caption)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        // MARK: - Settings Score Card

        private func settingsScoreCard(_ score: SettingsScore) -> some View {
            VStack(spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(localized: "Settings Score", comment: "Score card title"))
                            .font(.headline)
                        Text(score.grade.localizedTitle)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    // Circular Score
                    ZStack {
                        Circle()
                            .stroke(Color.gray.opacity(0.2), lineWidth: 8)
                            .frame(width: 70, height: 70)
                        Circle()
                            .trim(from: 0, to: CGFloat(score.score) / 100.0)
                            .stroke(
                                scoreGradient(score.score),
                                style: StrokeStyle(lineWidth: 8, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                            .frame(width: 70, height: 70)
                        Text("\(score.score)")
                            .font(.title2.bold())
                    }
                }

                // Metrics Row
                HStack(spacing: 0) {
                    metricPill(
                        label: String(localized: "TIR", comment: "Time In Range"),
                        value: String(format: "%.0f%%", score.tir)
                    )
                    Spacer()
                    metricPill(
                        label: String(localized: "GMI", comment: "Glucose Management Indicator"),
                        value: String(format: "%.1f%%", score.gmi)
                    )
                    Spacer()
                    metricPill(
                        label: String(localized: "Below", comment: "Time below range"),
                        value: String(format: "%.1f%%", score.timeBelowRange)
                    )
                    Spacer()
                    metricPill(
                        label: String(localized: "CV", comment: "Coefficient of variation"),
                        value: String(format: "%.0f%%", score.cv)
                    )
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(colorScheme == .dark ? Color.bgDarkerDarkBlue.opacity(0.8) : Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(colorScheme == .dark ? Color.white.opacity(0.1) : Color.gray.opacity(0.15), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 4)
        }

        private func metricPill(label: String, value: String) -> some View {
            VStack(spacing: 2) {
                Text(value)
                    .font(.subheadline.bold())
                Text(label)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }

        private func scoreGradient(_ score: Int) -> LinearGradient {
            let colors: [Color]
            switch score {
            case 80...: colors = [.green, .green.opacity(0.7)]
            case 60..<80: colors = [.yellow, .orange]
            case 40..<60: colors = [.orange, .red.opacity(0.8)]
            default: colors = [.red, .red.opacity(0.7)]
            }
            return LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
        }

        // MARK: - Analyze Button

        private var analyzeButton: some View {
            Button {
                Task { await state.runAnalysis() }
            } label: {
                HStack {
                    if state.isAnalyzing {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        Text(String(localized: "Analyzing...", comment: "Analysis in progress"))
                            .font(.headline)
                    } else {
                        Image(systemName: "wand.and.stars")
                        Text(String(localized: "Analyze Settings", comment: "Analyze button label"))
                            .font(.headline)
                    }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.7215686275, green: 0.3411764706, blue: 1),
                                    Color(red: 0.262745098, green: 0.7333333333, blue: 0.9137254902)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                )
            }
            .disabled(state.isAnalyzing || !state.aiEnabled)
            .opacity(state.aiEnabled ? 1.0 : 0.5)
        }

        // MARK: - Suggestions Section

        private var suggestionsSection: some View {
            Section(header: Text(String(localized: "Suggestions", comment: "Suggestions section header"))) {
                ForEach(state.suggestions) { suggestion in
                    SuggestionRow(
                        suggestion: suggestion,
                        colorScheme: colorScheme
                    )
                    .contextMenu {
                        Button(String(localized: "Apply", comment: "Apply suggestion"), systemImage: "checkmark.circle") {
                            state.requestApply(suggestion)
                        }
                        Button(String(localized: "Edit Settings", comment: "Open therapy setting editor"), systemImage: "pencil") {
                            therapySettingsDestination = settingsScreen(for: suggestion.settingType)
                        }
                        Button(String(localized: "Delete", comment: "Delete suggestion"), systemImage: "trash", role: .destructive) {
                            state.dismissSuggestion(suggestion)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(String(localized: "Delete", comment: "Delete suggestion"), systemImage: "trash", role: .destructive) {
                            state.dismissSuggestion(suggestion)
                        }
                        Button(String(localized: "Edit", comment: "Edit therapy settings"), systemImage: "pencil") {
                            therapySettingsDestination = settingsScreen(for: suggestion.settingType)
                        }
                        .tint(.blue)
                    }
                    .swipeActions(edge: .leading) {
                        Button(String(localized: "Apply", comment: "Apply suggestion"), systemImage: "checkmark.circle") {
                            state.requestApply(suggestion)
                        }
                        .tint(.green)
                    }
                }
            }
            .listRowBackground(Color.chart)
        }

        // MARK: - History Section

        private var historySection: some View {
            Section {
                ForEach(state.suggestionHistory) { record in
                    HistoryRecordRow(
                        record: record,
                        colorScheme: colorScheme
                    )
                    .contextMenu {
                        Button(String(localized: "Open Settings", comment: "Open therapy setting editor"), systemImage: "pencil") {
                            therapySettingsDestination = settingsScreen(for: record.suggestion.settingType)
                        }
                        if record.status == .applied {
                            Button(String(localized: "Revert", comment: "Revert suggestion"), systemImage: "arrow.uturn.backward") {
                                Task { await state.revertSuggestion(record) }
                            }
                        }
                        Button(String(localized: "Delete", comment: "Delete history item"), systemImage: "trash", role: .destructive) {
                            state.deleteHistoryRecord(record)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(String(localized: "Delete", comment: "Delete history item"), systemImage: "trash", role: .destructive) {
                            state.deleteHistoryRecord(record)
                        }
                        Button(String(localized: "Edit", comment: "Edit therapy settings"), systemImage: "pencil") {
                            therapySettingsDestination = settingsScreen(for: record.suggestion.settingType)
                        }
                        .tint(.blue)
                    }
                    .swipeActions(edge: .leading) {
                        if record.status == .applied {
                            Button(String(localized: "Revert", comment: "Revert suggestion"), systemImage: "arrow.uturn.backward") {
                                Task { await state.revertSuggestion(record) }
                            }
                            .tint(.orange)
                        }
                    }
                }
            } header: {
                HStack {
                    Text(String(localized: "History", comment: "Suggestion history header"))
                    Spacer()
                    Button(String(localized: "Clear", comment: "Clear history")) {
                        state.clearHistory()
                    }
                    .font(.caption)
                }
            }
            .listRowBackground(Color.chart)
        }

        private func settingsScreen(for settingType: Suggestion.SettingType) -> Screen {
            switch settingType {
            case .basalRate:
                return .basalProfileEditor
            case .isf:
                return .isfEditor
            case .carbRatio:
                return .crEditor
            }
        }

        // MARK: - Empty State

        private var emptyStateView: some View {
            VStack(spacing: 16) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 48))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                Color(red: 0.4862745098, green: 0.5450980392, blue: 0.9529411765),
                                Color(red: 0.3411764706, green: 0.6666666667, blue: 0.9254901961)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .padding(.top, 40)

                Text(String(localized: "Analyze your therapy settings", comment: "Empty state title"))
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)

                Text(String(localized: "Select a time period above and tap Analyze to receive AI-powered suggestions for your basal rates, ISF, and carb ratios.", comment: "Empty state description"))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                if !state.aiEnabled {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(String(localized: "AI Insights is disabled. Enable it in Settings.", comment: "AI disabled message"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.chart.opacity(0.5))
                    )
                }
            }
        }
    }
}

// MARK: - Suggestion Row

private struct SuggestionRow: View {
    let suggestion: AIInsights.Suggestion
    let colorScheme: ColorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: settingIcon)
                    .foregroundStyle(settingColor)
                Text(suggestion.settingType.localizedTitle)
                    .font(.subheadline.bold())
                Spacer()
                confidenceBadge
            }

            // Time Block
            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(suggestion.timeBlock)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Values
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Current", comment: "Current setting value"))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(suggestion.currentValue)
                        .font(.subheadline.bold())
                }

                Image(systemName: "arrow.right")
                    .foregroundColor(.secondary)
                    .font(.caption)

                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Proposed", comment: "Proposed setting value"))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(suggestion.proposedValue)
                        .font(.subheadline.bold())
                        .foregroundStyle(settingColor)
                }
            }

            // Reasoning
            Text(suggestion.reasoning)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(4)

        }
        .padding(.vertical, 6)
    }

    private var settingIcon: String {
        switch suggestion.settingType {
        case .basalRate: return "waveform.path.ecg.rectangle.fill"
        case .isf: return "syringe"
        case .carbRatio: return "fork.knife"
        }
    }

    private var settingColor: Color {
        switch suggestion.settingType {
        case .basalRate: return .blue
        case .isf: return .purple
        case .carbRatio: return .orange
        }
    }

    private var confidenceBadge: some View {
        Text(String(format: "%.0f%%", suggestion.confidence * 100))
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(confidenceColor.opacity(0.15))
            )
            .foregroundStyle(confidenceColor)
    }

    private var confidenceColor: Color {
        switch suggestion.confidence {
        case 0.7...: return .green
        case 0.4..<0.7: return .orange
        default: return .red
        }
    }
}

// MARK: - History Record Row

private struct HistoryRecordRow: View {
    let record: AIInsights.SuggestionHistoryRecord
    let colorScheme: ColorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                    .font(.caption)
                Text(record.suggestion.settingType.localizedTitle)
                    .font(.caption.bold())
                Spacer()
                Text(record.appliedAt, style: .relative)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(record.suggestion.timeBlock)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            // Before → After
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Before", comment: "Before snapshot"))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(record.suggestion.currentValue)
                        .font(.caption.bold())
                }

                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "After", comment: "After snapshot"))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(record.suggestion.proposedValue)
                        .font(.caption.bold())
                }

                Spacer()

                // Status badge
                Text(record.status.localizedTitle)
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(statusColor.opacity(0.15))
                    )
                    .foregroundStyle(statusColor)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(colorScheme == .dark ? Color.bgDarkerDarkBlue.opacity(0.5) : Color(.systemGray6).opacity(0.7))
        )
    }

    private var statusIcon: String {
        switch record.status {
        case .applied: return "checkmark.circle.fill"
        case .reverted: return "arrow.uturn.backward.circle.fill"
        case .dismissed: return "xmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch record.status {
        case .applied: return .green
        case .reverted: return .orange
        case .dismissed: return .gray
        }
    }
}
