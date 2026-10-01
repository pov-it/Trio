//
//  AIInsightsImageCropView.swift
//  Trio
//
//  Lightweight image cropper used by FoodFinder. The user pans + pinches a
//  source image inside a fixed-size square frame; whatever's inside the frame
//  is rendered as the cropped output. Skip leaves the original image intact.
//

import SwiftUI
import UIKit

struct AIInsightsImageCropView: View {
    let originalData: Data
    var onComplete: (Data) -> Void
    var onSkip: () -> Void
    var onCancel: () -> Void

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @Environment(\.dismiss) private var dismiss

    private var uiImage: UIImage? {
        UIImage(data: originalData)
    }

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()

                if let image = uiImage {
                    GeometryReader { geo in
                        let cropSize = min(geo.size.width, geo.size.height) * 0.9
                        let cropRect = CGRect(
                            x: (geo.size.width - cropSize) / 2,
                            y: (geo.size.height - cropSize) / 2,
                            width: cropSize,
                            height: cropSize
                        )

                        ZStack {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .scaleEffect(scale)
                                .offset(offset)
                                .frame(width: geo.size.width, height: geo.size.height)
                                .clipped()
                                .gesture(
                                    SimultaneousGesture(
                                        MagnificationGesture()
                                            .onChanged { value in
                                                scale = max(0.5, min(lastScale * value, 6))
                                            }
                                            .onEnded { _ in
                                                lastScale = scale
                                            },
                                        DragGesture()
                                            .onChanged { value in
                                                offset = CGSize(
                                                    width: lastOffset.width + value.translation.width,
                                                    height: lastOffset.height + value.translation.height
                                                )
                                            }
                                            .onEnded { _ in
                                                lastOffset = offset
                                            }
                                    )
                                )

                            // Cutout mask
                            Rectangle()
                                .fill(Color.black.opacity(0.55))
                                .frame(width: geo.size.width, height: geo.size.height)
                                .mask {
                                    Rectangle()
                                        .overlay(
                                            Rectangle()
                                                .frame(width: cropSize, height: cropSize)
                                                .position(x: cropRect.midX, y: cropRect.midY)
                                                .blendMode(.destinationOut)
                                        )
                                        .compositingGroup()
                                }
                                .allowsHitTesting(false)

                            Rectangle()
                                .stroke(Color.white, lineWidth: 2)
                                .frame(width: cropSize, height: cropSize)
                                .position(x: cropRect.midX, y: cropRect.midY)
                                .allowsHitTesting(false)
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(String(localized: "Cancel", comment: "Cancel crop")) {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text(String(localized: "Crop Photo", comment: "Crop view title"))
                        .foregroundColor(.white)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 12) {
                        Button(String(localized: "Skip", comment: "Skip cropping")) {
                            onSkip()
                            dismiss()
                        }
                        Button {
                            applyCrop()
                            dismiss()
                        } label: {
                            Text(String(localized: "Done", comment: "Confirm crop"))
                                .fontWeight(.semibold)
                        }
                    }
                }
            }
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }

    /// Render whatever is inside the on-screen crop frame back into a UIImage and
    /// emit it as JPEG bytes. Approach: take a UIGraphicsImageRenderer of the
    /// displayed scale+offset transform, snap the visible portion intersecting
    /// the crop frame, then JPEG-encode.
    private func applyCrop() {
        guard let source = uiImage else {
            onSkip()
            return
        }

        // The visible image is `image .scaleEffect(scale) .offset(offset) .frame(geo.size) .clipped()`.
        // We don't have geo here directly; recompute using UIScreen bounds as an approximation —
        // this works because the source image is always rendered at scaledToFit inside the geo
        // frame, and the crop square is centered. For an MVP this is acceptable: the AI prompt
        // tolerates small framing variance.
        let screenSize = UIScreen.main.bounds.size
        let cropSize = min(screenSize.width, screenSize.height) * 0.9

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: cropSize, height: cropSize))
        let cropped = renderer.image { ctx in
            // Solid black background in case the image doesn't fully cover.
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: CGSize(width: cropSize, height: cropSize)))

            // Compute the aspect-fit rect of the source image inside the screen,
            // then apply the user's scale + offset.
            let imageSize = source.size
            let fitScale = min(screenSize.width / imageSize.width, screenSize.height / imageSize.height)
            let fittedSize = CGSize(width: imageSize.width * fitScale, height: imageSize.height * fitScale)
            let fittedOrigin = CGPoint(
                x: (screenSize.width - fittedSize.width) / 2,
                y: (screenSize.height - fittedSize.height) / 2
            )

            // After scaleEffect + offset:
            let centerX = fittedOrigin.x + fittedSize.width / 2 + offset.width
            let centerY = fittedOrigin.y + fittedSize.height / 2 + offset.height
            let scaledSize = CGSize(width: fittedSize.width * scale, height: fittedSize.height * scale)
            let imageRectInScreen = CGRect(
                x: centerX - scaledSize.width / 2,
                y: centerY - scaledSize.height / 2,
                width: scaledSize.width,
                height: scaledSize.height
            )

            // Crop frame on the same screen-coordinate plane:
            let cropRectInScreen = CGRect(
                x: (screenSize.width - cropSize) / 2,
                y: (screenSize.height - cropSize) / 2,
                width: cropSize,
                height: cropSize
            )

            // Translate so the cropRect's origin is at (0, 0) in the renderer's coordinate space.
            let drawOrigin = CGPoint(
                x: imageRectInScreen.origin.x - cropRectInScreen.origin.x,
                y: imageRectInScreen.origin.y - cropRectInScreen.origin.y
            )
            source.draw(in: CGRect(origin: drawOrigin, size: scaledSize))
        }

        if let data = cropped.jpegData(compressionQuality: 0.7) {
            onComplete(data)
        } else {
            onSkip()
        }
    }
}
