import SwiftUI
import Swinject

extension AIInsights {
    struct RootView: BaseView {
        let resolver: Resolver
        @State var state: StateModel

        init(resolver: Resolver) {
            self.resolver = resolver
            _state = State(initialValue: StateModel(resolver: resolver))
        }

        var body: some View {
            Form {
                Section(header: Text("AI Provider Configuration")) {
                    Picker("Provider", selection: $state.providerType) {
                        ForEach(AIProvider.allCases) { provider in
                            Text(provider.rawValue).tag(provider)
                        }
                    }
                    .onChange(of: state.providerType) { _ in
                        state.resetToDefaults()
                    }
                    
                    SecureField("API Key", text: $state.apiKey)
                        .onChange(of: state.apiKey) { _ in
                            state.saveAPIKey()
                        }
                    
                    TextField("Model", text: $state.model)
                    TextField("Base URL", text: $state.baseURL)
                    
                    Button("Reset to Defaults") {
                        state.resetToDefaults()
                    }
                    .font(.caption)
                }
                
                Section(header: Text("System Prompt")) {
                    TextEditor(text: $state.systemPrompt)
                        .frame(height: 150)
                        .font(.system(.body, design: .monospaced))
                    Text("The instructions given to the AI. Use this to customize the analysis style and focus.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Section {
                    Button(action: {
                        Task {
                            await state.generateInsights()
                        }
                    }) {
                        if state.isGenerating {
                            HStack {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle())
                                    .padding(.trailing, 5)
                                Text("Analyzing Data...")
                            }
                        } else {
                            Text("Generate AI Insights")
                        }
                    }
                    .disabled(state.isGenerating || state.apiKey.isEmpty)
                }
                
                if !state.insightsResult.isEmpty {
                    Section(header: Text("Results")) {
                        ScrollView {
                            Text(state.insightsResult)
                                .font(.system(.body, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minHeight: 200)
                        
                        Button(action: {
                            UIPasteboard.general.string = state.insightsResult
                        }) {
                            Label("Copy to Clipboard", systemImage: "doc.on.doc")
                        }
                        .font(.caption)
                    }
                }
            }
            .navigationTitle("AI Insights")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
