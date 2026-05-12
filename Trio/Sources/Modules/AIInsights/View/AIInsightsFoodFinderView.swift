import SwiftUI
import Swinject

extension AIInsights {
    struct FoodFinderView: BaseView {
        let resolver: Resolver
        @State var state = FoodFinderStateModel()

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState
        @FocusState private var isTextFieldFocused: Bool

        var body: some View {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 20) {
                        // Result View or Empty State
                        if let result = state.currentResult {
                            resultView(result)
                        } else {
                            emptyStateView
                        }

                        // Recent Results
                        if state.currentResult == nil && !state.recentResults.isEmpty {
                            recentResultsSection
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 12)
                }

                // Input Bar
                foodInputBar
            }
            .background(appState.trioBackgroundColor(for: colorScheme))
            .navigationTitle(String(localized: "FoodFinder", comment: "Nav title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if state.currentResult != nil {
                        Button {
                            state.clearResult()
                        } label: {
                            Text(String(localized: "New", comment: "New analysis button"))
                                .font(.subheadline)
                        }
                    }
                }
            }
            .onAppear(perform: configureView)
            .sheet(isPresented: $state.showCamera) {
                AIInsights.CameraCaptureView { imageData in
                    Task { await state.analyzeImage(imageData) }
                }
            }
            .sheet(isPresented: $state.showBarcodeScanner) {
                AIInsights.BarcodeScannerView { barcode in
                    Task { await state.lookupBarcode(barcode) }
                }
            }
        }

        // MARK: - Empty State

        private var emptyStateView: some View {
            VStack(spacing: 16) {
                Image(systemName: "fork.knife.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                Color(red: 0.3411764706, green: 0.6666666667, blue: 0.9254901961),
                                Color(red: 0.262745098, green: 0.7333333333, blue: 0.9137254902)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .padding(.top, 60)

                Text(String(localized: "Describe your meal", comment: "FoodFinder empty state title"))
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)

                Text(String(localized: "Type what you're eating and AI will estimate the carbs, protein, fat, and calories for each item.", comment: "FoodFinder empty state description"))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                // Example chips
                VStack(spacing: 8) {
                    Text(String(localized: "Try something like:", comment: "Example prompt label"))
                        .font(.caption)
                        .foregroundColor(.secondary)

                    FlowLayout(spacing: 8) {
                        ForEach(exampleFoods, id: \.self) { food in
                            Button {
                                state.foodDescription = food
                                Task { await state.analyzeFood(description: food) }
                            } label: {
                                Text(food)
                                    .font(.caption)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(
                                        Capsule()
                                            .fill(colorScheme == .dark ? Color.bgDarkerDarkBlue.opacity(0.8) : Color(.systemGray6))
                                    )
                                    .foregroundStyle(colorScheme == .dark ? .white : .primary)
                            }
                        }
                    }
                }
                .padding(.top, 12)

                if !state.aiEnabled {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(String(localized: "AI Insights is disabled. Enable it in Settings.", comment: "AI disabled message"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.chart.opacity(0.5))
                    )
                }
            }
        }

        private var exampleFoods: [String] {
            [
                "Two slices of pepperoni pizza",
                "Bowl of oatmeal with banana",
                "Chicken wrap with rice",
                "Pasta bolognese"
            ]
        }

        // MARK: - Result View

        private func resultView(_ result: FoodAnalysisResult) -> some View {
            VStack(spacing: 16) {
                // Total Card
                totalCarbsCard(result)

                // Individual Items
                ForEach(result.items) { item in
                    foodItemCard(item)
                }

                // Error
                if let error = state.errorMessage {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.orange.opacity(0.1))
                    )
                }

                // Disclaimer
                Text(String(localized: "⚠️ AI estimates may be inaccurate. Always verify carb counts before dosing.", comment: "FoodFinder disclaimer"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }

        private func totalCarbsCard(_ result: FoodAnalysisResult) -> some View {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "Total Carbs", comment: "Total carbs label"))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text(String(format: "%.0f g", result.totalCarbs))
                        .font(.largeTitle.bold())
                        .foregroundStyle(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.3411764706, green: 0.6666666667, blue: 0.9254901961),
                                    Color(red: 0.262745098, green: 0.7333333333, blue: 0.9137254902)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(String(localized: "Calories", comment: "Calories label"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(String(format: "%.0f kcal", result.totalCalories))
                        .font(.headline)
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(colorScheme == .dark ? Color.bgDarkerDarkBlue.opacity(0.8) : Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color(red: 0.3411764706, green: 0.6666666667, blue: 0.9254901961).opacity(0.3),
                                Color(red: 0.262745098, green: 0.7333333333, blue: 0.9137254902).opacity(0.3)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        lineWidth: 1.5
                    )
            )
            .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 4)
        }

        private func foodItemCard(_ item: FoodItem) -> some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(.subheadline.bold())
                        Text(item.portion)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()

                    // Portion stepper
                    HStack(spacing: 4) {
                        Button {
                            state.updatePortion(for: item.id, multiplier: item.portionMultiplier - 0.25)
                        } label: {
                            Image(systemName: "minus.circle")
                                .foregroundColor(.secondary)
                        }
                        Text(String(format: "%.2fx", item.portionMultiplier))
                            .font(.caption.monospacedDigit())
                            .frame(width: 42)
                        Button {
                            state.updatePortion(for: item.id, multiplier: item.portionMultiplier + 0.25)
                        } label: {
                            Image(systemName: "plus.circle")
                                .foregroundColor(.secondary)
                        }
                    }

                    // Delete button
                    Button {
                        withAnimation { state.removeItem(item.id) }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red.opacity(0.6))
                    }
                }

                // Macro pills row
                HStack(spacing: 12) {
                    macroPill(label: String(localized: "Carbs", comment: "Carbs macro"), value: String(format: "%.0fg", item.adjustedCarbs), color: .blue)
                    macroPill(label: String(localized: "Fat", comment: "Fat macro"), value: String(format: "%.0fg", item.fat * item.portionMultiplier), color: .yellow)
                    macroPill(label: String(localized: "Protein", comment: "Protein macro"), value: String(format: "%.0fg", item.protein * item.portionMultiplier), color: .red)
                    macroPill(label: String(localized: "Fiber", comment: "Fiber macro"), value: String(format: "%.0fg", item.fiber * item.portionMultiplier), color: .green)
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(colorScheme == .dark ? Color.bgDarkerDarkBlue.opacity(0.8) : Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(colorScheme == .dark ? Color.white.opacity(0.08) : Color.gray.opacity(0.15), lineWidth: 1)
            )
        }

        private func macroPill(label: String, value: String, color: Color) -> some View {
            VStack(spacing: 2) {
                Text(value)
                    .font(.caption.bold())
                    .foregroundStyle(color)
                Text(label)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }

        // MARK: - Recent Results

        private var recentResultsSection: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text(String(localized: "Recent Meals", comment: "Recent results section header"))
                    .font(.headline)
                    .padding(.top, 8)

                ForEach(state.recentResults.prefix(5)) { result in
                    Button {
                        state.currentResult = result
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.items.map(\.name).joined(separator: ", "))
                                    .font(.subheadline)
                                    .lineLimit(1)
                                    .foregroundStyle(colorScheme == .dark ? .white : .primary)
                                Text(result.timestamp, style: .relative)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Text(String(format: "%.0fg", result.totalCarbs))
                                .font(.subheadline.bold())
                                .foregroundStyle(.blue)
                        }
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(colorScheme == .dark ? Color.bgDarkerDarkBlue.opacity(0.6) : Color(.systemGray6))
                        )
                    }
                }
            }
        }

        // MARK: - Input Bar

        private var foodInputBar: some View {
            HStack(spacing: 8) {
                // Camera button
                Button {
                    state.showCamera = true
                } label: {
                    Image(systemName: "camera.fill")
                        .frame(width: 36, height: 36)
                        .background(
                            Circle()
                                .fill(colorScheme == .dark ? Color.bgDarkerDarkBlue : Color(.systemGray5))
                        )
                        .foregroundStyle(colorScheme == .dark ? .white : .primary)
                }
                .disabled(state.isAnalyzing)

                // Barcode button
                Button {
                    state.showBarcodeScanner = true
                } label: {
                    Image(systemName: "barcode.viewfinder")
                        .frame(width: 36, height: 36)
                        .background(
                            Circle()
                                .fill(colorScheme == .dark ? Color.bgDarkerDarkBlue : Color(.systemGray5))
                        )
                        .foregroundStyle(colorScheme == .dark ? .white : .primary)
                }
                .disabled(state.isAnalyzing)

                TextField(
                    String(localized: "Describe your meal...", comment: "FoodFinder input placeholder"),
                    text: $state.foodDescription,
                    axis: .vertical
                )
                .lineLimit(1 ... 3)
                .focused($isTextFieldFocused)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(colorScheme == .dark ? Color.bgDarkerDarkBlue : Color(.systemGray6))
                )

                Button {
                    let desc = state.foodDescription
                    isTextFieldFocused = false
                    Task { await state.analyzeFood(description: desc) }
                } label: {
                    Group {
                        if state.isAnalyzing {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        } else {
                            Image(systemName: "sparkle.magnifyingglass")
                        }
                    }
                    .frame(width: 36, height: 36)
                    .background(
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.3411764706, green: 0.6666666667, blue: 0.9254901961),
                                        Color(red: 0.262745098, green: 0.7333333333, blue: 0.9137254902)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .foregroundStyle(.white)
                }
                .disabled(state.foodDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.isAnalyzing)
                .opacity(state.foodDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.isAnalyzing ? 0.5 : 1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(colorScheme == .dark ? Color.bgDarkBlue : Color.white)
        }
    }
}

// MARK: - Flow Layout (for example food chips)

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = computeLayout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = computeLayout(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private struct LayoutResult {
        var size: CGSize
        var positions: [CGPoint]
    }

    private func computeLayout(proposal: ProposedViewSize, subviews: Subviews) -> LayoutResult {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            positions.append(CGPoint(x: currentX, y: currentY))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            totalHeight = currentY + lineHeight
        }

        return LayoutResult(size: CGSize(width: maxWidth, height: totalHeight), positions: positions)
    }
}
