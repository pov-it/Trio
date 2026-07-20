import SwiftUI
import Swinject
import UIKit

extension AIInsights {
    struct RootView: BaseView {
        let resolver: Resolver
        @State var state = StateModel()

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        var body: some View {
            NavigationStack {
                List {
                    // MARK: - Quick Access to Chat
                    Section(
                        header: Text("AI Insights", comment: "AI Insights section header"),
                        footer: Text("Chat with AI about your glucose data, patterns, and therapy settings.", comment: "AI Insights footer")
                    ) {
                        NavigationLink {
                            ChatView(resolver: resolver)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "bubble.left.and.bubble.right.fill")
                                    .font(.title2)
                                    .foregroundStyle(
                                        LinearGradient(
                                            colors: [
                                                Color(red: 0.7215686275, green: 0.3411764706, blue: 1),
                                                Color(red: 0.262745098, green: 0.7333333333, blue: 0.9137254902)
                                            ],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                VStack(alignment: .leading) {
                                    Text("AI Chat", comment: "Chat navigation label")
                                        .font(.headline)
                                    Text("Ask about your data and settings", comment: "Chat subtitle")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                        NavigationLink {
                            AISettingsView(resolver: resolver)
                        } label: {
                            Label(String(localized: "AI Settings", comment: "Settings navigation label"), systemImage: "gearshape")
                        }
                    }
                    .listRowBackground(Color.chart)

                    // MARK: - Legacy Generate Section
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
                                    Text(String(localized: "Analyzing Data...", comment: "AI legacy analyze in-progress label"))
                                }
                            } else {
                                Text(String(localized: "Generate AI Insights (Legacy)", comment: "AI legacy generate button"))
                            }
                        }
                        .disabled(state.isGenerating || state.apiKey.isEmpty)
                    }
                    .listRowBackground(Color.chart)

                    if !state.insightsResult.isEmpty {
                        Section(header: Text(String(localized: "Results", comment: "AI legacy results section header"))) {
                            ScrollView {
                                Text(state.insightsResult)
                                    .font(.system(.body, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(minHeight: 200)

                            Button(action: {
                                UIPasteboard.general.string = state.insightsResult
                            }) {
                                Label(String(localized: "Copy to Clipboard", comment: "Copy legacy AI result"), systemImage: "doc.on.doc")
                            }
                            .font(.caption)
                        }
                        .listRowBackground(Color.chart)
                    }
                }
                .scrollContentBackground(.hidden)
                .background(appState.trioBackgroundColor(for: colorScheme))
                .navigationTitle(String(localized: "AI Insights", comment: "AI Insights nav title"))
                .navigationBarTitleDisplayMode(.inline)
            }
            .onAppear(perform: configureView)
        }
    }
}
