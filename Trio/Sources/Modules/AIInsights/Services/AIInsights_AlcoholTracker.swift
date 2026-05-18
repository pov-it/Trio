//
//  AIInsights_AlcoholTracker.swift
//  Trio
//
//  Alcohol intake log + standard-drink accounting + late-hypo risk window.
//  Pattern mirrors AIInsights_CaffeineTracker.
//
//  Standard drink = 14 g pure alcohol (US). 1 unit (UK) = 8 g; Europe varies.
//  Elimination roughly linear: ~10–15 g/hour (we use 12 g/hr default).
//  Algorithmic significance for T1D:
//    • Alcohol blocks hepatic gluconeogenesis for 4–12h post-consumption,
//      raising hypo risk (especially overnight) even after BG has returned
//      to baseline.
//

import Combine
import Foundation
import HealthKit

// MARK: - Models

struct AIInsightsAlcoholEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let timestamp: Date
    /// Number of standard drinks (US: 14 g pure alcohol each).
    let standardDrinks: Double
    let source: String
    var isFromHealthKit: Bool = false

    init(id: UUID = UUID(), timestamp: Date = Date(), standardDrinks: Double, source: String, isFromHealthKit: Bool = false) {
        self.id = id
        self.timestamp = timestamp
        self.standardDrinks = standardDrinks
        self.source = source
        self.isFromHealthKit = isFromHealthKit
    }

    enum CodingKeys: String, CodingKey {
        case id, timestamp, standardDrinks, source
    }
}

struct AIInsightsAlcoholState: Equatable {
    /// Estimated remaining standard drinks in-system (linear elimination).
    let currentDrinks: Double
    let drinksLast24h: Double
    let entriesLast24h: Int
    let lastIntakeTime: Date?
    /// True if any drinks consumed in the past 12h — late-hypo risk window active.
    let lateHypoRiskActive: Bool

    static let zero = AIInsightsAlcoholState(
        currentDrinks: 0,
        drinksLast24h: 0,
        entriesLast24h: 0,
        lastIntakeTime: nil,
        lateHypoRiskActive: false
    )
}

struct AlcoholBarcodeLookup {
    let name: String
    let volumeMl: Double?
    let abvPercent: Double?
}

struct AIInsightsAlcoholPreset: Identifiable {
    let id = UUID()
    let name: String
    let icon: String
    let standardDrinks: Double

    static let defaults: [AIInsightsAlcoholPreset] = [
        .init(name: String(localized: "Beer (small)", comment: "Alcohol preset"), icon: "🍺", standardDrinks: 1.0),
        .init(name: String(localized: "Beer (pint)", comment: "Alcohol preset"), icon: "🍻", standardDrinks: 1.6),
        .init(name: String(localized: "Wine (glass)", comment: "Alcohol preset"), icon: "🍷", standardDrinks: 1.0),
        .init(name: String(localized: "Sparkling wine", comment: "Alcohol preset"), icon: "🥂", standardDrinks: 1.0),
        .init(name: String(localized: "Spirit (shot)", comment: "Alcohol preset"), icon: "🥃", standardDrinks: 1.0),
        .init(name: String(localized: "Cocktail", comment: "Alcohol preset"), icon: "🍸", standardDrinks: 1.5),
        .init(name: String(localized: "Low-alc beer", comment: "Alcohol preset"), icon: "🍺", standardDrinks: 0.3),
        .init(name: String(localized: "Sake / soju", comment: "Alcohol preset"), icon: "🍶", standardDrinks: 1.0)
    ]
}

// MARK: - HealthKit Bridge

final class AIInsightsAlcoholHealthKitBridge {
    static let shared = AIInsightsAlcoholHealthKitBridge()

    private let store = HKHealthStore()
    private let drinksType = HKQuantityType.quantityType(forIdentifier: .numberOfAlcoholicBeverages)!

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func authorizationStatus() -> HKAuthorizationStatus {
        store.authorizationStatus(for: drinksType)
    }

    func requestAuthorization() async throws {
        guard isAvailable else { return }
        try await store.requestAuthorization(toShare: [], read: [drinksType])
    }

    func fetchEntries(start: Date, end: Date) async throws -> [AIInsightsAlcoholEntry] {
        guard isAvailable else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: drinksType,
                predicate: predicate,
                limit: 200,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let quantitySamples = (samples as? [HKQuantitySample]) ?? []
                let mapped: [AIInsightsAlcoholEntry] = quantitySamples.map { sample in
                    let drinks = sample.quantity.doubleValue(for: .count())
                    let source = sample.sourceRevision.source.name
                    return AIInsightsAlcoholEntry(
                        id: sample.uuid,
                        timestamp: sample.startDate,
                        standardDrinks: drinks,
                        source: source.isEmpty ? "Apple Health" : source,
                        isFromHealthKit: true
                    )
                }
                continuation.resume(returning: mapped)
            }
            store.execute(query)
        }
    }
}

// MARK: - Tracker

final class AIInsights_AlcoholTracker: ObservableObject, @unchecked Sendable {
    static let shared = AIInsights_AlcoholTracker()

    /// Standard drinks eliminated per hour (sober individual, average). Used for
    /// "current drinks remaining" estimate. Real metabolism varies widely.
    private static let drinksPerHour: Double = 12.0 / 14.0

    /// Late-hypo risk window after the last drink: 12 hours.
    private static let lateHypoWindow: TimeInterval = 12 * 3600

    private static let storageKey = "AIInsights_alcoholEntries"
    private static let retention: TimeInterval = 48 * 3600

    @Published private(set) var entries: [AIInsightsAlcoholEntry] = []

    private var healthKitEntries: [AIInsightsAlcoholEntry] = []

    private init() {
        rebuildMergedEntries()
    }

    // MARK: - Public API

    func logDrink(standardDrinks: Double, source: String, at timestamp: Date = Date()) {
        var manual = loadManualEntries()
        manual.append(AIInsightsAlcoholEntry(timestamp: timestamp, standardDrinks: standardDrinks, source: source))
        saveManualEntries(manual)
        rebuildMergedEntries()
    }

    func removeEntry(_ entry: AIInsightsAlcoholEntry) {
        guard !entry.isFromHealthKit else { return }
        var manual = loadManualEntries()
        manual.removeAll { $0.id == entry.id }
        saveManualEntries(manual)
        rebuildMergedEntries()
    }

    func updateEntry(id: UUID, standardDrinks: Double, source: String, timestamp: Date) {
        var manual = loadManualEntries()
        guard let idx = manual.firstIndex(where: { $0.id == id }) else { return }
        manual[idx] = AIInsightsAlcoholEntry(id: id, timestamp: timestamp, standardDrinks: standardDrinks, source: source)
        saveManualEntries(manual)
        rebuildMergedEntries()
    }

    func clearAllManualEntries() {
        saveManualEntries([])
        rebuildMergedEntries()
    }

    // MARK: - Math helpers

    /// Convert "drank volume in ml + ABV %" into US standard drinks.
    /// Formula: ml × (abv/100) × ethanolDensity ÷ 14
    /// where ethanolDensity = 0.789 g/ml, 14 g ethanol = 1 US standard drink.
    static func standardDrinks(volumeMl: Double, abvPercent: Double) -> Double {
        let ethanolGrams = volumeMl * (abvPercent / 100.0) * 0.789
        return ethanolGrams / 14.0
    }

    // MARK: - Barcode lookup (OpenFoodFacts)

    /// Looks up a barcode on OpenFoodFacts and tries to extract drink name, serving
    /// volume in ml, and ABV %. Returns nil for any field that cannot be resolved.
    static func lookupBarcode(_ barcode: String, baseURL: String) async -> AlcoholBarcodeLookup? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "https://world.openfoodfacts.org/api/v2" : trimmed
        guard let url = URL(string: "\(base)/product/\(barcode).json?fields=product_name,serving_size,serving_quantity,nutriments") else {
            return nil
        }

        var request = URLRequest(url: url)
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        request.setValue("TrioAIInsights/\(appVersion) (https://github.com/pov-it/Trio)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let product = json["product"] as? [String: Any]
            else {
                return nil
            }

            let name = (product["product_name"] as? String) ?? barcode
            let nutriments = product["nutriments"] as? [String: Any] ?? [:]

            // OFF stores ABV either in `alcohol_value` (%) or `alcohol_100g` (g/100g — convert).
            var abv: Double?
            if let raw = doubleValueAny(nutriments["alcohol_value"]) {
                abv = raw
            } else if let alcoholPer100g = doubleValueAny(nutriments["alcohol_100g"]) {
                // Approx convert grams alcohol per 100 g to % ABV (assumes density ~1 g/ml; close enough for beer/wine.)
                abv = alcoholPer100g / 0.789
            }

            var volumeMl: Double?
            if let raw = doubleValueAny(product["serving_quantity"]) {
                volumeMl = raw
            } else if let str = product["serving_size"] as? String {
                volumeMl = parseMl(from: str)
            }

            return AlcoholBarcodeLookup(name: name, volumeMl: volumeMl, abvPercent: abv)
        } catch {
            return nil
        }
    }

    private static func doubleValueAny(_ value: Any?) -> Double? {
        if let v = value as? Double { return v }
        if let v = value as? Int { return Double(v) }
        if let v = value as? String {
            return Double(v.replacingOccurrences(of: ",", with: "."))
        }
        return nil
    }

    private static func parseMl(from text: String) -> Double? {
        let pattern = #"(\d+(?:[.,]\d+)?)\s*ml"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let valueRange = Range(match.range(at: 1), in: text)
        else { return nil }
        return Double(text[valueRange].replacingOccurrences(of: ",", with: "."))
    }

    // MARK: - HealthKit

    @MainActor
    func syncFromHealthKit() async {
        let bridge = AIInsightsAlcoholHealthKitBridge.shared
        guard bridge.isAvailable else { return }
        do {
            let start = Date().addingTimeInterval(-Self.retention)
            let fetched = try await bridge.fetchEntries(start: start, end: Date())
            healthKitEntries = fetched
            rebuildMergedEntries()
        } catch {
            // Silent
        }
    }

    // MARK: - State

    func currentState(at now: Date = Date()) -> AIInsightsAlcoholState {
        var remaining: Double = 0
        var totalLast24h: Double = 0
        var entriesLast24h = 0
        var lastIntake: Date?

        let twentyFourHoursAgo = now.addingTimeInterval(-24 * 3600)

        for entry in entries {
            let hoursSince = now.timeIntervalSince(entry.timestamp) / 3600
            guard hoursSince >= 0 else { continue }

            let eliminated = Self.drinksPerHour * hoursSince
            let entryRemaining = max(0, entry.standardDrinks - eliminated)
            remaining += entryRemaining

            if entry.timestamp >= twentyFourHoursAgo {
                totalLast24h += entry.standardDrinks
                entriesLast24h += 1
            }

            if lastIntake == nil || entry.timestamp > (lastIntake ?? .distantPast) {
                lastIntake = entry.timestamp
            }
        }

        let lateHypoActive: Bool
        if let last = lastIntake {
            lateHypoActive = now.timeIntervalSince(last) < Self.lateHypoWindow
        } else {
            lateHypoActive = false
        }

        return AIInsightsAlcoholState(
            currentDrinks: remaining,
            drinksLast24h: totalLast24h,
            entriesLast24h: entriesLast24h,
            lastIntakeTime: lastIntake,
            lateHypoRiskActive: lateHypoActive
        )
    }

    // MARK: - Prompt context

    func buildAlcoholPromptContext(at now: Date = Date()) -> String {
        let state = currentState(at: now)
        guard state.entriesLast24h > 0 else { return "" }

        var ctx = "## Alcohol Intake\n"
        ctx += "- Total drinks last 24h: \(formatDrinks(state.drinksLast24h)) (\(state.entriesLast24h) entry/entries)\n"
        ctx += "- Estimated remaining: \(formatDrinks(state.currentDrinks)) standard drinks\n"
        if let lastTime = state.lastIntakeTime {
            let minutesAgo = Int(now.timeIntervalSince(lastTime) / 60)
            if minutesAgo < 60 {
                ctx += "- Last intake: \(minutesAgo) minutes ago\n"
            } else {
                ctx += "- Last intake: \(minutesAgo / 60)h \(minutesAgo % 60)m ago\n"
            }
        }

        if state.lateHypoRiskActive {
            ctx += "** LATE-HYPO RISK: Alcohol consumed within last 12h blocks hepatic gluconeogenesis. Overnight and post-meal hypo risk is elevated. Consider raising target / reducing basal during this window. **\n"
        }

        let recent = entries.filter { $0.timestamp >= now.addingTimeInterval(-24 * 3600) }
        if !recent.isEmpty {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            ctx += "- Recent entries: "
            ctx += recent.prefix(5)
                .map { "\(formatter.string(from: $0.timestamp)) \($0.source) (\(self.formatDrinks($0.standardDrinks)))" }
                .joined(separator: "; ")
            ctx += "\n"
        }

        return ctx
    }

    private func formatDrinks(_ drinks: Double) -> String {
        String(format: "%.1f", drinks)
    }

    // MARK: - Persistence

    private func rebuildMergedEntries() {
        var merged = loadManualEntries()
        let manualKeys = merged.map { ($0.timestamp, $0.standardDrinks) }
        let dedupedHK = healthKitEntries.filter { hk in
            !manualKeys.contains { manual in
                abs(manual.0.timeIntervalSince(hk.timestamp)) < 60 && abs(manual.1 - hk.standardDrinks) < 0.1
            }
        }
        merged.append(contentsOf: dedupedHK)
        merged.sort { $0.timestamp > $1.timestamp }

        DispatchQueue.main.async {
            self.entries = merged
        }
    }

    private func loadManualEntries() -> [AIInsightsAlcoholEntry] {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([AIInsightsAlcoholEntry].self, from: data)
        else {
            return []
        }
        let cutoff = Date().addingTimeInterval(-Self.retention)
        return decoded.filter { $0.timestamp >= cutoff }
    }

    private func saveManualEntries(_ manual: [AIInsightsAlcoholEntry]) {
        let cutoff = Date().addingTimeInterval(-Self.retention)
        let pruned = manual.filter { $0.timestamp >= cutoff && !$0.isFromHealthKit }
        if let data = try? JSONEncoder().encode(pruned) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
