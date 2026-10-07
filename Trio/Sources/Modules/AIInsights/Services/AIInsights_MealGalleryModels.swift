//
//  AIInsights_MealGalleryModels.swift
//  Trio
//
//  Gallery query helpers (Feature M follow-up): meal-slot folders, manual
//  tags/groups, and local-only filters. Pure Foundation so the matching rules
//  can be unit-tested without UIKit / disk I/O.
//
//  Meal-slot hour cutoffs are local-time (Calendar.current, so a phone set to
//  Europe/Amsterdam classifies Dutch mealtimes correctly):
//    breakfast  05:00–10:59
//    lunch      11:00–15:59
//    dinner     16:00–21:59
//    other      22:00–04:59
//

import Foundation

extension AIInsights {

    /// Auto folder derived from the local hour of a meal's `date`.
    enum MealSlot: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
        case breakfast
        case lunch
        case dinner
        case other

        var id: String { rawValue }

        /// Inclusive start hour (0–23) of this slot in local time.
        var startHour: Int {
            switch self {
            case .breakfast: return 5
            case .lunch: return 11
            case .dinner: return 16
            case .other: return 22
            }
        }

        var localizedTitle: String {
            switch self {
            case .breakfast:
                return String(localized: "Breakfast", comment: "Meal gallery breakfast folder")
            case .lunch:
                return String(localized: "Lunch", comment: "Meal gallery lunch folder")
            case .dinner:
                return String(localized: "Dinner", comment: "Meal gallery dinner folder")
            case .other:
                return String(localized: "Other", comment: "Meal gallery other-hours folder")
            }
        }

        var systemImage: String {
            switch self {
            case .breakfast: return "sunrise"
            case .lunch: return "sun.max"
            case .dinner: return "sunset"
            case .other: return "moon"
            }
        }

        /// Classify `date` using `calendar`'s timezone. Defaults to the device
        /// calendar so travel/TZ changes keep grouping aligned with local clock.
        static func from(date: Date, calendar: Calendar = .current) -> MealSlot {
            let hour = calendar.component(.hour, from: date)
            switch hour {
            case Self.breakfast.startHour ..< Self.lunch.startHour: return .breakfast
            case Self.lunch.startHour ..< Self.dinner.startHour: return .lunch
            case Self.dinner.startHour ..< Self.other.startHour: return .dinner
            default: return .other
            }
        }
    }

    /// Compact per-ingredient snapshot stored in the gallery index so a meal
    /// can be reloaded into FoodFinder / `FoodBolusHandoff` after the 20-item
    /// recent-results cap has dropped the full `FoodAnalysisResult`.
    struct GalleryFoodSnapshot: Codable, Equatable, Sendable {
        var name: String
        var portion: String
        var carbs: Double
        var fat: Double
        var protein: Double
        var fiber: Double
        var calories: Double
        var portionMultiplier: Double
        /// `FoodItem.basisUnit`; nil in snapshots stored before it was kept.
        var basisUnit: MeasurementUnit? = nil

        init(
            name: String,
            portion: String,
            carbs: Double,
            fat: Double,
            protein: Double,
            fiber: Double,
            calories: Double,
            portionMultiplier: Double = 1.0,
            basisUnit: MeasurementUnit? = nil
        ) {
            self.name = name
            self.portion = portion
            self.carbs = carbs
            self.fat = fat
            self.protein = protein
            self.fiber = fiber
            self.calories = calories
            self.portionMultiplier = portionMultiplier
            self.basisUnit = basisUnit
        }

        init(item: FoodItem) {
            self.init(
                name: item.name,
                portion: item.portion,
                carbs: item.carbs,
                fat: item.fat,
                protein: item.protein,
                fiber: item.fiber,
                calories: item.calories,
                portionMultiplier: item.portionMultiplier,
                basisUnit: item.basisUnit == .unknown ? nil : item.basisUnit
            )
        }

        enum CodingKeys: String, CodingKey {
            case name
            case portion
            case carbs
            case fat
            case protein
            case fiber
            case calories
            case portionMultiplier
            case basisUnit
        }

        /// Every field is optional on decode: snapshots come from several earlier builds, and an unknown unit or a
        /// missing macro must not drop the meal they belong to.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = container.lossyDecode(String.self, forKey: .name) ?? ""
            portion = container.lossyDecode(String.self, forKey: .portion) ?? ""
            carbs = container.lossyNumber(forKey: .carbs) ?? 0
            fat = container.lossyNumber(forKey: .fat) ?? 0
            protein = container.lossyNumber(forKey: .protein) ?? 0
            fiber = container.lossyNumber(forKey: .fiber) ?? 0
            calories = container.lossyNumber(forKey: .calories) ?? 0
            let multiplier = container.lossyNumber(forKey: .portionMultiplier) ?? 1
            portionMultiplier = multiplier.isFinite && multiplier > 0 ? multiplier : 1
            basisUnit = container.lossyDecode(MeasurementUnit.self, forKey: .basisUnit)
        }

        func toFoodItem() -> FoodItem {
            FoodItem(
                name: name,
                portion: portion,
                carbs: carbs,
                fat: fat,
                protein: protein,
                fiber: fiber,
                calories: calories,
                portionMultiplier: portionMultiplier
            )
        }
    }

    /// Local-only gallery query. All fields optional; an empty filter matches
    /// everything. Matching never hits the network.
    struct GalleryFilter: Equatable, Sendable {
        var nameQuery: String = ""
        var startDate: Date?
        var endDate: Date?
        var minCarbs: Double?
        var maxCarbs: Double?
        var tags: Set<String> = []
        var mealSlot: MealSlot?

        var isActive: Bool {
            !normalizedQuery.isEmpty
                || startDate != nil
                || endDate != nil
                || minCarbs != nil
                || maxCarbs != nil
                || !tags.isEmpty
                || mealSlot != nil
        }

        var normalizedQuery: String {
            nameQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func matches(
            _ item: MealGalleryStore.GalleryItem,
            calendar: Calendar = .current
        ) -> Bool {
            if let slot = mealSlot, item.resolvedMealSlot(calendar: calendar) != slot {
                return false
            }
            if let minCarbs, item.totalCarbs < minCarbs { return false }
            if let maxCarbs, item.totalCarbs > maxCarbs { return false }
            if let startDate {
                let start = calendar.startOfDay(for: startDate)
                if item.date < start { return false }
            }
            if let endDate {
                guard let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: endDate))
                else { return false }
                if item.date >= nextDay { return false }
            }
            if !tags.isEmpty {
                let itemTags = Set(item.tags.map { Self.normalizeTag($0) })
                let wanted = Set(tags.map { Self.normalizeTag($0) })
                if itemTags.isDisjoint(with: wanted) { return false }
            }
            let query = normalizedQuery
            if !query.isEmpty {
                let haystack = item.searchHaystack
                if haystack.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
                    return false
                }
            }
            return true
        }

        static func normalizeTag(_ raw: String) -> String {
            raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    /// The saved-meal folders of earlier versions, one folder per normalized meal name. Only read by
    /// `MealFolderStore.migrateIfNeeded`; the meal library files meals in `MealFolderStore`.
    struct SavedMealFolderStore {
        static let assignmentsKey = "ai_foodfinder_saved_meal_folders"
        static let namesKey = "ai_foodfinder_saved_meal_folder_names"

        let defaults: UserDefaults

        init(defaults: UserDefaults = .standard) {
            self.defaults = defaults
        }

        /// Folder per meal key.
        func assignments() -> [String: String] {
            StoredFolders.assignments(defaults, Self.assignmentsKey).compactMapValues(\.first)
        }

        /// Stored names plus any name still in use, deduplicated ignoring case and accents, sorted.
        func folderNames() -> [String] {
            Self.deduplicated(StoredFolders.strings(defaults, Self.namesKey) + Array(assignments().values))
        }

        /// Adds a folder and returns its name as stored (an existing folder's spelling when it matches).
        @discardableResult
        func addFolder(_ raw: String) -> String? {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            let names = folderNames()
            if let existing = names.first(where: { Self.same($0, name) }) {
                return existing
            }
            defaults.set(Self.deduplicated(names + [name]), forKey: Self.namesKey)
            return name
        }

        /// Files the meal under `folder`, or takes it out of its folder when nil.
        func setFolder(_ folder: String?, forMealKey key: String) {
            guard !key.isEmpty else { return }
            var current = assignments()
            if let folder, let name = addFolder(folder) {
                current[key] = name
            } else {
                current.removeValue(forKey: key)
            }
            defaults.set(current, forKey: Self.assignmentsKey)
        }

        /// Removes the folder; its meals are no longer in a folder.
        func deleteFolder(_ name: String) {
            defaults.set(folderNames().filter { !Self.same($0, name) }, forKey: Self.namesKey)
            defaults.set(assignments().filter { !Self.same($0.value, name) }, forKey: Self.assignmentsKey)
        }

        static func same(_ lhs: String, _ rhs: String) -> Bool {
            lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }

        static func deduplicated(_ names: [String]) -> [String] {
            var result: [String] = []
            for raw in names {
                let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, !result.contains(where: { same($0, name) }) else { continue }
                result.append(name)
            }
            return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }
    }

    /// The one folder model of the meal library: saved meals, photographed meals and recent meals are filed in the
    /// same folders. A meal is filed by `memberKey` (its normalized name, as the saved-meal folders did), so every
    /// photo of "Pasta pesto" and the saved "Pasta pesto" share their folders. A meal can be in several folders.
    /// Stays on this phone.
    ///
    /// Replaces the saved-meal folders (`SavedMealFolderStore`) and the gallery groups (`GalleryItem.tags`). Both are
    /// copied in once by `migrateIfNeeded`; their stored data is left as it was.
    struct MealFolderStore {
        static let namesKey = "ai_meal_library_folder_names"
        static let assignmentsKey = "ai_meal_library_folder_assignments"
        static let migratedKey = "ai_meal_library_folders_migrated_v1"

        let defaults: UserDefaults

        init(defaults: UserDefaults = .standard) {
            self.defaults = defaults
        }

        /// The key a meal is filed under: its name, else its description, else its ingredient names, normalized like
        /// `MealEventIdentity`. A meal with none of these only matches itself.
        static func memberKey(mealName: String?, mealDescription: String? = nil, itemNames: [String], id: UUID) -> String {
            let candidates = [mealName ?? "", mealDescription ?? "", itemNames.joined(separator: ", ")]
            for candidate in candidates {
                let key = MealEventIdentity.normalized(candidate)
                if !key.isEmpty { return key }
            }
            return "meal:" + id.uuidString.lowercased()
        }

        static func memberKey(for result: FoodAnalysisResult) -> String {
            memberKey(
                mealName: result.mealName,
                mealDescription: result.mealDescription,
                itemNames: result.items.map(\.name),
                id: result.id
            )
        }

        /// Folders per member key.
        func assignments() -> [String: [String]] {
            StoredFolders.assignments(defaults, Self.assignmentsKey)
        }

        /// Stored names plus any name still in use, deduplicated ignoring case and accents, sorted.
        func folderNames() -> [String] {
            SavedMealFolderStore.deduplicated(StoredFolders.strings(defaults, Self.namesKey) + assignments().values.flatMap { $0 })
        }

        func folders(forMemberKey key: String) -> [String] {
            assignments()[key] ?? []
        }

        /// Adds a folder and returns its name as stored (an existing folder's spelling when it matches).
        @discardableResult
        func addFolder(_ raw: String) -> String? {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            let names = folderNames()
            if let existing = names.first(where: { SavedMealFolderStore.same($0, name) }) {
                return existing
            }
            defaults.set(SavedMealFolderStore.deduplicated(names + [name]), forKey: Self.namesKey)
            return name
        }

        /// Files the meal in exactly `folders`; an empty list takes it out of every folder.
        func setFolders(_ folders: [String], forMemberKey key: String) {
            guard !key.isEmpty else { return }
            let names = SavedMealFolderStore.deduplicated(folders.compactMap { addFolder($0) })
            var current = assignments()
            current[key] = names.isEmpty ? nil : names
            defaults.set(current, forKey: Self.assignmentsKey)
        }

        func isInFolder(_ folder: String, memberKey key: String) -> Bool {
            folders(forMemberKey: key).contains { SavedMealFolderStore.same($0, folder) }
        }

        /// Puts the meal in `folder`, or takes it out when it is already there.
        func toggle(_ folder: String, forMemberKey key: String) {
            var folders = folders(forMemberKey: key)
            if folders.contains(where: { SavedMealFolderStore.same($0, folder) }) {
                folders.removeAll { SavedMealFolderStore.same($0, folder) }
            } else {
                folders.append(folder)
            }
            setFolders(folders, forMemberKey: key)
        }

        func renameFolder(from old: String, to raw: String) {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name != old else { return }
            let names = folderNames().filter { !SavedMealFolderStore.same($0, old) }
            defaults.set(SavedMealFolderStore.deduplicated(names + [name]), forKey: Self.namesKey)
            var current = assignments()
            for (key, folders) in current {
                guard folders.contains(where: { SavedMealFolderStore.same($0, old) }) else { continue }
                current[key] = SavedMealFolderStore.deduplicated(
                    folders.map { SavedMealFolderStore.same($0, old) ? name : $0 }
                )
            }
            defaults.set(current, forKey: Self.assignmentsKey)
        }

        /// Removes the folder; its meals stay in the library, just not in this folder.
        func deleteFolder(_ name: String) {
            defaults.set(folderNames().filter { !SavedMealFolderStore.same($0, name) }, forKey: Self.namesKey)
            var current = assignments()
            for (key, folders) in current {
                let kept = folders.filter { !SavedMealFolderStore.same($0, name) }
                current[key] = kept.isEmpty ? nil : kept
            }
            defaults.set(current, forKey: Self.assignmentsKey)
        }

        /// Copies the saved-meal folders and the gallery groups into this store, once. Every folder name of either is
        /// kept, a saved meal keeps its folder and a gallery meal keeps all its groups; meals filed in both get both.
        func migrateIfNeeded(galleryItems: [MealGalleryStore.GalleryItem], galleryGroupNames: [String]) {
            guard !defaults.bool(forKey: Self.migratedKey) else { return }
            let saved = SavedMealFolderStore(defaults: defaults)

            var current = assignments()
            func file(_ folders: [String], under key: String) {
                guard !key.isEmpty, !folders.isEmpty else { return }
                current[key] = SavedMealFolderStore.deduplicated((current[key] ?? []) + folders)
            }
            for (key, folder) in saved.assignments() {
                file([folder], under: key)
            }
            for item in galleryItems where !item.tags.isEmpty {
                file(item.tags, under: Self.memberKey(for: item))
            }

            let names = StoredFolders.strings(defaults, Self.namesKey)
                + saved.folderNames()
                + galleryGroupNames
                + current.values.flatMap { $0 }
            defaults.set(SavedMealFolderStore.deduplicated(names), forKey: Self.namesKey)
            defaults.set(current, forKey: Self.assignmentsKey)
            defaults.set(true, forKey: Self.migratedKey)
        }

        static func memberKey(for item: MealGalleryStore.GalleryItem) -> String {
            memberKey(mealName: item.mealName, itemNames: item.items.map(\.name), id: item.id)
        }
    }

    /// The automatic Drinks folder of the meal library. Nothing is stored: a meal is a drink when every ingredient is
    /// measured as a liquid, from its unit (`FoodItem.basisUnit`) or its portion text ("250 ml", "1 glass (200 ml)",
    /// a barcode product's "330 ml"). A meal with a drink on the side stays out.
    enum DrinkClassifier {
        static var folderTitle: String {
            String(localized: "Drinks", comment: "FoodFinder automatic folder with every drink (meals measured in ml, cl or l)")
        }

        /// A number followed by a volume unit: ml, cl, dl, l, liter/litre(s), fl oz.
        private static let liquidPortion = try? NSRegularExpression(
            pattern: #"(?<![\p{L}\d])\d+(?:[.,]\d+)?\s*(?:ml|cl|dl|l|ltr|liters?|litres?|fl\.?\s*oz)(?![\p{L}])"#,
            options: [.caseInsensitive]
        )

        static func isLiquidPortion(_ portion: String) -> Bool {
            guard let liquidPortion, !portion.isEmpty else { return false }
            let range = NSRange(portion.startIndex..., in: portion)
            return liquidPortion.firstMatch(in: portion, options: [], range: range) != nil
        }

        static func isDrink(_ items: [FoodItem]) -> Bool {
            !items.isEmpty && items.allSatisfy { $0.basisUnit == .milliliter || isLiquidPortion($0.portion) }
        }

        static func isDrink(_ snapshots: [GalleryFoodSnapshot]) -> Bool {
            !snapshots.isEmpty && snapshots.allSatisfy { $0.basisUnit == .milliliter || isLiquidPortion($0.portion) }
        }
    }

    /// Reads folder data written by any earlier build: a name list may hold non-strings, and a meal's folders may be
    /// one name or a list. Anything else is skipped rather than failing the whole store.
    enum StoredFolders {
        static func strings(_ defaults: UserDefaults, _ key: String) -> [String] {
            strings(from: defaults.object(forKey: key))
        }

        static func strings(from value: Any?) -> [String] {
            switch value {
            case let name as String:
                return [name]
            case let list as [Any]:
                return list.compactMap { $0 as? String }
            default:
                return []
            }
        }

        static func assignments(_ defaults: UserDefaults, _ key: String) -> [String: [String]] {
            guard let stored = defaults.object(forKey: key) as? [String: Any] else { return [:] }
            var result: [String: [String]] = [:]
            for (memberKey, value) in stored {
                let names = strings(from: value).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                if !memberKey.isEmpty, !names.isEmpty {
                    result[memberKey] = names
                }
            }
            return result
        }
    }

    /// Decodes a stored JSON list one element at a time, so one entry an older or newer build wrote differently
    /// costs that entry instead of the whole list.
    enum LossyJSONList {
        private struct Element<Value: Decodable>: Decodable {
            let value: Value?

            init(from decoder: Decoder) throws {
                value = try? Value(from: decoder)
            }
        }

        /// The readable elements and how many were skipped; nil when the data is not a JSON list at all.
        static func decode<Value: Decodable>(_: Value.Type, from data: Data) -> (values: [Value], skipped: Int)? {
            guard let elements = try? JSONDecoder().decode([Element<Value>].self, from: data) else { return nil }
            let values = elements.compactMap(\.value)
            return (values, elements.count - values.count)
        }

        /// Keeps the stored bytes once under `<key>.unreadable` before a list that could not be read in full is
        /// written back, so entries this build cannot read are not lost to the next save.
        static func preserveUnreadable(_ data: Data, forKey key: String, defaults: UserDefaults = .standard) {
            let backupKey = key + ".unreadable"
            guard defaults.data(forKey: backupKey) == nil else { return }
            defaults.set(data, forKey: backupKey)
        }

        /// Reads the list stored under `key`, keeping the first entry per id.
        static func load<Value: Decodable & Identifiable>(
            _ type: Value.Type,
            forKey key: String,
            defaults: UserDefaults = .standard
        ) -> [Value]? {
            guard let data = defaults.data(forKey: key) else { return nil }
            guard let decoded = decode(type, from: data) else {
                preserveUnreadable(data, forKey: key, defaults: defaults)
                return nil
            }
            if decoded.skipped > 0 {
                preserveUnreadable(data, forKey: key, defaults: defaults)
            }
            return decoded.values.aiInsightsUniqued(by: \.id)
        }
    }
}

extension KeyedDecodingContainer {
    /// The value, or nil when the key is missing, null or holds something else.
    func lossyDecode<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }

    /// A number stored as a number or as a numeric string; nil otherwise or when not finite.
    func lossyNumber(forKey key: Key) -> Double? {
        let value = lossyDecode(Double.self, forKey: key)
            ?? lossyDecode(String.self, forKey: key).flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
        guard let value, value.isFinite else { return nil }
        return value
    }
}

extension Array {
    /// The elements in order, keeping only the first one per key.
    func aiInsightsUniqued<Key: Hashable>(by key: (Element) -> Key) -> [Element] {
        var seen = Set<Key>()
        return filter { seen.insert(key($0)).inserted }
    }
}
