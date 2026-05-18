//
//  AIInsights_CaffeineTracker.swift
//  Trio
//
//  Caffeine intake log + half-life decay model + AI prompt context.
//  Ported from Loop PowerPack (LoopInsights_CaffeineTracker.swift) by Taylor Patterson,
//  adapted to Trio. UserDefaults-backed; HealthKit sync omitted in initial port.
//

import Combine
import Foundation

// MARK: - Models

struct AIInsightsCaffeineEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let timestamp: Date
    let milligrams: Double
    let source: String

    init(id: UUID = UUID(), timestamp: Date = Date(), milligrams: Double, source: String) {
        self.id = id
        self.timestamp = timestamp
        self.milligrams = milligrams
        self.source = source
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
        .init(name: String(localized: "Espresso"), icon: "☕️", milligrams: 64),
        .init(name: String(localized: "Coffee (cup)"), icon: "☕️", milligrams: 95),
        .init(name: String(localized: "Cold Brew"), icon: "🧊", milligrams: 200),
        .init(name: String(localized: "Black Tea"), icon: "🍵", milligrams: 47),
        .init(name: String(localized: "Green Tea"), icon: "🍵", milligrams: 28),
        .init(name: String(localized: "Energy Drink"), icon: "⚡️", milligrams: 80),
        .init(name: String(localized: "Soda (cola)"), icon: "🥤", milligrams: 34),
        .init(name: String(localized: "Dark Chocolate"), icon: "🍫", milligrams: 24)
    ]
}

// MARK: - Tracker

/// Tracks caffeine intake with half-life decay model and provides prompt context.
/// Persisted in UserDefaults. 5.7-hour half-life. Entries auto-pruned after 48 h.
final class AIInsights_CaffeineTracker: ObservableObject {
    static let shared = AIInsights_CaffeineTracker()

    private static let halfLife: TimeInterval = 5.7 * 3600
    private static let storageKey = "AIInsights_caffeineEntries"
    private static let retention: TimeInterval = 48 * 3600

    @Published private(set) var entries: [AIInsightsCaffeineEntry] = []

    private init() {
        entries = loadFromDefaults()
    }

    // MARK: - Public API

    func logCaffeine(milligrams: Double, source: String, at timestamp: Date = Date()) {
        var current = loadFromDefaults()
        current.append(AIInsightsCaffeineEntry(timestamp: timestamp, milligrams: milligrams, source: source))
        save(current)
    }

    func removeEntry(_ entry: AIInsightsCaffeineEntry) {
        var current = loadFromDefaults()
        current.removeAll { $0.id == entry.id }
        save(current)
    }

    func updateEntry(id: UUID, milligrams: Double, source: String, timestamp: Date) {
        var current = loadFromDefaults()
        guard let idx = current.firstIndex(where: { $0.id == id }) else { return }
        current[idx] = AIInsightsCaffeineEntry(id: id, timestamp: timestamp, milligrams: milligrams, source: source)
        save(current)
    }

    func clearAllEntries() {
        save([])
    }

    /// Compute current caffeine state at `now` from all entries.
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

    /// Build prompt-injectable context. Empty string when no recent entries.
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
            ctx += "** HIGH CAFFEINE: Current level >200mg may significantly affect insulin sensitivity and glucose variability **\n"
        } else if state.currentLevelMg > 100 {
            ctx += "** MODERATE CAFFEINE: May influence glucose response, especially post-meal **\n"
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

    private func loadFromDefaults() -> [AIInsightsCaffeineEntry] {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([AIInsightsCaffeineEntry].self, from: data)
        else {
            return []
        }
        let cutoff = Date().addingTimeInterval(-Self.retention)
        return decoded.filter { $0.timestamp >= cutoff }.sorted { $0.timestamp > $1.timestamp }
    }

    private func save(_ entries: [AIInsightsCaffeineEntry]) {
        let cutoff = Date().addingTimeInterval(-Self.retention)
        let pruned = entries.filter { $0.timestamp >= cutoff }
        if let data = try? JSONEncoder().encode(pruned) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
        DispatchQueue.main.async {
            self.entries = pruned.sorted { $0.timestamp > $1.timestamp }
        }
    }
}
