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
        @State private var editingItem: FoodItem?
        @State private var editingTotals: Bool = false

        @FetchRequest(
            entity: MealPresetStored.entity(),
            sortDescriptors: [NSSortDescriptor(key: "dish", ascending: true)]
        ) var savedMealPresets: FetchedResults<MealPresetStored>


        var body: some View {
            rootContent
                .navigationDestination(isPresented: Binding(
                    get: { state.currentResult != nil },
                    set: { isPresented in
                        if !isPresented { state.currentResult = nil }
                    }
                )) {
                    mealDetailScreen
                }
                .onAppear(perform: configureView)
                .fullScreenCover(isPresented: $state.showCamera) {
                AIInsights.CameraCaptureView { imageData in
                    state.pendingImageForCrop = imageData
                }
                .ignoresSafeArea()
            }
            .fullScreenCover(isPresented: $state.showBarcodeScanner) {
                AIInsights.BarcodeScannerView { barcode in
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
                AIInsights.PhotoLibraryPickerView { imageData in
                    state.pendingImageForCrop = imageData
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
            .sheet(item: $editingItem) { item in
                IngredientEditSheet(
                    initialItem: item,
                    onSave: { updated in state.replaceItem(updated) },
                    onReanalyze: { query in
                        Task { await state.reanalyzeItem(item.id, query: query) }
                    }
                )
            }
            .sheet(isPresented: $editingTotals) {
                if let result = state.currentResult {
                    TotalsEditSheet(
                        result: result,
                        onSave: { override in state.updateManualMacroOverride(override) }
                    )
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
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // Only show the input bar at the root when no meal is active.
                // Otherwise SwiftUI is in the middle of pushing the meal detail
                // and we'd briefly render the "Adding to..." context here.
                if state.currentResult == nil {
                    foodInputBar
                }
            }
            .navigationTitle(String(localized: "FoodFinder", comment: "Nav title"))
            .navigationBarTitleDisplayMode(.inline)
        }

        // MARK: - Meal detail screen (pushed onto nav stack)

        @ViewBuilder private var mealDetailScreen: some View {
            if let result = state.currentResult {
                List {
                    resultSections(result)
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(appState.trioBackgroundColor(for: colorScheme))
                .scrollDismissesKeyboard(.interactively)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    foodInputBar
                }
                .navigationTitle(mealTitle(for: result))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            state.clearResult()
                        } label: {
                            Text(String(localized: "New", comment: "New analysis button"))
                                .font(.subheadline)
                        }
                    }
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
                        .swipeActions(edge: .trailing) {
                            Button(String(localized: "Delete", comment: "Delete food item"), systemImage: "trash", role: .destructive) {
                                withAnimation { state.removeItem(item.id) }
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button(String(localized: "Edit", comment: "Edit food item"), systemImage: "slider.horizontal.3") {
                                editingItem = item
                            }
                            .tint(.blue)
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
                    Label(String(localized: "Use in Bolus Calculator", comment: "FoodFinder bolus handoff button"), systemImage: "arrow.forward.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(result.items.isEmpty)

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
                    Button {
                        editingTotals = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(String(localized: "Edit totals", comment: "Edit meal totals accessibility label"))
                }
                .padding(.top, 11)
                .padding(.bottom, 4)

                Divider()
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
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                        Text(item.portion)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    portionControl(for: item)
                }

                HStack(spacing: 14) {
                    ingredientMetric(String(localized: "Carbs", comment: "Carbs macro"), value: item.adjustedCarbs, unit: "g", color: .blue)
                    ingredientMetric(String(localized: "Fat", comment: "Fat macro"), value: item.adjustedFat, unit: "g", color: .yellow)
                    ingredientMetric(String(localized: "Protein", comment: "Protein macro"), value: item.adjustedProtein, unit: "g", color: .red)
                    ingredientMetric(String(localized: "Fiber", comment: "Fiber macro"), value: item.adjustedFiber, unit: "g", color: .green)
                    ingredientMetric(String(localized: "Calories", comment: "Calories label"), value: item.adjustedCalories, unit: "kcal", color: .secondary)
                }
            }
            .padding(.vertical, 6)
        }

        /// Compact portion editor: minus / editable grams (or "x.xx×") / plus.
        /// Tries to extract grams from `item.portion` (e.g. "500g cooked"); if found,
        /// renders a numeric TextField for direct gram entry. Otherwise falls back to
        /// the multiplier display. +/- step is 0.25× either way.
        @ViewBuilder
        private func portionControl(for item: FoodItem) -> some View {
            if let base = portionGramsFromString(item.portion) {
                PortionGramsControl(
                    modelGrams: base * item.portionMultiplier,
                    baseGrams: base,
                    onCommit: { newGrams in
                        let multiplier = max(0.1, newGrams / base)
                        state.updatePortion(for: item.id, multiplier: multiplier)
                    }
                )
            } else {
                HStack(spacing: 4) {
                    Button {
                        state.updatePortion(for: item.id, multiplier: item.portionMultiplier - 0.25)
                    } label: {
                        Image(systemName: "minus.circle")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .contentShape(Rectangle())

                    Text(String(format: "%.2fx", item.portionMultiplier))
                        .font(.caption.monospacedDigit())
                        .frame(width: 42)

                    Button {
                        state.updatePortion(for: item.id, multiplier: item.portionMultiplier + 0.25)
                    } label: {
                        Image(systemName: "plus.circle")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .contentShape(Rectangle())
                }
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
                // Context banner: shown when viewing a meal (all inputs add to that meal).
                // Only this banner animates in — the rest of the bar stays visually stable.
                if let result = state.currentResult {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                            .font(.caption.bold())
                        Text(
                            String(
                                format: String(
                                    localized: "Adding to \"%@\"",
                                    comment: "FoodFinder add ingredient context banner"
                                ),
                                mealTitle(for: result)
                            )
                        )
                        .font(.caption.bold())
                        .lineLimit(1)
                        Spacer()
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

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
                                Text(
                                    state.currentResult != nil
                                        ? String(localized: "Photo will be added as ingredient.", comment: "FoodFinder photo add ingredient help")
                                        : String(localized: "This photo will be analyzed with your description.", comment: "FoodFinder attached photo help")
                                )
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

                        roundInputButton(systemImage: "photo.on.rectangle") {
                            state.showPhotoPicker = true
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
                            state.currentResult != nil
                                ? String(localized: "Search ingredient...", comment: "FoodFinder ingredient search placeholder")
                                : String(localized: "Describe your meal...", comment: "FoodFinder input placeholder"),
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
                            Task {
                                if state.currentResult != nil {
                                    await state.addIngredientFromCurrentInput()
                                } else {
                                    await state.analyzeCurrentInput()
                                }
                            }
                        } label: {
                            Group {
                                if state.isAnalyzing {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                } else {
                                    Image(systemName: state.currentResult != nil ? "plus.circle.fill" : "sparkle.magnifyingglass")
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
            }
            .background(colorScheme == .dark ? Color.bgDarkBlue : Color.white)
            .animation(.easeInOut(duration: 0.25), value: state.currentResult?.id)
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

// MARK: - Ingredient Edit Sheet

private struct IngredientEditSheet: View {
    let initialItem: AIInsights.FoodItem
    let onSave: (AIInsights.FoodItem) -> Void
    let onReanalyze: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppState.self) private var appState

    @State private var name: String = ""
    @State private var portion: String = ""
    @State private var carbs: Double = 0
    @State private var fat: Double = 0
    @State private var protein: Double = 0
    @State private var fiber: Double = 0
    @State private var calories: Double = 0
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case name, portion, carbs, fat, protein, fiber, calories
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text(String(localized: "Ingredient", comment: "Edit ingredient section header"))) {
                    TextField(
                        String(localized: "Name", comment: "Ingredient name field"),
                        text: $name
                    )
                    .focused($focusedField, equals: .name)

                    TextField(
                        String(localized: "Portion description", comment: "Ingredient portion field"),
                        text: $portion
                    )
                    .focused($focusedField, equals: .portion)
                }

                Section(
                    header: Text(String(localized: "Macros (per base portion)", comment: "Edit ingredient macros section header")),
                    footer: Text(String(localized: "These values are per the base portion shown above. Use the +/- buttons in the ingredient row to scale.", comment: "Edit ingredient macros footer"))
                ) {
                    macroField(label: String(localized: "Carbs", comment: "Carbs macro"), value: $carbs, unit: "g", field: .carbs)
                    macroField(label: String(localized: "Fat", comment: "Fat macro"), value: $fat, unit: "g", field: .fat)
                    macroField(label: String(localized: "Protein", comment: "Protein macro"), value: $protein, unit: "g", field: .protein)
                    macroField(label: String(localized: "Fiber", comment: "Fiber macro"), value: $fiber, unit: "g", field: .fiber)
                    macroField(label: String(localized: "Calories", comment: "Calories label"), value: $calories, unit: "kcal", field: .calories)
                }

                Section {
                    Button {
                        let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !query.isEmpty else { return }
                        onReanalyze(query)
                        dismiss()
                    } label: {
                        Label(
                            String(localized: "Re-analyze with AI", comment: "Re-analyze ingredient button"),
                            systemImage: "sparkles"
                        )
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .navigationTitle(String(localized: "Edit Ingredient", comment: "Edit ingredient sheet title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "Cancel", comment: "Cancel button")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "Save", comment: "Save button")) {
                        commit()
                        dismiss()
                    }
                    .bold()
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(String(localized: "Done", comment: "Dismiss keyboard")) { focusedField = nil }.bold()
                }
            }
            .onAppear {
                name = initialItem.name
                portion = initialItem.portion
                carbs = initialItem.carbs
                fat = initialItem.fat
                protein = initialItem.protein
                fiber = initialItem.fiber
                calories = initialItem.calories
            }
        }
    }

    private func macroField(label: String, value: Binding<Double>, unit: String, field: Field) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField(label, value: value, format: .number.precision(.fractionLength(0 ... 1)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .focused($focusedField, equals: field)
                .frame(maxWidth: 80)
            Text(unit)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(width: 36, alignment: .leading)
        }
    }

    private func commit() {
        var updated = initialItem
        updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? initialItem.name
            : name
        updated.portion = portion
        updated.carbs = max(0, carbs)
        updated.fat = max(0, fat)
        updated.protein = max(0, protein)
        updated.fiber = max(0, fiber)
        updated.calories = max(0, calories)
        onSave(updated)
    }
}

// MARK: - Totals Edit Sheet

private struct TotalsEditSheet: View {
    let result: AIInsights.FoodAnalysisResult
    let onSave: (AIInsights.MacroOverride?) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppState.self) private var appState

    @State private var carbs: Double = 0
    @State private var fat: Double = 0
    @State private var protein: Double = 0
    @State private var fiber: Double = 0
    @State private var calories: Double = 0
    @State private var overrideEnabled: Bool = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case carbs, fat, protein, fiber, calories
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(
                    footer: Text(String(localized: "Disable to fall back to the sum of ingredient macros.", comment: "Totals override footer"))
                ) {
                    Toggle(String(localized: "Override totals", comment: "Manual totals override toggle"), isOn: $overrideEnabled)
                }

                Section(header: Text(String(localized: "Meal Totals", comment: "Totals edit section header"))) {
                    totalsField(label: String(localized: "Carbs", comment: "Carbs macro"), value: $carbs, unit: "g", field: .carbs)
                    totalsField(label: String(localized: "Fat", comment: "Fat macro"), value: $fat, unit: "g", field: .fat)
                    totalsField(label: String(localized: "Protein", comment: "Protein macro"), value: $protein, unit: "g", field: .protein)
                    totalsField(label: String(localized: "Fiber", comment: "Fiber macro"), value: $fiber, unit: "g", field: .fiber)
                    totalsField(label: String(localized: "Calories", comment: "Calories label"), value: $calories, unit: "kcal", field: .calories)
                }
                .disabled(!overrideEnabled)
            }
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .navigationTitle(String(localized: "Edit Totals", comment: "Edit totals sheet title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "Cancel", comment: "Cancel button")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "Save", comment: "Save button")) {
                        commit()
                        dismiss()
                    }
                    .bold()
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(String(localized: "Done", comment: "Dismiss keyboard")) { focusedField = nil }.bold()
                }
            }
            .onAppear {
                let existing = result.manualMacroOverride
                carbs = existing?.carbs ?? result.totalCarbs
                fat = existing?.fat ?? result.totalFat
                protein = existing?.protein ?? result.totalProtein
                fiber = existing?.fiber ?? result.totalFiber
                calories = existing?.calories ?? result.totalCalories
                overrideEnabled = result.hasManualMacroOverride
            }
        }
    }

    private func totalsField(label: String, value: Binding<Double>, unit: String, field: Field) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField(label, value: value, format: .number.precision(.fractionLength(0 ... 1)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .focused($focusedField, equals: field)
                .frame(maxWidth: 80)
            Text(unit)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(width: 36, alignment: .leading)
        }
    }

    private func commit() {
        guard overrideEnabled else {
            onSave(nil)
            return
        }
        let override = AIInsights.MacroOverride(
            carbs: max(0, carbs),
            fat: max(0, fat),
            protein: max(0, protein),
            fiber: max(0, fiber),
            calories: max(0, calories)
        )
        onSave(override)
    }
}

// MARK: - Flow Layout (for example food chips)

/// Compact portion editor: minus / editable grams field / plus, with a
/// keyboard Done button so the user can commit explicitly. The +/- buttons
/// operate on the currently-displayed grams (including any uncommitted typed
/// value), so typing "300" and tapping + adds a step to 300 — not to the
/// pre-edit value.
private struct PortionGramsControl: View {
    let modelGrams: Double
    let baseGrams: Double
    let onCommit: (Double) -> Void

    @State private var text: String = ""
    @FocusState private var focused: Bool

    private var displayedGrams: Double {
        let normalized = text.replacingOccurrences(of: ",", with: ".")
        if let g = Double(normalized), g > 0 { return g }
        return modelGrams
    }

    private var step: Double {
        max(1, baseGrams * 0.25)
    }

    var body: some View {
        HStack(spacing: 4) {
            Button {
                let newGrams = max(baseGrams * 0.1, displayedGrams - step)
                text = formatted(newGrams)
                onCommit(newGrams)
            } label: {
                Image(systemName: "minus.circle")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .contentShape(Rectangle())

            TextField("", text: $text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.center)
                .font(.caption.monospacedDigit())
                .focused($focused)
                .frame(width: 64)
                .onAppear { syncText() }
                .onChange(of: modelGrams) {
                    if !focused { syncText() }
                }
                .onChange(of: focused) {
                    if !focused { commit() }
                }
                .onSubmit { commit() }
                .padding(.vertical, 2)
                .padding(.horizontal, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.4), lineWidth: 0.5)
                )
                .overlay(alignment: .trailing) {
                    Text("g")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.trailing, 2)
                        .opacity(focused ? 0 : 1)
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

            Button {
                let newGrams = displayedGrams + step
                text = formatted(newGrams)
                onCommit(newGrams)
            } label: {
                Image(systemName: "plus.circle")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .contentShape(Rectangle())
        }
    }

    private func syncText() {
        text = formatted(modelGrams)
    }

    private func commit() {
        let normalized = text.replacingOccurrences(of: ",", with: ".")
        if let grams = Double(normalized), grams > 0 {
            onCommit(grams)
        } else {
            syncText()
        }
    }

    private func formatted(_ grams: Double) -> String {
        String(format: "%.0f", grams)
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
