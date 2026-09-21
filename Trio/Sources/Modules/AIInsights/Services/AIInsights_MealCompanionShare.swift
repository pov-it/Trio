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
//  CloudKit publisher matches pov-it/meals-companion:
//    container iCloud.org.pov-it.<TEAMID>.meals
//    zone MealsZone, records Meal + MealFeed
//    fields title / photographedAt / photo / ownerDisplayName (never glucose).
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

    /// CloudKit record contract for `pov-it/meals-companion`. Keep field names
    /// in lockstep with `MealsKit/MealModels.swift` in that repo.
    enum MealCloudKitContract {
        static let zoneName = "MealsZone"
        static let mealRecordType = "Meal"
        static let feedRecordType = "MealFeed"
        static let feedRecordName = "MealFeedRoot"
        static let titleKey = "title"
        static let photographedAtKey = "photographedAt"
        static let photoKey = "photo"
        static let ownerDisplayNameKey = "ownerDisplayName"
        static let mealFieldKeys: [String] = [
            titleKey, photographedAtKey, photoKey, ownerDisplayNameKey
        ]
        static let containerBundleBase = "org.pov-it"
        static let containerSuffix = "meals"

        /// `iCloud.org.pov-it.<TEAMID>.meals`. Nil when the team id is missing
        /// or still a build placeholder (`TEAMID`, `$(DEVELOPMENT_TEAM)`).
        static func containerIdentifier(teamID: String) -> String? {
            let trimmed = teamID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let upper = trimmed.uppercased()
            if upper == "TEAMID" || trimmed.contains("$(") { return nil }
            return "iCloud.\(containerBundleBase).\(trimmed).\(containerSuffix)"
        }
    }

    enum MealCompanionShareSettings {
        static let enabledKey = "ai_meal_companion_share_enabled"
        /// Optional override. Empty means derive `iCloud.org.pov-it.<TEAM>.meals`.
        static let cloudKitContainerKey = "ai_meal_companion_cloudkit_container"
        /// Optional companion App Group identifier. MUST NOT be `trio-app-group`.
        /// Empty (the default) means we never touch an App Group suite.
        static let companionAppGroupKey = "ai_meal_companion_app_group"
        static let ownerDisplayNameKey = "ai_meal_companion_owner_display_name"
        static let shareURLKey = "ai_meal_companion_share_url"

        /// Hard-coded Trio therapy App Group suffix — never used for meals.
        static let forbiddenTrioAppGroupSuffix = "trio-app-group"

        static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
            defaults.bool(forKey: enabledKey)
        }

        static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
            defaults.set(enabled, forKey: enabledKey)
        }

        static func cloudKitContainerIdentifier(_ defaults: UserDefaults = .standard) -> String {
            let override = (defaults.string(forKey: cloudKitContainerKey) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !override.isEmpty { return override }
            return MealCloudKitContract.containerIdentifier(teamID: signingTeamID) ?? ""
        }

        /// `TeamID` is substituted from `$(DEVELOPMENT_TEAM)` in Info.plist.
        static var signingTeamID: String {
            let fromInfo = Bundle.main.object(forInfoDictionaryKey: "TeamID") as? String
            let fromBundle = Bundle.main.object(forInfoDictionaryKey: "DEVELOPMENT_TEAM") as? String
            return (fromInfo ?? fromBundle ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        static func ownerDisplayName(_ defaults: UserDefaults = .standard) -> String {
            let stored = (defaults.string(forKey: ownerDisplayNameKey) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return stored.isEmpty ? "Meal" : stored
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

    // MARK: - CloudKit (Meal / MealFeed in iCloud.org.pov-it.<TEAM>.meals)

    final class CloudKitMealShareTransport: MealCompanionTransport, @unchecked Sendable {
        private let defaults: UserDefaults
        private let fileManager: FileManager

        init(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
            self.defaults = defaults
            self.fileManager = fileManager
        }

        func publish(_ record: SharedMealRecord) async {
            if MealSharePrivacy.rejectReason(for: record.payload) != nil { return }
            let containerID = MealCompanionShareSettings.cloudKitContainerIdentifier(defaults)
            guard !containerID.isEmpty else { return }

            #if canImport(CloudKit)
                do {
                    try await saveToCloudKit(record, containerID: containerID)
                } catch {
                    // Local outbox already holds the meal; CloudKit can catch up later.
                }
            #endif
        }

        #if canImport(CloudKit)
            private func saveToCloudKit(_ record: SharedMealRecord, containerID: String) async throws {
                let container = CKContainer(identifier: containerID)
                let database = container.privateCloudDatabase
                let zoneID = CKRecordZone.ID(zoneName: MealCloudKitContract.zoneName, ownerName: CKCurrentUserDefaultName)
                try await ensureZone(database: database, zoneID: zoneID)

                let owner = MealCompanionShareSettings.ownerDisplayName(defaults)
                let feedID = CKRecord.ID(
                    recordName: MealCloudKitContract.feedRecordName,
                    zoneID: zoneID
                )
                let feed = CKRecord(recordType: MealCloudKitContract.feedRecordType, recordID: feedID)
                feed[MealCloudKitContract.ownerDisplayNameKey] = owner as NSString
                _ = try await database.save(feed)

                let mealID = CKRecord.ID(recordName: record.payload.id.uuidString, zoneID: zoneID)
                let meal = CKRecord(recordType: MealCloudKitContract.mealRecordType, recordID: mealID)
                meal.parent = CKRecord.Reference(recordID: feedID, action: .none)
                meal[MealCloudKitContract.titleKey] = (record.payload.mealName ?? "Meal") as NSString
                meal[MealCloudKitContract.photographedAtKey] = record.payload.date as NSDate
                meal[MealCloudKitContract.ownerDisplayNameKey] = owner as NSString
                if let jpeg = record.thumbnailJPEG, !jpeg.isEmpty,
                   let asset = try? ckAsset(from: jpeg, id: record.payload.id)
                {
                    meal[MealCloudKitContract.photoKey] = asset
                }
                // Never write carbs / glucose / IOB / COB / Nightscout onto Meal.
                _ = try await database.save(meal)

                if defaults.string(forKey: MealCompanionShareSettings.shareURLKey) == nil {
                    try await ensureShare(database: database, feed: feed)
                }
            }

            private func ensureZone(database: CKDatabase, zoneID: CKRecordZone.ID) async throws {
                let zone = CKRecordZone(zoneID: zoneID)
                do {
                    _ = try await database.save(zone)
                } catch let error as CKError where error.code == .serverRecordChanged || error.code == .zoneNotFound {
                    // zoneNotFound on save is unexpected; serverRecordChanged means it exists.
                } catch let error as CKError where error.code == .networkFailure || error.code == .networkUnavailable {
                    throw error
                } catch {
                    // Zone may already exist.
                }
            }

            private func ensureShare(database: CKDatabase, feed: CKRecord) async throws {
                let share = CKShare(rootRecord: feed)
                share.publicPermission = .none
                _ = try await database.save(share)
                if let url = share.url?.absoluteString {
                    defaults.set(url, forKey: MealCompanionShareSettings.shareURLKey)
                }
            }

            private func ckAsset(from jpeg: Data, id: UUID) throws -> CKAsset {
                let dir = fileManager.temporaryDirectory.appendingPathComponent("MealCompanionCK", isDirectory: true)
                if !fileManager.fileExists(atPath: dir.path) {
                    try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
                }
                let url = dir.appendingPathComponent("\(id.uuidString).jpg")
                try jpeg.write(to: url, options: .atomic)
                return CKAsset(fileURL: url)
            }
        #endif
    }
}
