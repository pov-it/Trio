import SwiftUI
import Swinject

extension AIInsights {
    struct AISettingsView: BaseView {
        let resolver: Resolver
        @State var state = StateModel()

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

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

                // MARK: - System Prompt
                Section(
                    header: Text("System Prompt", comment: "System prompt section header"),
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
            .alert(
                String(localized: "Connection Test", comment: "Test alert title"),
                isPresented: $showTestResult,
                presenting: testErrorMessage
            ) { _ in
                Button("OK") {}
            } message: { errorMsg in
                if let errorMsg = errorMsg {
                    Text(String(localized: "Connection failed:\n", comment: "Test failure prefix") + errorMsg)
                } else {
                    Text("Connection successful! ✅", comment: "Test success")
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
