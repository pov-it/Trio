import Foundation

// MARK: - Suggestion History

extension AIInsights {
    /// A record of a suggestion that was applied, including before/after therapy snapshots for revert.
    struct SuggestionHistoryRecord: Identifiable, Codable {
        var id: UUID = UUID()
        let suggestion: Suggestion
        let appliedAt: Date
        let status: Status
        let beforeSnapshot: TherapySnapshot
        let afterSnapshot: TherapySnapshot

        enum Status: String, Codable {
            case applied
            case reverted
            case dismissed
        }
    }

    /// A snapshot of therapy settings at a point in time, for before/after comparison and revert.
    struct TherapySnapshot: Codable {
        let basalProfile: [BasalProfileEntry]
        let isfSensitivity: Decimal
        let carbRatio: Decimal
        let target: Decimal
        let capturedAt: Date
        let insulinSensitivities: InsulinSensitivities?
        let carbRatios: CarbRatios?
        let bgTargets: BGTargets?
    }

    /// Persists and retrieves suggestion history records.
    enum SuggestionHistoryStore {
        private static let key = "ai_insights_suggestion_history"

        static func load() -> [SuggestionHistoryRecord] {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let records = try? JSONDecoder().decode([SuggestionHistoryRecord].self, from: data)
            else { return [] }
            return records
        }

        static func save(_ records: [SuggestionHistoryRecord]) {
            if let data = try? JSONEncoder().encode(records) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }

        static func append(_ record: SuggestionHistoryRecord) {
            var records = load()
            records.insert(record, at: 0)
            // Keep last 50
            save(Array(records.prefix(50)))
        }

        static func updateStatus(for recordId: UUID, to status: SuggestionHistoryRecord.Status) {
            var records = load()
            if let idx = records.firstIndex(where: { $0.id == recordId }) {
                let old = records[idx]
                records[idx] = SuggestionHistoryRecord(
                    id: old.id,
                    suggestion: old.suggestion,
                    appliedAt: old.appliedAt,
                    status: status,
                    beforeSnapshot: old.beforeSnapshot,
                    afterSnapshot: old.afterSnapshot
                )
                save(records)
            }
        }

        static func delete(_ recordId: UUID) {
            var records = load()
            records.removeAll { $0.id == recordId }
            save(records)
        }

        static func clear() {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
