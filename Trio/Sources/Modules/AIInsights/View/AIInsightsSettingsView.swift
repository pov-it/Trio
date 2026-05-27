import SwiftUI
import Swinject

extension AIInsights {
    struct AISettingsView: BaseView {
        let resolver: Resolver
        @State var state = StateModel()

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState
        @State private var isEditingSystemPromptFullscreen = false

        var body: some View {
            Form {
                // MARK: - Feature Toggle
                Section(
                    header: Text("AI Insights", comment: "AI settings section header"),
                    footer: Text("When enabled, you can chat with AI about your glucose data and therapy settings.", comment: "AI settings footer")
                ) {
                    Toggle(isOn: $state.aiEnabled) {
                        Label(String(localized: "Enable AI Insights", comment: "Toggle label"), systemImage: "brain")
                    }
                    .onChange(of: state.aiEnabled) {
                        state.saveSettings()
                    }
                }
                .listRowBackground(Color.chart)

                // MARK: - Provider Configuration
                Section(
                    header: Text("AI Provider", comment: "AI provider section header"),
                    footer: Text("Choose your AI provider and enter your own API key. Your key is stored securely in the iOS Keychain.", comment: "AI provider footer")
                ) {
                    Picker(String(localized: "Provider", comment: "Provider picker label"), selection: $state.providerType) {
                        ForEach(AIProvider.allCases) { provider in
                            Text(provider.rawValue).tag(provider)
                        }
                    }
                    .onChange(of: state.providerType) {
                        state.resetToDefaults()
                    }

                    SecureField(String(localized: "API Key", comment: "API key field placeholder"), text: $state.apiKey)
                        .onChange(of: state.apiKey) {
                            state.saveAPIKey()
                        }

                    TextField(String(localized: "Model", comment: "Model field placeholder"), text: $state.model)
                        .onChange(of: state.model) {
                            state.saveSettings()
                        }

                    TextField(String(localized: "Endpoint URL", comment: "URL field placeholder"), text: $state.baseURL, axis: .vertical)
                        .lineLimit(1...5)
                        .onChange(of: state.baseURL) {
                            state.saveSettings()
                        }
                        .font(.system(.caption, design: .monospaced))
                        .autocorrectionDisabled()
                        .autocapitalization(.none)

                    Button(String(localized: "Reset to Defaults", comment: "Reset button label")) {
                        state.resetToDefaults()
                    }
                    .font(.caption)

                    Button {
                        Task {
                            await testConnection()
                        }
                    } label: {
                        HStack {
                            if isTestingConnection {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle())
                            }
                            Text("Test Connection", comment: "Test connection button")
                        }
                    }
                    .disabled(state.apiKey.isEmpty || isTestingConnection)
                }
                .listRowBackground(Color.chart)

                // MARK: - Dictation
                Section(
                    header: Text("Dictation", comment: "AI dictation settings section header"),
                    footer: Text("When enabled, FoodFinder records your voice and asks the selected AI provider to transcribe it. If the provider cannot transcribe or the request fails, Trio falls back to Apple Speech dictation.", comment: "AI dictation settings footer")
                ) {
                    Toggle(isOn: $state.aiDictationEnabled) {
                        Label(String(localized: "Use AI provider for dictation", comment: "AI dictation provider toggle"), systemImage: "waveform")
                    }
                    .onChange(of: state.aiDictationEnabled) {
                        state.saveSettings()
                    }

                    if state.aiDictationEnabled {
                        Toggle(isOn: $state.aiDictationUsesSeparateProvider) {
                            Label(String(localized: "Use a different dictation provider", comment: "Separate dictation provider toggle"), systemImage: "arrow.triangle.branch")
                        }
                        .onChange(of: state.aiDictationUsesSeparateProvider) {
                            state.resetDictationDefaults()
                        }

                        if state.aiDictationUsesSeparateProvider {
                            Picker(String(localized: "Dictation Provider", comment: "Dictation provider picker label"), selection: $state.aiDictationProviderType) {
                                ForEach(AIProvider.allCases) { provider in
                                    Text(provider.rawValue).tag(provider)
                                }
                            }
                            .onChange(of: state.aiDictationProviderType) {
                                state.resetDictationDefaults()
                            }

                            TextField(
                                String(localized: "Dictation Endpoint URL", comment: "Dictation endpoint URL placeholder"),
                                text: $state.aiDictationBaseURL,
                                axis: .vertical
                            )
                            .lineLimit(1...5)
                            .onChange(of: state.aiDictationBaseURL) {
                                state.saveSettings()
                            }
                            .font(.system(.caption, design: .monospaced))
                            .autocorrectionDisabled()
                            .autocapitalization(.none)

                            SecureField(String(localized: "Dictation API Key", comment: "Dictation API key field placeholder"), text: $state.aiDictationAPIKey)
                                .onChange(of: state.aiDictationAPIKey) {
                                    state.saveDictationAPIKey()
                                }
                        }

                        TextField(String(localized: "Dictation Model", comment: "Dictation model placeholder"), text: $state.aiDictationModel)
                            .onChange(of: state.aiDictationModel) {
                                state.saveSettings()
                            }
                            .autocorrectionDisabled()
                            .autocapitalization(.none)

                        Button(String(localized: "Reset Dictation Defaults", comment: "Reset dictation defaults button")) {
                            state.resetDictationDefaults()
                        }
                        .font(.caption)
                    }
                }
                .listRowBackground(Color.chart)

                // MARK: - Analysis Settings
                Section(
                    header: Text("Analysis", comment: "Analysis section header")
                ) {
                    Picker(String(localized: "Analysis Period", comment: "Period picker label"), selection: $state.analysisPeriodDays) {
                        Text("3 days", comment: "3 day period").tag(3)
                        Text("7 days", comment: "7 day period").tag(7)
                        Text("14 days", comment: "14 day period").tag(14)
                        Text("30 days", comment: "30 day period").tag(30)
                        Text("90 days", comment: "90 day period").tag(90)
                    }
                    .onChange(of: state.analysisPeriodDays) {
                        state.saveSettings()
                    }

                    Picker(String(localized: "AI Personality", comment: "Personality picker label"), selection: $state.personality) {
                        ForEach(AIPersonality.allCases) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    .onChange(of: state.personality) {
                        state.saveSettings()
                    }
                }
                .listRowBackground(Color.chart)

                // MARK: - Apple Health
                Section(
                    header: Text(String(localized: "Apple Health", comment: "Apple Health section header")),
                    footer: Text(String(localized: "Trio reads from Apple Health (no writes). Enabling a source triggers iOS's Health permission prompt the first time. The tracker pages merge HealthKit-sourced entries (heart icon) with manual entries.", comment: "Apple Health section footer"))
                ) {
                    Toggle(isOn: $state.healthKitCaffeineEnabled) {
                        Label(String(localized: "Sync dietary caffeine", comment: "Caffeine HealthKit toggle"), systemImage: "cup.and.saucer.fill")
                    }
                    .onChange(of: state.healthKitCaffeineEnabled) {
                        state.saveSettings()
                        if state.healthKitCaffeineEnabled {
                            Task {
                                try? await AIInsightsCaffeineHealthKitBridge.shared.requestAuthorization()
                                await AIInsights_CaffeineTracker.shared.syncFromHealthKit()
                            }
                        }
                    }

                    Toggle(isOn: $state.healthKitAlcoholEnabled) {
                        Label(String(localized: "Sync alcoholic beverages", comment: "Alcohol HealthKit toggle"), systemImage: "wineglass.fill")
                    }
                    .onChange(of: state.healthKitAlcoholEnabled) {
                        state.saveSettings()
                        if state.healthKitAlcoholEnabled {
                            Task {
                                try? await AIInsightsAlcoholHealthKitBridge.shared.requestAuthorization()
                                await AIInsights_AlcoholTracker.shared.syncFromHealthKit()
                            }
                        }
                    }
                }
                .listRowBackground(Color.chart)

                // MARK: - Location Context
                Section(
                    header: Text("Location Context", comment: "Location context section header"),
                    footer: Text("When on, Trio reverse-geocodes your current location (venue + city + country) and adds it to the AI prompt for richer answers. iOS will ask for Location permission on first use. Coordinates stay on-device.", comment: "Location context footer")
                ) {
                    Toggle(isOn: $state.locationContextEnabled) {
                        Label(String(localized: "Inject venue + locality into AI prompt", comment: "Location context toggle"), systemImage: "location")
                    }
                    .onChange(of: state.locationContextEnabled) {
                        state.saveSettings()
                        if state.locationContextEnabled {
                            AIInsights_LocationService.shared.requestLocationIfEnabled()
                        } else {
                            AIInsights_LocationService.shared.clearLocation()
                        }
                    }
                }
                .listRowBackground(Color.chart)

                // MARK: - FoodFinder
                Section(
                    header: Text("FoodFinder", comment: "FoodFinder AI settings section header"),
                    footer: Text("Use the lookup agent during testing to let FoodFinder ground ingredients against configured food databases before falling back to AI estimates.", comment: "FoodFinder agent settings footer")
                ) {
                    Picker(String(localized: "Search method", comment: "FoodFinder lookup mode picker"), selection: $state.foodFinderLookupMode) {
                        ForEach(FoodFinderLookupMode.allCases) { mode in
                            Text(mode.localizedTitle).tag(mode)
                        }
                    }
                    .onChange(of: state.foodFinderLookupMode) {
                        state.saveSettings()
                    }

                    Picker(String(localized: "Preferred source", comment: "FoodFinder preferred source picker"), selection: $state.foodFinderPreferredSource) {
                        ForEach([FoodSourceID.openFoodFacts, FoodSourceID.usda, FoodSourceID.aiEstimate]) { source in
                            Text(source.localizedTitle).tag(source)
                        }
                    }
                    .onChange(of: state.foodFinderPreferredSource) {
                        state.saveSettings()
                    }
                    .disabled(state.foodFinderLookupMode == .aiEstimateOnly)
                }
                .listRowBackground(Color.chart)

                Section(
                    header: Text("FoodFinder Providers", comment: "FoodFinder providers settings section header"),
                    footer: Text("OpenFoodFacts needs no key. USDA FoodData Central can improve fresh ingredient matches when you add your own API key.", comment: "FoodFinder providers settings footer")
                ) {
                    Toggle(isOn: $state.foodFinderOpenFoodFactsEnabled) {
                        Label(String(localized: "OpenFoodFacts", comment: "OpenFoodFacts provider toggle"), systemImage: "checkmark.seal")
                    }
                    .onChange(of: state.foodFinderOpenFoodFactsEnabled) {
                        state.saveSettings()
                    }

                    TextField(
                        String(localized: "OpenFoodFacts API URL", comment: "OpenFoodFacts API URL field"),
                        text: $state.openFoodFactsBaseURL,
                        axis: .vertical
                    )
                    .lineLimit(1...3)
                    .onChange(of: state.openFoodFactsBaseURL) {
                        state.saveSettings()
                    }
                    .font(.system(.caption, design: .monospaced))
                    .autocorrectionDisabled()
                    .autocapitalization(.none)

                    Button(String(localized: "Reset OpenFoodFacts URL", comment: "Reset OpenFoodFacts URL button")) {
                        state.resetOpenFoodFactsURL()
                    }
                    .font(.caption)

                    Toggle(isOn: $state.foodFinderUSDAEnabled) {
                        Label(String(localized: "USDA FoodData Central", comment: "USDA provider toggle"), systemImage: "building.columns")
                    }
                    .onChange(of: state.foodFinderUSDAEnabled) {
                        state.saveSettings()
                    }

                    if state.foodFinderUSDAEnabled {
                        SecureField(String(localized: "USDA API Key", comment: "USDA API key field placeholder"), text: $state.foodFinderUSDAAPIKey)
                            .onChange(of: state.foodFinderUSDAAPIKey) {
                                state.saveFoodFinderUSDAAPIKey()
                            }
                    }
                }
                .listRowBackground(Color.chart)

                // MARK: - System Prompt
                Section(
                    header: HStack {
                        Text("System Prompt", comment: "System prompt section header")
                        Spacer()
                        Button {
                            isEditingSystemPromptFullscreen = true
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(String(localized: "Edit system prompt fullscreen", comment: "System prompt fullscreen button accessibility label"))
                    },
                    footer: Text("The instructions given to the AI. Customize the analysis style and focus.", comment: "System prompt footer")
                ) {
                    TextEditor(text: $state.systemPrompt)
                        .frame(height: 150)
                        .font(.system(.body, design: .monospaced))
                        .onChange(of: state.systemPrompt) {
                            state.saveSettings()
                        }
                }
                .listRowBackground(Color.chart)
            }
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .navigationTitle(String(localized: "AI Settings", comment: "AI settings nav title"))
            .navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(isPresented: $isEditingSystemPromptFullscreen) {
                SystemPromptEditorSheet(systemPrompt: $state.systemPrompt) {
                    state.saveSettings()
                }
            }
            .alert(
                String(localized: "Connection Test", comment: "Test alert title"),
                isPresented: $showTestResult
            ) {
                Button(String(localized: "OK", comment: "OK alert button")) {}
            } message: {
                if let errorMsg = testErrorMessage {
                    Text(String(localized: "Connection failed:\n", comment: "Test failure prefix") + errorMsg)
                } else {
                    Text("Connection successful!", comment: "Test success")
                }
            }
            .onAppear(perform: configureView)
        }

        // MARK: - Test Connection State

        @State private var isTestingConnection = false
        @State private var showTestResult = false
        @State private var testErrorMessage: String?

        private func testConnection() async {
            isTestingConnection = true
            defer { isTestingConnection = false }

            do {
                let success = try await AIServiceAdapter.testConnection(
                    provider: state.providerType,
                    model: state.model,
                    baseURL: state.baseURL,
                    apiKey: state.apiKey
                )
                testErrorMessage = success ? nil : String(localized: "Unknown error occurred.")
            } catch let error as AIServiceAdapter.AIError {
                testErrorMessage = error.errorDescription ?? error.localizedDescription
            } catch {
                testErrorMessage = error.localizedDescription
            }
            showTestResult = true
        }
    }
}

private struct SystemPromptEditorSheet: View {
    @Binding var systemPrompt: String
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            TextEditor(text: $systemPrompt)
                .font(.system(.body, design: .monospaced))
                .padding()
                .scrollContentBackground(.hidden)
                .background(Color(.systemGroupedBackground))
                .focused($isFocused)
                .navigationTitle(String(localized: "System Prompt", comment: "System prompt editor title"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Close", comment: "Close button")) {
                            onSave()
                            dismiss()
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Done", comment: "Done button")) {
                            onSave()
                            dismiss()
                        }
                        .bold()
                    }
                }
                .onAppear {
                    isFocused = true
                }
                .onChange(of: systemPrompt) {
                    onSave()
                }
        }
    }
}
