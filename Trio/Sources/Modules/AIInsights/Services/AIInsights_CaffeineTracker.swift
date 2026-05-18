//
//  AIInsights_CaffeineTracker.swift
//  Trio
//
//  Caffeine intake log + half-life decay model + AI prompt context.
//  Ported from Loop PowerPack (LoopInsights_CaffeineTracker.swift) by Taylor Patterson,
//  adapted to Trio. UserDefaults-backed manual entries + optional HealthKit
//  dietary-caffeine merge.
//

import Combine
import Foundation
import HealthKit

// MARK: - Models

struct AIInsightsCaffeineEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let timestamp: Date
    let milligrams: Double
    let source: String
    /// True when this entry was pulled from HealthKit rather than logged in-app.
    /// Not persisted: HealthKit entries are merged on demand and rebuilt each sync.
    var isFromHealthKit: Bool = false

    init(id: UUID = UUID(), timestamp: Date = Date(), milligrams: Double, source: String, isFromHealthKit: Bool = false) {
        self.id = id
        self.timestamp = timestamp
        self.milligrams = milligrams
        self.source = source
        self.isFromHealthKit = isFromHealthKit
    }

    enum CodingKeys: String, CodingKey {
        case id, timestamp, milligrams, source
    }
}

struct AIInsightsCaffeineState: Equatable {
    let currentLevelMg: Double
    let peakLevelToday: Double
    let lastIntakeTime: Date?
    let entriesLast24h: Int
    let totalMgLast24h: Double

    static let zero = AIInsightsCaffeineState(
        currentLevelMg: 0,
        peakLevelToday: 0,
        lastIntakeTime: nil,
        entriesLast24h: 0,
        totalMgLast24h: 0
    )
}

struct AIInsightsCaffeinePreset: Identifiable {
    let id = UUID()
    let name: String
    let icon: String
    let milligrams: Double

    static let defaults: [AIInsightsCaffeinePreset] = [
        .init(name: String(localized: "Espresso", comment: "Caffeine preset"), icon: "☕️", milligrams: 64),
        .init(name: String(localized: "Coffee (cup)", comment: "Caffeine preset"), icon: "☕️", milligrams: 95),
        .init(name: String(localized: "Cold Brew", comment: "Caffeine preset"), icon: "🧊", milligrams: 200),
        .init(name: String(localized: "Black Tea", comment: "Caffeine preset"), icon: "🍵", milligrams: 47),
        .init(name: String(localized: "Green Tea", comment: "Caffeine preset"), icon: "🍵", milligrams: 28),
        .init(name: String(localized: "Energy Drink", comment: "Caffeine preset"), icon: "⚡️", milligrams: 80),
        .init(name: String(localized: "Soda (cola)", comment: "Caffeine preset"), icon: "🥤", milligrams: 34),
        .init(name: String(localized: "Dark Chocolate", comment: "Caffeine preset"), icon: "🍫", milligrams: 24)
    ]
}

// MARK: - HealthKit bridge

/// Thin wrapper around HKHealthStore so the tracker can pull dietaryCaffeine without
/// taking on the full HealthKitManager injection chain. Read-only.
final class AIInsightsCaffeineHealthKitBridge {
    static let shared = AIInsightsCaffeineHealthKitBridge()

    private let store = HKHealthStore()

    /// `HKQuantityType.quantityType(forIdentifier: .dietaryCaffeine)!` — guaranteed
    /// non-nil per Apple's HealthKit type registry.
    private let caffeineType = HKQuantityType.quantityType(forIdentifier: .dietaryCaffeine)!

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func authorizationStatus() -> HKAuthorizationStatus {
        store.authorizationStatus(for: caffeineType)
    }

    /// Request read-only authorization. Apple returns the same `success` payload regardless
    /// of whether the user granted read access (privacy preserving) — caller should treat
    /// "no data returned" the same as "permission denied".
    func requestAuthorization() async throws {
        guard isAvailable else { return }
        try await store.requestAuthorization(toShare: [], read: [caffeineType])
    }

    /// Fetch `dietaryCaffeine` samples between `start` and `end`. Returns Trio-native entries
    /// flagged as HealthKit-sourced.
    func fetchEntries(start: Date, end: Date) async throws -> [AIInsightsCaffeineEntry] {
        guard isAvailable else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: caffeineType,
                predicate: predicate,
                limit: 200,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let quantitySamples = (samples as? [HKQuantitySample]) ?? []
                let mapped: [AIInsightsCaffeineEntry] = quantitySamples.map { sample in
                    let mg = sample.quantity.doubleValue(for: .gramUnit(with: .milli))
                    let source = sample.sourceRevision.source.name
                    return AIInsightsCaffeineEntry(
                        id: sample.uuid,
                        timestamp: sample.startDate,
                        milligrams: mg,
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

/// Tracks caffeine intake with half-life decay model and provides prompt context.
/// Manual entries persisted in UserDefaults. Optional HealthKit dietary caffeine
/// is merged in-memory on `syncFromHealthKit()`. 5.7-hour half-life. Auto-prune at 48h.
final class AIInsights_CaffeineTracker: ObservableObject, @unchecked Sendable {
    static let shared = AIInsights_CaffeineTracker()

    private static let halfLife: TimeInterval = 5.7 * 3600
    private static let storageKey = "AIInsights_caffeineEntries"
    private static let retention: TimeInterval = 48 * 3600

    /// Combined manual + HealthKit, sorted descending by timestamp.
    @Published private(set) var entries: [AIInsightsCaffeineEntry] = []

    private var healthKitEntries: [AIInsightsCaffeineEntry] = []

    private init() {
        rebuildMergedEntries()
    }

    // MARK: - Public API

    func logCaffeine(milligrams: Double, source: String, at timestamp: Date = Date()) {
        var manual = loadManualEntries()
        manual.append(AIInsightsCaffeineEntry(timestamp: timestamp, milligrams: milligrams, source: source))
        saveManualEntries(manual)
        rebuildMergedEntries()
    }

    func removeEntry(_ entry: AIInsightsCaffeineEntry) {
        guard !entry.isFromHealthKit else { return }
        var manual = loadManualEntries()
        manual.removeAll { $0.id == entry.id }
        saveManualEntries(manual)
        rebuildMergedEntries()
    }

    func updateEntry(id: UUID, milligrams: Double, source: String, timestamp: Date) {
        var manual = loadManualEntries()
        guard let idx = manual.firstIndex(where: { $0.id == id }) else { return }
        manual[idx] = AIInsightsCaffeineEntry(id: id, timestamp: timestamp, milligrams: milligrams, source: source)
        saveManualEntries(manual)
        rebuildMergedEntries()
    }

    func clearAllManualEntries() {
        saveManualEntries([])
        rebuildMergedEntries()
    }

    // MARK: - HealthKit Integration

    /// Refresh HealthKit-sourced entries and merge. Caller is responsible for permission
    /// state; this method silently no-ops on auth failure (HealthKit doesn't tell us
    /// whether read access was granted).
    @MainActor
    func syncFromHealthKit() async {
        let bridge = AIInsightsCaffeineHealthKitBridge.shared
        guard bridge.isAvailable else { return }
        do {
            let start = Date().addingTimeInterval(-Self.retention)
            let fetched = try await bridge.fetchEntries(start: start, end: Date())
            healthKitEntries = fetched
            rebuildMergedEntries()
        } catch {
            // Silent — HealthKit returns errors for many benign cases (no permission, etc.)
        }
    }

    // MARK: - State derivation

    func currentState(at now: Date = Date()) -> AIInsightsCaffeineState {
        var currentLevel: Double = 0
        var peakToday: Double = 0
        var totalLast24h: Double = 0
        var entriesLast24h = 0
        var lastIntake: Date?

        let twentyFourHoursAgo = now.addingTimeInterval(-24 * 3600)
        let startOfToday = Calendar.current.startOfDay(for: now)

        for entry in entries {
            let elapsed = now.timeIntervalSince(entry.timestamp)
            guard elapsed >= 0 else { continue }

            let remaining = entry.milligrams * pow(0.5, elapsed / Self.halfLife)
            if remaining > 0.1 {
                currentLevel += remaining
            }

            if entry.timestamp >= twentyFourHoursAgo {
                totalLast24h += entry.milligrams
                entriesLast24h += 1
            }

            if lastIntake == nil || entry.timestamp > (lastIntake ?? .distantPast) {
                lastIntake = entry.timestamp
            }

            if entry.timestamp >= startOfToday {
                var levelAtEntry: Double = 0
                for other in entries where other.timestamp <= entry.timestamp {
                    let otherElapsed = entry.timestamp.timeIntervalSince(other.timestamp)
                    levelAtEntry += other.milligrams * pow(0.5, otherElapsed / Self.halfLife)
                }
                peakToday = max(peakToday, levelAtEntry)
            }
        }

        return AIInsightsCaffeineState(
            currentLevelMg: currentLevel,
            peakLevelToday: peakToday,
            lastIntakeTime: lastIntake,
            entriesLast24h: entriesLast24h,
            totalMgLast24h: totalLast24h
        )
    }

    // MARK: - Prompt Context

    func buildCaffeinePromptContext(at now: Date = Date()) -> String {
        let state = currentState(at: now)
        guard state.entriesLast24h > 0 else { return "" }

        var ctx = "## Caffeine Intake\n"
        ctx += "- Current estimated caffeine level: \(String(format: "%.0f", state.currentLevelMg)) mg\n"
        ctx += "- Total caffeine last 24h: \(String(format: "%.0f", state.totalMgLast24h)) mg (\(state.entriesLast24h) intake(s))\n"
        if let lastTime = state.lastIntakeTime {
            let minutesAgo = Int(now.timeIntervalSince(lastTime) / 60)
            if minutesAgo < 60 {
                ctx += "- Last intake: \(minutesAgo) minutes ago\n"
            } else {
                ctx += "- Last intake: \(minutesAgo / 60)h \(minutesAgo % 60)m ago\n"
            }
        }
        ctx += "- Peak caffeine level today: \(String(format: "%.0f", state.peakLevelToday)) mg\n"

        if state.currentLevelMg > 200 {
            ctx += "** HIGH CAFFEINE: Current level >200mg can reduce insulin sensitivity by 15-30% in T1D (elevated cortisol + adrenaline), often producing slow post-meal glucose rises 30-90min after intake. **\n"
        } else if state.currentLevelMg > 100 {
            ctx += "** MODERATE CAFFEINE: May modestly raise glucose and blunt insulin response, especially with meals taken within the next 2-3h. **\n"
        }

        let recent = entries.filter { $0.timestamp >= now.addingTimeInterval(-24 * 3600) }
        if !recent.isEmpty {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            ctx += "- Recent entries: "
            ctx += recent.prefix(5)
                .map { "\(formatter.string(from: $0.timestamp)) \($0.source) (\(String(format: "%.0f", $0.milligrams))mg)" }
                .joined(separator: "; ")
            ctx += "\n"
        }

        return ctx
    }

    // MARK: - Persistence

    private func rebuildMergedEntries() {
        var merged = loadManualEntries()
        // Deduplicate HealthKit entries that nearly match a manual one (±60s, same mg)
        // so manual logs aren't shadowed when Apple Health later picks them up.
        let manualTimestamps = merged.map { ($0.timestamp, $0.milligrams) }
        let dedupedHK = healthKitEntries.filter { hk in
            !manualTimestamps.contains { manual in
                abs(manual.0.timeIntervalSince(hk.timestamp)) < 60 && abs(manual.1 - hk.milligrams) < 1
            }
        }
        merged.append(contentsOf: dedupedHK)
        merged.sort { $0.timestamp > $1.timestamp }

        DispatchQueue.main.async {
            self.entries = merged
        }
    }

    private func loadManualEntries() -> [AIInsightsCaffeineEntry] {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([AIInsightsCaffeineEntry].self, from: data)
        else {
            return []
        }
        let cutoff = Date().addingTimeInterval(-Self.retention)
        return decoded.filter { $0.timestamp >= cutoff }
    }

    private func saveManualEntries(_ manual: [AIInsightsCaffeineEntry]) {
        let cutoff = Date().addingTimeInterval(-Self.retention)
        let pruned = manual.filter { $0.timestamp >= cutoff && !$0.isFromHealthKit }
        if let data = try? JSONEncoder().encode(pruned) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
