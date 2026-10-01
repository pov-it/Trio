import Foundation

extension AIInsights {
    /// One JSON file of `MealEvent`s under Application Support, outside Trio's Core Data model and its 90-day purge.
    ///
    /// A file that cannot be decoded is moved aside rather than overwritten, events that no longer decode are
    /// dropped only after a backup copy is made, and a file written by a newer schema is never modified.
    struct MealEventStore: Sendable {
        struct Loaded: Equatable {
            var events: [MealEvent]
            var isReadOnly: Bool
            var note: String?
        }

        static let schemaVersion = 1
        static let retention: TimeInterval = 730 * 24 * 60 * 60
        static let maxEvents = 3000
        static let directoryName = "FoodFinderMealEvents"
        static let fileName = "meal-events.json"

        let fileURL: URL

        init(directory: URL) {
            fileURL = directory.appendingPathComponent(Self.fileName)
        }

        static func applicationSupport() -> MealEventStore {
            let fileManager = FileManager.default
            let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            return MealEventStore(directory: base.appendingPathComponent(directoryName, isDirectory: true))
        }

        /// Throws only when an existing file cannot be read, so that nothing overwrites it.
        func load() throws -> Loaded {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                return Loaded(events: [], isReadOnly: false, note: nil)
            }
            let data = try Data(contentsOf: fileURL)
            let decoder = Self.makeDecoder()

            guard let header = try? decoder.decode(Header.self, from: data) else {
                return try setAsideUnreadableFile()
            }
            let lossy = try? decoder.decode(LossyFile.self, from: data)
            let events = lossy?.events.compactMap(\.event) ?? []

            if header.schemaVersion > Self.schemaVersion {
                return Loaded(
                    events: events,
                    isReadOnly: true,
                    note: "FoodFinder meal events: schema \(header.schemaVersion) is newer than \(Self.schemaVersion), read-only"
                )
            }
            guard let lossy else {
                return try setAsideUnreadableFile()
            }

            let dropped = lossy.events.count - events.count
            guard dropped > 0 else {
                return Loaded(events: events, isReadOnly: false, note: nil)
            }
            let backup = try copyAside(label: "backup")
            return Loaded(
                events: events,
                isReadOnly: false,
                note: "FoodFinder meal events: dropped \(dropped) unreadable events, original kept as \(backup.lastPathComponent)"
            )
        }

        func save(_ events: [MealEvent]) throws {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try Self.makeEncoder().encode(File(schemaVersion: Self.schemaVersion, events: events))
            #if os(iOS)
                try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
                try data.write(to: fileURL, options: .atomic)
            #endif
        }

        /// Keeps events from the last `retention`, and at most the newest `maxEvents`, in recorded order.
        static func pruned(_ events: [MealEvent], now: Date) -> [MealEvent] {
            let cutoff = now.addingTimeInterval(-retention)
            let kept = events
                .filter { $0.recordedAt >= cutoff || $0.mealTime >= cutoff }
                .sorted { $0.recordedAt < $1.recordedAt }
            return Array(kept.suffix(maxEvents))
        }

        static func makeEncoder() -> JSONEncoder {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            encoder.outputFormatting = [.sortedKeys]
            return encoder
        }

        static func makeDecoder() -> JSONDecoder {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            return decoder
        }

        private func setAsideUnreadableFile() throws -> Loaded {
            let moved = try moveAside(label: "unreadable")
            return Loaded(
                events: [],
                isReadOnly: false,
                note: "FoodFinder meal events: unreadable file moved to \(moved.lastPathComponent)"
            )
        }

        private func asideURL(label: String) -> URL {
            let stamp = "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))"
            return fileURL.deletingLastPathComponent().appendingPathComponent("meal-events.\(label)-\(stamp).json")
        }

        private func moveAside(label: String) throws -> URL {
            let target = asideURL(label: label)
            try FileManager.default.moveItem(at: fileURL, to: target)
            return target
        }

        private func copyAside(label: String) throws -> URL {
            let target = asideURL(label: label)
            try FileManager.default.copyItem(at: fileURL, to: target)
            return target
        }

        private struct File: Encodable {
            var schemaVersion: Int
            var events: [MealEvent]
        }

        private struct Header: Decodable {
            var schemaVersion: Int
        }

        private struct LossyFile: Decodable {
            var events: [LossyEvent]
        }

        private struct LossyEvent: Decodable {
            var event: MealEvent?

            init(from decoder: Decoder) throws {
                event = try? MealEvent(from: decoder)
            }
        }
    }
}
