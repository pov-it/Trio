import Charts
import SwiftUI
import UIKit

extension AIInsights {
    /// Glucose after a meal over the times it was saved from the bolus calculator, with the insulin that went in
    /// each time. Shown for one gallery meal and for a whole gallery group. Describes the past; no dosing advice.
    struct MealResponseCard: View {
        let title: String
        let mealIDs: Set<UUID>
        let foodResultIDs: Set<UUID>
        var units: GlucoseUnits = .mgdL
        var cardFill: Color = Color(UIColor.secondarySystemGroupedBackground)
        /// Carbs of the portion being looked at, for the estimate at this portion size.
        var currentCarbs: Double? = nil

        @State private var analyses: [MealEventAnalysis] = []
        @State private var isLoading = true
        @State private var scale: MealResponseScale = .change
        @State private var showsSixHours = false
        @State private var includesDisturbed = false

        private var endMinute: Int { showsSixHours ? 360 : 240 }

        private var loadKey: Set<UUID> { mealIDs.union(foodResultIDs) }

        var body: some View {
            let summary = MealResponseSummary.make(
                analyses: analyses,
                scale: scale,
                includeDisturbed: includesDisturbed,
                fromMinute: -30,
                throughMinute: endMinute
            )
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !isLoading, summary.style != .empty {
                        InfoButton(title: title, message: explanation(summary))
                    }
                }

                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                } else if summary.style == .empty {
                    Text(String(
                        localized: "Appears once this meal is saved from the bolus calculator.",
                        comment: "Meal response card without saved meals"
                    ))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                } else {
                    content(summary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(cardFill))
            .task(id: loadKey) {
                await load()
            }
        }

        @ViewBuilder private func content(_ summary: MealResponseSummary) -> some View {
            Text(headline(summary))
                .font(.footnote)
            if let needLine = needLine(summary) {
                Text(needLine)
                    .font(.footnote.weight(.semibold))
            }

            HStack(spacing: 8) {
                Picker(String(localized: "Scale", comment: "Meal response scale picker"), selection: $scale) {
                    Text(String(localized: "Change", comment: "Meal response scale: change from the start"))
                        .tag(MealResponseScale.change)
                    Text(String(localized: "Glucose", comment: "Meal response scale: measured glucose"))
                        .tag(MealResponseScale.absolute)
                }
                .pickerStyle(.segmented)
                Toggle(String(localized: "6 h", comment: "Meal response toggle: show six hours"), isOn: $showsSixHours)
                    .toggleStyle(.button)
                    .font(.caption)
            }

            MealResponseGlucoseChart(summary: summary, units: units, endMinute: endMinute)
                .frame(height: 190)

            MealResponseInsulinChart(bars: summary.insulin)
                .frame(height: 120)

            if !summary.leftOut.isEmpty || includesDisturbed {
                Toggle(
                    String(localized: "Include disturbed meals", comment: "Meal response toggle: include meals with other carbs or gaps"),
                    isOn: $includesDisturbed
                )
                .font(.caption)
            }
        }

        private func load() async {
            isLoading = analyses.isEmpty
            let loaded = await MealResponseLoader.analyses(mealIDs: mealIDs, foodResultIDs: foodResultIDs)
            analyses = loaded
            isLoading = false
        }

        // MARK: - Text

        private func headline(_ summary: MealResponseSummary) -> String {
            let n = summary.includedCount
            var parts = [String(format: String(localized: "n = %d", comment: "Meal response: meals counted"), n)]
            if let rise = summary.medianRise {
                if let peak = summary.medianPeakMinute {
                    parts.append(String(
                        format: String(localized: "%@ after %d min", comment: "Meal response: median rise and minutes to the peak"),
                        signedGlucose(rise),
                        peak
                    ))
                } else {
                    parts.append(signedGlucose(rise))
                }
            }
            if let inRange = summary.medianInRange0to4h {
                parts.append(String(
                    format: String(localized: "TIR 0–4 h %d%%", comment: "Meal response: median time in range 0–4 h"),
                    inRange
                ))
            }
            if n > 0 {
                parts.append(String(
                    format: String(localized: "low %d/%d", comment: "Meal response: meals with a low within 4 h, of n"),
                    summary.lowCount,
                    n
                ))
                parts.append(String(
                    format: String(localized: "correction %d/%d", comment: "Meal response: meals with a manual correction, of n"),
                    summary.correctionCount,
                    n
                ))
            }
            let leftOut = summary.totalCount - summary.includedCount
            if leftOut > 0 {
                parts.append(String(
                    format: String(localized: "%d left out", comment: "Meal response: meals drawn dashed and not counted"),
                    leftOut
                ))
            }
            return parts.joined(separator: " · ")
        }

        private func insulinLine(_ summary: MealResponseSummary) -> String? {
            guard let mealBolus = summary.medianMealBolus else { return nil }
            var parts = [String(
                format: String(localized: "Median meal bolus %@ U", comment: "Meal response: median meal bolus"),
                unitsText(mealBolus)
            )]
            if let smb = summary.medianSMB {
                parts.append(String(format: String(localized: "SMB %@ U", comment: "Meal response: median SMB 0–4 h"), unitsText(smb)))
            }
            if let temp = summary.medianTempBasalExtra {
                parts.append(String(
                    format: String(localized: "temp basal %@ U", comment: "Meal response: median temp basal above scheduled"),
                    signedUnits(temp)
                ))
            }
            if let correction = summary.medianCorrectionUnits {
                parts.append(String(
                    format: String(localized: "correction %@ U", comment: "Meal response: median correction when given"),
                    unitsText(correction)
                ))
            }
            return parts.joined(separator: " · ") + "."
        }

        private func needLine(_ summary: MealResponseSummary) -> String? {
            guard let needed = summary.medianNeeded else { return nil }
            var line = String(
                format: String(localized: "Took ≈ %@ U", comment: "Meal response: median estimated insulin the meal took"),
                unitsText(needed)
            )
            if let low = summary.neededP25, let high = summary.neededP75, summary.needCount >= 4 {
                line += " (\(unitsText(low))–\(unitsText(high)))"
            }
            if let factor = summary.medianMealFactor {
                line += " · ×" + String(format: "%.2f", factor) + " CR"
            }
            if let perTen = summary.medianUnitsPer10g {
                line += " · " + String(
                    format: String(localized: "%@ U/10 g", comment: "Meal response: needed insulin per 10 g carbs"),
                    String(format: "%.2f", perTen)
                )
            }
            if let currentCarbs, let estimate = summary.neededEstimate(forCarbs: currentCarbs) {
                line += " · " + String(
                    format: String(
                        localized: "this portion ≈ %@ U",
                        comment: "Meal response: estimated insulin for the current portion from past meals"
                    ),
                    unitsText(estimate)
                )
            }
            return line
        }

        /// Everything the card leaves out to stay short, for the info button.
        private func explanation(_ summary: MealResponseSummary) -> String {
            var lines: [String] = []
            lines.append(String(
                localized: "Glucose after each time this meal was saved from the bolus calculator. Change shows the difference from the 15 minutes before the meal.",
                comment: "Meal response info: what the chart shows"
            ))
            switch summary.style {
            case .band:
                lines.append(String(
                    localized: "Line: median. Band: middle half of the meals; the light band covers 80 % from 10 meals on. Orange: the latest meal.",
                    comment: "Meal response: band explanation"
                ))
            case .lines, .single:
                lines.append(String(
                    localized: "Each line is one meal; orange is the latest. A band appears from 5 meals on.",
                    comment: "Meal response: lines explanation"
                ))
            case .empty:
                break
            }
            let left = summary.leftOut
            if !left.isEmpty {
                var reasons: [String] = []
                if left.mealBefore > 0 {
                    reasons.append(String(
                        format: String(localized: "%d with other carbs in the 2 h before", comment: "Meal response: left out, carbs before"),
                        left.mealBefore
                    ))
                }
                if left.mealAfter > 0 {
                    reasons.append(String(
                        format: String(localized: "%d with other carbs within 3 h", comment: "Meal response: left out, carbs after"),
                        left.mealAfter
                    ))
                }
                if left.lowCoverage > 0 {
                    reasons.append(String(
                        format: String(localized: "%d with gaps in glucose", comment: "Meal response: left out, glucose gaps"),
                        left.lowCoverage
                    ))
                }
                if left.noBaseline > 0 {
                    reasons.append(String(
                        format: String(localized: "%d without glucose at the start", comment: "Meal response: left out, no baseline"),
                        left.noBaseline
                    ))
                }
                lines.append(String(
                    format: String(localized: "Left out of the numbers (dashed): %@.", comment: "Meal response: meals left out"),
                    reasons.joined(separator: ", ")
                ))
            }
            lines.append(String(
                localized: "Insulin bars: meal bolus, SMB and temp basal above the scheduled rate in the 4 h after the meal, and manual corrections from 30 min on. ◆ is what the bolus calculator recommended, ● the estimated insulin the meal took and ▲ marks a low or rescue carbs.",
                comment: "Meal response: insulin chart explanation"
            ))
            if let insulinLine = insulinLine(summary) {
                lines.append(insulinLine)
            }
            if summary.medianNeeded != nil {
                lines.append(String(
                    localized: "Took: insulin on board at the meal plus everything delivered in 4 h, minus what was still on board, corrected for where glucose ended (via ISF) and for rescue carbs (via the carb ratio). ×CR compares that with the carbs at your carb ratio. Fat and protein absorbing after 4 h and a basal that is off are not separated out.",
                    comment: "Meal response: how the needed insulin is estimated"
                ))
            }
            lines.append(String(
                localized: "The loop reacts to the curve itself, so read glucose together with the insulin. A higher curve can come from the carb estimate as well as from settings. This describes past meals; it is not dosing advice.",
                comment: "Meal response: disclaimer"
            ))
            return lines.joined(separator: "\n\n")
        }

        private func signedGlucose(_ mgdl: Double) -> String {
            let text = units == .mgdL
                ? String(format: "%+.0f", mgdl)
                : String(format: "%+.1f", mgdl * Double(truncating: GlucoseUnits.exchangeRate as NSNumber))
            return "\(text) \(units.rawValue)"
        }

        private func unitsText(_ value: Double) -> String {
            String(format: "%.1f", value)
        }

        private func signedUnits(_ value: Double) -> String {
            String(format: "%+.1f", value)
        }
    }

    /// A small (i) button that shows an explanation in a popover, so the page itself can stay short.
    struct InfoButton: View {
        let title: String
        let message: String

        @State private var isPresented = false

        var body: some View {
            Button {
                isPresented = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.subheadline)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(title)
            .popover(isPresented: $isPresented) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title)
                            .font(.headline)
                        Text(message)
                            .font(.footnote)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding()
                    .frame(width: 320, alignment: .leading)
                }
                .frame(maxHeight: 440)
                .presentationCompactAdaptation(.popover)
            }
        }
    }

    /// Glucose after the meal: one line per meal, and from five meals on the median with percentile bands.
    struct MealResponseGlucoseChart: View {
        let summary: MealResponseSummary
        let units: GlucoseUnits
        let endMinute: Int

        private struct LinePoint: Identifiable {
            let id: String
            let series: String
            let minute: Double
            let value: Double
            let isIncluded: Bool
            let isLatest: Bool
        }

        private var factor: Double {
            units == .mgdL ? 1 : Double(truncating: GlucoseUnits.exchangeRate as NSNumber)
        }

        /// Splits each curve where glucose is missing, so a gap is not drawn as a straight line.
        private var linePoints: [LinePoint] {
            var points: [LinePoint] = []
            for curve in summary.curves {
                var segment = 0
                var previous: Int?
                for point in curve.points {
                    if let previous, point.minute - previous > MealEventCurve.stepMinutes {
                        segment += 1
                    }
                    previous = point.minute
                    let series = "\(curve.id.uuidString)-\(segment)"
                    points.append(LinePoint(
                        id: "\(series)-\(point.minute)",
                        series: series,
                        minute: Double(point.minute),
                        value: point.value * factor,
                        isIncluded: curve.isIncluded,
                        isLatest: curve.isLatest
                    ))
                }
            }
            return points
        }

        var body: some View {
            Chart {
                targetRange
                bands
                lines
                median
                RuleMark(x: .value("Meal", 0.0))
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            .chartXScale(domain: -30.0 ... Double(endMinute))
            .chartXAxis {
                AxisMarks(values: xTicks) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        Text(hourLabel(value.as(Double.self) ?? 0))
                    }
                }
            }
            .chartYAxisLabel(yAxisLabel)
        }

        private var xTicks: [Double] {
            Array(Swift.stride(from: 0.0, through: Double(endMinute), by: 60.0))
        }

        private var yAxisLabel: String {
            summary.scale == .change
                ? String(format: String(localized: "Δ %@", comment: "Meal response y axis: change in glucose"), units.rawValue)
                : units.rawValue
        }

        private func hourLabel(_ minute: Double) -> String {
            String(format: String(localized: "%d h", comment: "Meal response x axis: hours after the meal"), Int(minute / 60))
        }

        @ChartContentBuilder private var targetRange: some ChartContent {
            if summary.scale == .absolute {
                RectangleMark(
                    xStart: .value("From", -30.0),
                    xEnd: .value("To", Double(endMinute)),
                    yStart: .value("Low", Double(FoodFinderPostMealLimits.standard.lowMgdl) * factor),
                    yEnd: .value("High", Double(FoodFinderPostMealLimits.standard.highMgdl) * factor)
                )
                .foregroundStyle(Color.green.opacity(0.08))
            } else {
                RuleMark(y: .value("Start", 0.0))
                    .foregroundStyle(Color.secondary.opacity(0.5))
            }
        }

        @ChartContentBuilder private var bands: some ChartContent {
            ForEach(summary.band, id: \.minute) { point in
                if let p10 = point.p10, let p90 = point.p90 {
                    RectangleMark(
                        xStart: .value("From", Double(point.minute) - 2.5),
                        xEnd: .value("To", Double(point.minute) + 2.5),
                        yStart: .value("P10", p10 * factor),
                        yEnd: .value("P90", p90 * factor)
                    )
                    .foregroundStyle(Color.blue.opacity(0.1))
                }
                RectangleMark(
                    xStart: .value("From", Double(point.minute) - 2.5),
                    xEnd: .value("To", Double(point.minute) + 2.5),
                    yStart: .value("P25", point.p25 * factor),
                    yEnd: .value("P75", point.p75 * factor)
                )
                .foregroundStyle(Color.blue.opacity(0.2))
            }
        }

        @ChartContentBuilder private var lines: some ChartContent {
            ForEach(linePoints) { point in
                LineMark(
                    x: .value("Minutes", point.minute),
                    y: .value("Glucose", point.value),
                    series: .value("Meal", point.series)
                )
                .foregroundStyle(lineColor(point))
                .lineStyle(lineStyle(point))
            }
        }

        @ChartContentBuilder private var median: some ChartContent {
            ForEach(summary.band, id: \.minute) { point in
                LineMark(
                    x: .value("Minutes", Double(point.minute)),
                    y: .value("Glucose", point.median * factor),
                    series: .value("Meal", "median")
                )
                .foregroundStyle(Color.blue)
                .lineStyle(StrokeStyle(lineWidth: 2.5))
            }
        }

        private func lineColor(_ point: LinePoint) -> Color {
            if point.isLatest { return Color.orange }
            switch summary.style {
            case .band: return Color.secondary.opacity(0.35)
            default: return point.isIncluded ? Color.blue.opacity(0.7) : Color.secondary.opacity(0.5)
            }
        }

        private func lineStyle(_ point: LinePoint) -> StrokeStyle {
            let width: CGFloat = point.isLatest ? 2 : (summary.style == .band ? 1 : 1.5)
            return StrokeStyle(lineWidth: width, dash: point.isIncluded ? [] : [3, 3])
        }
    }

    /// Insulin in the four hours after each meal, stacked by source, oldest meal first.
    struct MealResponseInsulinChart: View {
        let bars: [MealResponseSummary.InsulinBar]

        private struct Segment: Identifiable {
            let id: String
            let label: String
            let kind: String
            let units: Double
        }

        private struct Marker: Identifiable {
            let id: String
            let label: String
            let units: Double
        }

        private static let mealBolusKind = String(localized: "Meal bolus", comment: "Meal response insulin: meal bolus")
        private static let smbKind = String(localized: "SMB", comment: "Meal response insulin: SMB")
        private static let tempBasalKind = String(localized: "Temp basal", comment: "Meal response insulin: temp basal above scheduled")
        private static let correctionKind = String(localized: "Correction", comment: "Meal response insulin: manual correction")

        /// Short, unique x labels: the meal date, numbered when a date repeats.
        private var labels: [UUID: String] {
            var seen: [String: Int] = [:]
            var labels: [UUID: String] = [:]
            for bar in bars {
                let base = bar.mealTime.formatted(.dateTime.day().month(.defaultDigits))
                let count = (seen[base] ?? 0) + 1
                seen[base] = count
                labels[bar.id] = count == 1 ? base : "\(base) (\(count))"
            }
            return labels
        }

        private var segments: [Segment] {
            let labels = self.labels
            var segments: [Segment] = []
            for bar in bars {
                let label = labels[bar.id] ?? ""
                let parts: [(String, Double)] = [
                    (Self.mealBolusKind, bar.mealBolus),
                    (Self.smbKind, bar.smb),
                    (Self.tempBasalKind, bar.tempBasalExtra ?? 0),
                    (Self.correctionKind, bar.correction)
                ]
                for part in parts where part.1 != 0 {
                    segments.append(Segment(id: "\(bar.id)-\(part.0)", label: label, kind: part.0, units: part.1))
                }
            }
            return segments
        }

        private var recommendations: [Marker] {
            let labels = self.labels
            return bars.compactMap { bar -> Marker? in
                guard let recommended = bar.recommended else { return nil }
                return Marker(id: "\(bar.id)-recommended", label: labels[bar.id] ?? "", units: recommended)
            }
        }

        private var needs: [Marker] {
            let labels = self.labels
            return bars.compactMap { bar -> Marker? in
                guard let needed = bar.needed else { return nil }
                return Marker(id: "\(bar.id)-needed", label: labels[bar.id] ?? "", units: needed)
            }
        }

        private var lows: [Marker] {
            let labels = self.labels
            return bars.compactMap { bar -> Marker? in
                guard bar.hadLow || bar.hadRescueCarbs else { return nil }
                let top = bar.mealBolus + bar.smb + max(0, bar.tempBasalExtra ?? 0) + bar.correction
                return Marker(id: "\(bar.id)-low", label: labels[bar.id] ?? "", units: top + 0.5)
            }
        }

        var body: some View {
            Chart {
                ForEach(segments) { segment in
                    BarMark(
                        x: .value("Meal", segment.label),
                        y: .value("Units", segment.units)
                    )
                    .foregroundStyle(by: .value("Source", segment.kind))
                }
                ForEach(recommendations) { marker in
                    PointMark(
                        x: .value("Meal", marker.label),
                        y: .value("Units", marker.units)
                    )
                    .symbol(.diamond)
                    .foregroundStyle(Color.primary)
                }
                ForEach(needs) { marker in
                    PointMark(
                        x: .value("Meal", marker.label),
                        y: .value("Units", marker.units)
                    )
                    .symbol(.circle)
                    .foregroundStyle(Color.green)
                }
                ForEach(lows) { marker in
                    PointMark(
                        x: .value("Meal", marker.label),
                        y: .value("Units", marker.units)
                    )
                    .symbol(.triangle)
                    .foregroundStyle(Color.red)
                }
            }
            .chartForegroundStyleScale([
                Self.mealBolusKind: Color.blue,
                Self.smbKind: Color.teal,
                Self.tempBasalKind: Color.purple,
                Self.correctionKind: Color.orange
            ])
            .chartLegend(position: .bottom)
            .chartYAxisLabel("U")
        }
    }
}
