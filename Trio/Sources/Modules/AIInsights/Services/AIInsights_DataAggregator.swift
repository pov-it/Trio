import Foundation

// MARK: - Data Aggregator

/// Reads Trio stores → aggregated statistics for AI analysis.
/// This is the data bridge between Trio's data layer and the AI service.
extension AIInsights {
    struct AggregatedStats {
        let periodDays: Int
        let startDate: Date
        let endDate: Date

        // Glucose stats
        let glucoseReadings: [GlucosePoint]
        let averageGlucose: Double
        let glucoseStdDev: Double
        let tir: TIRStats
        let gmi: Double

        // Insulin stats
        let totalInsulin: Double
        let averageDailyInsulin: Double
        let basalPercentage: Double
        let bolusPercentage: Double
        let tdd: Double

        // Carb stats
        let totalCarbs: Double
        let averageDailyCarbs: Double
        let carbEntries: Int

        // Pattern detection
        let hourlyGlucoseAverage: [HourlyGlucose]
        let detectedPatterns: [DetectedPattern]

        // Current settings context
        let currentBasalProfile: String
        let currentISF: String
        let currentCR: String
        let currentTarget: String

        // Live status
        let currentIOB: Double?
        let currentCOB: Double?
        let currentGlucose: Double?
        let currentDirection: String?
    }

    struct GlucosePoint {
        let date: Date
        let glucose: Double
        let direction: String?
    }

    struct TIRStats {
        let timeBelowLow: Double // % below low threshold
        let timeBelowTarget: Double // % below target
        let timeInRange: Double // % between low and high
        let timeAboveTarget: Double // % above target
        let timeAboveHigh: Double // % above high threshold
    }

    struct HourlyGlucose {
        let hour: Int
        let average: Double
        let min: Double
        let max: Double
        let count: Int
    }

    enum DetectedPattern: String {
        case dawnPhenomenon = "Dawn Phenomenon"
        case overnightLow = "Overnight Low"
        case postMealSpike = "Post-Meal Spike"
        case highVariability = "High Variability"
        case consistentHigh = "Consistent High"
        case consistentLow = "Consistent Low"
        case exerciseResponse = "Exercise Response"
        case noSignificantPattern = "No Significant Pattern"
    }

    // MARK: - Aggregator Logic

    enum DataAggregator {
        /// Compute aggregated stats from raw glucose, insulin, and carb data.
        static func aggregate(
            glucose: [BloodGlucose],
            carbs: [CarbsEntry],
            basalProfile: [BasalProfileEntry],
            isf: Decimal,
            cr: Decimal,
            target: Decimal,
            units: GlucoseUnits,
            iob: Double?,
            cob: Double?,
            periodDays: Int,
            lowThreshold: Decimal,
            highThreshold: Decimal
        ) -> AggregatedStats {
            let endDate = Date()
            let startDate = endDate.addingTimeInterval(-Double(periodDays) * 24 * 3600)

            // Filter glucose to period
            let filteredGlucose = glucose.filter { gl ->
                Bool in
                guard let date = gl.dateString else { return false }
                return date >= startDate && date <= endDate
            }

            // Build glucose points
            let glucosePoints = filteredGlucose.compactMap { gl -> GlucosePoint? in
                guard let sgv = gl.sgv, let date = gl.dateString else { return nil }
                let glucoseValue = units == .mmolL ? Double(Decimal(sgv).asMmolL) : Double(sgv)
                return GlucosePoint(
                    date: date,
                    glucose: glucoseValue,
                    direction: gl.direction?.rawValue
                )
            }

            // Compute averages
            let glucoseValues = glucosePoints.map { $0.glucose }
            let averageGlucose = glucoseValues.isEmpty ? 0 : glucoseValues.reduce(0, +) / Double(glucoseValues.count)
            let glucoseStdDev = glucoseValues.isEmpty ? 0 : standardDeviation(glucoseValues)

            // TIR calculation
            let lowThresholdDouble = units == .mmolL ? Double(lowThreshold.asMmolL) : Double(lowThreshold)
            let highThresholdDouble = units == .mmolL ? Double(highThreshold.asMmolL) : Double(highThreshold)
            let targetDouble = units == .mmolL ? Double(target.asMmolL) : Double(target)

            let tir = computeTIR(
                values: glucoseValues,
                low: lowThresholdDouble,
                target: targetDouble,
                high: highThresholdDouble
            )

            // GMI (Glucose Management Indicator)
            let gmi = computeGMI(averageGlucose: averageGlucose, units: units)

            // Hourly averages
            let hourlyGlucose = computeHourlyAverages(glucosePoints)

            // Pattern detection
            let patterns = detectPatterns(hourlyGlucose: hourlyGlucose, tir: tir, stdDev: glucoseStdDev)

            // Carb stats
            let totalCarbs = carbs.reduce(0.0) { sum, entry in sum + Double(entry.carbs) }
            let averageDailyCarbs = periodDays > 0 ? totalCarbs / Double(periodDays) : 0

            // Format current settings
            let currentBasalProfile = formatBasalProfile(basalProfile)
            let currentISF = formatISF(isf, units: units)
            let currentCR = "\(cr)"
            let currentTarget = formatTarget(target, units: units)

            // Current glucose
            let currentGlucose = glucosePoints.last?.glucose
            let currentDirection = glucosePoints.last?.direction

            return AggregatedStats(
                periodDays: periodDays,
                startDate: startDate,
                endDate: endDate,
                glucoseReadings: glucosePoints,
                averageGlucose: averageGlucose,
                glucoseStdDev: glucoseStdDev,
                tir: tir,
                gmi: gmi,
                totalInsulin: 0, // Would need dose data
                averageDailyInsulin: 0,
                basalPercentage: 0,
                bolusPercentage: 0,
                tdd: 0,
                totalCarbs: totalCarbs,
                averageDailyCarbs: averageDailyCarbs,
                carbEntries: carbs.count,
                hourlyGlucoseAverage: hourlyGlucose,
                detectedPatterns: patterns,
                currentBasalProfile: currentBasalProfile,
                currentISF: currentISF,
                currentCR: currentCR,
                currentTarget: currentTarget,
                currentIOB: iob,
                currentCOB: cob,
                currentGlucose: currentGlucose,
                currentDirection: currentDirection
            )
        }

        // MARK: - Stats Computation

        private static func computeTIR(values: [Double], low: Double, target: Double, high: Double) -> TIRStats {
            guard !values.isEmpty else {
                return TIRStats(timeBelowLow: 0, timeBelowTarget: 0, timeInRange: 0, timeAboveTarget: 0, timeAboveHigh: 0)
            }
            let total = Double(values.count)
            let belowLow = Double(values.filter { $0 < low }.count)
            let belowTarget = Double(values.filter { $0 >= low && $0 < target }.count)
            let inRange = Double(values.filter { $0 >= low && $0 <= high }.count)
            let aboveTarget = Double(values.filter { $0 > target && $0 <= high }.count)
            let aboveHigh = Double(values.filter { $0 > high }.count)

            return TIRStats(
                timeBelowLow: belowLow / total * 100,
                timeBelowTarget: belowTarget / total * 100,
                timeInRange: inRange / total * 100,
                timeAboveTarget: aboveTarget / total * 100,
                timeAboveHigh: aboveHigh / total * 100
            )
        }

        private static func computeGMI(averageGlucose: Double, units: GlucoseUnits) -> Double {
            // GMI formula: GMI (%) = 3.31 + 0.02392 × mean glucose (mg/dL)
            // For mmol/L: GMI (%) = 12.71 + 4.70587 × mean glucose (mmol/L)
            if units == .mmolL {
                return 12.71 + 4.70587 * averageGlucose
            } else {
                return 3.31 + 0.02392 * averageGlucose
            }
        }

        private static func computeHourlyAverages(points: [GlucosePoint]) -> [HourlyGlucose] {
            var hourlyData: [Int: [Double]] = [:]
            for point in points {
                let hour = Calendar.current.component(.hour, from: point.date)
                hourlyData[hour, default: []].append(point.glucose)
            }

            return (0 ..< 24).compactMap { hour -> HourlyGlucose? in
                guard let values = hourlyData[hour], !values.isEmpty else { return nil }
                return HourlyGlucose(
                    hour: hour,
                    average: values.reduce(0, +) / Double(values.count),
                    min: values.min() ?? 0,
                    max: values.max() ?? 0,
                    count: values.count
                )
            }.sorted { $0.hour < $1.hour }
        }

        private static func detectPatterns(
            hourlyGlucose: [HourlyGlucose],
            tir: TIRStats,
            stdDev: Double
        ) -> [DetectedPattern] {
            var patterns: [DetectedPattern] = []

            // Dawn phenomenon: 3-7 AM average significantly higher than overnight
            let earlyMorning = hourlyGlucose.filter { $0.hour >= 3 && $0.hour <= 7 }
            let overnight = hourlyGlucose.filter { $0.hour >= 0 && $0.hour <= 2 }
            if let earlyAvg = earlyMorning.map(\.average).mean,
               let nightAvg = overnight.map(\.average).mean,
               earlyAvg > nightAvg + 20
            {
                patterns.append(.dawnPhenomenon)
            }

            // Overnight low: average glucose between 0-5 AM below low threshold
            let lateNight = hourlyGlucose.filter { $0.hour >= 0 && $0.hour <= 5 }
            if let nightAvg = lateNight.map(\.average).mean, nightAvg < 70 {
                patterns.append(.overnightLow)
            }

            // High variability
            if stdDev > 50 {
                patterns.append(.highVariability)
            }

            // Consistent high
            if tir.timeAboveHigh > 25 {
                patterns.append(.consistentHigh)
            }

            // Consistent low
            if tir.timeBelowLow > 5 {
                patterns.append(.consistentLow)
            }

            if patterns.isEmpty {
                patterns.append(.noSignificantPattern)
            }

            return patterns
        }

        // MARK: - Formatting Helpers

        private static func formatBasalProfile(_ profile: [BasalProfileEntry]) -> String {
            profile.map { entry in
                "\(entry.start) — \(entry.rate) U/hr"
            }.joined(separator: "\n")
        }

        private static func formatISF(_ isf: Decimal, units: GlucoseUnits) -> String {
            let displayISF = units == .mmolL ? isf.asMmolL : isf
            return "\(displayISF) \(units.rawValue)/U"
        }

        private static func formatTarget(_ target: Decimal, units: GlucoseUnits) -> String {
            let displayTarget = units == .mmolL ? target.asMmolL : target
            return "\(displayTarget) \(units.rawValue)"
        }

        // MARK: - Math Helpers

        private static func standardDeviation(_ values: [Double]) -> Double {
            guard values.count > 1 else { return 0 }
            let mean = values.reduce(0, +) / Double(values.count)
            let variance = values.reduce(0) { sum, val in sum + (val - mean) * (val - mean) } / Double(values.count - 1)
            return sqrt(variance)
        }
    }
}

// MARK: - Array Average Extension

private extension [Double] {
    var mean: Double? {
        guard !isEmpty else { return nil }
        return reduce(0, +) / Double(count)
    }
}