//
//  AIInsightsMealGalleryView.swift
//  Trio
//
//  Meal-photo gallery for FoodFinder (Feature M). A grid of thumbnails of
//  previously analyzed meals that have a photo, newest first, each with a small
//  carbs badge. Tapping a thumbnail opens a detail sheet with the larger image,
//  meal name, timestamp, macros, tags, and actions to reload FoodFinder or
//  `FoodBolusHandoff` ("Use in Bolus Calculator").
//
//  Browse modes: flat list, auto folders by meal slot (local hour of `date`),
//  and manual groups/tags. Filters (date, name, carbs, tags/slot) apply on
//  top of every mode. Source of truth is the durable `MealGalleryStore`.
//  When that store is still empty it falls back to FoodFinder's recent
//  `imageData` so history is still shown. Local-first — never waits on sync.
//

import SwiftUI

extension AIInsights {
    struct MealGalleryView: View {
        /// Recent FoodFinder results, used as a fallback when the on-disk
        /// gallery store is empty (older meals that predate the store) and as
        /// the preferred full `FoodItem` list when re-bolusing a recent meal.
        let fallbackResults: [FoodAnalysisResult]
        var onOpenInFoodFinder: ((FoodAnalysisResult) -> Void)? = nil
        var onUseInBolusCalculator: ((FoodAnalysisResult) -> Void)? = nil

        @Environment(\.dismiss) private var dismiss

        @State private var meals: [DisplayMeal] = []
        @State private var selectedMeal: DisplayMeal?
        @State private var isLoading = true
        @State private var filter = GalleryFilter()
        @State private var browseMode: GalleryBrowseMode = .all
        @State private var showFilters = false
        @State private var showShareSettings = false
        @State private var shareEnabled = MealCompanionPublisher.shared.isShareEnabled
        @State private var groupNames: [String] = []
        @State private var newGroupName: String = ""

        private let columns = [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12)
        ]

        // MARK: - View model

        /// Unified display item, built from either the gallery store or the
        /// fallback recent results.
        struct DisplayMeal: Identifiable, Equatable {
            let id: UUID
            let date: Date
            let mealName: String?
            let totalCarbs: Double
            let totalFat: Double
            let totalProtein: Double
            let totalFiber: Double
            let totalCalories: Double
            var tags: [String]
            let mealSlot: MealSlot
            /// Thumbnail bytes for the grid cell.
            let thumbnailData: Data?
            /// Larger image bytes for the detail view (inline image when we have
            /// it, otherwise the thumbnail).
            let fullImageData: Data?
            /// Per-item carbs (name, adjusted carbs) — from the store snapshot
            /// or the fallback recent result.
            let items: [ItemCarb]
            let snapshots: [GalleryFoodSnapshot]

            struct ItemCarb: Identifiable, Equatable {
                let id: UUID
                let name: String
                let carbs: Double
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

        private var visibleMeals: [DisplayMeal] {
            meals.filter { meal in
                filter.matches(displayMealAsItem(meal))
            }
        }

        // MARK: - Body

        var body: some View {
            NavigationStack {
                Group {
                    if meals.isEmpty && !isLoading {
                        emptyState
                    } else {
                        browseContent
                    }
                }
                .navigationTitle(String(localized: "Meal gallery", comment: "Meal gallery navigation title"))
                .navigationBarTitleDisplayMode(.inline)
                .searchable(
                    text: $filter.nameQuery,
                    prompt: String(localized: "Search meals", comment: "Meal gallery search prompt")
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
                        .accessibilityLabel(String(localized: "Gallery options", comment: "Meal gallery options menu"))
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
                    knownGroups: groupNames,
                    shareEnabled: shareEnabled,
                    onOpenInFoodFinder: { result in
                        selectedMeal = nil
                        onOpenInFoodFinder?(result)
                    },
                    onUseInBolusCalculator: { result in
                        selectedMeal = nil
                        onUseInBolusCalculator?(result)
                    },
                    onTagsChanged: { id, tags in
                        MealGalleryStore.shared.setTags(for: id, tags: tags)
                        if let index = meals.firstIndex(where: { $0.id == id }) {
                            meals[index].tags = MealGalleryStore.normalizedTags(tags)
                        }
                        groupNames = MealGalleryStore.shared.loadGroupNames()
                    }
                )
            }
            .sheet(isPresented: $showFilters) {
                GalleryFilterSheet(filter: $filter, knownTags: groupNames)
            }
            .sheet(isPresented: $showShareSettings) {
                CompanionShareSettingsSheet(isEnabled: $shareEnabled)
            }
        }

        @ViewBuilder
        private var browseContent: some View {
            switch browseMode {
            case .all:
                mealGrid(visibleMeals)
            case .mealSlot:
                mealSlotFolders
            case .groups:
                groupFolders
            }
        }

        private var mealSlotFolders: some View {
            List {
                ForEach(MealSlot.allCases) { slot in
                    let slotMeals = visibleMeals.filter { $0.mealSlot == slot }
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

        private var groupFolders: some View {
            List {
                Section {
                    ForEach(groupNames, id: \.self) { name in
                        let grouped = visibleMeals.filter { meal in
                            meal.tags.contains { $0.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
                        }
                        NavigationLink {
                            mealGrid(grouped)
                                .navigationTitle(name)
                        } label: {
                            Label {
                                HStack {
                                    Text(name)
                                    Spacer()
                                    Text("\(grouped.count)")
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "folder")
                            }
                        }
                    }
                    let ungrouped = visibleMeals.filter(\.tags.isEmpty)
                    NavigationLink {
                        mealGrid(ungrouped)
                            .navigationTitle(String(localized: "Ungrouped", comment: "Meal gallery ungrouped folder"))
                    } label: {
                        Label {
                            HStack {
                                Text(String(localized: "Ungrouped", comment: "Meal gallery ungrouped folder"))
                                Spacer()
                                Text("\(ungrouped.count)")
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
                            String(localized: "New group (e.g. halve stokbroodjes)", comment: "Meal gallery new group placeholder"),
                            text: $newGroupName
                        )
                        Button(String(localized: "Add", comment: "Add meal gallery group")) {
                            if MealGalleryStore.shared.addGroupName(newGroupName) != nil {
                                groupNames = MealGalleryStore.shared.loadGroupNames()
                                newGroupName = ""
                            }
                        }
                        .disabled(newGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } footer: {
                    Text(String(
                        localized: "Manual groups stay on this phone. Meal folders (breakfast / lunch / dinner / other) are assigned from the local hour of the photo.",
                        comment: "Meal gallery groups footer"
                    ))
                }
            }
            .listStyle(.insetGrouped)
        }

        private func mealGrid(_ items: [DisplayMeal]) -> some View {
            Group {
                if items.isEmpty {
                    ContentUnavailableView(
                        String(localized: "No matching meals", comment: "Meal gallery empty filter title"),
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text(String(
                            localized: "Try clearing filters or photographing a meal in FoodFinder.",
                            comment: "Meal gallery empty filter description"
                        ))
                    )
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(items) { meal in
                                Button {
                                    selectedMeal = meal
                                } label: {
                                    thumbnailCell(meal)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(16)
                    }
                }
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

        private func thumbnailCell(_ meal: DisplayMeal) -> some View {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let data = meal.thumbnailData, let image = UIImage(data: data) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.gray.opacity(0.25))
                            .overlay(
                                Image(systemName: "photo")
                                    .foregroundStyle(.secondary)
                            )
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                carbsBadge(meal.totalCarbs)
                    .padding(6)
            }
        }

        /// Small, subtle carbs indicator overlaid in a corner of a thumbnail.
        private func carbsBadge(_ carbs: Double) -> some View {
            Text("\(Int(carbs.rounded())) g")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(.black.opacity(0.55))
                )
        }

        private var emptyState: some View {
            VStack(spacing: 12) {
                Image(systemName: "photo.stack")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text(String(localized: "Nog geen maaltijden", comment: "Meal gallery empty state title"))
                    .font(.headline)
                Text(String(
                    localized: "Meals you photograph in FoodFinder appear here.",
                    comment: "Meal gallery empty state description"
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }

        // MARK: - Loading

        private func loadMeals() async {
            let fallback = fallbackResults
            // Do disk reads off the main actor, then publish on the main actor.
            let loaded: ([DisplayMeal], [String]) = await Task.detached(priority: .userInitiated) {
                let store = MealGalleryStore.shared
                let names = store.loadGroupNames()
                let index = store.loadIndex()
                if !index.isEmpty {
                    let meals = index.map { item -> DisplayMeal in
                        let data = store.thumbnailData(for: item)
                        let fallbackMatch = fallback.first(where: { $0.id == item.id })
                        return Self.makeDisplayMeal(
                            item: item,
                            thumbnailData: data,
                            fallback: fallbackMatch
                        )
                    }
                    return (meals, names)
                }
                // Fallback: inline recent results that carry a photo.
                let meals = fallback
                    .filter { ($0.imageData?.isEmpty == false) }
                    .sorted { $0.timestamp > $1.timestamp }
                    .map { Self.makeDisplayMeal(result: $0) }
                return (meals, names)
            }.value

            await MainActor.run {
                self.meals = loaded.0
                self.groupNames = loaded.1
                self.isLoading = false
            }
        }

        private static func makeDisplayMeal(
            item: MealGalleryStore.GalleryItem,
            thumbnailData: Data?,
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
                tags: item.tags,
                mealSlot: item.resolvedMealSlot(),
                thumbnailData: thumbnailData ?? fallback?.imageData,
                fullImageData: fallback?.imageData ?? thumbnailData,
                items: itemCarbs,
                snapshots: snapshots
            )
        }

        private static func makeDisplayMeal(result: FoodAnalysisResult) -> DisplayMeal {
            DisplayMeal(
                id: result.id,
                date: result.timestamp,
                mealName: result.mealName,
                totalCarbs: result.totalCarbs,
                totalFat: result.totalFat,
                totalProtein: result.totalProtein,
                totalFiber: result.totalFiber,
                totalCalories: result.totalCalories,
                tags: [],
                mealSlot: MealSlot.from(date: result.timestamp),
                thumbnailData: result.imageData,
                fullImageData: result.imageData,
                items: result.items.map { .init(id: $0.id, name: $0.name, carbs: $0.adjustedCarbs) },
                snapshots: result.items.map { GalleryFoodSnapshot(item: $0) }
            )
        }

        /// Project a display row back onto `GalleryItem` so the shared filter
        /// matcher stays the single source of truth.
        private func displayMealAsItem(_ meal: DisplayMeal) -> MealGalleryStore.GalleryItem {
            MealGalleryStore.GalleryItem(
                id: meal.id,
                date: meal.date,
                mealName: meal.mealName,
                totalCarbs: meal.totalCarbs,
                thumbnailFilename: "\(meal.id.uuidString).jpg",
                totalFat: meal.totalFat,
                totalProtein: meal.totalProtein,
                totalFiber: meal.totalFiber,
                totalCalories: meal.totalCalories,
                tags: meal.tags,
                mealSlot: meal.mealSlot,
                items: meal.snapshots
            )
        }

        func preferredResult(for meal: DisplayMeal) -> FoodAnalysisResult {
            if let fallback = fallbackResults.first(where: { $0.id == meal.id }), !fallback.items.isEmpty {
                return fallback
            }
            return meal.resolvedResult
        }
    }

    // MARK: - Detail

    /// Full-size view of a single gallery meal.
    struct MealDetailView: View {
        let meal: MealGalleryView.DisplayMeal
        let result: FoodAnalysisResult
        var knownGroups: [String] = []
        var shareEnabled: Bool = false
        var onOpenInFoodFinder: ((FoodAnalysisResult) -> Void)? = nil
        var onUseInBolusCalculator: ((FoodAnalysisResult) -> Void)? = nil
        var onTagsChanged: ((UUID, [String]) -> Void)? = nil

        @Environment(\.dismiss) private var dismiss
        @State private var tags: [String]
        @State private var newTag: String = ""

        init(
            meal: MealGalleryView.DisplayMeal,
            result: FoodAnalysisResult,
            knownGroups: [String] = [],
            shareEnabled: Bool = false,
            onOpenInFoodFinder: ((FoodAnalysisResult) -> Void)? = nil,
            onUseInBolusCalculator: ((FoodAnalysisResult) -> Void)? = nil,
            onTagsChanged: ((UUID, [String]) -> Void)? = nil
        ) {
            self.meal = meal
            self.result = result
            self.knownGroups = knownGroups
            self.shareEnabled = shareEnabled
            self.onOpenInFoodFinder = onOpenInFoodFinder
            self.onUseInBolusCalculator = onUseInBolusCalculator
            self.onTagsChanged = onTagsChanged
            _tags = State(initialValue: meal.tags)
        }

        private var dateText: String {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter.string(from: meal.date)
        }

        var body: some View {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let data = meal.fullImageData, let image = UIImage(data: data) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            if let name = meal.mealName, !name.isEmpty {
                                Text(name)
                                    .font(.title3.weight(.semibold))
                            }
                            Text(dateText)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text(meal.mealSlot.localizedTitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(String(
                                localized: "Total carbs: \(Int(meal.totalCarbs.rounded())) g",
                                comment: "Meal detail total carbs"
                            ))
                            .font(.headline)
                            if meal.totalFat > 0 || meal.totalProtein > 0 {
                                Text(String(
                                    localized: "Fat \(Int(meal.totalFat.rounded())) g · Protein \(Int(meal.totalProtein.rounded())) g",
                                    comment: "Meal detail fat and protein"
                                ))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            }
                        }

                        if !meal.items.isEmpty {
                            Divider()
                            VStack(alignment: .leading, spacing: 8) {
                                Text(String(localized: "Items", comment: "Meal detail per-item list header"))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                ForEach(meal.items) { item in
                                    HStack {
                                        Text(item.name)
                                            .lineLimit(1)
                                        Spacer()
                                        Text("\(Int(item.carbs.rounded())) g")
                                            .foregroundStyle(.secondary)
                                    }
                                    .font(.subheadline)
                                }
                            }
                        }

                        Divider()
                        tagsSection

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
                            }

                            if shareEnabled {
                                Button {
                                    MealCompanionPublisher.shared.publish(
                                        payload: SharedMealPayload(result: result, thumbnailFilename: nil),
                                        thumbnailJPEG: meal.thumbnailData
                                    )
                                } label: {
                                    Text(String(localized: "Share this meal", comment: "Manually publish one gallery meal to companion outbox"))
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                    .padding(16)
                }
                .navigationTitle(String(localized: "Meal", comment: "Meal detail navigation title"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
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

        private var tagsSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "Groups", comment: "Meal detail groups header"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                if !tags.isEmpty {
                    FlowTagList(tags: tags) { tag in
                        tags.removeAll { $0 == tag }
                        onTagsChanged?(meal.id, tags)
                    }
                }

                HStack {
                    TextField(
                        String(localized: "Add group", comment: "Add group to gallery meal"),
                        text: $newTag
                    )
                    .textInputAutocapitalization(.never)
                    Button(String(localized: "Add", comment: "Add meal gallery group")) {
                        addTag(newTag)
                    }
                    .disabled(newTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if !knownGroups.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(knownGroups, id: \.self) { name in
                                Button(name) {
                                    addTag(name)
                                }
                                .buttonStyle(.bordered)
                                .font(.caption)
                                .disabled(tags.contains { $0.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame })
                            }
                        }
                    }
                }
            }
        }

        private func addTag(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if tags.contains(where: { $0.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
                newTag = ""
                return
            }
            tags.append(trimmed)
            newTag = ""
            onTagsChanged?(meal.id, tags)
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
                        Section(String(localized: "Groups", comment: "Meal gallery tag filter section")) {
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
                    Section {
                        Toggle(isOn: $isEnabled) {
                            Text(String(localized: "Share meals with companion", comment: "Opt-in companion meal share toggle"))
                        }
                        .onChange(of: isEnabled) { _, newValue in
                            MealCompanionPublisher.shared.isShareEnabled = newValue
                        }
                    } footer: {
                        Text(String(
                            localized: "Off by default. When on, newly archived meals write a meal-only payload (name, time, photo) to a local outbox and CloudKit Meal / MealFeed records in iCloud.org.pov-it.<TEAM>.meals for Meals Companion. Glucose, IOB, COB, and Nightscout URL/token are never included. This is not the Trio therapy App Group. See https://github.com/pov-it/meals-companion.",
                            comment: "Companion meal share privacy footer"
                        ))
                    }
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
