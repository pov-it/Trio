//
//  AIInsights_MealCompanionShare.swift
//  Trio
//
//  Opt-in publisher that can hand a meal-ONLY payload to a companion app
//  (Mayee). Default OFF. Local-first: writes an on-disk outbox and never
//  blocks FoodFinder / gallery archive on network or CloudKit.
//
//  Privacy boundary (enforced in `SharedMealPayload` + `MealSharePrivacy`):
//    ALLOWED: id, date, mealName, thumbnail (bytes or filename), optional carbs
//    FORBIDDEN: glucose, IOB, COB, Nightscout URL/token, pump, insulin, API keys
//
//  The Trio App Group (`trio-app-group` / `$(APP_GROUP_ID)`) is NOT used.
//  A dedicated companion App Group would be registered separately by the
//  Apple Team; until that identifier is configured this publisher stays in
//  Application Support and never copies Nightscout secrets anywhere.
//
//  CloudKit (private DB + CKShare to Mayee) needs Marijn's Apple Team, an
//  iCloud container, and the CloudKit capability on the App ID. This file
//  implements the Trio-side protocol + an offline outbox. The CloudKit
//  transport compiles and no-ops until a container identifier is set.
//  See DeveloperDocs/MealCompanionShare.md.
//

import Foundation
#if canImport(CloudKit)
    import CloudKit
#endif

extension AIInsights {

    // MARK: - Payload (meal-only)

    /// Companion-safe meal record. Codable keys are an explicit allow-list;
    /// do not add therapy, CGM, or Nightscout fields here.
    struct SharedMealPayload: Codable, Equatable, Sendable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let id: UUID
        let date: Date
        let mealName: String?
        let thumbnailFilename: String?
        let carbs: Double?

        enum CodingKeys: String, CodingKey {
            case schemaVersion
            case id
            case date
            case mealName
            case thumbnailFilename
            case carbs
        }

        init(
            id: UUID,
            date: Date,
            mealName: String?,
            thumbnailFilename: String?,
            carbs: Double?,
            schemaVersion: Int = SharedMealPayload.currentSchemaVersion
        ) {
            self.schemaVersion = schemaVersion
            self.id = id
            self.date = date
            self.mealName = mealName
            self.thumbnailFilename = thumbnailFilename
            self.carbs = carbs
        }

        init(item: MealGalleryStore.GalleryItem, includeCarbs: Bool = true) {
            self.init(
                id: item.id,
                date: item.date,
                mealName: item.mealName,
                thumbnailFilename: item.thumbnailFilename,
                carbs: includeCarbs ? item.totalCarbs : nil
            )
        }

        init(result: FoodAnalysisResult, thumbnailFilename: String?, includeCarbs: Bool = true) {
            self.init(
                id: result.id,
                date: result.timestamp,
                mealName: result.mealName,
                thumbnailFilename: thumbnailFilename,
                carbs: includeCarbs ? result.totalCarbs : nil
            )
        }
    }

    /// Static allow / deny lists used before any bytes hit disk or CloudKit.
    enum MealSharePrivacy {
        /// JSON object keys that may appear in a companion payload.
        static let allowedKeys: Set<String> = [
            "schemaVersion",
            "id",
            "date",
            "mealName",
            "thumbnailFilename",
            "carbs"
        ]

        /// JSON object keys that must never appear, even nested.
        static let forbiddenKeys: Set<String> = [
            "glucose", "sgv", "bg", "bloodglucose", "bloodGlucose",
            "iob", "cob", "insulin", "insulinOnBoard", "carbsOnBoard",
            "nightscout", "nightscoutURL", "nightscoutUrl", "nsUrl", "nsurl",
            "token", "secret", "apiKey", "api_key", "accesstoken", "accessToken",
            "pump", "direction", "delta", "predicted", "forecast"
        ]

        static func objectKeys(in json: Any, prefix: String = "") -> [String] {
            if let dict = json as? [String: Any] {
                return dict.flatMap { key, value -> [String] in
                    let path = prefix.isEmpty ? key : "\(prefix).\(key)"
                    return [key] + objectKeys(in: value, prefix: path)
                }
            }
            if let array = json as? [Any] {
                return array.flatMap { objectKeys(in: $0, prefix: prefix) }
            }
            return []
        }

        /// Returns nil when the payload is companion-safe; otherwise a reason.
        static func rejectReason(for payload: SharedMealPayload) -> String? {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(payload),
                  let json = try? JSONSerialization.jsonObject(with: data)
            else {
                return "payload did not encode"
            }
            let keys = Set(objectKeys(in: json))
            if let forbidden = keys.first(where: { forbiddenKeys.contains($0) }) {
                return "forbidden key: \(forbidden)"
            }
            if let extra = keys.first(where: { !allowedKeys.contains($0) }) {
                return "unexpected key: \(extra)"
            }
            return nil
        }
    }

    struct SharedMealRecord: Sendable {
        let payload: SharedMealPayload
        let thumbnailJPEG: Data?
    }

    protocol MealCompanionTransport: Sendable {
        func publish(_ record: SharedMealRecord) async
    }

    // MARK: - Settings (opt-in, default OFF)

    enum MealCompanionShareSettings {
        static let enabledKey = "ai_meal_companion_share_enabled"
        /// Optional CloudKit container, e.g. `iCloud.org.nightscout.<TEAMID>.trio.meals`.
        /// Empty (the default) means the CloudKit transport is a no-op.
        static let cloudKitContainerKey = "ai_meal_companion_cloudkit_container"
        /// Optional companion App Group identifier. MUST NOT be `trio-app-group`.
        /// Empty (the default) means we never touch an App Group suite.
        static let companionAppGroupKey = "ai_meal_companion_app_group"

        /// Hard-coded Trio therapy App Group suffix — never used for meals.
        static let forbiddenTrioAppGroupSuffix = "trio-app-group"

        static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
            defaults.bool(forKey: enabledKey)
        }

        static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
            defaults.set(enabled, forKey: enabledKey)
        }

        static func cloudKitContainerIdentifier(_ defaults: UserDefaults = .standard) -> String {
            (defaults.string(forKey: cloudKitContainerKey) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        static func companionAppGroupIdentifier(_ defaults: UserDefaults = .standard) -> String? {
            let raw = (defaults.string(forKey: companionAppGroupKey) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return nil }
            if raw.lowercased().contains(forbiddenTrioAppGroupSuffix) {
                return nil
            }
            return raw
        }
    }

    // MARK: - Publisher

    final class MealCompanionPublisher: @unchecked Sendable {
        static let shared = MealCompanionPublisher()

        private let defaults: UserDefaults
        private let fileManager: FileManager
        private let overrideOutbox: URL?
        private let ioQueue = DispatchQueue(label: "trio.ai.mealshare.io", qos: .utility)
        private var transports: [any MealCompanionTransport]

        var isShareEnabled: Bool {
            get { MealCompanionShareSettings.isEnabled(defaults) }
            set { MealCompanionShareSettings.setEnabled(newValue, defaults: defaults) }
        }

        convenience init() {
            self.init(defaults: .standard, fileManager: .default, outboxDirectory: nil)
        }

        init(
            defaults: UserDefaults,
            fileManager: FileManager = .default,
            outboxDirectory: URL? = nil,
            transports: [any MealCompanionTransport]? = nil
        ) {
            self.defaults = defaults
            self.fileManager = fileManager
            self.overrideOutbox = outboxDirectory
            if let transports {
                self.transports = transports
            } else {
                let outbox = SharedMealsOutboxTransport(
                    defaults: defaults,
                    fileManager: fileManager,
                    directory: outboxDirectory
                )
                self.transports = [
                    outbox,
                    CloudKitMealShareTransport(defaults: defaults)
                ]
            }
        }

        var outboxDirectoryURL: URL? {
            if let overrideOutbox { return overrideOutbox }
            guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                return nil
            }
            return base.appendingPathComponent("SharedMealsOutbox", isDirectory: true)
        }

        /// Called from gallery archive (has thumbnail) and from FoodFinder
        /// `saveRecentResults` (may not). No-op unless the user opted in.
        /// Never throws into the caller; never includes glucose fields.
        func publish(item: MealGalleryStore.GalleryItem, thumbnailJPEG: Data?) {
            publish(payload: SharedMealPayload(item: item), thumbnailJPEG: thumbnailJPEG)
        }

        func publish(result: FoodAnalysisResult, thumbnailJPEG: Data?) {
            publish(
                payload: SharedMealPayload(result: result, thumbnailFilename: nil),
                thumbnailJPEG: thumbnailJPEG
            )
        }

        func publish(payload: SharedMealPayload, thumbnailJPEG: Data?) {
            guard isShareEnabled else { return }
            if let reason = MealSharePrivacy.rejectReason(for: payload) {
                assertionFailure("Refusing to publish companion meal: \(reason)")
                return
            }
            let record = SharedMealRecord(payload: payload, thumbnailJPEG: thumbnailJPEG)
            let transports = self.transports
            ioQueue.async {
                Task {
                    for transport in transports {
                        await transport.publish(record)
                    }
                }
            }
        }
    }

    // MARK: - Outbox (offline-first, works without CloudKit / App Group)

    final class SharedMealsOutboxTransport: MealCompanionTransport, @unchecked Sendable {
        private let defaults: UserDefaults
        private let fileManager: FileManager
        private let overrideDirectory: URL?
        private static let publishedIDsKey = "ai_meal_companion_outbox_ids"

        init(defaults: UserDefaults = .standard, fileManager: FileManager = .default, directory: URL? = nil) {
            self.defaults = defaults
            self.fileManager = fileManager
            self.overrideDirectory = directory
        }

        private var directoryURL: URL? {
            if let overrideDirectory { return overrideDirectory }
            guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                return nil
            }
            return base.appendingPathComponent("SharedMealsOutbox", isDirectory: true)
        }

        func publish(_ record: SharedMealRecord) async {
            guard let dir = ensureDirectory() else { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            encoder.dateEncodingStrategy = .iso8601
            guard let json = try? encoder.encode(record.payload) else { return }
            if let reason = MealSharePrivacy.rejectReason(for: record.payload) {
                assertionFailure("Outbox refused companion meal: \(reason)")
                return
            }

            let jsonURL = dir.appendingPathComponent("\(record.payload.id.uuidString).json", isDirectory: false)
            if fileManager.fileExists(atPath: jsonURL.path), record.thumbnailJPEG == nil {
                return
            }
            try? json.write(to: jsonURL, options: .atomic)

            if let jpeg = record.thumbnailJPEG, !jpeg.isEmpty {
                let jpgURL = dir.appendingPathComponent("\(record.payload.id.uuidString).jpg", isDirectory: false)
                try? jpeg.write(to: jpgURL, options: .atomic)
            }

            var ids = defaults.stringArray(forKey: Self.publishedIDsKey) ?? []
            let idString = record.payload.id.uuidString
            if !ids.contains(idString) {
                ids.append(idString)
                defaults.set(ids, forKey: Self.publishedIDsKey)
            }

            writeCompanionAppGroupIndexIfConfigured(record.payload)
        }

        func loadPublishedIDs() -> [String] {
            defaults.stringArray(forKey: Self.publishedIDsKey) ?? []
        }

        func loadPayload(id: UUID) -> SharedMealPayload? {
            guard let dir = directoryURL else { return nil }
            let url = dir.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
            guard let data = try? Data(contentsOf: url) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(SharedMealPayload.self, from: data)
        }

        private func ensureDirectory() -> URL? {
            guard let dir = directoryURL else { return nil }
            if !fileManager.fileExists(atPath: dir.path) {
                try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            return dir
        }

        /// Optional mirror of the meal-only JSON into a dedicated companion
        /// App Group. Refuses `trio-app-group` so Nightscout/CGM App Group
        /// state cannot be mixed into Mayee's suite.
        private func writeCompanionAppGroupIndexIfConfigured(_ payload: SharedMealPayload) {
            guard let suiteName = MealCompanionShareSettings.companionAppGroupIdentifier(defaults),
                  let suite = UserDefaults(suiteName: suiteName)
            else { return }
            guard let data = try? JSONEncoder().encode(payload) else { return }
            if MealSharePrivacy.rejectReason(for: payload) != nil { return }
            suite.set(data, forKey: "sharedMeal.\(payload.id.uuidString)")
        }
    }

    // MARK: - CloudKit (compiles; no-ops until a container ID is configured)

    final class CloudKitMealShareTransport: MealCompanionTransport, @unchecked Sendable {
        static let recordType = "SharedMeal"

        private let defaults: UserDefaults

        init(defaults: UserDefaults = .standard) {
            self.defaults = defaults
        }

        func publish(_ record: SharedMealRecord) async {
            if MealSharePrivacy.rejectReason(for: record.payload) != nil { return }
            let containerID = MealCompanionShareSettings.cloudKitContainerIdentifier(defaults)
            guard !containerID.isEmpty else { return }

            #if canImport(CloudKit)
                let container = CKContainer(identifier: containerID)
                let privateDB = container.privateCloudDatabase
                let recordID = CKRecord.ID(recordName: record.payload.id.uuidString)
                let ckRecord = CKRecord(recordType: Self.recordType, recordID: recordID)
                ckRecord["schemaVersion"] = record.payload.schemaVersion as NSNumber
                ckRecord["date"] = record.payload.date as NSDate
                if let mealName = record.payload.mealName {
                    ckRecord["mealName"] = mealName as NSString
                }
                if let carbs = record.payload.carbs {
                    ckRecord["carbs"] = carbs as NSNumber
                }
                if let filename = record.payload.thumbnailFilename {
                    ckRecord["thumbnailFilename"] = filename as NSString
                }
                // Intentionally no glucose / IOB / COB / Nightscout fields.
                do {
                    _ = try await privateDB.save(ckRecord)
                } catch {
                    // Local outbox already holds the meal; CloudKit can catch up later.
                }
            #endif
        }
    }
}
