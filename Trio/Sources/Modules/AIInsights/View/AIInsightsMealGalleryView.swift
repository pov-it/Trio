//
//  AIInsightsMealGalleryView.swift
//  Trio
//
//  The FoodFinder meal library: saved meals (kept FoodFinder meals and Trio
//  meal presets), every photographed meal from the durable `MealGalleryStore`
//  and the recent FoodFinder meals, in one screen. Tapping a meal opens a
//  detail sheet with the larger image, meal name, timestamp, macros, folders,
//  a share card and actions to reload FoodFinder or `FoodBolusHandoff`
//  ("Use in Bolus Calculator").
//
//  Browse modes: everything (saved, then all meals newest first), auto folders
//  by meal slot (local hour of `date`), and the folders of `MealFolderStore`,
//  which saved and photographed meals share. Search matches the meal name and
//  its ingredients; filters (date, carbs, folders/slot) apply on top of every
//  mode. Local-first — never waits on sync.
//

import SwiftUI
import UIKit

extension AIInsights {
    /// A saved meal FoodFinder hands to the library: a kept FoodFinder meal, or a Trio meal preset.
    struct LibrarySavedMeal: Identifiable {
        let id: String
        let result: FoodAnalysisResult
        /// False for a Trio meal preset, which has no photo or meal time of its own.
        let isKept: Bool
    }

    struct MealGalleryView: View {
        /// Recent FoodFinder results: shown next to the archived meals (also the ones without a photo) and the
        /// preferred full `FoodItem` list when re-bolusing a recent meal.
        let fallbackResults: [FoodAnalysisResult]
        var savedMeals: [LibrarySavedMeal] = []
        var onOpenInFoodFinder: ((FoodAnalysisResult) -> Void)? = nil
        var onUseInBolusCalculator: ((FoodAnalysisResult) -> Void)? = nil
        var onSaveMeal: ((FoodAnalysisResult) -> Void)? = nil
        /// Removes the saved meal with this `LibrarySavedMeal.id`.
        var onRemoveSavedMeal: ((String) -> Void)? = nil
        /// Glucose units for the meal response charts.
        var units: GlucoseUnits = .mgdL

        @Environment(\.dismiss) private var dismiss

        /// Meals from the gallery archive, newest first.
        @State private var archivedMeals: [DisplayMeal] = []
        @State private var selectedMeal: DisplayMeal?
        @State private var isLoading = true
        @State private var filter = GalleryFilter()
        @State private var browseMode: GalleryBrowseMode = .all
        @State private var showFilters = false
        @State private var showShareSettings = false
        @State private var shareEnabled = MealCompanionPublisher.shared.isShareEnabled
        @State private var folderNames: [String] = []
        @State private var folderAssignments: [String: [String]] = [:]
        @State private var newFolderName: String = ""
        @State private var isAddingFolder = false
        /// Meal to file in the folder being created, when it was started from a meal.
        @State private var newFolderMemberKey: String?
        @State private var renamingFolder: String?
        @State private var renamedFolderName: String = ""

        // MARK: - View model

        /// One meal in the library, built from the gallery store, a recent result or a saved meal.
        struct DisplayMeal: Identifiable, Equatable {
            let id: UUID
            let date: Date
            let mealName: String?
            let totalCarbs: Double
            let totalFat: Double
            let totalProtein: Double
            let totalFiber: Double
            let totalCalories: Double
            let mealSlot: MealSlot
            /// Key the meal is filed under in `MealFolderStore`.
            let memberKey: String
            /// Larger image bytes for the detail view, when the meal still carries its capture.
            let fullImageData: Data?
            /// Per-item carbs (name, adjusted carbs) — from the store snapshot
            /// or the fallback recent result.
            let items: [ItemCarb]
            let snapshots: [GalleryFoodSnapshot]
            /// Set for the entries of the saved meals.
            var savedID: String? = nil
            /// A Trio meal preset: no meal time, so date filters and meal slots do not apply.
            var isUndated: Bool = false

            struct ItemCarb: Identifiable, Equatable {
                let id: UUID
                let name: String
                let carbs: Double
            }

            var title: String {
                mealName?.trimmingCharacters(in: .whitespacesAndNewlines).aiInsightsNilIfEmpty
                    ?? items.map(\.name).joined(separator: ", ").aiInsightsNilIfEmpty
                    ?? String(localized: "Meal", comment: "Generic meal title")
            }

            var resolvedResult: FoodAnalysisResult {
                let foodItems: [FoodItem]
                if !snapshots.isEmpty {
                    foodItems = snapshots.map { $0.toFoodItem() }
                } else if !items.isEmpty {
                    foodItems = items.map {
                        FoodItem(name: $0.name, portion: "", carbs: $0.carbs, fat: 0, protein: 0, fiber: 0, calories: 0)
                    }
                } else {
                    foodItems = [
                        FoodItem(
                            name: mealName ?? String(localized: "Meal", comment: "Generic meal title"),
                            portion: "",
                            carbs: totalCarbs,
                            fat: totalFat,
                            protein: totalProtein,
                            fiber: totalFiber,
                            calories: totalCalories
                        )
                    ]
                }
                return FoodAnalysisResult(
                    id: id,
                    items: foodItems,
                    rawResponse: nil,
                    timestamp: date,
                    source: .aiCamera,
                    imageData: fullImageData,
                    mealDescription: mealName,
                    mealName: mealName
                )
            }
        }

        /// Archived meals plus the recent meals the archive does not hold (such as the ones without a photo).
        private var historyMeals: [DisplayMeal] {
            let archivedIDs = Set(archivedMeals.map(\.id))
            let recent = fallbackResults
                .filter { !archivedIDs.contains($0.id) }
                .map { Self.makeDisplayMeal(result: $0) }
            return (archivedMeals + recent).sorted { $0.date > $1.date }
        }

        private var savedDisplayMeals: [DisplayMeal] {
            savedMeals.map { saved in
                var meal = Self.makeDisplayMeal(result: saved.result)
                meal.savedID = saved.id
                meal.isUndated = !saved.isKept
                return meal
            }
        }

        /// Every meal once: the history, then the saved meals that are not part of it.
        private var libraryMeals: [DisplayMeal] {
            let history = historyMeals
            let ids = Set(history.map(\.id))
            return history + savedDisplayMeals.filter { !ids.contains($0.id) }
        }

        private var savedMemberKeys: Set<String> {
            Set(savedMeals.map { MealFolderStore.memberKey(for: $0.result) })
        }

        private func savedEntryID(for meal: DisplayMeal) -> String? {
            if let savedID = meal.savedID { return savedID }
            return savedMeals.first { MealFolderStore.memberKey(for: $0.result) == meal.memberKey }?.id
        }

        private func folders(of meal: DisplayMeal) -> [String] {
            folderAssignments[meal.memberKey] ?? []
        }

        private func isInFolder(_ meal: DisplayMeal, _ folder: String) -> Bool {
            folders(of: meal).contains { SavedMealFolderStore.same($0, folder) }
        }

        private func matches(_ meal: DisplayMeal) -> Bool {
            var effective = filter
            if meal.isUndated {
                effective.startDate = nil
                effective.endDate = nil
                effective.mealSlot = nil
            }
            return effective.matches(displayMealAsItem(meal))
        }

        // MARK: - Body

        var body: some View {
            NavigationStack {
                Group {
                    if isLoading, libraryMeals.isEmpty {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if libraryMeals.isEmpty, folderNames.isEmpty {
                        emptyState
                    } else {
                        browseContent
                    }
                }
                .navigationTitle(String(localized: "Meal library", comment: "Meal library navigation title"))
                .navigationBarTitleDisplayMode(.inline)
                .searchable(
                    text: $filter.nameQuery,
                    prompt: String(localized: "Search name or ingredient", comment: "Meal library search prompt")
                )
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Button {
                                showFilters = true
                            } label: {
                                Label(
                                    String(localized: "Filters", comment: "Meal gallery filters button"),
                                    systemImage: filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
                                )
                            }
                            Button {
                                startNewFolder(for: nil)
                            } label: {
                                Label(
                                    String(localized: "New folder", comment: "FoodFinder new saved-meal folder alert title"),
                                    systemImage: "folder.badge.plus"
                                )
                            }
                            Button {
                                showShareSettings = true
                            } label: {
                                Label(
                                    String(localized: "Companion sharing", comment: "Meal gallery companion-share settings"),
                                    systemImage: shareEnabled ? "person.2.fill" : "person.2"
                                )
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel(String(localized: "Library options", comment: "Meal library options menu"))
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            dismiss()
                        } label: {
                            Text(String(localized: "Done", comment: "Close meal gallery button"))
                        }
                    }
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 8) {
                        Picker(String(localized: "Browse", comment: "Meal gallery browse mode picker"), selection: $browseMode) {
                            ForEach(GalleryBrowseMode.allCases) { mode in
                                Text(mode.localizedTitle).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)

                        if filter.isActive {
                            filterChips
                        }
                    }
                    .padding(.bottom, 8)
                    .background(.bar)
                }
            }
            .task {
                await loadMeals()
            }
            .sheet(item: $selectedMeal) { meal in
                MealDetailView(
                    meal: meal,
                    result: preferredResult(for: meal),
                    folders: folders(of: meal),
                    knownFolders: folderNames,
                    shareEnabled: shareEnabled,
                    units: units,
                    onOpenInFoodFinder: { result in
                        selectedMeal = nil
                        onOpenInFoodFinder?(result)
                    },
                    onUseInBolusCalculator: { result in
                        selectedMeal = nil
                        DispatchQueue.main.async {
                            onUseInBolusCalculator?(result)
                        }
                    },
                    onFoldersChanged: { folders in
                        MealFolderStore().setFolders(folders, forMemberKey: meal.memberKey)
                        reloadFolders()
                    }
                )
            }
            .sheet(isPresented: $showFilters) {
                GalleryFilterSheet(filter: $filter, knownTags: folderNames)
            }
            .sheet(isPresented: $showShareSettings) {
                CompanionShareSettingsSheet(isEnabled: $shareEnabled)
            }
            .alert(
                String(localized: "New folder", comment: "FoodFinder new saved-meal folder alert title"),
                isPresented: $isAddingFolder
            ) {
                TextField(
                    String(localized: "Folder name", comment: "FoodFinder new saved-meal folder name field"),
                    text: $newFolderName
                )
                Button(String(localized: "Add", comment: "Add meal gallery group")) {
                    addFolder()
                }
                Button(String(localized: "Cancel", comment: "Cancel button"), role: .cancel) {
                    newFolderMemberKey = nil
                }
            }
            .alert(
                String(localized: "Rename folder", comment: "Meal library rename folder alert title"),
                isPresented: Binding(
                    get: { renamingFolder != nil },
                    set: { if !$0 { renamingFolder = nil } }
                )
            ) {
                TextField(
                    String(localized: "Folder name", comment: "FoodFinder new saved-meal folder name field"),
                    text: $renamedFolderName
                )
                Button(String(localized: "Rename", comment: "Meal library rename folder button")) {
                    if let old = renamingFolder {
                        MealFolderStore().renameFolder(from: old, to: renamedFolderName)
                        reloadFolders()
                    }
                    renamingFolder = nil
                }
                Button(String(localized: "Cancel", comment: "Cancel button"), role: .cancel) {
                    renamingFolder = nil
                }
            }
        }

        @ViewBuilder
        private var browseContent: some View {
            switch browseMode {
            case .all:
                allMeals
            case .mealSlot:
                mealSlotFolders
            case .groups:
                folderList
            }
        }

        /// Saved meals first, then every meal newest first.
        @ViewBuilder private var allMeals: some View {
            let saved = savedDisplayMeals.filter(matches)
            let history = historyMeals.filter(matches)
            if saved.isEmpty, history.isEmpty {
                noMatchingMeals
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if !saved.isEmpty {
                            FoodFinderMealGridSection(
                                title: String(localized: "Saved Meals", comment: "Saved meal presets section header"),
                                count: saved.count
                            ) {
                                ForEach(saved) { meal in
                                    mealTile(meal)
                                }
                            }
                        }
                        if !history.isEmpty {
                            FoodFinderMealGridSection(
                                title: String(localized: "All meals", comment: "Meal library history section header"),
                                count: history.count
                            ) {
                                ForEach(history) { meal in
                                    mealTile(meal, showsDate: true)
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }

        private var mealSlotFolders: some View {
            List {
                ForEach(MealSlot.allCases) { slot in
                    let slotMeals = historyMeals.filter { $0.mealSlot == slot && matches($0) }
                    NavigationLink {
                        mealGrid(slotMeals)
                            .navigationTitle(slot.localizedTitle)
                    } label: {
                        Label {
                            HStack {
                                Text(slot.localizedTitle)
                                Spacer()
                                Text("\(slotMeals.count)")
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: slot.systemImage)
                        }
                    }
                    .disabled(slotMeals.isEmpty)
                }
            }
            .listStyle(.insetGrouped)
        }

        private var folderList: some View {
            let visible = libraryMeals.filter(matches)
            return List {
                Section {
                    ForEach(folderNames, id: \.self) { name in
                        let inFolder = visible.filter { isInFolder($0, name) }
                        NavigationLink {
                            mealGrid(inFolder, responseTitle: String(
                                localized: "Glucose after meals in this group",
                                comment: "Meal gallery group response card title"
                            ))
                            .navigationTitle(name)
                        } label: {
                            Label {
                                HStack {
                                    Text(name)
                                    Spacer()
                                    Text("\(inFolder.count)")
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "folder")
                            }
                        }
                        .contextMenu {
                            folderActions(name)
                        }
                        .swipeActions(edge: .trailing) {
                            folderActions(name)
                        }
                    }
                    let loose = visible.filter { folders(of: $0).isEmpty }
                    NavigationLink {
                        mealGrid(loose)
                            .navigationTitle(String(localized: "No folder", comment: "FoodFinder saved meals without a folder"))
                    } label: {
                        Label {
                            HStack {
                                Text(String(localized: "No folder", comment: "FoodFinder saved meals without a folder"))
                                Spacer()
                                Text("\(loose.count)")
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "tray")
                        }
                    }
                }

                Section {
                    HStack {
                        TextField(
                            String(localized: "Folder name", comment: "FoodFinder new saved-meal folder name field"),
                            text: $newFolderName
                        )
                        Button(String(localized: "Add", comment: "Add meal gallery group")) {
                            newFolderMemberKey = nil
                            addFolder()
                        }
                        .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } footer: {
                    Text(String(
                        localized: "Saved and photographed meals share these folders, which stay on this phone. Meal folders (breakfast / lunch / dinner / other) are assigned from the local hour of the photo.",
                        comment: "Meal library folders footer"
                    ))
                }
            }
            .listStyle(.insetGrouped)
        }

        @ViewBuilder private func folderActions(_ name: String) -> some View {
            Button(role: .destructive) {
                MealFolderStore().deleteFolder(name)
                reloadFolders()
            } label: {
                Label(String(localized: "Delete folder", comment: "FoodFinder delete saved-meal folder"), systemImage: "trash")
            }
            Button {
                renamedFolderName = name
                renamingFolder = name
            } label: {
                Label(String(localized: "Rename", comment: "Meal library rename folder button"), systemImage: "pencil")
            }
        }

        /// `responseTitle` adds a response card for all the meals in `items` above the grid.
        @ViewBuilder private func mealGrid(_ items: [DisplayMeal], responseTitle: String? = nil) -> some View {
            if items.isEmpty {
                noMatchingMeals
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let responseTitle {
                            let keys = MealResponseKeys(results: items.map { preferredResult(for: $0) })
                            MealResponseCard(
                                title: responseTitle,
                                mealIDs: keys.mealIDs,
                                foodResultIDs: keys.foodResultIDs,
                                units: units
                            )
                        }
                        FoodFinderMealGridSection(title: "", count: items.count) {
                            ForEach(items) { meal in
                                mealTile(meal, showsDate: !meal.isUndated)
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }

        private var noMatchingMeals: some View {
            ContentUnavailableView(
                String(localized: "No matching meals", comment: "Meal gallery empty filter title"),
                systemImage: "line.3.horizontal.decrease.circle",
                description: Text(String(
                    localized: "Try clearing filters or photographing a meal in FoodFinder.",
                    comment: "Meal gallery empty filter description"
                ))
            )
        }

        private func mealTile(_ meal: DisplayMeal, showsDate: Bool = false) -> some View {
            let isSaved = meal.savedID != nil || savedMemberKeys.contains(meal.memberKey)
            return Button {
                selectedMeal = meal
            } label: {
                FoodFinderMealTile(
                    title: meal.title,
                    carbs: meal.totalCarbs,
                    subtitle: showsDate ? meal.date.formatted(date: .abbreviated, time: .shortened) : nil,
                    photoID: meal.isUndated ? nil : meal.id,
                    inlineImage: meal.fullImageData,
                    badgeSystemImage: isSaved && meal.savedID == nil ? "bookmark.fill" : nil
                )
            }
            .buttonStyle(.plain)
            .contextMenu {
                folderMenu(for: meal)
                if isSaved, let savedID = savedEntryID(for: meal), let onRemoveSavedMeal {
                    Button(role: .destructive) {
                        onRemoveSavedMeal(savedID)
                    } label: {
                        Label(
                            String(localized: "Remove from saved meals", comment: "Remove a meal from the FoodFinder saved meals"),
                            systemImage: "bookmark.slash"
                        )
                    }
                } else if !isSaved, let onSaveMeal {
                    Button {
                        onSaveMeal(preferredResult(for: meal))
                    } label: {
                        Label(String(localized: "Save", comment: "Save as meal preset"), systemImage: "bookmark")
                    }
                }
            }
        }

        @ViewBuilder private func folderMenu(for meal: DisplayMeal) -> some View {
            Menu {
                ForEach(folderNames, id: \.self) { name in
                    Button {
                        MealFolderStore().toggle(name, forMemberKey: meal.memberKey)
                        reloadFolders()
                    } label: {
                        if isInFolder(meal, name) {
                            Label(name, systemImage: "checkmark")
                        } else {
                            Text(name)
                        }
                    }
                }
                Button {
                    startNewFolder(for: meal.memberKey)
                } label: {
                    Label(
                        String(localized: "New folder…", comment: "FoodFinder new saved-meal folder from a meal"),
                        systemImage: "folder.badge.plus"
                    )
                }
            } label: {
                Label(String(localized: "Folders", comment: "Meal library browse-by-folder mode"), systemImage: "folder")
            }
        }

        private var filterChips: some View {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if filter.isActive {
                        Button {
                            filter = GalleryFilter()
                        } label: {
                            Label(
                                String(localized: "Clear filters", comment: "Clear meal gallery filters"),
                                systemImage: "xmark.circle.fill"
                            )
                            .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                    }
                    if let slot = filter.mealSlot {
                        chip(slot.localizedTitle)
                    }
                    if filter.minCarbs != nil || filter.maxCarbs != nil {
                        chip(carbChipTitle)
                    }
                    ForEach(Array(filter.tags).sorted(), id: \.self) { tag in
                        chip(tag)
                    }
                }
                .padding(.horizontal, 16)
            }
        }

        private var carbChipTitle: String {
            switch (filter.minCarbs, filter.maxCarbs) {
            case let (min?, max?):
                return "\(Int(min))–\(Int(max)) g"
            case let (min?, nil):
                return "≥ \(Int(min)) g"
            case let (nil, max?):
                return "≤ \(Int(max)) g"
            default:
                return String(localized: "Carbs", comment: "Meal gallery carbs filter chip")
            }
        }

        private func chip(_ title: String) -> some View {
            Text(title)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
        }

        private var emptyState: some View {
            VStack(spacing: 12) {
                Image(systemName: "photo.stack")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text(String(localized: "No meals yet", comment: "Meal library empty state title"))
                    .font(.headline)
                Text(String(
                    localized: "Meals you analyze or save in FoodFinder appear here.",
                    comment: "Meal library empty state description"
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }

        // MARK: - Folders

        private func startNewFolder(for memberKey: String?) {
            newFolderMemberKey = memberKey
            newFolderName = ""
            isAddingFolder = true
        }

        private func addFolder() {
            let store = MealFolderStore()
            if let name = store.addFolder(newFolderName), let key = newFolderMemberKey, !store.isInFolder(name, memberKey: key) {
                store.toggle(name, forMemberKey: key)
            }
            newFolderMemberKey = nil
            newFolderName = ""
            reloadFolders()
        }

        private func reloadFolders() {
            let store = MealFolderStore()
            folderNames = store.folderNames()
            folderAssignments = store.assignments()
            filter.tags = filter.tags.filter { tag in folderNames.contains { SavedMealFolderStore.same($0, tag) } }
        }

        // MARK: - Loading

        private func loadMeals() async {
            let fallback = fallbackResults
            // Do disk reads off the main actor, then publish on the main actor.
            let loaded: ([DisplayMeal], [String], [String: [String]]) = await Task.detached(priority: .userInitiated) {
                let store = MealGalleryStore.shared
                let index = store.loadIndex()
                let folderStore = MealFolderStore()
                folderStore.migrateIfNeeded(galleryItems: index, galleryGroupNames: store.loadGroupNames())
                let meals = index.map { item in
                    Self.makeDisplayMeal(item: item, fallback: fallback.first(where: { $0.id == item.id }))
                }
                return (meals, folderStore.folderNames(), folderStore.assignments())
            }.value

            await MainActor.run {
                self.archivedMeals = loaded.0
                self.folderNames = loaded.1
                self.folderAssignments = loaded.2
                self.isLoading = false
            }
        }

        nonisolated private static func makeDisplayMeal(
            item: MealGalleryStore.GalleryItem,
            fallback: FoodAnalysisResult?
        ) -> DisplayMeal {
            let snapshots = item.items.isEmpty
                ? (fallback?.items.map { GalleryFoodSnapshot(item: $0) } ?? [])
                : item.items
            let itemCarbs: [DisplayMeal.ItemCarb]
            if let fallback, !fallback.items.isEmpty {
                itemCarbs = fallback.items.map { .init(id: $0.id, name: $0.name, carbs: $0.adjustedCarbs) }
            } else {
                itemCarbs = snapshots.map {
                    .init(id: UUID(), name: $0.name, carbs: $0.carbs * $0.portionMultiplier)
                }
            }
            return DisplayMeal(
                id: item.id,
                date: item.date,
                mealName: item.mealName ?? fallback?.mealName,
                totalCarbs: item.totalCarbs,
                totalFat: item.totalFat > 0 ? item.totalFat : (fallback?.totalFat ?? 0),
                totalProtein: item.totalProtein > 0 ? item.totalProtein : (fallback?.totalProtein ?? 0),
                totalFiber: item.totalFiber,
                totalCalories: item.totalCalories,
                mealSlot: item.resolvedMealSlot(),
                memberKey: MealFolderStore.memberKey(for: item),
                fullImageData: fallback?.imageData,
                items: itemCarbs,
                snapshots: snapshots
            )
        }

        nonisolated private static func makeDisplayMeal(result: FoodAnalysisResult) -> DisplayMeal {
            DisplayMeal(
                id: result.id,
                date: result.timestamp,
                mealName: result.mealName?.aiInsightsNilIfEmpty ?? result.mealDescription,
                totalCarbs: result.totalCarbs,
                totalFat: result.totalFat,
                totalProtein: result.totalProtein,
                totalFiber: result.totalFiber,
                totalCalories: result.totalCalories,
                mealSlot: MealSlot.from(date: result.timestamp),
                memberKey: MealFolderStore.memberKey(for: result),
                fullImageData: result.imageData,
                items: result.items.map { .init(id: $0.id, name: $0.name, carbs: $0.adjustedCarbs) },
                snapshots: result.items.map { GalleryFoodSnapshot(item: $0) }
            )
        }

        /// Project a display row back onto `GalleryItem` so the shared filter matcher stays the single source of
        /// truth. Its tags are the meal's folders, so the folder filter and the search see them.
        private func displayMealAsItem(_ meal: DisplayMeal) -> MealGalleryStore.GalleryItem {
            MealGalleryStore.GalleryItem(
                id: meal.id,
                date: meal.date,
                mealName: meal.title,
                totalCarbs: meal.totalCarbs,
                thumbnailFilename: "\(meal.id.uuidString).jpg",
                totalFat: meal.totalFat,
                totalProtein: meal.totalProtein,
                totalFiber: meal.totalFiber,
                totalCalories: meal.totalCalories,
                tags: folders(of: meal),
                mealSlot: meal.mealSlot,
                items: meal.snapshots
            )
        }

        func preferredResult(for meal: DisplayMeal) -> FoodAnalysisResult {
            if let savedID = meal.savedID, let saved = savedMeals.first(where: { $0.id == savedID }) {
                return saved.result
            }
            if let fallback = fallbackResults.first(where: { $0.id == meal.id }), !fallback.items.isEmpty {
                return fallback
            }
            return meal.resolvedResult
        }
    }

    // MARK: - Detail

    /// Full-size view of a single gallery meal. Visual language matches
    /// FoodFinder's result cards (photo overlay, carbs hero, macro chips).
    struct MealDetailView: View {
        let meal: MealGalleryView.DisplayMeal
        let result: FoodAnalysisResult
        var knownFolders: [String] = []
        var shareEnabled: Bool = false
        var units: GlucoseUnits = .mgdL
        var onOpenInFoodFinder: ((FoodAnalysisResult) -> Void)? = nil
        var onUseInBolusCalculator: ((FoodAnalysisResult) -> Void)? = nil
        var onFoldersChanged: (([String]) -> Void)? = nil

        @Environment(\.dismiss) private var dismiss
        @Environment(\.colorScheme) private var colorScheme
        @State private var folders: [String]
        @State private var newFolder: String = ""
        /// HD photo from the gallery store, for meals whose capture has left the recent list.
        @State private var photoData: Data?

        private var displayImageData: Data? {
            result.imageData ?? photoData ?? meal.fullImageData
        }

        init(
            meal: MealGalleryView.DisplayMeal,
            result: FoodAnalysisResult,
            folders: [String] = [],
            knownFolders: [String] = [],
            shareEnabled: Bool = false,
            units: GlucoseUnits = .mgdL,
            onOpenInFoodFinder: ((FoodAnalysisResult) -> Void)? = nil,
            onUseInBolusCalculator: ((FoodAnalysisResult) -> Void)? = nil,
            onFoldersChanged: (([String]) -> Void)? = nil
        ) {
            self.meal = meal
            self.result = result
            self.knownFolders = knownFolders
            self.shareEnabled = shareEnabled
            self.units = units
            self.onOpenInFoodFinder = onOpenInFoodFinder
            self.onUseInBolusCalculator = onUseInBolusCalculator
            self.onFoldersChanged = onFoldersChanged
            _folders = State(initialValue: folders)
        }

        private var dateText: String {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter.string(from: meal.date)
        }

        /// Date and meal slot; a meal preset has no meal time.
        private var subtitleText: String? {
            meal.isUndated ? nil : "\(dateText) · \(meal.mealSlot.localizedTitle)"
        }

        private var cardFill: Color {
            colorScheme == .dark ? Color.bgDarkerDarkBlue.opacity(0.8) : Color.white
        }

        private var shareContent: MealShareContent {
            MealShareContent(
                title: meal.title,
                subtitle: subtitleText,
                carbs: meal.totalCarbs,
                fat: meal.totalFat,
                protein: meal.totalProtein,
                fiber: meal.totalFiber,
                calories: meal.totalCalories,
                photo: displayImageData
            )
        }

        var body: some View {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        photoOrIdentityCard

                        macroCard

                        if !meal.items.isEmpty {
                            itemsCard
                        }

                        responseCard

                        foldersCard

                        actions
                    }
                    .padding(16)
                }
                .background(colorScheme == .dark ? Color.clear : Color(UIColor.systemGroupedBackground))
                .task {
                    guard result.imageData == nil, meal.fullImageData == nil, !meal.isUndated else { return }
                    let id = meal.id
                    photoData = await Task.detached(priority: .userInitiated) {
                        let store = MealGalleryStore.shared
                        return store.photoData(forMealID: id) ?? store.thumbnailData(forMealID: id)
                    }.value
                }
                .navigationTitle(String(localized: "Meal", comment: "Meal detail navigation title"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        MealShareButton(content: shareContent)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            dismiss()
                        } label: {
                            Text(String(localized: "Done", comment: "Close meal detail button"))
                        }
                    }
                }
            }
        }

        @ViewBuilder private var photoOrIdentityCard: some View {
            if let data = displayImageData, let image = UIImage(data: data) {
                ZStack(alignment: .bottomLeading) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .aspectRatio(1.45, contentMode: .fit)
                        .clipped()

                    VStack(alignment: .leading, spacing: 3) {
                        Text(meal.title)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        if let subtitleText {
                            Text(subtitleText)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(1)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        LinearGradient(
                            colors: [.black.opacity(0), .black.opacity(0.62)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 14).fill(cardFill))
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(meal.title)
                        .font(.headline)
                        .lineLimit(2)
                    if let subtitleText {
                        Text(subtitleText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(RoundedRectangle(cornerRadius: 12).fill(cardFill))
            }
        }

        private var macroCard: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "Totals", comment: "FoodFinder totals card header"))
                    .font(.subheadline.bold())
                    .padding(.top, 11)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(String(format: "%.0f", meal.totalCarbs))
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(.blue)
                    Text(String(localized: "g carbs", comment: "FoodFinder carbs hero unit"))
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }

                HStack(spacing: 16) {
                    galleryMacroChip(label: String(localized: "Fat", comment: "Fat macro"), value: meal.totalFat, unit: "g", color: .yellow)
                    galleryMacroChip(label: String(localized: "Protein", comment: "Protein macro"), value: meal.totalProtein, unit: "g", color: .red)
                    galleryMacroChip(label: String(localized: "Fiber", comment: "Fiber macro"), value: meal.totalFiber, unit: "g", color: .green)
                    galleryMacroChip(label: String(localized: "Calories", comment: "Calories label"), value: meal.totalCalories, unit: "kcal", color: .secondary)
                    Spacer(minLength: 0)
                }
                .padding(.bottom, 12)
            }
            .padding(.horizontal)
            .background(RoundedRectangle(cornerRadius: 12).fill(cardFill))
        }

        private func galleryMacroChip(label: String, value: Double, unit: String, color: Color) -> some View {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(String(format: "%.0f", value)) \(unit)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(color)
                    .lineLimit(1)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }

        private var itemsCard: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "Ingredients", comment: "FoodFinder ingredients section"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(meal.items) { item in
                    HStack {
                        Text(item.name)
                            .lineLimit(1)
                        Spacer()
                        Text("\(Int(item.carbs.rounded())) g")
                            .foregroundStyle(.blue)
                            .fontWeight(.semibold)
                    }
                    .font(.subheadline)
                    .padding(.vertical, 4)
                    if item.id != meal.items.last?.id {
                        Divider()
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(cardFill))
        }

        private var responseCard: some View {
            let keys = MealResponseKeys(results: [result])
            return MealResponseCard(
                title: String(localized: "Glucose after this meal", comment: "Meal detail response card title"),
                mealIDs: keys.mealIDs,
                foodResultIDs: keys.foodResultIDs,
                units: units,
                cardFill: cardFill,
                currentCarbs: result.totalCarbs
            )
        }

        private var foldersCard: some View {
            foldersSection
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(cardFill))
        }

        private var actions: some View {
            VStack(spacing: 10) {
                if onUseInBolusCalculator != nil {
                    Button {
                        onUseInBolusCalculator?(result)
                        dismiss()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.forward.circle.fill")
                            Text(String(localized: "Use in Bolus Calculator", comment: "FoodFinder bolus handoff button"))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(meal.totalCarbs == 0 && meal.totalFat == 0 && meal.totalProtein == 0 && meal.items.isEmpty)
                }

                if onOpenInFoodFinder != nil {
                    Button {
                        onOpenInFoodFinder?(result)
                        dismiss()
                    } label: {
                        Text(String(localized: "Open in FoodFinder", comment: "Reload gallery meal into FoodFinder"))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }

                MealShareButton(content: shareContent, showsTitle: true)
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                // The companion only receives photographed meals.
                if shareEnabled, let source = displayImageData {
                    Button {
                        let payload = SharedMealPayload(result: result, thumbnailFilename: nil)
                        Task.detached(priority: .userInitiated) {
                            let photo = MealGalleryStore.makePhotoJPEG(from: source) ?? source
                            MealCompanionPublisher.shared.publish(payload: payload, thumbnailJPEG: photo)
                        }
                    } label: {
                        Text(String(localized: "Send to companion", comment: "Manually publish one gallery meal to companion outbox"))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                Label(
                    String(localized: "AI estimates may be inaccurate. Always verify carb counts before dosing.", comment: "FoodFinder disclaimer"),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            }
        }

        private var foldersSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "Folders", comment: "Meal library browse-by-folder mode"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                if !folders.isEmpty {
                    FlowTagList(tags: folders) { folder in
                        folders.removeAll { $0 == folder }
                        onFoldersChanged?(folders)
                    }
                }

                HStack {
                    TextField(
                        String(localized: "Add folder", comment: "Add a meal to a new library folder"),
                        text: $newFolder
                    )
                    Button(String(localized: "Add", comment: "Add meal gallery group")) {
                        addFolder(newFolder)
                    }
                    .disabled(newFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if !knownFolders.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(knownFolders, id: \.self) { name in
                                Button(name) {
                                    addFolder(name)
                                }
                                .buttonStyle(.bordered)
                                .font(.caption)
                                .disabled(folders.contains { SavedMealFolderStore.same($0, name) })
                            }
                        }
                    }
                }
            }
        }

        private func addFolder(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            newFolder = ""
            guard !trimmed.isEmpty, !folders.contains(where: { SavedMealFolderStore.same($0, trimmed) }) else { return }
            folders.append(knownFolders.first { SavedMealFolderStore.same($0, trimmed) } ?? trimmed)
            onFoldersChanged?(folders)
        }
    }

    // MARK: - Filters

    struct GalleryFilterSheet: View {
        @Binding var filter: GalleryFilter
        var knownTags: [String]
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            NavigationStack {
                Form {
                    Section(String(localized: "Date", comment: "Meal gallery date filter section")) {
                        Toggle(
                            String(localized: "Limit start date", comment: "Enable meal gallery start-date filter"),
                            isOn: Binding(
                                get: { filter.startDate != nil },
                                set: { filter.startDate = $0 ? Calendar.current.startOfDay(for: Date()) : nil }
                            )
                        )
                        Toggle(
                            String(localized: "Limit end date", comment: "Enable meal gallery end-date filter"),
                            isOn: Binding(
                                get: { filter.endDate != nil },
                                set: { filter.endDate = $0 ? Date() : nil }
                            )
                        )
                        if filter.startDate != nil {
                            DatePicker(
                                String(localized: "From", comment: "Meal gallery date-from"),
                                selection: Binding(
                                    get: { filter.startDate ?? Date() },
                                    set: { filter.startDate = $0 }
                                ),
                                displayedComponents: .date
                            )
                        }
                        if filter.endDate != nil {
                            DatePicker(
                                String(localized: "To", comment: "Meal gallery date-to"),
                                selection: Binding(
                                    get: { filter.endDate ?? Date() },
                                    set: { filter.endDate = $0 }
                                ),
                                displayedComponents: .date
                            )
                        }
                        HStack {
                            presetButton(String(localized: "Today", comment: "Meal gallery today preset")) {
                                let start = Calendar.current.startOfDay(for: Date())
                                filter.startDate = start
                                filter.endDate = Date()
                            }
                            presetButton(String(localized: "7 days", comment: "Meal gallery last-7-days preset")) {
                                filter.startDate = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: Date()))
                                filter.endDate = Date()
                            }
                            presetButton(String(localized: "30 days", comment: "Meal gallery last-30-days preset")) {
                                filter.startDate = Calendar.current.date(byAdding: .day, value: -29, to: Calendar.current.startOfDay(for: Date()))
                                filter.endDate = Date()
                            }
                        }
                    }

                    Section(String(localized: "Carbs", comment: "Meal gallery carbs filter section")) {
                        Toggle(
                            String(localized: "Minimum carbs", comment: "Enable meal gallery min-carbs filter"),
                            isOn: Binding(
                                get: { filter.minCarbs != nil },
                                set: { filter.minCarbs = $0 ? 0 : nil }
                            )
                        )
                        if filter.minCarbs != nil {
                            Stepper(
                                String(localized: "At least \(Int(filter.minCarbs ?? 0)) g", comment: "Meal gallery min carbs stepper"),
                                value: Binding(
                                    get: { filter.minCarbs ?? 0 },
                                    set: { filter.minCarbs = $0 }
                                ),
                                in: 0 ... 300,
                                step: 5
                            )
                        }
                        Toggle(
                            String(localized: "Maximum carbs", comment: "Enable meal gallery max-carbs filter"),
                            isOn: Binding(
                                get: { filter.maxCarbs != nil },
                                set: { filter.maxCarbs = $0 ? 60 : nil }
                            )
                        )
                        if filter.maxCarbs != nil {
                            Stepper(
                                String(localized: "At most \(Int(filter.maxCarbs ?? 0)) g", comment: "Meal gallery max carbs stepper"),
                                value: Binding(
                                    get: { filter.maxCarbs ?? 0 },
                                    set: { filter.maxCarbs = $0 }
                                ),
                                in: 0 ... 300,
                                step: 5
                            )
                        }
                    }

                    Section(String(localized: "Meal", comment: "Meal gallery slot filter section")) {
                        Picker(
                            String(localized: "Meal slot", comment: "Meal gallery slot filter picker"),
                            selection: Binding(
                                get: { filter.mealSlot },
                                set: { filter.mealSlot = $0 }
                            )
                        ) {
                            Text(String(localized: "Any", comment: "Any meal slot")).tag(Optional<MealSlot>.none)
                            ForEach(MealSlot.allCases) { slot in
                                Text(slot.localizedTitle).tag(Optional(slot))
                            }
                        }
                    }

                    if !knownTags.isEmpty {
                        Section(String(localized: "Folders", comment: "Meal library browse-by-folder mode")) {
                            ForEach(knownTags, id: \.self) { tag in
                                Toggle(tag, isOn: Binding(
                                    get: { filter.tags.contains(tag) },
                                    set: { on in
                                        if on { filter.tags.insert(tag) }
                                        else { filter.tags.remove(tag) }
                                    }
                                ))
                            }
                        }
                    }
                }
                .navigationTitle(String(localized: "Filters", comment: "Meal gallery filters title"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(String(localized: "Clear", comment: "Clear meal gallery filters")) {
                            filter = GalleryFilter()
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(String(localized: "Done", comment: "Close meal gallery filters")) {
                            dismiss()
                        }
                    }
                }
            }
        }

        private func presetButton(_ title: String, action: @escaping () -> Void) -> some View {
            Button(title, action: action)
                .buttonStyle(.bordered)
                .font(.caption)
        }
    }

    struct CompanionShareSettingsSheet: View {
        @Binding var isEnabled: Bool
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            NavigationStack {
                Form {
                    CompanionShareSettingsForm(isEnabled: $isEnabled)
                }
                .navigationTitle(String(localized: "Companion sharing", comment: "Companion share settings title"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(String(localized: "Done", comment: "Close companion share settings")) {
                            dismiss()
                        }
                    }
                }
            }
        }
    }

    /// Toggle + companion invite link. User-visible copy never includes `<TEAM>`.
    struct CompanionShareSettingsForm: View {
        @Binding var isEnabled: Bool
        var usesChartRowBackground: Bool = false

        @State private var shareURLString: String = MealCompanionPublisher.shared.storedShareURLString() ?? ""
        @State private var ownerName: String = MealCompanionShareSettings.storedOwnerDisplayName()
        @State private var isRefreshingInvite = false
        @State private var inviteStatus: String?
        @State private var inviteStatusIsError = false

        private var containerID: String {
            MealCompanionShareSettings.displayContainerIdentifier()
        }

        private var inviteURL: URL? {
            MealCompanionShareSettings.validatedICloudShareURL(from: shareURLString)
        }

        var body: some View {
            Section {
                Toggle(isOn: $isEnabled) {
                    Text(String(localized: "Share meals with companion", comment: "Opt-in companion meal share toggle"))
                }
                .onChange(of: isEnabled) { _, newValue in
                    MealCompanionPublisher.shared.isShareEnabled = newValue
                    reloadStoredURL()
                    if newValue { refreshEntitlementStatus() }
                }

                if isEnabled {
                    TextField(
                        String(localized: "Name on shared meals", comment: "Companion owner display name field"),
                        text: $ownerName,
                        prompt: Text(MealCompanionShareSettings.defaultOwnerDisplayName)
                    )
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .onChange(of: ownerName) { _, newValue in
                        MealCompanionShareSettings.setOwnerDisplayName(newValue)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(localized: "CloudKit container", comment: "Companion CloudKit container label"))
                            .font(.subheadline)
                        Text(containerID)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    }

                    if let inviteURL {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(String(localized: "Invite link", comment: "Companion invite URL label"))
                                .font(.subheadline)
                            Text(inviteURL.absoluteString)
                                .font(.caption)
                                .textSelection(.enabled)
                                .foregroundStyle(.secondary)
                            Button(String(localized: "Copy invite link", comment: "Copy companion invite URL")) {
                                copyInviteLink()
                            }
                            .disabled(isRefreshingInvite)
                        }
                    } else {
                        Text(String(
                            localized: "The invite link appears after CloudKit creates a share — tap Create invite, or it shows up after the first published meal.",
                            comment: "Companion invite missing help"
                        ))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }

                    Button {
                        Task { await refreshInvite() }
                    } label: {
                        if isRefreshingInvite {
                            ProgressView()
                        } else {
                            Text(String(localized: "Create / refresh invite", comment: "Create or refresh companion CKShare URL"))
                        }
                    }
                    .disabled(isRefreshingInvite)

                    if let inviteStatus {
                        Text(inviteStatus)
                            .font(.footnote)
                            .foregroundStyle(inviteStatusIsError ? Color.red : Color.secondary)
                            .textSelection(.enabled)
                    }
                }
            } header: {
                Text(String(localized: "Companion sharing", comment: "Companion meal share settings header"))
            } footer: {
                Text(String(
                    localized: "Off by default. When on, newly archived meals share name, time, and photo only — never glucose, IOB, COB, or Nightscout. Copy the invite link for the companion app. This is not the Trio therapy App Group.",
                    comment: "Companion meal share privacy footer without TEAM placeholder"
                ))
            }
            .modifier(OptionalChartRowBackground(enabled: usesChartRowBackground))
            .onAppear {
                reloadStoredURL()
                ownerName = MealCompanionShareSettings.storedOwnerDisplayName()
                if isEnabled { refreshEntitlementStatus() }
            }
        }

        private func reloadStoredURL() {
            shareURLString = MealCompanionPublisher.shared.storedShareURLString() ?? ""
        }

        private func refreshEntitlementStatus() {
            let id = MealCompanionShareSettings.cloudKitContainerIdentifier()
            switch MealCloudKitEntitlement.check(id) {
            case .entitled:
                return
            case .missing:
                setInviteStatus(MealCompanionShareError.missingCloudKitEntitlement.localizedDescription, isError: true)
            case .unreadable:
                setInviteStatus(MealCompanionShareError.unreadableSigningEntitlements.localizedDescription, isError: true)
            }
        }

        private func setInviteStatus(_ text: String?, isError: Bool) {
            inviteStatus = text
            inviteStatusIsError = isError
        }

        /// Pasteboard-only copy on the next main-queue turn. Do not flip button
        /// identity (`didCopy` / `ShareLink` / bordered `HStack`) during the tap —
        /// that rebuild crashed SwiftUI on device.
        @MainActor
        private func copyInviteLink() {
            guard let url = MealCompanionShareSettings.validatedICloudShareURL(from: shareURLString) else {
                setInviteStatus(
                    String(
                        localized: "No valid invite link to copy. Tap Create / refresh invite.",
                        comment: "Companion invite copy missing or invalid URL"
                    ),
                    isError: true
                )
                return
            }
            let text = url.absoluteString
            guard !text.isEmpty else {
                setInviteStatus(
                    String(
                        localized: "No valid invite link to copy. Tap Create / refresh invite.",
                        comment: "Companion invite copy missing or invalid URL"
                    ),
                    isError: true
                )
                return
            }
            DispatchQueue.main.async {
                writeInviteToPasteboard(text)
            }
        }

        @MainActor
        private func writeInviteToPasteboard(_ text: String) {
            guard MealCompanionShareSettings.validatedICloudShareURL(from: text) != nil else {
                setInviteStatus(
                    String(
                        localized: "No valid invite link to copy. Tap Create / refresh invite.",
                        comment: "Companion invite copy missing or invalid URL"
                    ),
                    isError: true
                )
                return
            }
            UIPasteboard.general.string = text
            setInviteStatus(
                String(
                    localized: "Copied. Send this invite link to your companion.",
                    comment: "Companion invite copied confirmation"
                ),
                isError: false
            )
        }

        @MainActor
        private func refreshInvite() async {
            isRefreshingInvite = true
            setInviteStatus(nil, isError: false)
            defer { isRefreshingInvite = false }
            let result = await MealCompanionPublisher.shared.ensureInviteShare()
            switch result {
            case let .success(url):
                if let validated = MealCompanionShareSettings.validatedICloudShareURL(from: url) {
                    shareURLString = validated.absoluteString
                    setInviteStatus(
                        String(
                            localized: "Invite ready. Copy the link for your companion.",
                            comment: "Companion invite created"
                        ),
                        isError: false
                    )
                } else {
                    reloadStoredURL()
                    let shown = url.count > 120 ? String(url.prefix(117)) + "..." : url
                    setInviteStatus(
                        MealCompanionShareError.inviteCreateFailed(
                            "CloudKit returned \"\(shown)\" which is not an https iCloud share link."
                        ).localizedDescription,
                        isError: true
                    )
                }
            case let .failure(error):
                reloadStoredURL()
                setInviteStatus(MealCompanionShareError.userFacingMessage(for: error), isError: true)
            }
        }
    }

    private struct OptionalChartRowBackground: ViewModifier {
        let enabled: Bool

        func body(content: Content) -> some View {
            if enabled {
                content.listRowBackground(Color.chart)
            } else {
                content
            }
        }
    }

    private struct FlowTagList: View {
        let tags: [String]
        var onRemove: (String) -> Void

        var body: some View {
            FlexibleTagWrap(tags: tags, onRemove: onRemove)
        }
    }

    private struct FlexibleTagWrap: View {
        let tags: [String]
        var onRemove: (String) -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(tags, id: \.self) { tag in
                    HStack(spacing: 4) {
                        Text(tag)
                            .font(.caption)
                        Button {
                            onRemove(tag)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
            }
        }
    }
}

// MARK: - Share card

extension AIInsights {
    /// What the share image of a meal shows. Never glucose, insulin or any therapy data.
    struct MealShareContent: Equatable {
        var title: String
        var subtitle: String?
        var carbs: Double
        var fat: Double
        var protein: Double
        var fiber: Double
        var calories: Double
        /// Meal photo; a meal without one gets the FoodFinder placeholder.
        var photo: Data?
        /// Meal whose archived photo is used when `photo` is nil.
        var photoMealID: UUID?

        init(
            title: String,
            subtitle: String?,
            carbs: Double,
            fat: Double,
            protein: Double,
            fiber: Double,
            calories: Double,
            photo: Data?,
            photoMealID: UUID? = nil
        ) {
            self.title = title
            self.subtitle = subtitle
            self.carbs = carbs
            self.fat = fat
            self.protein = protein
            self.fiber = fiber
            self.calories = calories
            self.photo = photo
            self.photoMealID = photoMealID
        }

        init(result: FoodAnalysisResult, title: String, subtitle: String?, photo: Data?) {
            self.init(
                title: title,
                subtitle: subtitle,
                carbs: result.totalCarbs,
                fat: result.totalFat,
                protein: result.totalProtein,
                fiber: result.totalFiber,
                calories: result.totalCalories,
                photo: photo,
                photoMealID: result.id
            )
        }

        /// Renders the share card. The photo is downscaled off the main thread first.
        @MainActor func render() async -> UIImage? {
            let data = photo
            let mealID = photoMealID
            let photo: UIImage? = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let source = data ?? mealID.flatMap({ MealGalleryStore.shared.photoData(forMealID: $0) }),
                      let jpeg = MealGalleryStore.makePhotoJPEG(from: source)
                else { return nil }
                return UIImage(data: jpeg)
            }.value
            let renderer = ImageRenderer(content: MealShareCard(content: self, photo: photo))
            renderer.scale = 3
            renderer.isOpaque = true
            return renderer.uiImage
        }
    }

    /// The image a meal is shared as: the photo with the meal name on it, the macros underneath, in the look of the
    /// FoodFinder meal card. Always light, so it reads the same wherever it is sent.
    struct MealShareCard: View {
        let content: MealShareContent
        let photo: UIImage?

        static let width: CGFloat = 390
        private static let photoHeight: CGFloat = 300

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .bottomLeading) {
                    photoView
                        .frame(width: Self.width - 24, height: Self.photoHeight)
                        .clipped()

                    VStack(alignment: .leading, spacing: 4) {
                        Text(content.title)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.white)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                        if let subtitle = content.subtitle {
                            Text(subtitle)
                                .font(.footnote)
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 36)
                    .padding(.bottom, 14)
                    .frame(width: Self.width - 24, alignment: .leading)
                    .background(
                        LinearGradient(
                            colors: [.black.opacity(0), .black.opacity(0.68)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(String(format: "%.0f", content.carbs))
                            .font(.system(size: 44, weight: .bold, design: .rounded))
                            .foregroundStyle(.blue)
                        Text(String(localized: "g carbs", comment: "FoodFinder carbs hero unit"))
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }

                    let chips = macroChips
                    if !chips.isEmpty {
                        HStack(spacing: 18) {
                            ForEach(chips, id: \.label) { chip in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("\(String(format: "%.0f", chip.value)) \(chip.unit)")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(chip.color)
                                        .lineLimit(1)
                                    Text(chip.label)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }

                    HStack(spacing: 4) {
                        Image(systemName: "fork.knife.circle.fill")
                        Text(String(localized: "Estimated with FoodFinder", comment: "Meal share card footer"))
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                }
                .padding(.horizontal, 8)
                .padding(.top, 14)
                .padding(.bottom, 8)
            }
            .padding(12)
            .frame(width: Self.width)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        }

        @ViewBuilder private var photoView: some View {
            if let photo {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: [Color.blue.opacity(0.35), Color.teal.opacity(0.3)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .overlay {
                    Image(systemName: "fork.knife")
                        .font(.system(size: 56, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.bottom, 40)
                }
            }
        }

        private struct MacroChip {
            let label: String
            let value: Double
            let unit: String
            let color: Color
        }

        /// Only the macros the meal has.
        private var macroChips: [MacroChip] {
            [
                MacroChip(label: String(localized: "Fat", comment: "Fat macro"), value: content.fat, unit: "g", color: .orange),
                MacroChip(label: String(localized: "Protein", comment: "Protein macro"), value: content.protein, unit: "g", color: .red),
                MacroChip(label: String(localized: "Fiber", comment: "Fiber macro"), value: content.fiber, unit: "g", color: .green),
                MacroChip(label: String(localized: "Calories", comment: "Calories label"), value: content.calories, unit: "kcal", color: .secondary)
            ]
            .filter { $0.value.rounded() > 0 }
        }
    }

    /// Shares a meal as its share card through the system share sheet. The card is rendered when the button appears
    /// and again when the meal changes.
    struct MealShareButton: View {
        let content: MealShareContent
        /// Shows "Share" next to the icon, for a full-width action button.
        var showsTitle: Bool = false

        @State private var image: UIImage?

        private var title: String {
            String(localized: "Share", comment: "Share a meal as an image")
        }

        var body: some View {
            Group {
                if let image {
                    ShareLink(
                        item: Image(uiImage: image),
                        preview: SharePreview(content.title, image: Image(uiImage: image))
                    ) {
                        label
                    }
                } else {
                    Button {} label: {
                        label
                    }
                    .disabled(true)
                }
            }
            .accessibilityLabel(String(localized: "Share meal", comment: "Share a meal as an image, accessibility label"))
            .task(id: content) {
                image = await content.render()
            }
        }

        @ViewBuilder private var label: some View {
            if showsTitle {
                Label(title, systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            } else {
                Image(systemName: "square.and.arrow.up")
            }
        }
    }
}
