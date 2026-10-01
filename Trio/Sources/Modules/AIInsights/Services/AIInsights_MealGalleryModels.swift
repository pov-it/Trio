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

    /// Folders for the saved meals on the FoodFinder start page. A meal is filed by its normalized name
    /// (`MealEventIdentity.normalized`), so a kept FoodFinder meal and a Trio preset with the same name share a folder.
    /// Stays on this phone, like the gallery groups.
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
                return String(localized: "Groups", comment: "Meal gallery browse-by-group mode")
            }
        }
    }
}
