import SwiftUI
import Swinject
import UIKit

extension AIInsights {
    struct RootView: BaseView {
        let resolver: Resolver
        @State var state = StateModel()

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
                        .onChange(of: state.model) { _ in
                            state.saveSettings()
                        }
                    TextField("Base URL", text: $state.baseURL)
                        .onChange(of: state.baseURL) { _ in
                            state.saveSettings()
                        }
                    
                    Button("Reset to Defaults") {
                        state.resetToDefaults()
                    }
                    .font(.caption)
                }
                
                Section(header: Text("System Prompt")) {
                    TextEditor(text: $state.systemPrompt)
                        .frame(height: 150)
                        .font(.system(.body, design: .monospaced))
                        .onChange(of: state.systemPrompt) { _ in
                            state.saveSettings()
                        }
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
            .onAppear(perform: configureView)
            .navigationTitle("AI Insights")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
