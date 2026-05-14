import SwiftUI
import Swinject

extension AIInsights {
    struct ChatView: BaseView {
        let resolver: Resolver
        @State var state = ChatStateModel()

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState
        @FocusState private var isTextFieldFocused: Bool
        @State private var showConversationHistory = false
        @State private var conversationSearchText = ""
        @State private var navigationTarget: ChatNavigationTarget?

        var body: some View {
            VStack(spacing: 0) {
                // Message list
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            if messages.isEmpty {
                                welcomeView
                            }

                            ForEach(messages) { message in
                                MessageBubble(message: message, units: state.provider?.units ?? .mgdL) { action in
                                    navigationTarget = target(for: action.destination)
                                }
                                    .id(message.id)
                            }

                            if state.isGenerating {
                                generatingBubble
                            }

                            if let error = state.errorMessage {
                                ErrorBubble(message: error)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    .onChange(of: state.messages.count) {
                        if let lastMessage = state.messages.last {
                            withAnimation {
                                proxy.scrollTo(lastMessage.id, anchor: .bottom)
                            }
                        }
                    }
                }

            }
            .background(appState.trioBackgroundColor(for: colorScheme))
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if !state.isGenerating && state.messages.count < 2 {
                        hintChipsView
                    }
                    inputBar
                }
            }
            .navigationTitle(String(localized: "AI Chat", comment: "Navigation title for AI chat"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showConversationHistory = true
                    } label: {
                        Image(systemName: "sidebar.left")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            state.startNewConversation()
                        } label: {
                            Label(String(localized: "New Chat", comment: "Menu item"), systemImage: "square.and.pencil")
                        }

                        Button {
                            showConversationHistory = true
                        } label: {
                            Label(String(localized: "Chat History", comment: "Menu item"), systemImage: "clock.arrow.circlepath")
                        }

                        Button {
                            state.clearChat()
                        } label: {
                            Label(String(localized: "Delete Current Chat", comment: "Menu item"), systemImage: "trash")
                        }

                        NavigationLink {
                            AISettingsView(resolver: resolver)
                        } label: {
                            Label(String(localized: "AI Settings", comment: "Menu item"), systemImage: "gearshape")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showConversationHistory) {
                conversationHistorySheet
            }
            .navigationDestination(item: $navigationTarget) { target in
                switch target {
                case .therapyInsights:
                    AIInsights.TherapyInsightsView(resolver: resolver)
                case .foodFinder:
                    AIInsights.FoodFinderView(resolver: resolver)
                case let .screen(screen):
                    screen.view(resolver: resolver)
                }
            }
            .onAppear(perform: configureView)
        }

        // MARK: - Subviews

        private var messages: [ChatMessage] {
            state.messages
        }

        private func target(for destination: ChatAction.Destination) -> ChatNavigationTarget {
            switch destination {
            case .therapyInsights:
                return .therapyInsights
            case .foodFinder:
                return .foodFinder
            case .aiSettings:
                return .screen(.aiSettings)
            case .therapySettings:
                return .screen(.therapySettings)
            case .basalSettings:
                return .screen(.basalProfileEditor)
            case .isfSettings:
                return .screen(.isfEditor)
            case .carbRatioSettings:
                return .screen(.crEditor)
            case .risingPattern, .fallingPattern:
                return .therapyInsights
            }
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

        private var conversationHistorySheet: some View {
            NavigationStack {
                List {
                    Button {
                        state.startNewConversation()
                        showConversationHistory = false
                    } label: {
                        Label(String(localized: "New Chat", comment: "New chat button"), systemImage: "square.and.pencil")
                    }

                    ForEach(state.filteredConversations(searchText: conversationSearchText)) { conversation in
                        Button {
                            state.selectConversation(conversation)
                            showConversationHistory = false
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(conversation.title)
                                    .font(.subheadline.bold())
                                    .lineLimit(1)
                                Text(conversation.preview)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                                Text(relativeMinutesText(from: conversation.updatedAt))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                        .swipeActions {
                            Button(String(localized: "Delete", comment: "Delete conversation"), systemImage: "trash", role: .destructive) {
                                state.deleteConversation(conversation)
                            }
                        }
                    }
                }
                .searchable(text: $conversationSearchText, prompt: String(localized: "Search chats...", comment: "Chat search prompt"))
                .navigationTitle(String(localized: "Chats", comment: "AI chat history title"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Close", comment: "Close button")) {
                            showConversationHistory = false
                        }
                    }
                }
            }
        }

        private var welcomeView: some View {
            VStack(spacing: 16) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 48))
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
                    .padding(.top, 40)

                Text(String(localized: "Ask about your glucose data", comment: "Chat welcome title"))
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)

                Text(String(localized: "I can analyze your patterns, review your settings, and help you prepare for appointments.", comment: "Chat welcome subtitle"))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                if !state.aiEnabled {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(String(localized: "AI Insights is disabled. Enable it in Settings.", comment: "AI disabled message"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        NavigationLink {
                            AISettingsView(resolver: resolver)
                        } label: {
                            Text(String(localized: "Open AI Settings", comment: "AI settings link"))
                                .font(.caption.bold())
                        }
                    }
                    .padding()
                    .background(Color.chart.opacity(0.5))
                    .cornerRadius(12)
                }
            }
        }

        private var hintChipsView: some View {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(HintChip.allCases) { chip in
                        Button {
                            state.sendHintChip(chip)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: chip.icon)
                                    .font(.caption2)
                                Text(chip.localizedTitle)
                                    .font(.caption)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(colorScheme == .dark ? Color.bgDarkerDarkBlue.opacity(0.8) : Color.insulin.opacity(0.1))
                            )
                            .overlay(
                                Capsule()
                                    .stroke(
                                        LinearGradient(
                                            colors: [
                                                Color(red: 0.7215686275, green: 0.3411764706, blue: 1).opacity(0.4),
                                                Color(red: 0.262745098, green: 0.7333333333, blue: 0.9137254902).opacity(0.4)
                                            ],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        ),
                                        lineWidth: 1
                                    )
                            )
                            .foregroundStyle(colorScheme == .dark ? .white : .primary)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }

        private var generatingBubble: some View {
            HStack(spacing: 8) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: colorScheme == .dark ? .white : .primary))
                Text(String(localized: "Analyzing...", comment: "AI generating state"))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(colorScheme == .dark ? Color.bgDarkerDarkBlue.opacity(0.8) : Color.insulin.opacity(0.1))
            )
        }

        private var inputBar: some View {
            HStack(spacing: 12) {
                TextField(
                    String(localized: "Ask about your data...", comment: "Chat text field placeholder"),
                    text: $inputText,
                    axis: .vertical
                )
                .lineLimit(1 ... 5)
                .focused($isTextFieldFocused)
                .textFieldStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(colorScheme == .dark ? Color.bgDarkerDarkBlue : Color(.systemGray6))
                )

                Button {
                    let text = inputText
                    inputText = ""
                    isTextFieldFocused = false
                    state.sendUserMessage(text)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
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
                }
                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.isGenerating)
                .opacity(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.isGenerating ? 0.4 : 1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(colorScheme == .dark ? Color.bgDarkBlue : Color.white)
        }

        @State private var inputText: String = ""
    }
}

// MARK: - Message Bubble

private struct MessageBubble: View {
    let message: AIInsights.ChatMessage
    let units: GlucoseUnits
    var onAction: (AIInsights.ChatAction) -> Void = { _ in }

    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        HStack {
            if message.isUser { Spacer(minLength: 60) }
            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
                if let chip = message.hintChip {
                    HStack(spacing: 4) {
                        Image(systemName: chip.icon)
                            .font(.caption2)
                        Text(chip.localizedTitle)
                            .font(.caption2)
                    }
                    .padding(.bottom, 2)
                }

                Text(formattedContent)
                    .font(.subheadline)
                    .foregroundStyle(message.isUser ? .white : (colorScheme == .dark ? .white : .primary))

                if let actions = message.actions, !actions.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(actions) { action in
                            Button {
                                onAction(action)
                            } label: {
                                Label(action.title, systemImage: action.systemImage)
                                    .font(.caption.weight(.semibold))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(.top, 4)
                }

                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(bubbleBackground)
            )
            if !message.isUser { Spacer(minLength: 60) }
        }
    }

    private var formattedContent: AttributedString {
        (try? AttributedString(markdown: message.content))
            ?? AttributedString(message.content)
    }

    private var bubbleBackground: some ShapeStyle {
        if message.isUser {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color(red: 0.7215686275, green: 0.3411764706, blue: 1),
                        Color(red: 0.262745098, green: 0.7333333333, blue: 0.9137254902)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        } else {
            return AnyShapeStyle(
                colorScheme == .dark ? Color.bgDarkerDarkBlue.opacity(0.8) : Color.insulin.opacity(0.1)
            )
        }
    }
}

private enum ChatNavigationTarget: Identifiable, Hashable {
    case therapyInsights
    case foodFinder
    case screen(Screen)

    var id: String {
        switch self {
        case .therapyInsights: return "therapyInsights"
        case .foodFinder: return "foodFinder"
        case let .screen(screen): return "screen-\(screen.id)"
        }
    }
}

// MARK: - Error Bubble

private struct ErrorBubble: View {
    let message: String

    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.orange.opacity(0.1))
        )
    }
}


