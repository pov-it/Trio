import Foundation

extension AIInsights {
    enum MealResponseScale: String, CaseIterable, Identifiable, Sendable {
        /// Glucose as measured.
        case absolute
        /// Glucose minus the baseline before the meal, so meals that started at different levels line up.
        case change

        var id: String { rawValue }
    }

    /// Which saved meals a response chart pools: the stable meal id of each FoodFinder result (the same for every
    /// time that meal is eaten) and the result ids themselves.
    struct MealResponseKeys: Equatable {
        var mealIDs: Set<UUID>
        var foodResultIDs: Set<UUID>

        init(results: [FoodAnalysisResult]) {
            var mealIDs = Set<UUID>()
            for result in results {
                let key = MealEventIdentity.mealKey(
                    mealName: result.mealName,
                    itemNames: result.items.map(\.name),
                    resultID: result.id
                )
                mealIDs.insert(MealEventIdentity.mealID(forKey: key))
            }
            self.mealIDs = mealIDs
            foodResultIDs = Set(results.map(\.id))
        }
    }

    /// Curves and numbers for one meal, or a group of meals, over the times they were saved from the bolus
    /// calculator. Everything is in mg/dL; the view converts for display.
    struct MealResponseSummary: Equatable, Sendable {
        enum Style: Equatable, Sendable {
            /// No meal with glucose yet.
            case empty
            case single
            /// Two to four meals: individual lines only.
            case lines
            /// Five or more: median with a 25–75 % band, and 10–90 % from ten on.
            case band
        }

        struct Point: Equatable, Sendable {
            var minute: Int
            var value: Double
        }

        struct Curve: Equatable, Identifiable, Sendable {
            var id: UUID
            var mealTime: Date
            var points: [Point]
            /// Counted in the band and the numbers.
            var isIncluded: Bool
            var isLatest: Bool
        }

        struct BandPoint: Equatable, Sendable {
            var minute: Int
            var count: Int
            var median: Double
            var p25: Double
            var p75: Double
            var p10: Double?
            var p90: Double?
        }

        /// Why meals were left out of the band and the numbers. One meal can have several reasons.
        struct LeftOut: Equatable, Sendable {
            var mealBefore = 0
            var mealAfter = 0
            var lowCoverage = 0
            var noBaseline = 0

            var isEmpty: Bool { mealBefore == 0 && mealAfter == 0 && lowCoverage == 0 && noBaseline == 0 }
        }

        /// One saved meal's insulin for the insulin chart, oldest first.
        struct InsulinBar: Equatable, Identifiable, Sendable {
            var id: UUID
            var mealTime: Date
            var mealBolus: Double
            var smb: Double
            var tempBasalExtra: Double?
            var correction: Double
            var recommended: Double?
            /// Estimated insulin the meal took (`MealOutcomeNeed`).
            var needed: Double?
            var hadLow: Bool
            var hadRescueCarbs: Bool
            var isIncluded: Bool
        }

        static let bandMinimum = 5
        static let wideBandMinimum = 10

        var scale: MealResponseScale
        /// Saved meals with glucose.
        var totalCount: Int
        /// Meals in the band and the numbers.
        var includedCount: Int
        var leftOut: LeftOut
        var style: Style
        var curves: [Curve]
        var band: [BandPoint]
        var insulin: [InsulinBar]
        var firstMealTime: Date?
        var lastMealTime: Date?

        // Over the included meals.
        var medianRise: Double?
        var medianPeakMinute: Int?
        var medianInRange0to4h: Int?
        var lowCount: Int
        var rescueCount: Int
        var correctionCount: Int
        var medianCorrectionUnits: Double?
        var medianMealBolus: Double?
        var medianSMB: Double?
        var medianTempBasalExtra: Double?

        /// Included meals with an estimate of the insulin they took.
        var needCount: Int = 0
        var medianNeeded: Double?
        var neededP25: Double?
        var neededP75: Double?
        var medianMealFactor: Double?
        var medianUnitsPer10g: Double?

        /// The estimate for `carbs` grams at the median units per 10 g; nil below `needMinimum` meals.
        func neededEstimate(forCarbs carbs: Double) -> Double? {
            guard needCount >= Self.needMinimum, let perTen = medianUnitsPer10g, carbs > 0 else { return nil }
            return perTen * carbs / 10
        }

        /// Meals needed before an estimate for a new portion is shown.
        static let needMinimum = 5

        static func make(
            analyses: [MealEventAnalysis],
            scale: MealResponseScale,
            includeDisturbed: Bool,
            fromMinute: Int = -30,
            throughMinute: Int = 240
        ) -> MealResponseSummary {
            let withGlucose = analyses
                .filter { !$0.curve.points(from: fromMinute, through: throughMinute).isEmpty }
                .sorted { $0.event.mealTime < $1.event.mealTime }
            let latestID = withGlucose.last?.id

            var leftOut = LeftOut()
            var curves: [Curve] = []
            var included: [MealEventAnalysis] = []
            for analysis in withGlucose {
                let flags = analysis.outcome.flags
                let baseline = analysis.outcome.baselineMgdl
                var isIncluded = includeDisturbed || flags.isUndisturbed
                if !includeDisturbed {
                    if flags.mealBefore { leftOut.mealBefore += 1 }
                    if flags.mealAfter { leftOut.mealAfter += 1 }
                    if flags.lowCoverage { leftOut.lowCoverage += 1 }
                }
                if scale == .change, baseline == nil {
                    isIncluded = false
                    leftOut.noBaseline += 1
                }
                let points = analysis.curve.points(from: fromMinute, through: throughMinute).compactMap { point -> Point? in
                    switch scale {
                    case .absolute:
                        return Point(minute: point.minute, value: Double(point.mgdl))
                    case .change:
                        guard let baseline else { return nil }
                        return Point(minute: point.minute, value: Double(point.mgdl) - baseline)
                    }
                }
                guard !points.isEmpty else { continue }
                curves.append(Curve(
                    id: analysis.id,
                    mealTime: analysis.event.mealTime,
                    points: points,
                    isIncluded: isIncluded,
                    isLatest: analysis.id == latestID
                ))
                if isIncluded {
                    included.append(analysis)
                }
            }

            let includedCurves = curves.filter(\.isIncluded)
            let style: Style
            switch includedCurves.count {
            case 0: style = curves.isEmpty ? .empty : .lines
            case 1: style = curves.count == 1 ? .single : .lines
            case 2 ..< bandMinimum: style = .lines
            default: style = .band
            }

            let outcomes: [MealOutcome] = included.map(\.outcome)
            let includedIDs = Set(included.map(\.id))
            let corrections = outcomes.filter(\.hadCorrection)
            var bars: [InsulinBar] = []
            for analysis in withGlucose {
                let insulin = analysis.outcome.insulin
                bars.append(InsulinBar(
                    id: analysis.id,
                    mealTime: analysis.event.mealTime,
                    mealBolus: insulin.mealBolusUnits,
                    smb: insulin.smbUnits,
                    tempBasalExtra: insulin.tempBasalExtraUnits,
                    correction: insulin.correctionUnits,
                    recommended: insulin.recommendedUnits,
                    needed: analysis.outcome.need?.neededUnits,
                    hadLow: analysis.outcome.hadLow,
                    hadRescueCarbs: analysis.outcome.hadRescueCarbs,
                    isIncluded: includedIDs.contains(analysis.id)
                ))
            }
            let bandPoints: [BandPoint] = style == .band
                ? Self.band(includedCurves, wide: includedCurves.count >= wideBandMinimum)
                : []
            let peakMinutes: [Double] = outcomes.compactMap { $0.peakMinute.map { Double($0) } }
            let inRange: [Double] = outcomes.compactMap { $0.window(0, 240)?.inRangePercent.map { Double($0) } }
            let medianPeak: Int? = median(peakMinutes).map { Int($0.rounded()) }
            let medianInRange: Int? = median(inRange).map { Int($0.rounded()) }
            let needs: [MealOutcomeNeed] = outcomes.compactMap(\.need)
            let neededSorted: [Double] = needs.map(\.neededUnits).sorted()

            return MealResponseSummary(
                scale: scale,
                totalCount: curves.count,
                includedCount: includedCurves.count,
                leftOut: leftOut,
                style: style,
                curves: curves,
                band: bandPoints,
                insulin: bars,
                firstMealTime: withGlucose.first?.event.mealTime,
                lastMealTime: withGlucose.last?.event.mealTime,
                medianRise: median(outcomes.compactMap(\.riseMgdl)),
                medianPeakMinute: medianPeak,
                medianInRange0to4h: medianInRange,
                lowCount: outcomes.filter(\.hadLow).count,
                rescueCount: outcomes.filter(\.hadRescueCarbs).count,
                correctionCount: corrections.count,
                medianCorrectionUnits: median(corrections.map(\.insulin.correctionUnits)),
                medianMealBolus: median(outcomes.map(\.insulin.mealBolusUnits)),
                medianSMB: median(outcomes.map(\.insulin.smbUnits)),
                medianTempBasalExtra: median(outcomes.compactMap(\.insulin.tempBasalExtraUnits)),
                needCount: needs.count,
                medianNeeded: median(neededSorted),
                neededP25: neededSorted.isEmpty ? nil : percentile(neededSorted, 0.25),
                neededP75: neededSorted.isEmpty ? nil : percentile(neededSorted, 0.75),
                medianMealFactor: median(needs.compactMap(\.mealFactor)),
                medianUnitsPer10g: median(needs.compactMap(\.unitsPer10g))
            )
        }

        /// Percentiles per grid minute, only where at least `bandMinimum` curves have a value.
        static func band(_ curves: [Curve], wide: Bool) -> [BandPoint] {
            var byMinute: [Int: [Double]] = [:]
            for curve in curves {
                for point in curve.points {
                    byMinute[point.minute, default: []].append(point.value)
                }
            }
            return byMinute.keys.sorted().compactMap { minute -> BandPoint? in
                guard let values = byMinute[minute], values.count >= bandMinimum else { return nil }
                let sorted = values.sorted()
                let isWide = wide && sorted.count >= wideBandMinimum
                return BandPoint(
                    minute: minute,
                    count: sorted.count,
                    median: percentile(sorted, 0.5),
                    p25: percentile(sorted, 0.25),
                    p75: percentile(sorted, 0.75),
                    p10: isWide ? percentile(sorted, 0.1) : nil,
                    p90: isWide ? percentile(sorted, 0.9) : nil
                )
            }
        }

        /// Linear interpolation between the closest ranks; `sorted` must be ascending and not empty.
        static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
            guard sorted.count > 1 else { return sorted.first ?? 0 }
            let position = fraction * Double(sorted.count - 1)
            let lower = Int(position.rounded(.down))
            let upper = min(lower + 1, sorted.count - 1)
            let weight = position - Double(lower)
            return sorted[lower] + (sorted[upper] - sorted[lower]) * weight
        }

        static func median(_ values: [Double]) -> Double? {
            guard !values.isEmpty else { return nil }
            return percentile(values.sorted(), 0.5)
        }
    }
}
