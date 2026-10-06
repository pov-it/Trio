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

        init(
            name: String,
            portion: String,
            carbs: Double,
            fat: Double,
            protein: Double,
            fiber: Double,
            calories: Double,
            portionMultiplier: Double = 1.0
        ) {
            self.name = name
            self.portion = portion
            self.carbs = carbs
            self.fat = fat
            self.protein = protein
            self.fiber = fiber
            self.calories = calories
            self.portionMultiplier = portionMultiplier
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
                portionMultiplier: item.portionMultiplier
            )
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
            defaults.dictionary(forKey: Self.assignmentsKey) as? [String: String] ?? [:]
        }

        /// Stored names plus any name still in use, deduplicated ignoring case and accents, sorted.
        func folderNames() -> [String] {
            let stored = defaults.stringArray(forKey: Self.namesKey) ?? []
            return Self.deduplicated(stored + Array(assignments().values))
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
            defaults.dictionary(forKey: Self.assignmentsKey) as? [String: [String]] ?? [:]
        }

        /// Stored names plus any name still in use, deduplicated ignoring case and accents, sorted.
        func folderNames() -> [String] {
            let stored = defaults.stringArray(forKey: Self.namesKey) ?? []
            return SavedMealFolderStore.deduplicated(stored + assignments().values.flatMap { $0 })
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

            let names = (defaults.stringArray(forKey: Self.namesKey) ?? [])
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

    /// How the gallery root is presented.
    enum GalleryBrowseMode: String, CaseIterable, Identifiable {
        case all
        case mealSlot
        case groups

        var id: String { rawValue }

        var localizedTitle: String {
            switch self {
            case .all:
                return String(localized: "All", comment: "Meal gallery browse-all mode")
            case .mealSlot:
                return String(localized: "By meal", comment: "Meal gallery browse-by-slot mode")
            case .groups:
                return String(localized: "Folders", comment: "Meal library browse-by-folder mode")
            }
        }
    }
}
