import SwiftUI
import UIKit

extension AIInsights {
    /// A section of meal tiles on the FoodFinder start page, in the same grid as the meal gallery.
    struct FoodFinderMealGridSection<Tile: View>: View {
        /// Empty for a grid without its own header.
        let title: String
        let count: Int
        /// A smaller header, for a folder inside a section.
        var isSubsection: Bool = false
        @ViewBuilder let tiles: () -> Tile

        private let columns = [
            GridItem(.flexible(), spacing: 12, alignment: .top),
            GridItem(.flexible(), spacing: 12, alignment: .top),
            GridItem(.flexible(), spacing: 12, alignment: .top)
        ]

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                if !title.isEmpty {
                    HStack(alignment: .firstTextBaseline) {
                        if isSubsection {
                            Label(title, systemImage: "folder")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                        } else {
                            Text(title)
                                .font(.headline)
                        }
                        Spacer()
                        Text("\(count)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                LazyVGrid(columns: columns, spacing: 14) {
                    tiles()
                }
            }
        }
    }

    /// One meal on the FoodFinder start page: the photo (or a placeholder), the name and the carbs.
    struct FoodFinderMealTile: View {
        let title: String
        let carbs: Double
        var subtitle: String? = nil
        /// Id of the meal in the gallery store, whose thumbnail is shown when there is one.
        var photoID: UUID? = nil
        /// Photo to fall back on when the gallery has no thumbnail; downscaled off the main thread.
        var inlineImage: Data? = nil
        var badgeSystemImage: String? = nil

        @State private var image: UIImage?

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        photo
                            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    }
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        Text("\(Int(carbs.rounded())) g")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(.black.opacity(0.55)))
                            .padding(6)
                    }
                    .overlay(alignment: .topLeading) {
                        if let badgeSystemImage {
                            Image(systemName: badgeSystemImage)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(5)
                                .background(Circle().fill(.black.opacity(0.45)))
                                .padding(6)
                        }
                    }

                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
            .task(id: photoID) {
                await loadImage()
            }
        }

        @ViewBuilder private var photo: some View {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: [Color.blue.opacity(0.25), Color.teal.opacity(0.2)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .overlay {
                    Image(systemName: "fork.knife")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
        }

        private func loadImage() async {
            let id = photoID
            let inline = inlineImage
            let loaded: UIImage? = await Task.detached(priority: .utility) { () -> UIImage? in
                if let id, let data = MealGalleryStore.shared.thumbnailData(forMealID: id), let stored = UIImage(data: data) {
                    return stored
                }
                guard let inline, let thumbnail = MealGalleryStore.makeThumbnailJPEG(from: inline) else { return nil }
                return UIImage(data: thumbnail)
            }.value
            image = loaded
        }
    }
}
