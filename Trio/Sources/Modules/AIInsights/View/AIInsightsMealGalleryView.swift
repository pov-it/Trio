//
//  AIInsightsMealGalleryView.swift
//  Trio
//
//  Meal-photo gallery for FoodFinder (Feature M). A grid of thumbnails of
//  previously analyzed meals that have a photo, newest first, each with a small
//  carbs badge. Tapping a thumbnail opens a detail sheet with the larger image,
//  meal name, timestamp, total carbs, and (when available) a per-item carb list.
//
//  Source of truth is the durable `MealGalleryStore` (compressed on-disk
//  thumbnails). When that store is still empty (e.g. for meals logged before the
//  store existed) it falls back to the inline `imageData` of FoodFinder's recent
//  results so history is still shown.
//

import SwiftUI

extension AIInsights {
    struct MealGalleryView: View {
        /// Recent FoodFinder results, used only as a fallback when the on-disk
        /// gallery store is empty (older meals that predate the store).
        let fallbackResults: [FoodAnalysisResult]

        @Environment(\.dismiss) private var dismiss
        @Environment(\.colorScheme) private var colorScheme

        @State private var meals: [DisplayMeal] = []
        @State private var selectedMeal: DisplayMeal?
        @State private var isLoading = true

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
            /// Thumbnail bytes for the grid cell.
            let thumbnailData: Data?
            /// Larger image bytes for the detail view (inline image when we have
            /// it, otherwise the thumbnail).
            let fullImageData: Data?
            /// Per-item carbs (name, adjusted carbs) — only present via the
            /// fallback path; empty when sourced from the compact store index.
            let items: [ItemCarb]

            struct ItemCarb: Identifiable, Equatable {
                let id = UUID()
                let name: String
                let carbs: Double
            }
        }

        // MARK: - Body

        var body: some View {
            NavigationStack {
                Group {
                    if meals.isEmpty {
                        emptyState
                    } else {
                        gridContent
                    }
                }
                .navigationTitle(String(localized: "Meal gallery", comment: "Meal gallery navigation title"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            dismiss()
                        } label: {
                            Text(String(localized: "Done", comment: "Close meal gallery button"))
                        }
                    }
                }
            }
            .task {
                await loadMeals()
            }
            .sheet(item: $selectedMeal) { meal in
                MealDetailView(meal: meal)
            }
        }

        private var gridContent: some View {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(meals) { meal in
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
            let loaded: [DisplayMeal] = await Task.detached(priority: .userInitiated) {
                let index = MealGalleryStore.shared.loadIndex()
                if !index.isEmpty {
                    return index.map { item in
                        let data = MealGalleryStore.shared.thumbnailData(for: item)
                        return DisplayMeal(
                            id: item.id,
                            date: item.date,
                            mealName: item.mealName,
                            totalCarbs: item.totalCarbs,
                            thumbnailData: data,
                            fullImageData: data,
                            items: []
                        )
                    }
                }
                // Fallback: inline recent results that carry a photo.
                return fallback
                    .filter { ($0.imageData?.isEmpty == false) }
                    .sorted { $0.timestamp > $1.timestamp }
                    .map { result in
                        DisplayMeal(
                            id: result.id,
                            date: result.timestamp,
                            mealName: result.mealName,
                            totalCarbs: result.totalCarbs,
                            thumbnailData: result.imageData,
                            fullImageData: result.imageData,
                            items: result.items.map { .init(name: $0.name, carbs: $0.adjustedCarbs) }
                        )
                    }
            }.value

            await MainActor.run {
                self.meals = loaded
                self.isLoading = false
            }
        }
    }

    // MARK: - Detail

    /// Full-size view of a single gallery meal.
    struct MealDetailView: View {
        let meal: MealGalleryView.DisplayMeal

        @Environment(\.dismiss) private var dismiss

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
                            Text(String(
                                localized: "Total carbs: \(Int(meal.totalCarbs.rounded())) g",
                                comment: "Meal detail total carbs"
                            ))
                            .font(.headline)
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
    }
}
