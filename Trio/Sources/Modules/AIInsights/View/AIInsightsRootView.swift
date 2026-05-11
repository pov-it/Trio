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
                Section(header: Text("Google Gemini Configuration")) {
                    SecureField("API Key", text: $state.apiKey)
                        .onChange(of: state.apiKey) { _ in
                            state.saveAPIKey()
                        }
                    TextField("Model", text: $state.model)
                    Text("Using Google Gemini for AI Insights. Make sure your API key has access to the specified model.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Section(header: Text("Manual Context (zGluco)")) {
                    TextEditor(text: $state.zglucoData)
                        .frame(height: 100)
                    Text("Additional text data from zGluco reports can be pasted here to provide more context to the AI.")
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
                    }
                }
            }
            .navigationTitle("AI Insights")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
