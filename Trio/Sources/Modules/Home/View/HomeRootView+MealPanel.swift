import Foundation
import SwiftUI

// MARK: - Zone C: meal panel (IOB / COB / delivery rate)

extension Home.RootView {
    /// Two states: the live IOB / COB / alarms row, and — while the chart is scrubbed — the
    /// readout for the selected point, which wins because it answers the same questions for a
    /// different instant without covering the data the finger is on. It renders from
    /// `chartReadoutDate`, not `chartSelection`, so a hole can't flicker the slot
    /// (see `updateChartReadout`).
    ///
    /// Both halves stay mounted and cross-fade on `opacity`. Swapping them with `if`/`else`
    /// left the exit to a removal transition, which never played: the row's root is a
    /// `ViewThatFits` and its background is a glass/material effect, and neither survives one
    /// — the readout blinked out while the arrival faded in normally. Opacity is a plain
    /// animatable value, so both directions animate.
    @ViewBuilder func mealPanel() -> some View {
        ZStack {
            liveMealPanel
                .opacity(isChartReadoutVisible ? 0 : 1)

            // Renders from the last resolved selection, which is deliberately not cleared on
            // decay: the row has to keep its values to fade out with, and it is invisible
            // (and untouchable) for as long as no readout is showing.
            if let readoutDate = chartReadoutDate,
               let selectedGlucose = ChartSelectionLookup.glucose(at: readoutDate, in: state.glucoseFromPersistence)
            {
                ChartSelectionRow(
                    selectedGlucose: selectedGlucose,
                    determination: chartReadoutDeterminationDate.flatMap {
                        ChartSelectionLookup.determination(at: $0, in: state.enactedAndNonEnactedDeterminations)
                    },
                    units: state.units,
                    highGlucose: state.highGlucose,
                    lowGlucose: state.lowGlucose,
                    currentGlucoseTarget: state.currentGlucoseTarget,
                    glucoseColorScheme: state.glucoseColorScheme,
                    isSmoothingEnabled: state.settingsManager.settings.smoothGlucose
                )
                .padding(.horizontal)
                .opacity(isChartReadoutVisible ? 1 : 0)
                .allowsHitTesting(isChartReadoutVisible)
            }
        }
    }

    /// Decays the readout instead of dropping it: readings and determinations have holes, and
    /// not the same ones, so each half remembers the last selection that resolved it and the
    /// slot only lets go once nothing has resolved for `ChartSelectionLookup.decay`. Run as
    /// `.task(id: chartSelection)`, so the next scrub step cancels a pending decay and
    /// crossing a hole never reaches the timeout.
    ///
    /// Only `isChartReadoutVisible` is cleared when it does let go; the dates it renders from
    /// stay, so the row keeps its values while fading out.
    ///
    /// `@MainActor` because the continuation after the decay sleep would otherwise resume off
    /// the main actor, writing view state from the wrong one.
    @MainActor func updateChartReadout() async {
        if let selection = chartSelection {
            var resolvedAnything = false

            if ChartSelectionLookup.glucose(at: selection, in: state.glucoseFromPersistence) != nil {
                chartReadoutDate = selection
                resolvedAnything = true
            }

            if ChartSelectionLookup.determination(
                at: selection,
                in: state.enactedAndNonEnactedDeterminations
            ) != nil {
                chartReadoutDeterminationDate = selection
                resolvedAnything = true
            } else if let held = chartReadoutDeterminationDate,
                      abs(held.timeIntervalSince(selection)) > ChartSelectionLookup.determinationHold
            {
                // a hop to a different part of the chart, not a hole: don't carry the values over
                chartReadoutDeterminationDate = nil
            }

            if resolvedAnything {
                isChartReadoutVisible = true
                return
            }
        }

        guard isChartReadoutVisible else { return }
        try? await Task.sleep(for: .seconds(ChartSelectionLookup.decay))
        guard !Task.isCancelled else { return }
        isChartReadoutVisible = false
    }

    @ViewBuilder private var liveMealPanel: some View {
        // One row so carbs stay between insulin and the action pills. A centered
        // overlay collided with sparkles + FoodFinder + the snooze capsule on a
        // narrow phone (glucose and pump already occupy the header above).
        HStack(spacing: 6) {
            insulinOnBoardLabel
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Spacer(minLength: 4)
            carbsOnBoardLabel
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Spacer(minLength: 4)
            HStack(spacing: 6) {
                aiHubPill
                foodFinderPill
                alarmsPill
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal)
    }

    /// Carb value on the row; the fork hangs off its leading edge.
    private var carbsOnBoardLabel: some View {
        let grams = Formatter.decimalFormatterWithTwoFractionDigits.string(
            from: NSNumber(value: state.enactedAndNonEnactedDeterminations.first?.cob ?? 0)
        ) ?? "0"
        let value = grams + String(localized: " g", comment: "gram of carbs")
        return Text(value)
            .font(.callout).fontWeight(.bold).fontDesign(.rounded)
            .overlay(alignment: .leading) {
                Image(systemName: "fork.knife")
                    .font(.callout)
                    .foregroundColor(.loopYellow)
                    .alignmentGuide(.leading) { $0.width + 5 }
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Carbs on board"))
            .accessibilityValue(Text(value))
    }

    private var insulinOnBoardLabel: some View {
        let units = (
            Formatter.decimalFormatterWithTwoFractionDigits
                .string(from: state.currentIOB as NSNumber) ?? "0"
        ) + String(localized: " U", comment: "Insulin unit")
        return HStack {
            Image(systemName: "syringe.fill")
                .font(.callout)
                .foregroundColor(Color.insulin)
            Text(units)
                .font(.callout).fontWeight(.bold).fontDesign(.rounded)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Insulin on board"))
        .accessibilityValue(Text(units))
    }

    func refreshAlarmsSnooze() {
        alarmsSnoozeUntil = UserDefaults.standard
            .object(forKey: "UserNotificationsManager.snoozeUntilDate") as? Date ?? .distantPast
    }

    /// Sparkles pill matching the alarm bell; opens AI Hub (chat, insights, trackers).
    @ViewBuilder var aiHubPill: some View {
        NavigationLink {
            AIInsights.HubView(resolver: resolver)
        } label: {
            Image(systemName: "sparkles")
                .font(.callout)
                .fontWeight(.semibold)
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            Color(red: 0.7215686275, green: 0.3411764706, blue: 1),
                            Color(red: 0.262745098, green: 0.7333333333, blue: 0.9137254902)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 32, height: 32)
                .overlay(
                    Circle()
                        .stroke(Color.primary.opacity(0.4), lineWidth: 2)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "AI Hub", comment: "AI Hub accessibility label"))
        .accessibilityHint(Text(String(localized: "Opens chat, insights, and trackers", comment: "AI Hub accessibility hint")))
        .accessibilityAddTraits(.isButton)
    }

    /// Opens FoodFinder as the same home-screen modal the widget deep link uses,
    /// so the composer docks to the keyboard the same way.
    @ViewBuilder var foodFinderPill: some View {
        Button {
            state.showModal(for: .aiFoodFinder)
        } label: {
            Image(systemName: "fork.knife")
                .font(.callout)
                .fontWeight(.semibold)
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            Color(red: 0.3411764706, green: 0.6666666667, blue: 0.9254901961),
                            Color(red: 0.262745098, green: 0.7333333333, blue: 0.9137254902)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 32, height: 32)
                .overlay(
                    Circle()
                        .stroke(Color.primary.opacity(0.4), lineWidth: 2)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "FoodFinder", comment: "FoodFinder home button accessibility label"))
        .accessibilityHint(Text(String(localized: "Opens FoodFinder", comment: "FoodFinder home button accessibility hint")))
        .accessibilityAddTraits(.isButton)
    }

    /// Bell pill matching the header pills; countdown replaces the label while snoozed.
    @ViewBuilder var alarmsPill: some View {
        // timerDate keeps the countdown ticking
        // measure from now, so calculation is not based off stale tick date
        // cf. https://github.com/nightscout/Trio/issues/1381
        let isSnoozed = alarmsSnoozeUntil > state.timerDate
        let remainingMinutes = max(Int(ceil(alarmsSnoozeUntil.timeIntervalSince(max(state.timerDate, Date())) / 60)), 0)

        Button {
            showSnoozeSheet = true
        } label: {
            Group {
                if isSnoozed {
                    HStack(spacing: 5) {
                        Image(systemName: "bell.slash.fill")
                            .font(.callout)
                        Text("\(remainingMinutes) m")
                            .font(.callout).fontWeight(.bold).fontDesign(.rounded)
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 10)
                    .foregroundStyle(.secondary)
                    .overlay(
                        Capsule()
                            .stroke(Color.primary.opacity(0.4), lineWidth: 2)
                    )
                } else {
                    Image(systemName: "bell.fill")
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .frame(width: 32, height: 32)
                        .overlay(
                            Circle()
                                .stroke(Color.primary.opacity(0.4), lineWidth: 2)
                        )
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Alarms"))
        .accessibilityValue(Text(
            isSnoozed
                ? String(
                    format: String(localized: "snoozed, %d minutes remaining", comment: "Accessibility: alarm snooze"),
                    remainingMinutes
                )
                : String(localized: "active", comment: "Accessibility: alarms active")
        ))
        .accessibilityHint(Text(String(localized: "Opens snooze options", comment: "Accessibility hint")))
        .accessibilityAddTraits(.isButton)
    }
}
