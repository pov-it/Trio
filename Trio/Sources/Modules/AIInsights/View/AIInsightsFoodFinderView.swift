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
        // Feature M — presents the meal-photo gallery from the empty FoodFinder screen.
        @State private var showMealGallery = false
        @State private var editingFoodItem: FoodItem?
        @State private var selectedSourceItem: FoodItem?
        @State private var compactInputMeasuredHeight: CGFloat = 0
        @State private var compactInputSingleLineHeight: CGFloat = 0
        @GestureState private var composerDragOffset: CGFloat = 0
        @State private var isComposerDragActive = false
        @State private var keyboardLift: CGFloat = 0
        @State private var dragFrozenKeyboardLift: CGFloat = 0
        @Namespace private var composerNamespace
        @State private var pendingGalleryBolus: FoodAnalysisResult?

        @FetchRequest(
            entity: MealPresetStored.entity(),
            sortDescriptors: [NSSortDescriptor(key: "dish", ascending: true)]
        ) var savedMealPresets: FetchedResults<MealPresetStored>


        var body: some View {
            ZStack(alignment: .bottom) {
                contentArea
                    .background(appState.trioBackgroundColor(for: colorScheme))
                barcodeStatusBanner
            }
            // One bottom composer. The host's keyboard safe area is stripped
            // and this view ignores it, so the bar is lifted only by
            // `keyboardLift` (keyboard overlap minus the tab bar and home
            // indicator this inset already clears).
            .safeAreaInset(edge: .bottom, spacing: 0) {
                foodInputBar
            }
            .aiInsightsStripKeyboardSafeArea()
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .background(appState.trioBackgroundColor(for: colorScheme))
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
                // Feature M — on the default/empty FoodFinder screen, offer the
                // meal-photo gallery in the top-right. Separate ToolbarItem from
                // the "New" button above, which only shows when a result exists.
                if state.currentResult == nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showMealGallery = true
                        } label: {
                            Image(systemName: "photo.stack")
                        }
                        .accessibilityLabel(String(localized: "Meal gallery", comment: "Meal gallery button accessibility label"))
                    }
                }
            }
            .sheet(isPresented: $showMealGallery, onDismiss: {
                if let result = pendingGalleryBolus {
                    pendingGalleryBolus = nil
                    state.sendToBolusCalculator(result: result, openBolusCalculator: onHandoffComplete == nil)
                    onHandoffComplete?()
                }
            }) {
                AIInsights.MealGalleryView(
                    fallbackResults: state.recentResults,
                    onOpenInFoodFinder: { result in
                        showMealGallery = false
                        state.currentResult = result
                    },
                    onUseInBolusCalculator: { result in
                        pendingGalleryBolus = result
                        showMealGallery = false
                    },
                    units: state.settingsManager.settings.units
                )
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
                AIInsights.CameraCaptureView(
                    targetCount: min(
                        AIInsights.CameraCaptureView.mealPhotoTarget,
                        max(1, state.maxFoodFinderImages - state.capturedImages.count)
                    )
                ) { images in
                    state.attachImages(images)
                }
                .ignoresSafeArea()
            }
            .fullScreenCover(isPresented: $state.showBarcodeScanner) {
                AIInsights.BarcodeScannerView(dismissOnScan: true) { barcode in
                    state.showBarcodeScanner = false
                    Task {
                        await state.attachScannedBarcode(barcode)
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
                // safeAreaInset already keeps the bar above the content;
                // just add a small gap so the banner floats above the bar.
                .padding(.bottom, 8)
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
            let saved = savedMealEntries
            let recent = state.recentResults
            return ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    emptyStateView(compact: !saved.isEmpty || !recent.isEmpty)
                        .frame(maxWidth: .infinity)

                    if !saved.isEmpty {
                        FoodFinderMealGridSection(
                            title: String(localized: "Saved Meals", comment: "Saved meal presets section header"),
                            count: saved.count
                        ) {
                            ForEach(saved) { entry in
                                savedMealTile(entry)
                            }
                        }
                    }

                    if !recent.isEmpty {
                        FoodFinderMealGridSection(
                            title: String(localized: "Recent Meals", comment: "Recent results section header"),
                            count: recent.count
                        ) {
                            ForEach(recent) { result in
                                recentMealTile(result)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(appState.trioBackgroundColor(for: colorScheme))
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
                    Task { await state.refreshPostMealSummaries() }
                }
            }
        }

        // MARK: - Empty State

        /// `compact` leaves out the introduction once there are meals on the page, keeping the notices.
        private func emptyStateView(compact: Bool) -> some View {
            VStack(spacing: 16) {
                if !compact {
                    emptyStateIntroduction
                }

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

        private var emptyStateIntroduction: some View {
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

                if let comparison = result.photoComparison {
                    photoComparisonCard(comparison)
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

            if let summary = state.postMealSummaries[result.id] {
                postMealSection(summary)
            }

            Section {
                let keys = MealResponseKeys(results: [result])
                MealResponseCard(
                    title: String(localized: "Glucose after this meal", comment: "Meal detail response card title"),
                    mealIDs: keys.mealIDs,
                    foodResultIDs: keys.foodResultIDs,
                    units: state.settingsManager.settings.units,
                    cardFill: colorScheme == .dark ? Color.bgDarkerDarkBlue.opacity(0.8) : Color.white,
                    currentCarbs: result.totalCarbs
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
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

        private func photoComparisonCard(_ comparison: FoodFinderPhotoComparison) -> some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(String(localized: "Agreement", comment: "FoodFinder photo agreement label"))
                        .font(.subheadline.bold())
                    Spacer()
                    Text(agreementText(comparison.agreementPercent))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(agreementColor(comparison.agreementPercent))
                }
                Text(loggedMealNote(comparison))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 8) {
                    photoSideColumn(comparison.onDevice, engine: .onDevice, adopted: comparison.adoptedEngine)
                    photoSideColumn(comparison.gemini, engine: .gemini, adopted: comparison.adoptedEngine)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(colorScheme == .dark ? Color.bgDarkerDarkBlue.opacity(0.8) : Color.white)
            )
        }

        private func agreementText(_ percent: Int?) -> String {
            guard let percent else {
                return String(localized: "n/a", comment: "FoodFinder photo agreement not available")
            }
            return "\(percent)%"
        }

        private func agreementColor(_ percent: Int?) -> Color {
            guard let percent else { return .secondary }
            if percent >= 80 { return .green }
            if percent >= 50 { return .orange }
            return .red
        }

        private func loggedMealNote(_ comparison: FoodFinderPhotoComparison) -> String {
            let other = comparison.adoptedEngine == .gemini ? comparison.onDevice : comparison.gemini
            if other.outcome == .ready {
                return comparison.adoptedEngine == .gemini
                    ? String(
                        localized: "Logged meal uses Gemini. Tap On-device to switch, then edit the numbers.",
                        comment: "FoodFinder comparison uses Gemini"
                    )
                    : String(
                        localized: "Logged meal uses On-device. Tap Gemini to switch, then edit the numbers.",
                        comment: "FoodFinder comparison uses on-device"
                    )
            }
            return comparison.adoptedEngine == .gemini
                ? String(
                    localized: """
                    Logged meal uses Gemini. The on-device estimate is not available. \
                    Edit the numbers before you use them.
                    """,
                    comment: "FoodFinder comparison Gemini only"
                )
                : String(
                    localized: """
                    Logged meal uses On-device. Gemini is not available. \
                    Edit the numbers before you use them.
                    """,
                    comment: "FoodFinder comparison on-device only"
                )
        }

        private func photoSideColumn(
            _ side: FoodFinderPhotoSide,
            engine: FoodFinderPhotoEngine,
            adopted: FoodFinderPhotoEngine
        ) -> some View {
            let selected = adopted == engine && side.outcome == .ready
            return Button {
                state.adoptPhotoEngine(engine)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(engine.columnTitle)
                            .font(.caption.weight(.semibold))
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption2)
                        }
                        Spacer(minLength: 0)
                    }
                    if side.outcome == .ready {
                        Text(
                            side.mealName?.trimmingCharacters(in: .whitespacesAndNewlines).aiInsightsNilIfEmpty
                                ?? String(localized: "Meal", comment: "Generic meal title")
                        )
                        .font(.caption.weight(.semibold))
                        .lineLimit(2)
                        Text(
                            String(
                                format: String(localized: "%.0f g carbs", comment: "FoodFinder comparison carbs"),
                                side.carbs
                            )
                        )
                        .font(.caption)
                        Text(
                            String(
                                format: String(
                                    localized: "%.0f g fat · %.0f g protein",
                                    comment: "FoodFinder comparison fat and protein"
                                ),
                                side.fat,
                                side.protein
                            )
                        )
                        .font(.caption2)
                        Text(
                            String(
                                format: String(localized: "%.0f kcal", comment: "FoodFinder comparison calories"),
                                side.calories
                            )
                        )
                        .font(.caption2)
                    } else {
                        Text(
                            side.outcome == .unavailable
                                ? String(localized: "Unavailable", comment: "FoodFinder photo side unavailable")
                                : String(localized: "Didn't finish", comment: "FoodFinder photo side failed")
                        )
                        .font(.caption.weight(.semibold))
                        if let message = side.message, !message.isEmpty {
                            Text(message)
                                .font(.caption2)
                                .lineLimit(4)
                        }
                    }
                }
                .foregroundStyle(colorScheme == .dark ? .white : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.primary.opacity(selected ? 0.08 : 0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 1.5)
                )
            }
            .buttonStyle(.plain)
            .disabled(side.outcome != .ready)
            .accessibilityLabel(engine.columnTitle)
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
                    mealPortionControl(result)
                        .padding(.top, 10)
                        .padding(.bottom, 12)
                }
            }
            .padding(.horizontal)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(colorScheme == .dark ? Color.bgDarkerDarkBlue.opacity(0.8) : Color.white)
            )
        }

        /// Scales the whole meal at once, so a bigger or smaller plate of the same dish is one tap.
        private func mealPortionControl(_ result: FoodAnalysisResult) -> some View {
            let multiplier = result.mealPortionMultiplier ?? 1
            let range = FoodFinderStateModel.mealPortionRange
            let step = FoodFinderStateModel.mealPortionStep
            return HStack(spacing: 10) {
                Text(String(localized: "Portion", comment: "FoodFinder whole-meal portion label"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    state.updateMealPortion(multiplier: multiplier - step)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .disabled(multiplier <= range.lowerBound)
                .accessibilityLabel(String(localized: "Smaller portion", comment: "FoodFinder whole-meal portion minus"))

                EditableMultiplierField(
                    multiplier: multiplier,
                    onCommit: { newValue in
                        state.updateMealPortion(multiplier: newValue)
                    }
                )

                Button {
                    state.updateMealPortion(multiplier: multiplier + step)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .disabled(multiplier >= range.upperBound)
                .accessibilityLabel(String(localized: "Larger portion", comment: "FoodFinder whole-meal portion plus"))
            }
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
                if result.photoComparison == nil, let engine = result.photoEngine {
                    Text(engine.localizedCaption)
                        .font(.caption)
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
            case .ah:
                return .cyan
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

        // MARK: - Saved and recent meals (start page grid)

        /// One saved meal: a FoodFinder meal kept with its photo and ingredients (often eaten, or saved from the
        /// recent meals), or a Trio meal preset. A preset with the same name as a kept meal is shown once, as that meal.
        private struct SavedMealEntry: Identifiable {
            let id: String
            let result: FoodAnalysisResult
            let isKept: Bool
            let presets: [MealPresetStored]
        }

        private var savedMealEntries: [SavedMealEntry] {
            var entries: [SavedMealEntry] = []
            var shownPresets = Set<NSManagedObjectID>()
            for result in state.frequentMeals {
                let key = MealEventIdentity.normalized(mealTitle(for: result))
                let matching = savedMealPresets.filter { preset in
                    !shownPresets.contains(preset.objectID) && MealEventIdentity.normalized(preset.dish ?? "") == key
                }
                for preset in matching {
                    shownPresets.insert(preset.objectID)
                }
                entries.append(SavedMealEntry(
                    id: "kept-" + result.id.uuidString,
                    result: result,
                    isKept: true,
                    presets: matching
                ))
            }
            for preset in savedMealPresets where !shownPresets.contains(preset.objectID) {
                entries.append(SavedMealEntry(
                    id: preset.objectID.uriRepresentation().absoluteString,
                    result: resultFromPreset(preset),
                    isKept: false,
                    presets: [preset]
                ))
            }
            return entries
        }

        private func isSavedMeal(_ result: FoodAnalysisResult) -> Bool {
            if state.frequentMeals.contains(where: { $0.id == result.id }) { return true }
            let key = MealEventIdentity.normalized(mealTitle(for: result))
            return !key.isEmpty && savedMealEntries.contains { MealEventIdentity.normalized(mealTitle(for: $0.result)) == key }
        }

        private func savedMealTile(_ entry: SavedMealEntry) -> some View {
            Button {
                state.currentResult = entry.result
            } label: {
                FoodFinderMealTile(
                    title: mealTitle(for: entry.result),
                    carbs: entry.result.totalCarbs,
                    photoID: entry.isKept ? entry.result.id : nil,
                    inlineImage: entry.result.imageData
                )
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button(role: .destructive) {
                    removeSavedMeal(entry)
                } label: {
                    Label(
                        String(localized: "Remove from saved meals", comment: "Remove a meal from the FoodFinder saved meals"),
                        systemImage: "trash"
                    )
                }
            }
        }

        private func recentMealTile(_ result: FoodAnalysisResult) -> some View {
            let saved = isSavedMeal(result)
            return Button {
                state.currentResult = result
            } label: {
                FoodFinderMealTile(
                    title: mealTitle(for: result),
                    carbs: result.totalCarbs,
                    subtitle: relativeMinutesText(from: result.timestamp),
                    photoID: result.id,
                    inlineImage: result.imageData,
                    badgeSystemImage: saved ? "bookmark.fill" : nil
                )
            }
            .buttonStyle(.plain)
            .contextMenu {
                if !saved {
                    Button {
                        saveMeal(result)
                    } label: {
                        Label(String(localized: "Save", comment: "Save as meal preset"), systemImage: "bookmark")
                    }
                }
                Button(role: .destructive) {
                    state.deleteRecentResult(result)
                } label: {
                    Label(String(localized: "Delete", comment: "Delete recent meal"), systemImage: "trash")
                }
            }
        }

        /// Keeps the meal with its photo and ingredients, and adds it to Trio's meal presets if it is not there yet.
        private func saveMeal(_ result: FoodAnalysisResult) {
            state.keepMeal(result)
            let key = MealEventIdentity.normalized(mealTitle(for: result))
            if !savedMealPresets.contains(where: { MealEventIdentity.normalized($0.dish ?? "") == key }) {
                saveRecentResultAsPreset(result)
            }
        }

        private func removeSavedMeal(_ entry: SavedMealEntry) {
            if entry.isKept {
                state.deleteFrequentMeal(entry.result)
            }
            for preset in entry.presets {
                deleteSavedMealPreset(preset)
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

        private func postMealSection(_ summary: FoodFinderPostMealSummary) -> some View {
            Section {
                postMealWindowRow(summary.zeroToTwoHours)
                postMealWindowRow(summary.twoToFourHours)
                if let fpu = summary.fpu {
                    Text(postMealFPUNote(fpu))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(String(localized: "After this meal", comment: "FoodFinder post-meal section"))
            } footer: {
                Text(postMealFooter(summary))
            }
        }

        private func postMealWindowRow(_ window: FoodFinderPostMealWindow) -> some View {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(postMealWindowTitle(window))
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(postMealHeadline(window))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(window.timeInRangePercent == nil ? Color.secondary : Color.primary)
                }
                if let detail = postMealDetail(window) {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(postMealOccurrences(window))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }

        private func postMealWindowTitle(_ window: FoodFinderPostMealWindow) -> String {
            String(
                format: String(localized: "%d–%d h", comment: "FoodFinder post-meal window, hours after the meal"),
                window.startHour,
                window.endHour
            )
        }

        private func postMealHeadline(_ window: FoodFinderPostMealWindow) -> String {
            guard let percent = window.timeInRangePercent else {
                return window.isComplete
                    ? String(localized: "No glucose", comment: "FoodFinder post-meal window with no glucose")
                    : String(localized: "Waiting", comment: "FoodFinder post-meal window still collecting glucose")
            }
            if window.isComplete {
                return String(
                    format: String(localized: "%d%% in range", comment: "FoodFinder post-meal time in range"),
                    percent
                )
            }
            return String(
                format: String(
                    localized: "%d%% in range so far",
                    comment: "FoodFinder post-meal time in range while the window is open"
                ),
                percent
            )
        }

        private func postMealDetail(_ window: FoodFinderPostMealWindow) -> String? {
            guard let below = window.timeBelowRangePercent, let above = window.timeAboveRangePercent else { return nil }
            return String(
                format: String(
                    localized: "Below range %d%% · above range %d%%",
                    comment: "FoodFinder post-meal time below and above range"
                ),
                below,
                above
            )
        }

        private func postMealOccurrences(_ window: FoodFinderPostMealWindow) -> String {
            guard window.occurrenceCount > 0 else {
                return String(localized: "n = 0", comment: "FoodFinder post-meal window without meals that have glucose")
            }
            return String(
                format: String(
                    localized: "n = %d · below range in %d · above range in %d",
                    comment: "FoodFinder post-meal meals with glucose in the window and how many went below or above range"
                ),
                window.occurrenceCount,
                window.lowOccurrenceCount,
                window.highOccurrenceCount
            )
        }

        private func postMealFPUNote(_ fpu: FoodFinderPostMealFPU) -> String {
            switch fpu {
            case let .insideFourHourWindow(until):
                return String(
                    format: String(
                        localized: "Fat and protein equivalents are logged through %@.",
                        comment: "FoodFinder Warsaw equivalents inside the 4 hour window"
                    ),
                    until.formatted(date: .omitted, time: .shortened)
                )
            case let .afterFourHourWindow(until):
                return String(
                    format: String(
                        localized: "Fat and protein equivalents continue past 4 hours, through %@.",
                        comment: "FoodFinder Warsaw equivalents past the 4 hour window"
                    ),
                    until.formatted(date: .omitted, time: .shortened)
                )
            }
        }

        private func postMealFooter(_ summary: FoodFinderPostMealSummary) -> String {
            let units = state.settingsManager.settings.units
            let low = summary.limits.lowMgdl.formatted(for: units)
            let high = summary.limits.highMgdl.formatted(for: units)
            let range = "\(low)–\(high) \(units.rawValue)"
            let basis: String
            switch summary.basis {
            case .loggedMeals:
                basis = String(
                    format: String(
                        localized: "Pooled over the latest times this meal was saved in the bolus calculator, up to %d in the last %d days, each timed from the saved meal.",
                        comment: "FoodFinder post-meal footer for saved meals: the most meals pooled, then the days looked back"
                    ),
                    FoodFinderPostMealSummary.savedMealLimit,
                    FoodFinderPostMealSummary.savedMealLookbackDays
                )
            case .analysisTime:
                basis = String(
                    localized: "Timed from this FoodFinder analysis. Once the meal is saved in the bolus calculator, it is timed from the saved meal.",
                    comment: "FoodFinder post-meal footer for a meal not logged yet"
                )
            }
            let method = String(
                format: String(
                    localized: "Share of time in range (%@), weighted by the time between readings. n is the number of meals with glucose in that window.",
                    comment: "FoodFinder post-meal footer explaining time in range and n"
                ),
                range
            )
            let disclaimer = String(
                localized: "This describes past glucose; it is not dosing advice.",
                comment: "FoodFinder post-meal footer disclaimer"
            )
            return "\(basis) \(method) \(disclaimer)"
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
            VStack(spacing: 8) {
                if isComposerExpanded {
                    composerDragHandle
                    if let result = state.currentResult {
                        expandedContextBanner(result)
                    }
                    composerActionGrid
                } else if let result = state.currentResult {
                    compactContextBanner(result)
                }

                if !state.capturedImages.isEmpty || !state.capturedBarcodeItems.isEmpty {
                    attachedDraftStrip
                }

                compactFoodInputRow
            }
            .padding(.top, 8)
            .padding(.bottom, 8)
            .background {
                UnevenRoundedRectangle(
                    topLeadingRadius: 24,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 24,
                    style: .continuous
                )
                .fill(composerBarFill)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.10), radius: 8, y: -2)
                .ignoresSafeArea(.container, edges: .bottom)
            }
            // Pad below the rounded bar, then paint the same fill through that
            // gap so the list does not flash between the bar and the keyboard.
            .padding(.bottom, isComposerDragActive ? dragFrozenKeyboardLift : keyboardLift)
            .background {
                composerBarFill
                    .ignoresSafeArea(.container, edges: .bottom)
            }
            .aiInsightsComposerKeyboardLift(isDragging: isComposerDragActive) { lift in
                keyboardLift = lift
            }
            // Offset does not change layout, and the lift is frozen for the
            // gesture, so the keyboard pad cannot chase the finger.
            .offset(y: isComposerExpanded ? composerDragOffset : 0)
            .transaction { transaction in
                if isComposerDragActive {
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
            .onChange(of: composerDragOffset) { _, offset in
                // Gesture cancellation resets GestureState without onEnded.
                // Unfreeze the keyboard lift or the bar stays stuck.
                if offset == 0 {
                    isComposerDragActive = false
                }
            }
        }

        private var composerBarFill: Color {
            colorScheme == .dark ? Color.bgDarkBlue.opacity(0.96) : Color.white.opacity(0.96)
        }

        private var compactFoodInputRow: some View {
            HStack(spacing: 8) {
                if isComposerExpanded {
                    collapseComposerButton
                } else {
                    expandComposerButton
                        .disabled(state.isAnalyzing)
                }

                TextField(
                    compactInputPlaceholder,
                    text: $state.foodDescription,
                    axis: .vertical
                )
                .lineLimit(1...(isComposerExpanded ? 6 : 1))
                .focused($isTextFieldFocused)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(minHeight: 40)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(colorScheme == .dark ? Color.bgDarkerDarkBlue : Color(.systemGray6))
                )
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
            withAnimation(.interactiveSpring(response: 0.42, dampingFraction: 0.88, blendDuration: 0.08)) {
                isComposerExpanded = true
            }
            if keepKeyboard {
                isTextFieldFocused = true
            }
        }

        private func collapseComposer(keepKeyboard: Bool) {
            withAnimation(.interactiveSpring(response: 0.42, dampingFraction: 0.9, blendDuration: 0.08)) {
                isComposerExpanded = false
            }
            isTextFieldFocused = keepKeyboard
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
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .updating($composerDragOffset) { value, state, transaction in
                    // GestureState otherwise springs every sample and fights
                    // the keyboard pad. The finger owns this offset.
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                    state = max(0, value.translation.height)
                }
                .onChanged { _ in
                    guard !isComposerDragActive else { return }
                    dragFrozenKeyboardLift = keyboardLift
                    isComposerDragActive = true
                }
                .onEnded { value in
                    isComposerDragActive = false
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

        private var collapseComposerButton: some View {
            Button {
                collapseComposer(keepKeyboard: true)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 42, height: 42)
                    .background(
                        Circle()
                            .fill(colorScheme == .dark ? Color.bgDarkerDarkBlue : Color(.systemGray5))
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(colorScheme == .dark ? .white : .primary)
            .accessibilityLabel(String(localized: "Close FoodFinder tools", comment: "Collapse FoodFinder tools button"))
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
                        }
                    }
                    .frame(width: 48, height: 48)
                    .glassMaterialFill(Circle())
                    .overlay(
                        Circle().fill((tint ?? Color.accentColor).opacity(colorScheme == .dark ? 0.22 : 0.12))
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
            !state.capturedImages.isEmpty
                || !state.capturedBarcodeItems.isEmpty
                || !state.foodDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        /// Horizontal strip of attached photos and scanned barcode products.
        /// Each thumb has its own delete affordance so the user can swap one
        /// without clearing the rest. Barcode chips stay as draft attachments
        /// until the user confirms the meal.
        @ViewBuilder
        private var attachedDraftStrip: some View {
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

                    ForEach(state.capturedBarcodeItems) { item in
                        ZStack(alignment: .topTrailing) {
                            VStack(spacing: 2) {
                                Image(systemName: "barcode")
                                    .font(.system(size: 16, weight: .semibold))
                                Text(item.name)
                                    .font(.caption2.weight(.semibold))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                            }
                            .foregroundStyle(colorScheme == .dark ? Color.white : Color.primary)
                            .padding(6)
                            .frame(width: 72, height: 56)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(colorScheme == .dark ? Color.bgDarkerDarkBlue : Color(.systemGray6))
                            )

                            Button {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    state.removeCapturedBarcodeItem(id: item.id)
                                }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 16))
                                    .foregroundStyle(.white, Color.black.opacity(0.7))
                                    .padding(2)
                            }
                        }
                    }

                    if state.capturedImages.count < state.maxFoodFinderImages, !state.capturedImages.isEmpty {
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
    @State private var weight: String
    // Feature B: an explicit unit + amount replace the old free-text portion /
    // weight fields. The macros the user types are the macros for exactly this
    // amount of this unit (the item's nutrition basis), so scaling is unambiguous.
    @State private var basisUnitSelection: AIInsights.MeasurementUnit
    @State private var amount: String
    @State private var carbs: String
    @State private var fat: String
    @State private var protein: String
    @State private var fiber: String
    @State private var calories: String

    init(item: AIInsights.FoodItem, onSave: @escaping (AIInsights.FoodItem) -> Void) {
        self.item = item
        self.onSave = onSave
        _name = State(initialValue: item.name)
        // Retained (hidden) so composedPortion/legacy helpers still resolve; the
        // visible editor now uses the unit picker + amount field below.
        _portion = State(initialValue: Self.portionLabel(item.portion))
        if let grams = Self.grams(from: item.portion) {
            _weight = State(initialValue: Self.format(grams * item.portionMultiplier))
        } else {
            _weight = State(initialValue: "")
        }

        // Seed the unit picker from the item's stored basis when it has one,
        // else infer grams from an embedded weight token, else default to grams.
        let seededUnit: AIInsights.MeasurementUnit = {
            if item.basisUnit.isScalable { return item.basisUnit }
            if Self.grams(from: item.portion) != nil { return .gram }
            return .gram
        }()
        _basisUnitSelection = State(initialValue: seededUnit)

        // Seed the amount as the CURRENT amount in that unit: for a scalable
        // basis that is basisAmount × the current multiplier; otherwise fall
        // back to any embedded grams (× multiplier); otherwise blank.
        let seededAmount: Double? = {
            if item.basisUnit.isScalable, item.basisAmount > 0 {
                return item.basisAmount * item.portionMultiplier
            }
            if let grams = Self.grams(from: item.portion) {
                return grams * item.portionMultiplier
            }
            return nil
        }()
        _amount = State(initialValue: seededAmount.map { Self.format($0) } ?? "")

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
                    Picker(
                        String(localized: "Unit", comment: "Food item measurement unit picker"),
                        selection: $basisUnitSelection
                    ) {
                        ForEach(AIInsights.MeasurementUnit.selectable) { unit in
                            Text(unit.localizedTitle).tag(unit)
                        }
                    }
                    HStack {
                        Text(String(localized: "Amount", comment: "Food item amount field"))
                        Spacer()
                        TextField("", text: $amount)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        Text(basisUnitSelection.abbreviation)
                            .foregroundColor(.secondary)
                    }
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
                    Text(String(localized: "The macros you enter are for the amount + unit above; the + / − stepper and amount field scale from there.", comment: "FoodFinder edit ingredient footer"))
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
        // Feature B: the macro fields are the macros for exactly `amount` of the
        // chosen `basisUnitSelection`. Bake that in as the nutrition basis with a
        // 1× multiplier, so the amount field and the +/- stepper scale linearly
        // and unambiguously from here (multiplier = newAmount / basisAmount).
        let enteredAmount = max(0, decimalValue(amount))
        // Only a positive amount yields a usable scalable basis; a blank/zero
        // amount stays `.unknown` so the amount field can't later divide by zero
        // or silently inflate carbs.
        let basisUnit: AIInsights.MeasurementUnit = enteredAmount > 0 ? basisUnitSelection : .unknown
        let portionText: String = enteredAmount > 0
            ? "\(Self.format(enteredAmount)) \(basisUnitSelection.abbreviation)"
            : composedPortion(label: portion, grams: decimalValue(weight))
        return AIInsights.FoodItem(
            id: item.id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            portion: portionText,
            carbs: max(0, decimalValue(carbs)),
            fat: max(0, decimalValue(fat)),
            protein: max(0, decimalValue(protein)),
            fiber: max(0, decimalValue(fiber)),
            calories: max(0, decimalValue(calories)),
            portionMultiplier: 1.0,
            source: item.source,
            sourceURL: item.sourceURL,
            sourceVerified: item.sourceVerified,
            sourceName: item.sourceName,
            sourceBrand: item.sourceBrand,
            sourceImageURL: item.sourceImageURL,
            sourceScore: item.sourceScore,
            alternateMatches: item.alternateMatches,
            barcode: item.barcode,
            basisUnit: basisUnit,
            basisAmount: enteredAmount
        )
    }

    /// Combine the human label and an explicit weight into a single portion
    /// string the rest of the app can re-parse, e.g. "2 slices (40 g)". When no
    /// weight is given we keep the label as-is; when the label is empty we fall
    /// back to just the weight ("40 g").
    private func composedPortion(label: String, grams: Double) -> String {
        let cleanLabel = Self.portionLabel(label.trimmingCharacters(in: .whitespacesAndNewlines))
        guard grams > 0 else {
            return cleanLabel.aiInsightsNilIfEmpty
                ?? label.trimmingCharacters(in: .whitespacesAndNewlines).aiInsightsNilIfEmpty
                ?? item.portion
        }
        let gramText = String(format: "%.0f g", grams)
        guard let base = cleanLabel.aiInsightsNilIfEmpty else { return gramText }
        return "\(base) (\(gramText))"
    }

    /// First gram/ml value embedded in a portion string, if any.
    private static func grams(from portion: String) -> Double? {
        let pattern = #"(\d+(?:[.,]\d+)?)\s*(?:g|gram|grams|ml|milliliter|milliliters)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(portion.startIndex ..< portion.endIndex, in: portion)
        guard let match = regex.firstMatch(in: portion, options: [], range: range),
              let valueRange = Range(match.range(at: 1), in: portion)
        else { return nil }
        return Double(String(portion[valueRange]).replacingOccurrences(of: ",", with: "."))
    }

    /// Strip any embedded weight token (and a wrapping "(...)") from a portion so
    /// only the descriptive label remains, e.g. "2 slices (90 g)" -> "2 slices".
    private static func portionLabel(_ portion: String) -> String {
        let pattern = #"\s*\(?\s*\d+(?:[.,]\d+)?\s*(?:g|gram|grams|ml|milliliter|milliliters)\b\s*\)?"#
        let stripped: String
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            let range = NSRange(portion.startIndex ..< portion.endIndex, in: portion)
            stripped = regex.stringByReplacingMatches(in: portion, options: [], range: range, withTemplate: "")
        } else {
            stripped = portion
        }
        return stripped
            .trimmingCharacters(in: CharacterSet(charactersIn: " ()-–,"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
