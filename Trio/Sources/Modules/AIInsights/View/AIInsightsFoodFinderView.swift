import CoreData
import SwiftUI
import Swinject

extension AIInsights {
    struct FoodFinderView: BaseView {
        let resolver: Resolver
        var onHandoffComplete: (() -> Void)? = nil
        @State var state = FoodFinderStateModel()

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState
        @Environment(\.managedObjectContext) var moc
        @FocusState private var isTextFieldFocused: Bool
        @State private var isComposerExpanded: Bool = false
        @State private var isEditingTotals = false
        @State private var editingFoodItem: FoodItem?
        @State private var selectedSourceItem: FoodItem?
        @State private var compactInputMeasuredHeight: CGFloat = 0
        @State private var compactInputSingleLineHeight: CGFloat = 0
        @State private var composerFocusRequest = 0
        @GestureState private var composerDragOffset: CGFloat = 0
        @Namespace private var composerNamespace

        @FetchRequest(
            entity: MealPresetStored.entity(),
            sortDescriptors: [NSSortDescriptor(key: "dish", ascending: true)]
        ) var savedMealPresets: FetchedResults<MealPresetStored>


        var body: some View {
            ZStack(alignment: .bottom) {
                contentArea
                foodInputBar
                barcodeStatusBanner
            }
            .background(appState.trioBackgroundColor(for: colorScheme))
            // Higher bottomSpacing tightens the gap above the keyboard.
            // Collapsed bar carries its own internal .padding(.bottom, 8), so it
            // needs a larger value to snap flush to the keyboard like the
            // expanded composer (which has no internal bottom padding).
            .aiInsightsKeyboardAdaptive(bottomSpacing: isComposerExpanded ? 50 : 84)
            .navigationTitle(currentNavTitle)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(state.currentResult != nil)
            .toolbar {
                if state.currentResult != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            state.clearResult()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.backward")
                                Text(String(localized: "FoodFinder", comment: "Nav title"))
                            }
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            state.clearResult(resetDraft: true)
                        } label: {
                            Text(String(localized: "New", comment: "New analysis button"))
                                .font(.subheadline)
                        }
                    }
                }
            }
            .simultaneousGesture(swipeBackGesture)
            .onAppear(perform: configureView)
            .onChange(of: state.barcodeStatusMessage) {
                guard let message = state.barcodeStatusMessage else { return }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if state.barcodeStatusMessage == message {
                        withAnimation(.easeOut(duration: 0.2)) {
                            state.barcodeStatusMessage = nil
                        }
                    }
                }
            }
            .fullScreenCover(isPresented: $state.showCamera) {
                AIInsights.CameraCaptureView { imageData in
                    state.pendingImageForCrop = imageData
                }
                .ignoresSafeArea()
            }
            .fullScreenCover(isPresented: $state.showBarcodeScanner) {
                AIInsights.BarcodeScannerView { barcode in
                    collapseComposer(keepKeyboard: false)
                    Task {
                        if state.currentResult != nil {
                            await state.addIngredientFromBarcode(barcode)
                        } else {
                            await state.lookupBarcode(barcode)
                        }
                    }
                }
                .ignoresSafeArea()
            }
            .fullScreenCover(isPresented: $state.showPhotoPicker) {
                AIInsights.PhotoLibraryPickerView(
                    selectionLimit: max(1, state.maxFoodFinderImages - state.capturedImages.count)
                ) { images in
                    if images.count == 1, let image = images.first {
                        state.pendingImageForCrop = image
                    } else {
                        state.attachImages(images)
                    }
                }
                .ignoresSafeArea()
            }
            .fullScreenCover(isPresented: Binding(
                get: { state.pendingImageForCrop != nil },
                set: { if !$0 { state.pendingImageForCrop = nil } }
            )) {
                if let data = state.pendingImageForCrop {
                    AIInsightsImageCropView(
                        originalData: data,
                        onComplete: { cropped in
                            state.attachImage(cropped)
                            state.pendingImageForCrop = nil
                        },
                        onSkip: {
                            state.attachImage(data)
                            state.pendingImageForCrop = nil
                        },
                        onCancel: {
                            state.pendingImageForCrop = nil
                        }
                    )
                    .ignoresSafeArea()
                }
            }
            .sheet(item: $editingFoodItem) { item in
                FoodItemEditSheet(item: item) { updatedItem in
                    state.replaceItem(updatedItem)
                    editingFoodItem = nil
                }
            }
            .sheet(item: $selectedSourceItem) { item in
                FoodSourceDetailSheet(item: item)
            }
        }

        // MARK: - Content area + transitions

        private var currentNavTitle: String {
            if let result = state.currentResult {
                return mealTitle(for: result)
            }
            return String(localized: "FoodFinder", comment: "Nav title")
        }

        @ViewBuilder
        private var contentArea: some View {
            ZStack {
                if let result = state.currentResult {
                    mealDetailScreen(for: result)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        ))
                } else {
                    rootContent
                        .transition(.asymmetric(
                            insertion: .move(edge: .leading).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                }
            }
            .animation(.easeInOut(duration: 0.28), value: state.currentResult?.id)
        }

        /// Edge-pan back gesture: starting near the left edge and dragging
        /// right closes the meal detail. Approximates the standard iOS
        /// swipe-back behavior without depending on a navigation push.
        private var swipeBackGesture: some Gesture {
            DragGesture(minimumDistance: 20, coordinateSpace: .global)
                .onEnded { value in
                    guard state.currentResult != nil else { return }
                    guard value.startLocation.x < 40 else { return }
                    guard value.translation.width > 80,
                          abs(value.translation.height) < 120
                    else { return }
                    state.clearResult()
                }
        }

        @ViewBuilder
        private var barcodeStatusBanner: some View {
            if let message = state.barcodeStatusMessage {
                HStack(spacing: 10) {
                    Image(systemName: state.barcodeStatusIsSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    Text(message)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(
                    Capsule()
                        .fill(state.barcodeStatusIsSuccess ? Color.green : Color.orange)
                        .shadow(color: Color.black.opacity(0.16), radius: 12, y: 5)
                )
                .padding(.horizontal, 18)
                .padding(.bottom, isComposerExpanded ? 12 : 76)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(3)
            }
        }

        private func scrollToLastAddedItem(with proxy: ScrollViewProxy) {
            guard let itemID = state.lastAddedFoodItemID else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                withAnimation(.easeInOut(duration: 0.28)) {
                    proxy.scrollTo(itemID, anchor: .center)
                }
            }
        }


        // MARK: - Root content (default FoodFinder page)

        private var rootContent: some View {
            List {
                Section {
                    VStack {
                        emptyStateView
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }

                if !state.frequentMeals.isEmpty {
                    frequentMealsSection
                }

                if !savedMealPresets.isEmpty {
                    savedMealsSection
                }

                if !state.recentResults.isEmpty {
                    recentResultsSection
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .scrollDismissesKeyboard(.interactively)
        }

        // MARK: - Meal detail screen (in-place swap, not nav push)

        @ViewBuilder
        private func mealDetailScreen(for result: FoodAnalysisResult) -> some View {
            ScrollViewReader { proxy in
                List {
                    resultSections(result)
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(appState.trioBackgroundColor(for: colorScheme))
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: state.lastAddedFoodItemID) {
                    scrollToLastAddedItem(with: proxy)
                }
                .onAppear {
                    scrollToLastAddedItem(with: proxy)
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

                if let error = state.errorMessage {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.orange.opacity(0.1))
                    )
                    .padding(.horizontal, 24)
                }
            }
        }

        // MARK: - Result View

        @ViewBuilder private func resultSections(_ result: FoodAnalysisResult) -> some View {
            Section {
                if let imageData = result.imageData {
                    mealImageCard(imageData, result: result)
                } else {
                    mealIdentityCard(result)
                }

                macroSummaryCard(result)
            }

            Section {
                ForEach(result.items) { item in
                    foodItemRow(item)
                        .id(item.id)
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            Button(String(localized: "Edit", comment: "Edit food item"), systemImage: "pencil") {
                                editingFoodItem = item
                            }
                            .tint(.blue)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(String(localized: "Delete", comment: "Delete food item"), systemImage: "trash", role: .destructive) {
                                withAnimation { state.removeItem(item.id) }
                            }
                        }
                }
            } header: {
                Text(String(localized: "Ingredients", comment: "FoodFinder ingredients section"))
            }

            Section {
                Button {
                    state.sendToBolusCalculator(openBolusCalculator: onHandoffComplete == nil)
                    onHandoffComplete?()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.forward.circle.fill")
                        Text(String(localized: "Use in Bolus Calculator", comment: "FoodFinder bolus handoff button"))
                    }
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(result.items.isEmpty || state.isAnalyzing)

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
                HStack {
                    Text(String(localized: "Totals", comment: "FoodFinder totals card header"))
                        .font(.subheadline.bold())
                    if result.hasManualMacroOverride {
                        Text(String(localized: "edited", comment: "FoodFinder edited totals badge"))
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                            .foregroundStyle(Color.accentColor)
                    }
                    Spacer()
                    if result.hasManualMacroOverride {
                        Button {
                            state.updateManualMacroOverride(nil)
                        } label: {
                            Text(String(localized: "Reset", comment: "Reset manual totals button"))
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                    }
                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                            isEditingTotals.toggle()
                        }
                    } label: {
                        Text(
                            isEditingTotals
                                ? String(localized: "Done", comment: "Done editing")
                                : String(localized: "Edit", comment: "Edit totals")
                        )
                        .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.top, 11)
                .padding(.bottom, 6)

                if isEditingTotals {
                    Divider()
                    totalsRow(
                        label: String(localized: "Carbs", comment: "Carbs macro"),
                        value: result.totalCarbs,
                        unit: "g",
                        color: .blue,
                        onCommit: { commitTotal($0, for: \MacroOverride.carbs, in: result) }
                    )
                    Divider()
                    totalsRow(
                        label: String(localized: "Fat", comment: "Fat macro"),
                        value: result.totalFat,
                        unit: "g",
                        color: .yellow,
                        onCommit: { commitTotal($0, for: \MacroOverride.fat, in: result) }
                    )
                    Divider()
                    totalsRow(
                        label: String(localized: "Protein", comment: "Protein macro"),
                        value: result.totalProtein,
                        unit: "g",
                        color: .red,
                        onCommit: { commitTotal($0, for: \MacroOverride.protein, in: result) }
                    )
                    Divider()
                    totalsRow(
                        label: String(localized: "Fiber", comment: "Fiber macro"),
                        value: result.totalFiber,
                        unit: "g",
                        color: .green,
                        onCommit: { commitTotal($0, for: \MacroOverride.fiber, in: result) }
                    )
                    Divider()
                    totalsRow(
                        label: String(localized: "Calories", comment: "Calories label"),
                        value: result.totalCalories,
                        unit: "kcal",
                        color: .secondary,
                        onCommit: { commitTotal($0, for: \MacroOverride.calories, in: result) }
                    )
                } else {
                    carbsHeroView(result)
                    secondaryMacroSummary(result)
                        .padding(.top, 8)
                        .padding(.bottom, 12)
                }
            }
            .padding(.horizontal)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(colorScheme == .dark ? Color.bgDarkerDarkBlue.opacity(0.8) : Color.white)
            )
        }

        private func totalsRow(
            label: String,
            value: Double,
            unit: String,
            color: Color,
            onCommit: @escaping (Double) -> Void
        ) -> some View {
            HStack {
                Text(label)
                Spacer()
                if isEditingTotals {
                    EditableDoubleField(
                        modelValue: value,
                        unit: unit,
                        color: color,
                        fieldWidth: 60,
                        alignTrailing: true,
                        onCommit: onCommit
                    )
                } else {
                    Text("\(String(format: "%.0f", value)) \(unit)")
                        .font(.subheadline.bold())
                        .foregroundStyle(color)
                }
            }
            .font(.subheadline)
            .padding(.vertical, 8)
        }

        /// Hero carbs readout: the dosing-relevant number gets visual primacy,
        /// with the dose-guard range, insulin uncertainty, and an
        /// underestimation hint stacked directly beneath it.
        @ViewBuilder
        private func carbsHeroView(_ result: FoodAnalysisResult) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(String(format: "%.0f", result.totalCarbs))
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(.blue)
                    Text(String(localized: "g carbs", comment: "FoodFinder carbs hero unit"))
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }

                if let candidateCount = result.analysisCandidateCount,
                   candidateCount > 1,
                   let lower = result.carbEstimateLowerBound,
                   let upper = result.carbEstimateUpperBound
                {
                    HStack(spacing: 6) {
                        Image(systemName: result.doseGuardApplied == true ? "shield.lefthalf.filled" : "chart.bar.xaxis")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                        Text(
                            String(
                                format: String(localized: "%.0f–%.0f g range", comment: "FoodFinder dose guard range chip"),
                                lower,
                                upper
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        if let uncertaintyUnits = result.carbEstimateUncertaintyUnits {
                            Text(
                                String(
                                    format: String(localized: "· ±%.1f E", comment: "FoodFinder insulin uncertainty units"),
                                    uncertaintyUnits
                                )
                            )
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(uncertaintyUnits <= 1.5 ? .green : .orange)
                        }
                        Text(
                            String(
                                format: String(localized: "· %d checks", comment: "FoodFinder dose guard check count"),
                                candidateCount
                            )
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }

                    if upper > result.totalCarbs + 0.5 {
                        Label(
                            String(
                                format: String(localized: "Could be up to %.0f g — adjust before dosing", comment: "FoodFinder underestimation hint"),
                                upper
                            ),
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    }
                }
            }
            .padding(.top, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        /// Compact secondary macro line shown under the carbs hero in view mode.
        private func secondaryMacroSummary(_ result: FoodAnalysisResult) -> some View {
            HStack(spacing: 16) {
                compactMacroValue(label: String(localized: "Fat", comment: "Fat macro"), value: result.totalFat, unit: "g", color: .yellow)
                compactMacroValue(label: String(localized: "Protein", comment: "Protein macro"), value: result.totalProtein, unit: "g", color: .red)
                compactMacroValue(label: String(localized: "Fiber", comment: "Fiber macro"), value: result.totalFiber, unit: "g", color: .green)
                compactMacroValue(label: String(localized: "Calories", comment: "Calories label"), value: result.totalCalories, unit: "kcal", color: .secondary)
                Spacer(minLength: 0)
            }
        }

        private func compactMacroValue(label: String, value: Double, unit: String, color: Color) -> some View {
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

        /// Commit one field of the manual totals override. Nil means: fall
        /// back to summed items for that macro.
        private func commitTotal(
            _ newValue: Double,
            for keyPath: WritableKeyPath<MacroOverride, Double?>,
            in result: FoodAnalysisResult
        ) {
            var override = result.manualMacroOverride ?? MacroOverride()
            // Treat values within 0.5 of the auto-summed total as "no
            // change" so the override only gets created when the user
            // actually deviates. This keeps the "edited" badge meaningful.
            let autoTotal: Double
            switch keyPath {
            case \MacroOverride.carbs: autoTotal = result.items.reduce(0) { $0 + $1.adjustedCarbs }
            case \MacroOverride.fat: autoTotal = result.items.reduce(0) { $0 + $1.adjustedFat }
            case \MacroOverride.protein: autoTotal = result.items.reduce(0) { $0 + $1.adjustedProtein }
            case \MacroOverride.fiber: autoTotal = result.items.reduce(0) { $0 + $1.adjustedFiber }
            case \MacroOverride.calories: autoTotal = result.items.reduce(0) { $0 + $1.adjustedCalories }
            default: autoTotal = 0
            }
            if abs(newValue - autoTotal) < 0.5 {
                override[keyPath: keyPath] = nil
            } else {
                override[keyPath: keyPath] = max(0, newValue)
            }
            state.updateManualMacroOverride(override.isEmpty ? nil : override)
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
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Text(item.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(colorScheme == .dark ? .white : .primary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    sourceBadge(for: item)
                }

                HStack(spacing: 8) {
                    Text(item.portion)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    portionControl(for: item)
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(String(format: "%.0f", item.adjustedCarbs))
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.blue)
                        Text(String(localized: "g carbs", comment: "FoodFinder carbs hero unit"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 10) {
                        ingredientMacroChip(label: String(localized: "F", comment: "Fat abbreviation"), value: item.adjustedFat, unit: "g", color: .yellow)
                        ingredientMacroChip(label: String(localized: "P", comment: "Protein abbreviation"), value: item.adjustedProtein, unit: "g", color: .red)
                        ingredientMacroChip(label: String(localized: "Fib", comment: "Fiber abbreviation"), value: item.adjustedFiber, unit: "g", color: .green)
                        ingredientMacroChip(label: nil, value: item.adjustedCalories, unit: "kcal", color: .secondary)
                    }
                }
            }
            .padding(.vertical, 6)
        }

        /// Compact per-ingredient secondary macro chip (fat/protein/fiber/kcal).
        /// Carbs is rendered separately with primacy in `foodItemRow`.
        private func ingredientMacroChip(label: String?, value: Double, unit: String, color: Color) -> some View {
            HStack(spacing: 2) {
                if let label {
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(unit == "kcal" ? "\(String(format: "%.0f", value)) kcal" : "\(String(format: "%.0f", value))\(unit)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(color)
            }
            .lineLimit(1)
        }

        @ViewBuilder
        private func sourceBadge(for item: FoodItem) -> some View {
            Button {
                selectedSourceItem = item
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: item.source.systemImage)
                        .font(.caption2)
                    Text(item.source.shortTitle)
                        .font(.caption2.weight(.semibold))
                    if item.sourceVerified {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(sourceTint(for: item).opacity(colorScheme == .dark ? 0.28 : 0.14))
                )
                .foregroundStyle(sourceTint(for: item))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(item.source.localizedTitle)
        }

        private func sourceTint(for item: FoodItem) -> Color {
            switch item.source {
            case .aiEstimate:
                return .orange
            case .openFoodFacts:
                return item.sourceVerified ? .green : .secondary
            case .usda:
                return .blue
            }
        }

        /// Two-line editable ingredient stat: value (TextField) above a label.
        /// On commit the new adjusted value is forwarded to the state model.
        private func editableIngredientMetric(
            label: String,
            value: Double,
            unit: String,
            color: Color,
            onCommit: @escaping (Double) -> Void
        ) -> some View {
            VStack(alignment: .leading, spacing: 2) {
                EditableDoubleField(
                    modelValue: value,
                    unit: unit,
                    color: color,
                    onCommit: onCommit
                )
                Text(label)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        /// Portion editor: minus / "1.00×" multiplier / plus, with an
        /// optional separate grams field on the right if the original portion
        /// description contained a gram value. Both controls map to the same
        /// underlying `portionMultiplier`, so editing grams keeps the
        /// multiplier in sync and vice versa.
        @ViewBuilder
        private func portionControl(for item: FoodItem) -> some View {
            let base = portionGramsFromString(item.portion)
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Button {
                        let new = max(0.1, item.portionMultiplier - 0.25)
                        state.updatePortion(for: item.id, multiplier: new)
                    } label: {
                        Image(systemName: "minus.circle")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .contentShape(Rectangle())

                    // Tap the factor to type any value directly (not just ±0.25 steps).
                    EditableMultiplierField(
                        multiplier: item.portionMultiplier,
                        onCommit: { newValue in
                            state.updatePortion(for: item.id, multiplier: newValue)
                        }
                    )

                    Button {
                        state.updatePortion(for: item.id, multiplier: item.portionMultiplier + 0.25)
                    } label: {
                        Image(systemName: "plus.circle")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .contentShape(Rectangle())
                }

                // Absolute gram entry — always available. When the portion has
                // a gram anchor the value scales the macros; otherwise the typed
                // weight is recorded as the portion (see setPortionGrams).
                PortionGramsField(
                    grams: base.map { $0 * item.portionMultiplier },
                    onCommit: { newGrams in
                        state.setPortionGrams(for: item.id, grams: newGrams)
                    }
                )
            }
        }

        /// Extract the first gram value from a free-form portion string. Matches
        /// "500g", "500 g", "500 gram", "500 grams". Returns nil if no match.
        private func portionGramsFromString(_ portion: String) -> Double? {
            let pattern = #"(\d+(?:[.,]\d+)?)\s*g(?:ram(?:s)?)?\b"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                return nil
            }
            let range = NSRange(portion.startIndex..<portion.endIndex, in: portion)
            guard let match = regex.firstMatch(in: portion, options: [], range: range),
                  match.numberOfRanges >= 2,
                  let valueRange = Range(match.range(at: 1), in: portion)
            else { return nil }
            let raw = String(portion[valueRange]).replacingOccurrences(of: ",", with: ".")
            return Double(raw)
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

        // MARK: - Frequent Meals (auto-promoted from usage frequency)

        private var frequentMealsSection: some View {
            Section {
                ForEach(state.frequentMeals.prefix(5)) { result in
                    Button {
                        state.currentResult = result
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mealTitle(for: result))
                                    .font(.subheadline)
                                    .lineLimit(1)
                                    .foregroundStyle(colorScheme == .dark ? .white : .primary)
                                Text(String(localized: "Often eaten", comment: "Frequent meals subtitle"))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            HStack(spacing: 6) {
                                Text(String(format: "%.0fg", result.totalCarbs))
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.blue)
                                Image(systemName: "star.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.yellow)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(String(localized: "Remove", comment: "Remove frequent meal"), systemImage: "trash", role: .destructive) {
                            state.deleteFrequentMeal(result)
                        }
                    }
                }
            } header: {
                Text(String(localized: "Frequent Meals", comment: "Frequent meals section header"))
            }
        }

        // MARK: - Saved Meals (MealPresets)

        private var savedMealsSection: some View {
            Section {
                ForEach(savedMealPresets) { preset in
                    Button {
                        state.currentResult = resultFromPreset(preset)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.dish ?? "")
                                    .font(.subheadline)
                                    .lineLimit(1)
                                    .foregroundStyle(colorScheme == .dark ? .white : .primary)
                            }
                            Spacer()
                            HStack(spacing: 6) {
                                Text(String(format: "%.0fg", preset.carbs?.doubleValue ?? 0))
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.blue)
                                Image(systemName: "bookmark.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(String(localized: "Delete", comment: "Delete saved meal"), systemImage: "trash", role: .destructive) {
                            deleteSavedMealPreset(preset)
                        }
                    }
                }
            } header: {
                Text(String(localized: "Saved Meals", comment: "Saved meal presets section header"))
            }
        }

        private func deleteSavedMealPreset(_ preset: MealPresetStored) {
            moc.delete(preset)
            do {
                if moc.hasChanges {
                    try moc.save()
                }
            } catch {
                debugPrint("Failed to delete meal preset: \(error)")
            }
        }

        // MARK: - Recent Results

        private var recentResultsSection: some View {
            Section {
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
                        .padding(.vertical, 6)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(String(localized: "Delete", comment: "Delete recent meal"), systemImage: "trash", role: .destructive) {
                            state.deleteRecentResult(result)
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            saveRecentResultAsPreset(result)
                        } label: {
                            Label(String(localized: "Save", comment: "Save as meal preset"), systemImage: "bookmark")
                        }
                        .tint(.blue)
                    }
                }
            } header: {
                Text(String(localized: "Recent Meals", comment: "Recent results section header"))
            }
        }

        private func resultFromPreset(_ preset: MealPresetStored) -> FoodAnalysisResult {
            let carbs = preset.carbs?.doubleValue ?? 0
            let fat = preset.fat?.doubleValue ?? 0
            let protein = preset.protein?.doubleValue ?? 0
            let kcal = carbs * 4 + fat * 9 + protein * 4
            let item = FoodItem(
                name: preset.dish ?? String(localized: "Meal", comment: "Generic meal title"),
                portion: String(localized: "1 serving", comment: "Default food serving"),
                carbs: carbs,
                fat: fat,
                protein: protein,
                fiber: 0,
                calories: kcal
            )
            return FoodAnalysisResult(
                items: [item],
                rawResponse: nil,
                timestamp: Date(),
                source: .aiText,
                imageData: nil,
                mealDescription: nil,
                mealName: preset.dish,
                mealPortion: nil,
                confidence: 1.0
            )
        }

        private func saveRecentResultAsPreset(_ result: FoodAnalysisResult) {
            let preset = MealPresetStored(context: moc)
            preset.dish = mealTitle(for: result)
            preset.carbs = NSDecimalNumber(value: result.totalCarbs)
            preset.fat = NSDecimalNumber(value: result.totalFat)
            preset.protein = NSDecimalNumber(value: result.totalProtein)
            do {
                guard moc.hasChanges else { return }
                try moc.save()
            } catch {
                debugPrint("Failed to save meal preset: \(error)")
            }
        }

        // MARK: - Input Bar

        private var foodInputBar: some View {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    if isComposerExpanded {
                        expandedFoodComposer
                            .offset(y: composerDragOffset)
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.94, anchor: .bottom).combined(with: .opacity),
                                removal: .scale(scale: 0.98, anchor: .bottom).combined(with: .opacity)
                            ))
                            .zIndex(1)
                    } else {
                        if let result = state.currentResult {
                            compactContextBanner(result)
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                        if !state.capturedImages.isEmpty {
                            attachedImagesStrip
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                        compactFoodInputRow
                    }
                }
                .padding(.top, isComposerExpanded ? 0 : 8)
                .padding(.bottom, isComposerExpanded ? 0 : 8)
            }
            // Collapsed bar: rounded only at the top, snapped flush to the
            // keyboard at the bottom (same as the expanded composer). The
            // expanded composer manages its own background, so leave it clear.
            .background {
                if !isComposerExpanded {
                    UnevenRoundedRectangle(
                        topLeadingRadius: 24,
                        bottomLeadingRadius: 0,
                        bottomTrailingRadius: 0,
                        topTrailingRadius: 24,
                        style: .continuous
                    )
                    .fill(colorScheme == .dark ? Color.bgDarkBlue.opacity(0.96) : Color.white.opacity(0.96))
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.10), radius: 8, y: -2)
                }
            }
            .animation(.spring(response: 0.45, dampingFraction: 0.72), value: state.currentResult?.id)
            .animation(.interactiveSpring(response: 0.42, dampingFraction: 0.88, blendDuration: 0.08), value: isComposerExpanded)
        }

        private var compactFoodInputRow: some View {
            HStack(spacing: 8) {
                expandComposerButton
                    .disabled(state.isAnalyzing)

                TextField(
                    compactInputPlaceholder,
                    text: $state.foodDescription,
                    axis: .vertical
                )
                .lineLimit(1)
                .focused($isTextFieldFocused)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(minHeight: 40)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(colorScheme == .dark ? Color.bgDarkerDarkBlue : Color(.systemGray6))
                )
                .matchedGeometryEffect(id: "composer-text", in: composerNamespace)
                .overlay(alignment: .topLeading) {
                    compactInputMeasurementLayer
                }
                .onPreferenceChange(FoodFinderCompactInputHeightKey.self) { height in
                    compactInputMeasuredHeight = height
                    expandCompactInputIfNeeded(measuredHeight: height)
                }
                .onPreferenceChange(FoodFinderCompactInputSingleLineHeightKey.self) { height in
                    compactInputSingleLineHeight = height
                }
                .onChange(of: state.foodDescription) {
                    expandCompactInputIfNeeded(measuredHeight: compactInputMeasuredHeight)
                }
                .layoutPriority(1)

                foodSearchButton
            }
            .padding(.horizontal, 12)
        }

        private var compactInputPlaceholder: String {
            state.currentResult != nil
                ? String(localized: "Search ingredient...", comment: "FoodFinder ingredient search placeholder")
                : String(localized: "Describe your meal...", comment: "FoodFinder input placeholder")
        }

        private func compactContextBanner(_ result: FoodAnalysisResult) -> some View {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill")
                    .font(.caption.bold())
                Text(
                    String(
                        format: String(localized: "Adding to \"%@\"", comment: "FoodFinder add ingredient context banner"),
                        mealTitle(for: result)
                    )
                )
                .font(.caption.bold())
                .lineLimit(1)
                Spacer()
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.18 : 0.12))
            )
            .padding(.horizontal, 12)
        }

        private var compactInputMeasurementLayer: some View {
            ZStack(alignment: .topLeading) {
                compactInputMeasuredText(compactInputMeasurementText)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: FoodFinderCompactInputHeightKey.self,
                                value: proxy.size.height
                            )
                        }
                    )

                compactInputMeasuredText("Ag")
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: FoodFinderCompactInputSingleLineHeightKey.self,
                                value: proxy.size.height
                            )
                        }
                    )
            }
            .opacity(0)
            .allowsHitTesting(false)
        }

        private var compactInputMeasurementText: String {
            let text = state.foodDescription.isEmpty ? compactInputPlaceholder : state.foodDescription
            return text.isEmpty ? " " : text
        }

        private func compactInputMeasuredText(_ text: String) -> some View {
            Text(text)
                .font(.body)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        private func expandCompactInputIfNeeded(measuredHeight: CGFloat) {
            guard !isComposerExpanded,
                  isTextFieldFocused,
                  !state.foodDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }

            let singleLineHeight = compactInputSingleLineHeight > 0 ? compactInputSingleLineHeight : 40
            let needsAnotherLine = measuredHeight > singleLineHeight + 6 || state.foodDescription.contains("\n")
            guard needsAnotherLine else { return }

            expandComposer(keepKeyboard: true)
        }

        private var expandedFoodComposer: some View {
            VStack(spacing: 10) {
                composerDragHandle

                if let result = state.currentResult {
                    expandedContextBanner(result)
                }

                composerActionGrid

                if !state.capturedImages.isEmpty {
                    attachedImagesStrip
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
                }

                expandedTextEditor

                HStack(spacing: 10) {
                    Button {
                        collapseComposer(keepKeyboard: true)
                    } label: {
                        Image(systemName: "chevron.down")
                            .frame(width: 38, height: 38)
                            .background(
                                Circle()
                                    .fill(colorScheme == .dark ? Color.bgDarkerDarkBlue : Color(.systemGray5))
                            )
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(colorScheme == .dark ? .white : .primary)

                    Text(
                        state.currentResult != nil
                            ? String(localized: "Add ingredient to this meal", comment: "Expanded FoodFinder add mode hint")
                            : String(localized: "Add photos or describe the meal", comment: "Expanded FoodFinder analyze mode hint")
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    foodSearchButton
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .background(
                FoodFinderComposerBackground(cornerRadius: 24)
                    .fill(colorScheme == .dark ? Color.bgDarkBlue : Color.white)
                    .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.3 : 0.12), radius: 18, y: 8)
            )
            .frame(maxWidth: .infinity)
            .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.9), value: composerDragOffset)
            .onAppear {
                refocusComposerInput()
            }
            .onChange(of: isComposerExpanded) {
                if isComposerExpanded {
                    refocusComposerInput()
                }
            }
        }

        private func expandedContextBanner(_ result: FoodAnalysisResult) -> some View {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill")
                    .font(.caption.bold())
                Text(
                    String(
                        format: String(localized: "Adding to \"%@\"", comment: "FoodFinder add ingredient context banner"),
                        mealTitle(for: result)
                    )
                )
                .font(.caption.bold())
                .lineLimit(1)
                Spacer()
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.18 : 0.12))
            )
        }

        private func expandComposer(keepKeyboard: Bool) {
            composerFocusRequest += 1
            let request = composerFocusRequest
            if keepKeyboard {
                isTextFieldFocused = true
            }
            withAnimation(.interactiveSpring(response: 0.42, dampingFraction: 0.88, blendDuration: 0.08)) {
                isComposerExpanded = true
            }
            if keepKeyboard {
                refocusComposerInput(request: request)
            }
        }

        private func collapseComposer(keepKeyboard: Bool) {
            composerFocusRequest += 1
            let request = composerFocusRequest
            if !keepKeyboard {
                isTextFieldFocused = false
            }
            withAnimation(.interactiveSpring(response: 0.42, dampingFraction: 0.9, blendDuration: 0.08)) {
                isComposerExpanded = false
            }
            if keepKeyboard {
                isTextFieldFocused = true
                DispatchQueue.main.async {
                    guard composerFocusRequest == request, !isComposerExpanded else { return }
                    isTextFieldFocused = true
                }
            }
        }

        private func refocusComposerInput(request: Int? = nil) {
            let request = request ?? composerFocusRequest
            isTextFieldFocused = true
            DispatchQueue.main.async {
                guard isComposerExpanded, composerFocusRequest == request else { return }
                isTextFieldFocused = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                guard isComposerExpanded, composerFocusRequest == request else { return }
                isTextFieldFocused = true
            }
        }

        private var composerDragHandle: some View {
            Capsule()
                .fill(Color.secondary.opacity(0.38))
                .frame(width: 44, height: 5)
                .padding(.top, 1)
                .padding(.bottom, 2)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .highPriorityGesture(composerDismissDragGesture)
                .accessibilityLabel(String(localized: "Drag down to collapse", comment: "FoodFinder composer drag handle accessibility label"))
        }

        private var composerDismissDragGesture: some Gesture {
            DragGesture(minimumDistance: 4, coordinateSpace: .local)
                .updating($composerDragOffset) { value, state, _ in
                    state = max(0, value.translation.height)
                }
                .onEnded { value in
                    let shouldCollapse = value.translation.height > 64 || value.predictedEndTranslation.height > 120
                    guard shouldCollapse else { return }
                    collapseComposer(keepKeyboard: false)
                }
        }

        private var composerActionGrid: some View {
            HStack(spacing: 18) {
                composerActionButton(
                    systemImage: "camera.fill",
                    title: String(localized: "Camera", comment: "Composer camera button"),
                    matchedID: "composer-camera"
                ) {
                    isTextFieldFocused = false
                    state.showCamera = true
                }
                .disabled(state.isAnalyzing || state.capturedImages.count >= state.maxFoodFinderImages)

                composerActionButton(
                    systemImage: "photo.on.rectangle",
                    title: String(localized: "Library", comment: "Composer photo library button"),
                    matchedID: "composer-library"
                ) {
                    isTextFieldFocused = false
                    state.showPhotoPicker = true
                }
                .disabled(state.isAnalyzing || state.capturedImages.count >= state.maxFoodFinderImages)

                composerActionButton(
                    systemImage: "barcode.viewfinder",
                    title: String(localized: "Barcode", comment: "Composer barcode button"),
                    matchedID: "composer-barcode"
                ) {
                    isTextFieldFocused = false
                    state.showBarcodeScanner = true
                }
                .disabled(state.isAnalyzing)

                composerActionButton(
                    systemImage: state.isDictating || state.isTranscribingDictation ? "mic.fill" : "mic",
                    title: state.isTranscribingDictation
                        ? String(localized: "Loading", comment: "Composer dictation loading")
                        : state.isDictating
                        ? String(localized: "Stop", comment: "Composer dictation stop")
                        : String(localized: "Dictate", comment: "Composer dictation start"),
                    matchedID: "composer-mic",
                    tint: state.isDictating ? .red : nil,
                    showsProgress: state.isTranscribingDictation
                ) {
                    state.toggleDictation()
                }
                .disabled(state.isAnalyzing || state.isTranscribingDictation)
            }
            .frame(maxWidth: .infinity)
        }

        private var expandedTextEditor: some View {
            ZStack(alignment: .topLeading) {
                if state.foodDescription.isEmpty {
                    Text(
                        state.currentResult != nil
                            ? String(localized: "Describe the ingredient(s) to add...", comment: "Composer placeholder add mode")
                            : String(localized: "Describe your meal in detail...", comment: "Composer placeholder analyze mode")
                    )
                    .font(.body)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .allowsHitTesting(false)
                }

                TextEditor(text: $state.foodDescription)
                    .focused($isTextFieldFocused)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(height: 132)
            }
            .frame(height: 132)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(colorScheme == .dark ? Color.bgDarkerDarkBlue : Color(.systemGray6))
            )
            .matchedGeometryEffect(id: "composer-text", in: composerNamespace)
        }

        private var expandComposerButton: some View {
            Button {
                expandComposer(keepKeyboard: true)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 42, height: 42)
                    .background(
                        Circle()
                            .fill(colorScheme == .dark ? Color.bgDarkerDarkBlue : Color(.systemGray5))
                    )
                    .overlay(
                        Circle()
                            .stroke(Color.accentColor.opacity(0.22), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Open FoodFinder tools", comment: "Expand FoodFinder tools button"))
            .foregroundStyle(colorScheme == .dark ? .white : .primary)
        }

        private func peekingComposerIcon(_ systemImage: String, matchedID: String) -> some View {
            Image(systemName: systemImage)
                .font(.system(size: 8, weight: .semibold))
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.accentColor.opacity(0.16)))
                .foregroundStyle(systemImage == "mic.fill" ? .red : Color.accentColor)
                .matchedGeometryEffect(id: matchedID, in: composerNamespace)
        }

        private func composerActionButton(
            systemImage: String,
            title: String,
            matchedID: String,
            tint: Color? = nil,
            showsProgress: Bool = false,
            action: @escaping () -> Void
        ) -> some View {
            Button(action: action) {
                VStack(spacing: 5) {
                    ZStack {
                        if showsProgress {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: tint ?? Color.accentColor))
                                .scaleEffect(0.82)
                        } else {
                            Image(systemName: systemImage)
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(tint ?? Color.accentColor)
                                .matchedGeometryEffect(id: matchedID, in: composerNamespace)
                        }
                    }
                    .frame(width: 48, height: 48)
                    .background(
                        Circle()
                            .fill((tint ?? Color.accentColor).opacity(colorScheme == .dark ? 0.25 : 0.14))
                    )

                    Text(title)
                        .font(.caption2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(colorScheme == .dark ? .white : .primary)
                }
                .frame(minWidth: 58)
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
        }

        private var foodSearchButton: some View {
            Button {
                submitFoodFinderInput()
            } label: {
                Group {
                    if state.isAnalyzing {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else {
                        Image(systemName: state.currentResult != nil ? "plus.circle.fill" : "sparkle.magnifyingglass")
                    }
                }
                .frame(width: 40, height: 40)
                .background(Circle().fill(foodFinderActionGradient))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(!hasFoodFinderInput || state.isAnalyzing)
            .opacity(!hasFoodFinderInput || state.isAnalyzing ? 0.5 : 1)
        }

        private var foodFinderActionGradient: LinearGradient {
            LinearGradient(
                colors: [
                    Color(red: 0.3411764706, green: 0.6666666667, blue: 0.9254901961),
                    Color(red: 0.262745098, green: 0.7333333333, blue: 0.9137254902)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        private func submitFoodFinderInput() {
            collapseComposer(keepKeyboard: false)
            Task {
                if state.currentResult != nil {
                    await state.addIngredientFromCurrentInput()
                } else {
                    await state.analyzeCurrentInput()
                }
            }
        }

        private var hasFoodFinderInput: Bool {
            !state.capturedImages.isEmpty || !state.foodDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        /// Horizontal strip of attached photos + a hint of how many more can
        /// be added (cap set by the active provider). Each thumb has its
        /// own delete affordance so the user can swap one without clearing
        /// the rest.
        @ViewBuilder
        private var attachedImagesStrip: some View {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(state.capturedImages.enumerated()), id: \.offset) { idx, data in
                        if let img = UIImage(data: data) {
                            ZStack(alignment: .topTrailing) {
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 56, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))

                                Button {
                                    withAnimation(.easeInOut(duration: 0.18)) {
                                        state.removeAttachedImage(at: idx)
                                    }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 16))
                                        .foregroundStyle(.white, Color.black.opacity(0.7))
                                        .padding(2)
                                }
                            }
                        }
                    }

                    if state.capturedImages.count < state.maxFoodFinderImages {
                        Text(
                            state.capturedImages.count == 1
                                ? String(localized: "Add more photos", comment: "FoodFinder add-more-photos hint")
                                : String(format: String(localized: "%d photos attached", comment: "FoodFinder attached photos count"), state.capturedImages.count)
                        )
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.leading, 4)
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(height: 64)
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


private struct FoodFinderComposerBackground: Shape {
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = min(cornerRadius, rect.width / 2, rect.height / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + radius, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + radius),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Flow Layout (for example food chips)

private struct FoodSourceDetailSheet: View {
    let item: AIInsights.FoodItem
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(String(localized: "Displayed item", comment: "FoodFinder source detail")) {
                        Text(item.name)
                            .multilineTextAlignment(.trailing)
                    }
                    if let sourceName = item.sourceName {
                        LabeledContent(String(localized: "Source match", comment: "FoodFinder source detail")) {
                            Text(sourceName)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    if let brand = item.sourceBrand {
                        LabeledContent(String(localized: "Brand", comment: "FoodFinder source detail"), value: brand)
                    }
                    LabeledContent(String(localized: "Source", comment: "FoodFinder source detail"), value: item.source.localizedTitle)
                    LabeledContent(String(localized: "Confidence", comment: "FoodFinder source detail")) {
                        Text(sourceConfidenceText)
                    }
                }

                Section(String(localized: "Nutrition", comment: "FoodFinder source nutrition section")) {
                    LabeledContent(String(localized: "Carbs", comment: "Carbs macro"), value: "\(String(format: "%.0f", item.adjustedCarbs)) g")
                    LabeledContent(String(localized: "Fat", comment: "Fat macro"), value: "\(String(format: "%.0f", item.adjustedFat)) g")
                    LabeledContent(String(localized: "Protein", comment: "Protein macro"), value: "\(String(format: "%.0f", item.adjustedProtein)) g")
                    LabeledContent(String(localized: "Fiber", comment: "Fiber macro"), value: "\(String(format: "%.0f", item.adjustedFiber)) g")
                    LabeledContent(String(localized: "Calories", comment: "Calories label"), value: "\(String(format: "%.0f", item.adjustedCalories)) kcal")
                }

                if let url = item.sourceURL {
                    Section {
                        Button {
                            openURL(url)
                        } label: {
                            Label(String(localized: "Open source", comment: "Open food source button"), systemImage: "safari")
                        }
                    }
                }

                if !item.alternateMatches.isEmpty {
                    Section(String(localized: "Other matches", comment: "FoodFinder alternate matches section")) {
                        ForEach(item.alternateMatches.prefix(5)) { match in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(match.name)
                                    .font(.subheadline.weight(.semibold))
                                Text(match.brand ?? match.sourceID.localizedTitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("\(String(format: "%.0f", match.carbs)) g \(String(localized: "carbs", comment: "Carbs lowercase")) - \(match.portion)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "Food source", comment: "FoodFinder source detail title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done", comment: "Done button")) {
                        dismiss()
                    }
                }
            }
        }
    }

    private var sourceConfidenceText: String {
        guard let score = item.sourceScore else {
            return item.sourceVerified
                ? String(localized: "Verified", comment: "FoodFinder verified source")
                : String(localized: "Estimated", comment: "FoodFinder estimated source")
        }
        return "\(String(format: "%.0f", score * 100))%"
    }
}

private struct FoodItemEditSheet: View {
    let item: AIInsights.FoodItem
    let onSave: (AIInsights.FoodItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var portion: String
    @State private var carbs: String
    @State private var fat: String
    @State private var protein: String
    @State private var fiber: String
    @State private var calories: String

    init(item: AIInsights.FoodItem, onSave: @escaping (AIInsights.FoodItem) -> Void) {
        self.item = item
        self.onSave = onSave
        _name = State(initialValue: item.name)
        _portion = State(initialValue: item.portion)
        _carbs = State(initialValue: Self.format(item.adjustedCarbs))
        _fat = State(initialValue: Self.format(item.adjustedFat))
        _protein = State(initialValue: Self.format(item.adjustedProtein))
        _fiber = State(initialValue: Self.format(item.adjustedFiber))
        _calories = State(initialValue: Self.format(item.adjustedCalories))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "Name", comment: "Food item name field"), text: $name)
                    TextField(String(localized: "Portion", comment: "Food item portion field"), text: $portion)
                } header: {
                    Text(String(localized: "Ingredient", comment: "FoodFinder ingredient section"))
                }

                Section {
                    macroField(String(localized: "Carbs", comment: "Carbs macro"), text: $carbs, unit: "g")
                    macroField(String(localized: "Fat", comment: "Fat macro"), text: $fat, unit: "g")
                    macroField(String(localized: "Protein", comment: "Protein macro"), text: $protein, unit: "g")
                    macroField(String(localized: "Fiber", comment: "Fiber macro"), text: $fiber, unit: "g")
                    macroField(String(localized: "Calories", comment: "Calories label"), text: $calories, unit: "kcal")
                } header: {
                    Text(String(localized: "Nutrition", comment: "FoodFinder nutrition section"))
                } footer: {
                    Text(String(localized: "These values apply to the currently selected portion multiplier.", comment: "FoodFinder edit ingredient footer"))
                }
            }
            .navigationTitle(String(localized: "Edit Ingredient", comment: "FoodFinder edit ingredient alert"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", comment: "Cancel button")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save", comment: "Save button")) {
                        onSave(updatedItem)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var updatedItem: AIInsights.FoodItem {
        let multiplier = max(item.portionMultiplier, 0.25)
        return AIInsights.FoodItem(
            id: item.id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            portion: portion.trimmingCharacters(in: .whitespacesAndNewlines).aiInsightsNilIfEmpty ?? item.portion,
            carbs: max(0, decimalValue(carbs)) / multiplier,
            fat: max(0, decimalValue(fat)) / multiplier,
            protein: max(0, decimalValue(protein)) / multiplier,
            fiber: max(0, decimalValue(fiber)) / multiplier,
            calories: max(0, decimalValue(calories)) / multiplier,
            portionMultiplier: item.portionMultiplier,
            source: item.source,
            sourceURL: item.sourceURL,
            sourceVerified: item.sourceVerified,
            sourceName: item.sourceName,
            sourceBrand: item.sourceBrand,
            sourceImageURL: item.sourceImageURL,
            sourceScore: item.sourceScore,
            alternateMatches: item.alternateMatches
        )
    }

    private func macroField(_ label: String, text: Binding<String>, unit: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("0", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
            Text(unit)
                .foregroundColor(.secondary)
        }
    }

    private func decimalValue(_ raw: String) -> Double {
        Double(raw.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.0f", value)
    }
}

private struct FoodFinderCompactInputHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct FoodFinderCompactInputSingleLineHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Grams TextField linked to the same underlying `portionMultiplier` as the
/// +/- multiplier control next to it. Owns its own text-state so the user
/// can type freely; commit happens on focus loss, submit, or the keyboard
/// Done button. Re-syncs from the model when not focused.
/// Inline-editable text field that looks like regular text until tapped.
/// Used for the ingredient name in `foodItemRow`.
private struct EditableNameField: View {
    let modelName: String
    let onCommit: (String) -> Void

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .font(.subheadline.weight(.semibold))
            .textFieldStyle(.plain)
            .lineLimit(1)
            .focused($focused)
            .submitLabel(.done)
            .onAppear { syncText() }
            .onChange(of: modelName) {
                if !focused { syncText() }
            }
            .onChange(of: focused) { if !focused { commit() } }
            .onSubmit { focused = false }
            .padding(.vertical, 1)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(focused ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(height: focused ? 1 : 0.5)
                    .offset(y: 2)
            }
            .toolbar {
                if focused {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button(String(localized: "Done", comment: "Dismiss keyboard")) {
                            focused = false
                        }
                        .bold()
                    }
                }
            }
    }

    private func syncText() { text = modelName }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            text = modelName
        } else if trimmed != modelName {
            onCommit(trimmed)
        }
    }
}

/// Inline-editable numeric field with a unit suffix. Owns its own text
/// state so the user can type freely; commit fires on focus loss / submit.
/// Used for ingredient macros and meal totals.
private struct EditableDoubleField: View {
    let modelValue: Double
    let unit: String
    let color: Color
    var fieldWidth: CGFloat = 44
    var alignTrailing: Bool = false
    let onCommit: (Double) -> Void

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 2) {
            TextField("", text: $text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(alignTrailing ? .trailing : .leading)
                .font(.caption.bold())
                .foregroundStyle(color)
                .focused($focused)
                .frame(width: fieldWidth)
                .onAppear { syncText() }
                .onChange(of: modelValue) {
                    if !focused { syncText() }
                }
                .onChange(of: focused) { if !focused { commit() } }
                .onSubmit { focused = false }
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(focused ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(height: focused ? 1 : 0.5)
                        .offset(y: 2)
                }

            Text(unit)
                .font(.caption2.bold())
                .foregroundStyle(color)
        }
        .toolbar {
            if focused {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(String(localized: "Done", comment: "Dismiss keyboard")) {
                        focused = false
                    }
                    .bold()
                }
            }
        }
    }

    private func syncText() {
        text = String(format: "%.0f", modelValue)
    }

    private func commit() {
        let normalized = text.replacingOccurrences(of: ",", with: ".")
        if let value = Double(normalized), value >= 0 {
            onCommit(value)
        } else {
            syncText()
        }
    }
}

/// Editable portion-multiplier field. Shows "X.XX×" and, when tapped, lets the
/// user type any factor directly instead of being limited to ±0.25 steps.
private struct EditableMultiplierField: View {
    let multiplier: Double
    let onCommit: (Double) -> Void

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 1) {
            TextField("", text: $text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.center)
                .font(.caption.monospacedDigit())
                .focused($focused)
                .frame(width: 38)
                .onAppear { syncText() }
                .onChange(of: multiplier) {
                    if !focused { syncText() }
                }
                .onChange(of: focused) {
                    if !focused { commit() }
                }
                .onSubmit { focused = false }
            Text("×")
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 3)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .stroke(focused ? Color.accentColor : Color.clear, lineWidth: 1)
        )
        .toolbar {
            if focused {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(String(localized: "Done", comment: "Dismiss keyboard")) {
                        focused = false
                    }
                    .bold()
                }
            }
        }
    }

    private func syncText() {
        text = String(format: "%.2f", multiplier)
    }

    private func commit() {
        let normalized = text.replacingOccurrences(of: ",", with: ".")
        if let value = Double(normalized), value > 0 {
            onCommit(value)
        } else {
            syncText()
        }
    }
}

/// Absolute gram entry for a portion. `grams` is nil when the portion has no
/// gram anchor yet — the field then shows a placeholder so the user can still
/// type a weight (the state model records it; see setPortionGrams).
private struct PortionGramsField: View {
    let grams: Double?
    let onCommit: (Double) -> Void

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(String(localized: "g", comment: "Grams placeholder"), text: $text)
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.center)
            .font(.caption.monospacedDigit())
            .focused($focused)
            .frame(width: 60)
            .onAppear { syncText() }
            .onChange(of: grams) {
                if !focused { syncText() }
            }
            .onChange(of: focused) {
                if !focused { commit() }
            }
            .onSubmit { commit() }
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(focused ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: focused ? 1 : 0.5)
            )
            .overlay(alignment: .trailing) {
                Text("g")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.trailing, 3)
                    .opacity(focused || text.isEmpty ? 0 : 1)
            }
            .toolbar {
                if focused {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button(String(localized: "Done", comment: "Dismiss keyboard")) {
                            focused = false
                        }
                        .bold()
                    }
                }
            }
    }

    private func syncText() {
        if let grams {
            text = String(format: "%.0f", grams)
        } else {
            text = ""
        }
    }

    private func commit() {
        let normalized = text.replacingOccurrences(of: ",", with: ".")
        if let value = Double(normalized), value > 0 {
            onCommit(value)
        } else {
            syncText()
        }
    }
}

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
