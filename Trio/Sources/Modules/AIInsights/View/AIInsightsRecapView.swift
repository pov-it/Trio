//
//  AIInsightsRecapView.swift
//  Trio
//
//  Displays the periodic-recap history and lets the user manually generate one.
//

import SwiftUI
import Swinject

extension AIInsights {
    struct RecapView: BaseView {
        let resolver: Resolver
        @State var state = RecapStateModel()

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        var body: some View {
            List {
                if state.entries.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(String(localized: "No recaps yet", comment: "Recap empty state title"))
                                .font(.headline)
                            Text(String(localized: "Trio generates an observations-only recap weekly when therapy changed, and monthly otherwise.", comment: "Recap empty state description"))
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 8)
                        .listRowBackground(Color.clear)
                    }
                } else {
                    ForEach(state.entries) { entry in
                        Section(header: Text(entry.title)) {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    Image(systemName: entry.cadence == .weekly ? "calendar.badge.clock" : "calendar")
                                        .foregroundStyle(.tint)
                                    Text(
                                        entry.cadence == .weekly
                                            ? String(localized: "Weekly", comment: "Recap cadence label")
                                            : String(localized: "Monthly", comment: "Recap cadence label")
                                    )
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    if entry.appliedSuggestionCount > 0 {
                                        Text(String(format: String(localized: "%d applied changes", comment: "Recap applied changes count"), entry.appliedSuggestionCount))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Text(entry.body)
                                    .font(.subheadline)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "Recap", comment: "Periodic recap navigation title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await state.generateNow() }
                    } label: {
                        if state.isGenerating {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise.circle")
                        }
                    }
                    .disabled(state.isGenerating)
                }
            }
            .onAppear(perform: configureView)
            .task {
                // Auto-generate when the user opens the recap screen and one
                // is due. Silent if it fails — the manual button still works.
                await state.generateIfDue()
            }
            .alert(
                String(localized: "Recap error", comment: "Recap generation error title"),
                isPresented: Binding(
                    get: { state.errorMessage != nil },
                    set: { if !$0 { state.errorMessage = nil } }
                )
            ) {
                Button(String(localized: "OK", comment: "OK button")) { state.errorMessage = nil }
            } message: {
                Text(state.errorMessage ?? "")
            }
        }
    }

    @Observable final class RecapStateModel: BaseStateModel<Provider> {
        var entries: [RecapEntry] = []
        var isGenerating: Bool = false
        var errorMessage: String?

        private var apiKey: String = ""
        private var providerType: AIProvider = .google
        private var baseURL: String = AIProvider.google.defaultEndpoint
        private var model: String = AIProvider.google.defaultModel

        override func subscribe() {
            apiKey = provider.keychain.getValue(String.self, forKey: "ai_insights_api_key") ?? ""
            providerType = provider.settings.aiProvider
            baseURL = provider.settings.aiBaseURL
            model = provider.settings.aiModel
            entries = PeriodicRecapService.shared.loadHistory()
        }

        @MainActor
        func generateNow() async {
            guard !apiKey.isEmpty else {
                errorMessage = String(localized: "API Key is missing. Configure it in AI Settings.", comment: "AI error")
                return
            }
            isGenerating = true
            defer { isGenerating = false }

            let conversations = loadConversations()
            let config = PeriodicRecapService.GenerationConfig(
                provider: providerType,
                apiKey: apiKey,
                baseURL: baseURL,
                model: model
            )
            // Always allow manual generation — cadence depends on whether we have
            // recent applied changes (weekly) or not (monthly).
            let cadence: RecapEntry.Cadence = PeriodicRecapService.shared.dueCadence() ?? .monthly
            do {
                _ = try await PeriodicRecapService.shared.forceGenerate(
                    config: config,
                    cadence: cadence,
                    conversations: conversations
                )
                entries = PeriodicRecapService.shared.loadHistory()
            } catch let error as AIServiceAdapter.AIError {
                errorMessage = error.errorDescription ?? error.localizedDescription
            } catch {
                errorMessage = String(localized: "Error: \(error.localizedDescription)", comment: "AI error")
            }
        }

        @MainActor
        func generateIfDue() async {
            guard !apiKey.isEmpty,
                  PeriodicRecapService.shared.dueCadence() != nil
            else { return }
            isGenerating = true
            defer { isGenerating = false }

            let conversations = loadConversations()
            let config = PeriodicRecapService.GenerationConfig(
                provider: providerType,
                apiKey: apiKey,
                baseURL: baseURL,
                model: model
            )
            do {
                if try await PeriodicRecapService.shared.generateRecapIfDue(
                    config: config,
                    conversations: conversations
                ) != nil {
                    entries = PeriodicRecapService.shared.loadHistory()
                }
            } catch {
                // Silent for the auto-generation path; the user can re-trigger
                // manually from the recap view if they want to see the error.
            }
        }

        private func loadConversations() -> [ChatConversation] {
            guard let data = UserDefaults.standard.data(forKey: "ai_insights_conversations"),
                  let saved = try? JSONDecoder().decode([ChatConversation].self, from: data)
            else { return [] }
            return saved
        }
    }
}
