//
//  AIInsights_MealGalleryStore.swift
//  Trio
//
//  On-disk COMPRESSED meal-photo gallery (Feature M).
//
//  FoodFinder keeps the last 20 analyses (with inline JPEG imageData) in
//  UserDefaults (`ai_foodfinder_recent`). This store is a separate, durable
//  archive that outlives that 20-item cap: for every analyzed meal that has a
//  photo it writes a small downscaled JPEG THUMBNAIL (~320px longest side,
//  quality ~0.5) to Application Support/MealGallery/<uuid>.jpg and records a
//  tiny Codable index entry (id, date, mealName, totalCarbs, filename) in
//  UserDefaults (`ai_meal_gallery_index`).
//
//  Memory stays low: only thumbnails are ever created/held, never the
//  full-resolution capture. Archiving is idempotent — a meal already in the
//  index is skipped, so it is cheap to call on every `saveRecentResults()`.
//

import Foundation
import UIKit

extension AIInsights {

    final class MealGalleryStore {

        static let shared = MealGalleryStore()

        /// UserDefaults key holding the JSON-encoded `[GalleryItem]` index.
        private static let indexKey = "ai_meal_gallery_index"
        /// Subfolder (under Application Support) holding the thumbnail JPEGs.
        private static let folderName = "MealGallery"
        /// Longest-side target for the stored thumbnail, in pixels.
        private static let maxThumbnailSide: CGFloat = 320
        /// JPEG compression quality for stored thumbnails.
        private static let thumbnailQuality: CGFloat = 0.5

        private let fileManager = FileManager.default
        private let ioQueue = DispatchQueue(label: "trio.ai.mealgallery.io", qos: .utility)

        private init() {}

        // MARK: - Index model

        /// A single persisted gallery entry. Deliberately small — the heavy
        /// image data lives on disk under `thumbnailFilename`.
        struct GalleryItem: Codable, Identifiable, Equatable {
            let id: UUID
            let date: Date
            let mealName: String?
            let totalCarbs: Double
            let thumbnailFilename: String
        }

        // MARK: - Paths

        private var galleryDirectoryURL: URL? {
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
            guard let data = UserDefaults.standard.data(forKey: Self.indexKey),
                  let saved = try? JSONDecoder().decode([GalleryItem].self, from: data)
            else { return [] }
            return saved.sorted { $0.date > $1.date }
        }

        private func saveIndex(_ items: [GalleryItem]) {
            if let data = try? JSONEncoder().encode(items) {
                UserDefaults.standard.set(data, forKey: Self.indexKey)
            }
        }

        // MARK: - Archiving

        /// Archive every result that has a photo and is not yet in the index.
        /// Idempotent and cheap to call repeatedly (e.g. from
        /// `saveRecentResults()`); already-archived meals are skipped. The
        /// actual downscale + disk write happens off the main thread.
        func archive(_ results: [FoodAnalysisResult]) {
            // Snapshot the minimal data we need up front so we don't retain the
            // full result objects across the async hop.
            let candidates: [(id: UUID, date: Date, mealName: String?, totalCarbs: Double, imageData: Data)] =
                results.compactMap { result in
                    guard let imageData = result.imageData, !imageData.isEmpty else { return nil }
                    return (result.id, result.timestamp, result.mealName, result.totalCarbs, imageData)
                }
            guard !candidates.isEmpty else { return }

            ioQueue.async { [weak self] in
                guard let self, let dir = self.ensureGalleryDirectory() else { return }

                var index = self.loadIndex()
                let existingIDs = Set(index.map { $0.id })
                var didChange = false

                for candidate in candidates where !existingIDs.contains(candidate.id) {
                    guard let thumbnailData = Self.makeThumbnailJPEG(from: candidate.imageData) else { continue }
                    let filename = "\(candidate.id.uuidString).jpg"
                    let url = dir.appendingPathComponent(filename, isDirectory: false)
                    do {
                        try thumbnailData.write(to: url, options: .atomic)
                    } catch {
                        continue
                    }
                    index.append(
                        GalleryItem(
                            id: candidate.id,
                            date: candidate.date,
                            mealName: candidate.mealName,
                            totalCarbs: candidate.totalCarbs,
                            thumbnailFilename: filename
                        )
                    )
                    didChange = true
                }

                if didChange {
                    // Persist newest-first for consistency with `loadIndex()`.
                    self.saveIndex(index.sorted { $0.date > $1.date })
                }
            }
        }

        // MARK: - Image downscaling

        /// Downscale to `maxThumbnailSide` on the longest edge (never upscaling)
        /// and re-encode as a low-quality JPEG. Returns nil if the input cannot
        /// be decoded as an image.
        static func makeThumbnailJPEG(from imageData: Data) -> Data? {
            guard let image = UIImage(data: imageData) else { return nil }
            let size = image.size
            guard size.width > 0, size.height > 0 else { return nil }

            let longestSide = max(size.width, size.height)
            let scale = min(1.0, maxThumbnailSide / longestSide)
            let targetSize = CGSize(width: size.width * scale, height: size.height * scale)

            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1 // target size is already in pixels
            format.opaque = true
            let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
            let resized = renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: targetSize))
            }
            return resized.jpegData(compressionQuality: thumbnailQuality)
        }
    }
}
