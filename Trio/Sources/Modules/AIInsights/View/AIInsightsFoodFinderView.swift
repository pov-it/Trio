import SwiftUI
import Swinject

extension AIInsights {
    struct FoodFinderView: BaseView {
        let resolver: Resolver
        var onHandoffComplete: (() -> Void)? = nil
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

            }
            .background(appState.trioBackgroundColor(for: colorScheme))
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                foodInputBar
            }
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
            .fullScreenCover(isPresented: $state.showCamera) {
                AIInsights.CameraCaptureView { imageData in
                    state.attachImage(imageData)
                }
                .ignoresSafeArea()
            }
            .fullScreenCover(isPresented: $state.showBarcodeScanner) {
                AIInsights.BarcodeScannerView { barcode in
                    Task { await state.lookupBarcode(barcode) }
                }
                .ignoresSafeArea()
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

        // MARK: - Result View

        private func resultView(_ result: FoodAnalysisResult) -> some View {
            VStack(spacing: 16) {
                if let imageData = result.imageData {
                    mealImageCard(imageData, result: result)
                } else {
                    mealIdentityCard(result)
                }

                macroSummaryCard(result)

                ForEach(result.items) { item in
                    foodItemRow(item)
                        .swipeActions(edge: .trailing) {
                            Button(String(localized: "Delete", comment: "Delete food item"), systemImage: "trash", role: .destructive) {
                                withAnimation { state.removeItem(item.id) }
                            }
                        }
                }

                Button {
                    state.sendToBolusCalculator(openBolusCalculator: onHandoffComplete == nil)
                    onHandoffComplete?()
                } label: {
                    Label(String(localized: "Use in Bolus Calculator", comment: "FoodFinder bolus handoff button"), systemImage: "arrow.forward.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(result.items.isEmpty)

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

                Label(
                    String(localized: "AI estimates may be inaccurate. Always verify carb counts before dosing.", comment: "FoodFinder disclaimer"),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            }
        }

        private func mealImageCard(_ imageData: Data, result: FoodAnalysisResult) -> some View {
            Group {
                if let image = UIImage(data: imageData) {
                    ZStack(alignment: .bottomLeading) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity)
                            .aspectRatio(1.45, contentMode: .fit)
                            .clipped()

                        VStack(alignment: .leading, spacing: 3) {
                            Text(mealTitle(for: result))
                                .font(.headline)
                                .foregroundStyle(.white)
                                .lineLimit(2)
                            if let portion = mealPortion(for: result) {
                                Text(portion)
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
                }
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(colorScheme == .dark ? Color.bgDarkerDarkBlue.opacity(0.8) : Color.white)
            )
        }

        private func macroSummaryCard(_ result: FoodAnalysisResult) -> some View {
            VStack(spacing: 0) {
                macroSummaryRow(label: String(localized: "Carbs", comment: "Carbs macro"), value: result.totalCarbs, unit: "g")
                Divider()
                macroSummaryRow(label: String(localized: "Fat", comment: "Fat macro"), value: result.totalFat, unit: "g")
                Divider()
                macroSummaryRow(label: String(localized: "Protein", comment: "Protein macro"), value: result.totalProtein, unit: "g")
                Divider()
                macroSummaryRow(label: String(localized: "Fiber", comment: "Fiber macro"), value: result.totalFiber, unit: "g")
                Divider()
                macroSummaryRow(label: String(localized: "Calories", comment: "Calories label"), value: result.totalCalories, unit: "kcal")
            }
            .padding(.horizontal)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(colorScheme == .dark ? Color.bgDarkerDarkBlue.opacity(0.8) : Color.white)
            )
        }

        private func macroSummaryRow(label: String, value: Double, unit: String) -> some View {
            HStack {
                Text(label)
                Spacer()
                Text("\(String(format: "%.0f", value)) \(unit)")
                    .foregroundColor(.secondary)
            }
            .font(.subheadline)
            .padding(.vertical, 11)
        }

        private func mealIdentityCard(_ result: FoodAnalysisResult) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(mealTitle(for: result))
                    .font(.headline)
                    .lineLimit(2)
                if let portion = mealPortion(for: result) {
                    Text(portion)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(colorScheme == .dark ? Color.bgDarkerDarkBlue.opacity(0.8) : Color.white)
            )
        }

        private func mealDescriptionCard(_ description: String) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "Description", comment: "FoodFinder meal description header"))
                    .font(.subheadline.weight(.semibold))
                Text(description)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(colorScheme == .dark ? Color.bgDarkerDarkBlue.opacity(0.8) : Color.white)
            )
        }

        private func foodItemRow(_ item: FoodItem) -> some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    TextField(
                        String(localized: "Ingredient", comment: "FoodFinder ingredient text field"),
                        text: Binding(
                            get: { item.name },
                            set: { state.updateItemName(for: item.id, name: $0) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.subheadline.weight(.semibold))
                    .submitLabel(.search)
                    .onSubmit {
                        Task { await state.reanalyzeItem(item.id) }
                    }

                    Spacer()

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

                    Button {
                        Task { await state.reanalyzeItem(item.id) }
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                    }
                }

                Text(item.portion)
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack(spacing: 14) {
                    ingredientMetric(String(localized: "Carbs", comment: "Carbs macro"), value: item.adjustedCarbs, unit: "g", color: .blue)
                    ingredientMetric(String(localized: "Fat", comment: "Fat macro"), value: item.adjustedFat, unit: "g", color: .yellow)
                    ingredientMetric(String(localized: "Protein", comment: "Protein macro"), value: item.adjustedProtein, unit: "g", color: .red)
                    ingredientMetric(String(localized: "Fiber", comment: "Fiber macro"), value: item.adjustedFiber, unit: "g", color: .green)
                    ingredientMetric(String(localized: "Calories", comment: "Calories label"), value: item.adjustedCalories, unit: "kcal", color: .secondary)
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

        private func ingredientMetric(_ label: String, value: Double, unit: String, color: Color) -> some View {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(String(format: "%.0f", value)) \(unit)")
                    .font(.caption.bold())
                    .foregroundStyle(color)
                    .lineLimit(1)
                Text(label)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        private func mealTitle(for result: FoodAnalysisResult) -> String {
            result.mealName?.trimmingCharacters(in: .whitespacesAndNewlines).aiInsightsNilIfEmpty
                ?? result.mealDescription?.trimmingCharacters(in: .whitespacesAndNewlines).aiInsightsNilIfEmpty
                ?? result.items.map(\.name).joined(separator: ", ").aiInsightsNilIfEmpty
                ?? String(localized: "Meal", comment: "Generic meal title")
        }

        private func mealPortion(for result: FoodAnalysisResult) -> String? {
            result.mealPortion?.trimmingCharacters(in: .whitespacesAndNewlines).aiInsightsNilIfEmpty
                ?? (result.items.count == 1 ? result.items.first?.portion : nil)
        }

        private func macroEditor(
            item: FoodItem,
            macro: FoodMacro,
            label: String,
            value: Double,
            unit: String,
            color: Color
        ) -> some View {
            VStack(spacing: 2) {
                HStack(spacing: 2) {
                    TextField(
                        label,
                        value: Binding(
                            get: { value },
                            set: { state.updateMacro(for: item.id, macro: macro, adjustedValue: $0) }
                        ),
                        format: .number.precision(.fractionLength(0 ... 1))
                    )
                    .multilineTextAlignment(.center)
                    .keyboardType(.decimalPad)
                    .font(.caption.bold())
                    .foregroundStyle(color)
                    .frame(minWidth: 24)
                    .textFieldStyle(.roundedBorder)

                    Text(unit)
                        .font(.caption2.bold())
                        .foregroundStyle(color)
                }
                Text(label)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(colorScheme == .dark ? Color.white.opacity(0.05) : Color(.systemGray6))
            )
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
                                Text(relativeMinutesText(from: result.timestamp))
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
                    .swipeActions(edge: .trailing) {
                        Button(String(localized: "Delete", comment: "Delete recent meal"), systemImage: "trash", role: .destructive) {
                            state.deleteRecentResult(result)
                        }
                    }
                }
            }
        }

        // MARK: - Input Bar

        private var foodInputBar: some View {
            VStack(spacing: 6) {
                if state.capturedImageData != nil {
                    HStack(spacing: 8) {
                        if let imageData = state.capturedImageData,
                           let image = UIImage(data: imageData)
                        {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 54, height: 54)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(localized: "Photo attached", comment: "FoodFinder photo attached label"))
                                .font(.caption.weight(.semibold))
                            Text(String(localized: "This photo will be analyzed with your description.", comment: "FoodFinder attached photo help"))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button {
                            state.discardCapturedImage()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                }

                HStack(spacing: 8) {
                    roundInputButton(systemImage: "camera.fill") {
                        state.showCamera = true
                    }
                    .disabled(state.isAnalyzing)

                    roundInputButton(systemImage: "barcode.viewfinder") {
                        state.showBarcodeScanner = true
                    }
                    .disabled(state.isAnalyzing)

                    roundInputButton(systemImage: state.isDictating ? "mic.fill" : "mic") {
                        state.toggleDictation()
                    }
                    .foregroundStyle(state.isDictating ? .red : (colorScheme == .dark ? .white : .primary))
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
                        isTextFieldFocused = false
                        Task { await state.analyzeCurrentInput() }
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
                    .disabled(!hasFoodFinderInput || state.isAnalyzing)
                    .opacity(!hasFoodFinderInput || state.isAnalyzing ? 0.5 : 1)
                }
                .padding(.horizontal, 12)
            }
            .padding(.vertical, 8)
            .background(colorScheme == .dark ? Color.bgDarkBlue : Color.white)
        }

        private var hasFoodFinderInput: Bool {
            state.capturedImageData != nil || !state.foodDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        private func roundInputButton(systemImage: String, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                Image(systemName: systemImage)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle()
                            .fill(colorScheme == .dark ? Color.bgDarkerDarkBlue : Color(.systemGray5))
                    )
                    .foregroundStyle(colorScheme == .dark ? .white : .primary)
            }
        }

        private func relativeMinutesText(from date: Date) -> String {
            let minutes = max(0, Int(Date().timeIntervalSince(date) / 60))
            if minutes < 1 {
                return String(localized: "< 1 min", comment: "Relative time less than one minute")
            }
            if minutes < 60 {
                return String(localized: "\(minutes) min", comment: "Relative time minutes")
            }
            let hours = minutes / 60
            if hours < 24 {
                return String(localized: "\(hours) h", comment: "Relative time hours")
            }
            return date.formatted(.dateTime.month().day().hour().minute())
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
