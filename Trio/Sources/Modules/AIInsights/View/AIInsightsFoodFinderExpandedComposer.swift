//
//  AIInsightsFoodFinderExpandedComposer.swift
//  Trio
//
//  Large-format composer for the FoodFinder. Slides up as a sheet from the
//  compact input bar (and can be reused as a standalone entry point) so the
//  user has room to write a long description and see all attached photos
//  at once.
//

import SwiftUI

extension AIInsights {
    struct FoodFinderExpandedComposer: View {
        @Bindable var state: FoodFinderStateModel
        var onSubmit: () -> Void

        @Environment(\.dismiss) private var dismiss
        @Environment(\.colorScheme) private var colorScheme
        @Environment(AppState.self) private var appState
        @FocusState private var textFocused: Bool

        var body: some View {
            NavigationStack {
                VStack(spacing: 12) {
                    // Photo grid — fills available height proportional to the
                    // number of attached images, so a single photo stays large
                    // and multi-photo stacks are still scannable.
                    if !state.capturedImages.isEmpty {
                        photoGrid
                    } else {
                        photoPlaceholder
                    }

                    // Add-photo actions
                    HStack(spacing: 10) {
                        composerButton(icon: "camera.fill",
                                       label: String(localized: "Camera", comment: "Composer camera button")) {
                            state.showCamera = true
                        }
                        composerButton(icon: "photo.on.rectangle",
                                       label: String(localized: "Library", comment: "Composer photo library button")) {
                            state.showPhotoPicker = true
                        }
                        composerButton(icon: "barcode.viewfinder",
                                       label: String(localized: "Barcode", comment: "Composer barcode button")) {
                            state.showBarcodeScanner = true
                        }
                        composerButton(
                            icon: state.isDictating ? "mic.fill" : "mic",
                            label: state.isDictating
                                ? String(localized: "Stop", comment: "Composer dictation stop")
                                : String(localized: "Dictate", comment: "Composer dictation start"),
                            tint: state.isDictating ? .red : nil
                        ) {
                            state.toggleDictation()
                        }
                    }
                    .padding(.horizontal, 4)
                    .disabled(false) // capacity guard handled per button

                    // Text editor
                    ZStack(alignment: .topLeading) {
                        if state.foodDescription.isEmpty {
                            Text(textPlaceholder)
                                .font(.body)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 14)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $state.foodDescription)
                            .focused($textFocused)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .scrollContentBackground(.hidden)
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(colorScheme == .dark ? Color.bgDarkerDarkBlue : Color(.systemGray6))
                    )
                    .frame(minHeight: 110, maxHeight: 280)

                    // Submit button
                    submitButton
                }
                .padding(16)
                .background(appState.trioBackgroundColor(for: colorScheme))
                .navigationTitle(state.currentResult != nil
                    ? String(localized: "Add to meal", comment: "Composer nav title add mode")
                    : String(localized: "Describe meal", comment: "Composer nav title analyze mode"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(String(localized: "Close", comment: "Close composer")) { dismiss() }
                    }
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button(String(localized: "Done", comment: "Dismiss keyboard")) { textFocused = false }
                            .bold()
                    }
                }
                .onAppear { textFocused = true }
            }
        }

        private var textPlaceholder: String {
            state.currentResult != nil
                ? String(localized: "Describe the ingredient(s) to add…", comment: "Composer placeholder add mode")
                : String(localized: "Describe your meal in detail…", comment: "Composer placeholder analyze mode")
        }

        private var photoGrid: some View {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                    ForEach(Array(state.capturedImages.enumerated()), id: \.offset) { idx, data in
                        if let img = UIImage(data: data) {
                            ZStack(alignment: .topTrailing) {
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(height: 110)
                                    .frame(maxWidth: .infinity)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))

                                Button {
                                    withAnimation(.easeInOut(duration: 0.18)) {
                                        state.removeAttachedImage(at: idx)
                                    }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 22))
                                        .foregroundStyle(.white, Color.black.opacity(0.7))
                                        .padding(6)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 240)
        }

        private var photoPlaceholder: some View {
            VStack(spacing: 6) {
                Image(systemName: "photo.stack")
                    .font(.system(size: 28))
                    .foregroundColor(.secondary)
                Text(String(localized: "No photos attached", comment: "Composer photos empty state"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(String(format: String(localized: "Add up to %d photos of the same meal", comment: "Composer photos empty state hint"), state.maxFoodFinderImages))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4]))
            )
        }

        private var submitButton: some View {
            Button {
                textFocused = false
                onSubmit()
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    if state.isAnalyzing {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else {
                        Image(systemName: state.currentResult != nil ? "plus.circle.fill" : "sparkle.magnifyingglass")
                    }
                    Text(state.currentResult != nil
                        ? String(localized: "Add to meal", comment: "Composer submit add mode")
                        : String(localized: "Analyze meal", comment: "Composer submit analyze mode"))
                        .bold()
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    LinearGradient(
                        colors: [
                            Color(red: 0.3411764706, green: 0.6666666667, blue: 0.9254901961),
                            Color(red: 0.262745098, green: 0.7333333333, blue: 0.9137254902)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .opacity(canSubmit ? 1 : 0.5)
            }
            .disabled(!canSubmit)
        }

        private var canSubmit: Bool {
            guard !state.isAnalyzing else { return false }
            return !state.capturedImages.isEmpty
                || !state.foodDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        private func composerButton(
            icon: String,
            label: String,
            tint: Color? = nil,
            action: @escaping () -> Void
        ) -> some View {
            Button(action: action) {
                VStack(spacing: 4) {
                    Image(systemName: icon)
                        .font(.system(size: 18))
                    Text(label)
                        .font(.caption2)
                }
                .foregroundStyle(tint ?? (colorScheme == .dark ? Color.white : Color.primary))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(colorScheme == .dark ? Color.bgDarkerDarkBlue.opacity(0.7) : Color(.systemGray6))
                )
            }
            .disabled(state.capturedImages.count >= state.maxFoodFinderImages && (icon == "camera.fill" || icon == "photo.on.rectangle"))
        }
    }
}
