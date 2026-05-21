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
            ScrollView {
                LazyVStack(spacing: 16) {
                    if state.entries.isEmpty {
                        emptyStateCard
                            .padding(.top, 16)
                    } else {
                        ForEach(state.entries) { entry in
                            recapCard(entry)
                        }
                    }
                    upcomingScheduleHint
                        .padding(.top, 4)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(appState.trioBackgroundColor(for: colorScheme))
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

        // MARK: - Cards

        private var emptyStateCard: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.title2)
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
                    Text(String(localized: "No recap yet", comment: "Recap empty state title"))
                        .font(.headline)
                    Spacer()
                }
                Text(String(
                    localized: "Trio writes a short textual analysis of the past 30 days here. It includes any therapy settings you changed, recurring patterns from your chats, and behavioral signals from caffeine, alcohol, meals, and AutoPresets activations.",
                    comment: "Recap empty state long description"
                ))
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Text(String(
                    localized: "Recaps run weekly when therapy changed in the last 7 days, and monthly otherwise. Tap the refresh button above to generate one now.",
                    comment: "Recap cadence explanation"
                ))
                .font(.footnote)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(colorScheme == .dark ? Color.bgDarkerDarkBlue.opacity(0.8) : Color.white)
            )
        }

        private func recapCard(_ entry: RecapEntry) -> some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: entry.cadence == .weekly ? "calendar.badge.clock" : "calendar")
                        .font(.title3)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(headerTitle(for: entry))
                            .font(.headline)
                            .lineLimit(2)
                        Text(headerSubtitle(for: entry))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    cadenceChip(entry.cadence)
                }

                Text(Self.markdownAttributed(entry.body))
                    .font(.subheadline)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if entry.appliedSuggestionCount > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption2)
                        Text(String(
                            format: String(localized: "%d applied therapy changes in this window", comment: "Recap applied changes footer"),
                            entry.appliedSuggestionCount
                        ))
                        .font(.caption)
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 2)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(colorScheme == .dark ? Color.bgDarkerDarkBlue.opacity(0.8) : Color.white)
            )
        }

        private func cadenceChip(_ cadence: RecapEntry.Cadence) -> some View {
            Text(
                cadence == .weekly
                    ? String(localized: "Weekly", comment: "Recap cadence label")
                    : String(localized: "Monthly", comment: "Recap cadence label")
            )
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            .foregroundStyle(Color.accentColor)
        }

        @ViewBuilder
        private var upcomingScheduleHint: some View {
            // Inline footer to set expectations about when the next recap
            // will arrive. We don't show this when the screen is empty —
            // the empty state already covers cadence.
            if !state.entries.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                    Text(String(
                        localized: "New recap arrives weekly after therapy changes, monthly otherwise.",
                        comment: "Recap cadence footer"
                    ))
                }
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.top, 4)
            } else {
                EmptyView()
            }
        }

        private func headerTitle(for entry: RecapEntry) -> String {
            let formatter = DateFormatter()
            formatter.dateStyle = .long
            formatter.timeStyle = .none
            let prefix = entry.cadence == .weekly
                ? String(localized: "Weekly recap", comment: "Weekly recap header")
                : String(localized: "Monthly recap", comment: "Monthly recap header")
            return "\(prefix) — \(formatter.string(from: entry.date))"
        }

        private func headerSubtitle(for entry: RecapEntry) -> String {
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return String(
                format: String(localized: "Generated %@", comment: "Recap generated-at subtitle"),
                formatter.string(from: entry.date)
            )
        }

        /// Convert the AI-produced body into an AttributedString so basic
        /// Markdown like **bold**, *italic*, and bullet lists render properly.
        /// Falls back to plain text if parsing fails.
        private static func markdownAttributed(_ body: String) -> AttributedString {
            (try? AttributedString(markdown: body, options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            ))) ?? AttributedString(body)
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
