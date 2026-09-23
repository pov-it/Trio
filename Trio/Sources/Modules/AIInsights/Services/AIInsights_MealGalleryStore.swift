//
//  AIInsights_MealGalleryStore.swift
//  Trio
//
//  On-disk COMPRESSED meal-photo gallery (Feature M).
//
//  FoodFinder keeps the last 20 analyses (with inline JPEG imageData) in
//  UserDefaults (`ai_foodfinder_recent`). This store is a separate, durable
//  archive that outlives that 20-item cap: for every analyzed meal that has a
//  photo it writes a small square JPEG THUMBNAIL (center-cropped, side capped
//  at 320px, quality ~0.5) to Application Support/MealGallery/<uuid>.jpg and
//  records a tiny Codable index entry in UserDefaults (`ai_meal_gallery_index`).
//
//  The index now also holds tags, auto meal-slot, and enough macros / item
//  snapshots to reload FoodFinder or `FoodBolusHandoff` after the recent cap.
//  Thumbnails stay on disk; the index stays small. Archiving is local-first
//  and never waits on companion sync.
//
//  Memory stays low: only thumbnails are ever created/held, never the
//  full-resolution capture. Archiving is idempotent — a meal already in the
//  index is skipped (macros/items may be upgraded in place; tags are kept),
//  so it is cheap to call on every `saveRecentResults()`.
//

import Foundation
import UIKit

extension AIInsights {

    final class MealGalleryStore {

        static let shared = MealGalleryStore()

        /// UserDefaults key holding the JSON-encoded `[GalleryItem]` index.
        static let indexKey = "ai_meal_gallery_index"
        /// UserDefaults key holding the JSON-encoded manual group-name catalog.
        static let groupNamesKey = "ai_meal_gallery_group_names"
        /// Subfolder (under Application Support) holding the thumbnail JPEGs.
        private static let folderName = "MealGallery"
        /// Side length cap for the stored square thumbnail, in pixels.
        private static let maxThumbnailSide: CGFloat = 320
        /// JPEG compression quality for stored thumbnails.
        private static let thumbnailQuality: CGFloat = 0.5

        private let defaults: UserDefaults
        private let fileManager: FileManager
        private let ioQueue = DispatchQueue(label: "trio.ai.mealgallery.io", qos: .utility)
        private let overrideDirectory: URL?
        /// Optional companion hook. The live `shared` store wires this to
        /// `MealCompanionPublisher`; tests leave it nil so archive stays local.
        var companionPublish: ((GalleryItem, Data?) -> Void)?

        convenience init() {
            self.init(defaults: .standard, fileManager: .default, directory: nil)
            companionPublish = { item, jpeg in
                MealCompanionPublisher.shared.publish(item: item, thumbnailJPEG: jpeg)
            }
        }

        /// Test seam: inject a suite `UserDefaults` and a temp directory so
        /// unit tests never touch the live gallery.
        init(defaults: UserDefaults, fileManager: FileManager = .default, directory: URL? = nil) {
            self.defaults = defaults
            self.fileManager = fileManager
            self.overrideDirectory = directory
        }

        // MARK: - Index model

        /// A single persisted gallery entry. Deliberately small — the heavy
        /// image data lives on disk under `thumbnailFilename`.
        ///
        /// New fields (`tags`, `mealSlot`, macros, `items`) are optional on
        /// decode so indexes written before this revision still load.
        struct GalleryItem: Codable, Identifiable, Equatable {
            let id: UUID
            let date: Date
            var mealName: String?
            var totalCarbs: Double
            let thumbnailFilename: String
            var totalFat: Double
            var totalProtein: Double
            var totalFiber: Double
            var totalCalories: Double
            var tags: [String]
            var mealSlot: MealSlot
            var items: [GalleryFoodSnapshot]

            init(
                id: UUID,
                date: Date,
                mealName: String?,
                totalCarbs: Double,
                thumbnailFilename: String,
                totalFat: Double = 0,
                totalProtein: Double = 0,
                totalFiber: Double = 0,
                totalCalories: Double = 0,
                tags: [String] = [],
                mealSlot: MealSlot? = nil,
                items: [GalleryFoodSnapshot] = []
            ) {
                self.id = id
                self.date = date
                self.mealName = mealName
                self.totalCarbs = totalCarbs
                self.thumbnailFilename = thumbnailFilename
                self.totalFat = totalFat
                self.totalProtein = totalProtein
                self.totalFiber = totalFiber
                self.totalCalories = totalCalories
                self.tags = MealGalleryStore.normalizedTags(tags)
                self.mealSlot = mealSlot ?? MealSlot.from(date: date)
                self.items = items
            }

            enum CodingKeys: String, CodingKey {
                case id
                case date
                case mealName
                case totalCarbs
                case thumbnailFilename
                case totalFat
                case totalProtein
                case totalFiber
                case totalCalories
                case tags
                case mealSlot
                case items
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                id = try container.decode(UUID.self, forKey: .id)
                date = try container.decode(Date.self, forKey: .date)
                mealName = try container.decodeIfPresent(String.self, forKey: .mealName)
                totalCarbs = try container.decodeIfPresent(Double.self, forKey: .totalCarbs) ?? 0
                thumbnailFilename = try container.decode(String.self, forKey: .thumbnailFilename)
                totalFat = try container.decodeIfPresent(Double.self, forKey: .totalFat) ?? 0
                totalProtein = try container.decodeIfPresent(Double.self, forKey: .totalProtein) ?? 0
                totalFiber = try container.decodeIfPresent(Double.self, forKey: .totalFiber) ?? 0
                totalCalories = try container.decodeIfPresent(Double.self, forKey: .totalCalories) ?? 0
                tags = MealGalleryStore.normalizedTags(
                    try container.decodeIfPresent([String].self, forKey: .tags) ?? []
                )
                mealSlot = try container.decodeIfPresent(MealSlot.self, forKey: .mealSlot)
                    ?? MealSlot.from(date: date)
                items = try container.decodeIfPresent([GalleryFoodSnapshot].self, forKey: .items) ?? []
            }

            func resolvedMealSlot(calendar: Calendar = .current) -> MealSlot {
                // Recompute from local hour so a stored slot from an older
                // cutoff table cannot drift; `mealSlot` is still persisted as
                // a cache / filter hint.
                MealSlot.from(date: date, calendar: calendar)
            }

            var searchHaystack: String {
                var parts: [String] = []
                if let mealName { parts.append(mealName) }
                parts.append(contentsOf: items.map(\.name))
                parts.append(contentsOf: tags)
                return parts.joined(separator: " ")
            }

            var canReuseForBolus: Bool {
                totalCarbs > 0 || totalFat > 0 || totalProtein > 0 || !items.isEmpty
            }

            /// Rebuild a FoodFinder result from the compact index. Prefer the
            /// live 20-item recent list (full `FoodItem`s) when the caller has
            /// it; this path is the durable fallback.
            func toFoodAnalysisResult(imageData: Data? = nil) -> FoodAnalysisResult {
                let foodItems: [FoodItem]
                if items.isEmpty {
                    foodItems = [
                        FoodItem(
                            name: mealName?.trimmingCharacters(in: .whitespacesAndNewlines).aiInsightsNilIfEmpty
                                ?? String(localized: "Meal", comment: "Generic meal title"),
                            portion: "",
                            carbs: totalCarbs,
                            fat: totalFat,
                            protein: totalProtein,
                            fiber: totalFiber,
                            calories: totalCalories
                        )
                    ]
                } else {
                    foodItems = items.map { $0.toFoodItem() }
                }
                return FoodAnalysisResult(
                    id: id,
                    items: foodItems,
                    rawResponse: nil,
                    timestamp: date,
                    source: .aiCamera,
                    imageData: imageData,
                    mealDescription: mealName,
                    mealName: mealName
                )
            }
        }

        // MARK: - Paths

        private var galleryDirectoryURL: URL? {
            if let overrideDirectory { return overrideDirectory }
            guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                return nil
            }
            return base.appendingPathComponent(Self.folderName, isDirectory: true)
        }

        private func ensureGalleryDirectory() -> URL? {
            guard let dir = galleryDirectoryURL else { return nil }
            if !fileManager.fileExists(atPath: dir.path) {
                try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            return dir
        }

        /// Absolute URL of the thumbnail for a given index entry, if present.
        func thumbnailURL(for item: GalleryItem) -> URL? {
            galleryDirectoryURL?.appendingPathComponent(item.thumbnailFilename, isDirectory: false)
        }

        /// Loads the thumbnail bytes for an entry (nil if the file is missing).
        func thumbnailData(for item: GalleryItem) -> Data? {
            guard let url = thumbnailURL(for: item) else { return nil }
            return try? Data(contentsOf: url)
        }

        // MARK: - Index persistence

        /// Returns the gallery index sorted newest-first.
        func loadIndex() -> [GalleryItem] {
            guard let data = defaults.data(forKey: Self.indexKey),
                  let saved = try? JSONDecoder().decode([GalleryItem].self, from: data)
            else { return [] }
            return saved.sorted { $0.date > $1.date }
        }

        private func saveIndex(_ items: [GalleryItem]) {
            if let data = try? JSONEncoder().encode(items) {
                defaults.set(data, forKey: Self.indexKey)
            }
        }

        func filteredIndex(_ filter: GalleryFilter, calendar: Calendar = .current) -> [GalleryItem] {
            loadIndex().filter { filter.matches($0, calendar: calendar) }
        }

        // MARK: - Manual groups / tags

        func loadGroupNames() -> [String] {
            let stored = defaults.stringArray(forKey: Self.groupNamesKey) ?? []
            let fromItems = loadIndex().flatMap(\.tags)
            return Self.normalizedTags(stored + fromItems)
        }

        func saveGroupNames(_ names: [String]) {
            defaults.set(Self.normalizedTags(names), forKey: Self.groupNamesKey)
        }

        @discardableResult
        func addGroupName(_ raw: String) -> String? {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            var names = loadGroupNames()
            if names.contains(where: { $0.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
                return names.first { $0.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
            }
            names.append(name)
            saveGroupNames(names)
            return name
        }

        func renameGroup(from old: String, to newRaw: String) {
            let newName = newRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newName.isEmpty else { return }
            var names = loadGroupNames().filter {
                $0.compare(old, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame
            }
            names.append(newName)
            saveGroupNames(names)
            mutateIndex { item in
                item.tags = item.tags.map { tag in
                    tag.compare(old, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame ? newName : tag
                }
            }
        }

        func deleteGroup(_ name: String) {
            saveGroupNames(loadGroupNames().filter {
                $0.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame
            })
            mutateIndex { item in
                item.tags.removeAll {
                    $0.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                }
            }
        }

        func setTags(for id: UUID, tags: [String]) {
            let normalized = Self.normalizedTags(tags)
            mutateIndex { item in
                guard item.id == id else { return }
                item.tags = normalized
            }
            var names = loadGroupNames()
            for tag in normalized where !names.contains(where: {
                $0.compare(tag, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }) {
                names.append(tag)
            }
            saveGroupNames(names)
        }

        private func mutateIndex(_ body: (inout GalleryItem) -> Void) {
            var index = loadIndex()
            for i in index.indices {
                body(&index[i])
            }
            saveIndex(index.sorted { $0.date > $1.date })
        }

        static func normalizedTags(_ tags: [String]) -> [String] {
            var seen = Set<String>()
            var result: [String] = []
            for tag in tags {
                let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let key = trimmed.lowercased()
                if seen.insert(key).inserted {
                    result.append(trimmed)
                }
            }
            return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }

        // MARK: - Archiving

        /// Archive every result that has a photo and is not yet in the index.
        /// Idempotent and cheap to call repeatedly (e.g. from
        /// `saveRecentResults()`); already-archived meals keep their thumbnail
        /// and tags, but macros/items are upgraded when the live result has
        /// them. The actual downscale + disk write happens off the main thread.
        /// Companion publish (if opted in) is fired after the local write and
        /// must not block FoodFinder.
        func archive(_ results: [FoodAnalysisResult]) {
            // Snapshot the minimal data we need up front so we don't retain the
            // full result objects across the async hop.
            struct Candidate {
                let id: UUID
                let date: Date
                let mealName: String?
                let totalCarbs: Double
                let totalFat: Double
                let totalProtein: Double
                let totalFiber: Double
                let totalCalories: Double
                let items: [GalleryFoodSnapshot]
                let imageData: Data
            }

            let candidates: [Candidate] = results.compactMap { result in
                guard let imageData = result.imageData, !imageData.isEmpty else { return nil }
                return Candidate(
                    id: result.id,
                    date: result.timestamp,
                    mealName: result.mealName,
                    totalCarbs: result.totalCarbs,
                    totalFat: result.totalFat,
                    totalProtein: result.totalProtein,
                    totalFiber: result.totalFiber,
                    totalCalories: result.totalCalories,
                    items: result.items.map { GalleryFoodSnapshot(item: $0) },
                    imageData: imageData
                )
            }
            guard !candidates.isEmpty else { return }

            ioQueue.async { [weak self] in
                guard let self, let dir = self.ensureGalleryDirectory() else { return }

                var index = self.loadIndex()
                var didChange = false
                var published: [(GalleryItem, Data)] = []

                for candidate in candidates {
                    if let existingIndex = index.firstIndex(where: { $0.id == candidate.id }) {
                        var existing = index[existingIndex]
                        let snapshotEmpty = existing.items.isEmpty && !candidate.items.isEmpty
                        let macrosStale = existing.totalFat == 0 && existing.totalProtein == 0
                            && (candidate.totalFat != 0 || candidate.totalProtein != 0)
                        if snapshotEmpty || macrosStale || existing.totalCarbs != candidate.totalCarbs {
                            existing.mealName = candidate.mealName ?? existing.mealName
                            existing.totalCarbs = candidate.totalCarbs
                            existing.totalFat = candidate.totalFat
                            existing.totalProtein = candidate.totalProtein
                            existing.totalFiber = candidate.totalFiber
                            existing.totalCalories = candidate.totalCalories
                            if !candidate.items.isEmpty {
                                existing.items = candidate.items
                            }
                            index[existingIndex] = existing
                            didChange = true
                        }
                        continue
                    }

                    guard let thumbnailData = Self.makeThumbnailJPEG(from: candidate.imageData) else { continue }
                    let filename = "\(candidate.id.uuidString).jpg"
                    let url = dir.appendingPathComponent(filename, isDirectory: false)
                    do {
                        try thumbnailData.write(to: url, options: .atomic)
                    } catch {
                        continue
                    }
                    let item = GalleryItem(
                        id: candidate.id,
                        date: candidate.date,
                        mealName: candidate.mealName,
                        totalCarbs: candidate.totalCarbs,
                        thumbnailFilename: filename,
                        totalFat: candidate.totalFat,
                        totalProtein: candidate.totalProtein,
                        totalFiber: candidate.totalFiber,
                        totalCalories: candidate.totalCalories,
                        items: candidate.items
                    )
                    index.append(item)
                    didChange = true
                    published.append((item, thumbnailData))
                }

                if didChange {
                    // Persist newest-first for consistency with `loadIndex()`.
                    self.saveIndex(index.sorted { $0.date > $1.date })
                }

                for (item, thumbnail) in published {
                    self.companionPublish?(item, thumbnail)
                }
            }
        }

        // MARK: - Image downscaling

        /// Center-crop to a square, downscale so the side is at most
        /// `maxThumbnailSide` (never upscaling), and re-encode as a low-quality
        /// JPEG. Portrait camera shots used to keep their aspect ratio, which
        /// the gallery then laid out as tall cells. Returns nil if the input
        /// cannot be decoded as an image.
        static func makeThumbnailJPEG(from imageData: Data) -> Data? {
            guard let image = UIImage(data: imageData) else { return nil }
            let size = image.size
            guard size.width > 0, size.height > 0 else { return nil }

            let cropSide = min(size.width, size.height)
            let targetSide = min(maxThumbnailSide, cropSide)
            let drawScale = targetSide / cropSide
            let cropOrigin = CGPoint(
                x: (size.width - cropSide) / 2,
                y: (size.height - cropSide) / 2
            )

            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1 // target size is already in pixels
            format.opaque = true
            let renderer = UIGraphicsImageRenderer(
                size: CGSize(width: targetSide, height: targetSide),
                format: format
            )
            let resized = renderer.image { _ in
                // `draw(in:)` applies UIImage orientation, so the crop is in
                // the oriented pixel space the gallery will display.
                image.draw(in: CGRect(
                    x: -cropOrigin.x * drawScale,
                    y: -cropOrigin.y * drawScale,
                    width: size.width * drawScale,
                    height: size.height * drawScale
                ))
            }
            return resized.jpegData(compressionQuality: thumbnailQuality)
        }
    }
}
