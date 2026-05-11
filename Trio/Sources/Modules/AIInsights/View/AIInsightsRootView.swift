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
                Section(header: Text("Configuration")) {
                    SecureField("API Key", text: $state.apiKey)
                    TextField("Base URL", text: $state.baseURL)
                    TextField("Model", text: $state.model)
                }
                
                Section(header: Text("zGluco Data")) {
                    TextEditor(text: $state.zglucoData)
                        .frame(height: 100)
                }
                
                Section {
                    Button(action: {
                        Task {
                            await state.generateInsights()
                        }
                    }) {
                        if state.isGenerating {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                        } else {
                            Text("Generate Insights")
                        }
                    }
                    .disabled(state.isGenerating || state.apiKey.isEmpty)
                }
                
                if !state.insightsResult.isEmpty {
                    Section(header: Text("AI Insights")) {
                        Text(state.insightsResult)
                            .font(.body)
                    }
                }
            }
            .navigationTitle("AI Insights")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
