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
                                MessageBubble(
                                    message: message,
                                    units: state.provider?.units ?? .mgdL,
                                    onNavigate: { destination in
                                        navigationTarget = target(for: destination)
                                    },
                                    onApplyTherapySuggestion: { suggestion in
                                        state.requestApply(suggestion)
                                    },
                                    onEditTherapySuggestion: { suggestion in
                                        navigationTarget = target(for: settingsDestination(for: suggestion.settingType))
                                    },
                                    onDismissTherapySuggestion: { suggestion in
                                        state.dismissTherapySuggestion(suggestion)
                                    },
                                    onAddAdjustmentPreset: { suggestion in
                                        Task { await state.addAdjustmentSuggestionToPresets(suggestion) }
                                    },
                                    onStartAdjustment: { suggestion in
                                        Task { await state.startAdjustmentSuggestion(suggestion) }
                                    },
                                    onEditAdjustment: { _ in
                                        navigationTarget = target(for: .adjustmentSettings)
                                    },
                                    onDismissAdjustment: { suggestion in
                                        state.dismissAdjustmentSuggestion(suggestion)
                                    }
                                )
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
            .alert(
                String(localized: "Apply Suggestion?", comment: "Disclaimer alert title"),
                isPresented: $state.showApplyDisclaimer
            ) {
                Button(String(localized: "Cancel", comment: "Cancel button"), role: .cancel) {
                    state.cancelApply()
                }
                Button(String(localized: "I Understand, Apply", comment: "Apply button"), role: .destructive) {
                    Task { await state.confirmApply() }
                }
            } message: {
                Text(String(localized: "This AI suggestion is informational only and NOT medical advice. Always consult your healthcare provider before adjusting therapy settings. Incorrect settings can cause dangerous hypo- or hyperglycemia. By proceeding, you acknowledge that you take full responsibility for any changes.", comment: "Disclaimer message"))
            }
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
            case .adjustmentSettings:
                return .screen(.overrideConfig)
            case .risingPattern, .fallingPattern:
                return .therapyInsights
            }
        }

        private func settingsDestination(for settingType: Suggestion.SettingType) -> ChatAction.Destination {
            switch settingType {
            case .basalRate:
                return .basalSettings
            case .isf:
                return .isfSettings
            case .carbRatio:
                return .carbRatioSettings
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
    var onNavigate: (AIInsights.ChatAction.Destination) -> Void = { _ in }
    var onApplyTherapySuggestion: (AIInsights.Suggestion) -> Void = { _ in }
    var onEditTherapySuggestion: (AIInsights.Suggestion) -> Void = { _ in }
    var onDismissTherapySuggestion: (AIInsights.Suggestion) -> Void = { _ in }
    var onAddAdjustmentPreset: (AIInsights.AdjustmentSuggestion) -> Void = { _ in }
    var onStartAdjustment: (AIInsights.AdjustmentSuggestion) -> Void = { _ in }
    var onEditAdjustment: (AIInsights.AdjustmentSuggestion) -> Void = { _ in }
    var onDismissAdjustment: (AIInsights.AdjustmentSuggestion) -> Void = { _ in }

    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        HStack {
            if message.isUser { Spacer(minLength: 60) }
            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 8) {
                if let chip = message.hintChip {
                    HStack(spacing: 4) {
                        Image(systemName: chip.icon)
                            .font(.caption2)
                        Text(chip.localizedTitle)
                            .font(.caption2)
                    }
                    .padding(.bottom, 2)
                }

                InlineMessageText(
                    content: message.content,
                    isUser: message.isUser,
                    onNavigate: onNavigate
                )
                .fixedSize(horizontal: false, vertical: true)

                if let suggestions = message.therapySuggestions, !suggestions.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(suggestions) { suggestion in
                            ChatTherapySuggestionCard(
                                suggestion: suggestion,
                                onApply: { onApplyTherapySuggestion(suggestion) },
                                onEdit: { onEditTherapySuggestion(suggestion) },
                                onDismiss: { onDismissTherapySuggestion(suggestion) }
                            )
                        }
                    }
                    .padding(.top, 2)
                }

                if let suggestions = message.adjustmentSuggestions, !suggestions.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(suggestions) { suggestion in
                            ChatAdjustmentSuggestionCard(
                                suggestion: suggestion,
                                units: units,
                                onAddPreset: { onAddAdjustmentPreset(suggestion) },
                                onStart: { onStartAdjustment(suggestion) },
                                onEdit: { onEditAdjustment(suggestion) },
                                onDismiss: { onDismissAdjustment(suggestion) }
                            )
                        }
                    }
                    .padding(.top, 2)
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

private struct InlineMessageText: View {
    let content: String
    let isUser: Bool
    var onNavigate: (AIInsights.ChatAction.Destination) -> Void

    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        renderedText
            .font(.subheadline)
            .foregroundStyle(isUser ? .white : (colorScheme == .dark ? .white : .primary))
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "trio-ai",
                      let destination = destination(for: url.host ?? url.absoluteString.replacingOccurrences(of: "trio-ai://", with: ""))
                else {
                    return .systemAction
                }
                onNavigate(destination)
                return .handled
            })
    }

    private var renderedText: Text {
        segments.reduce(Text("")) { partial, segment in
            partial + text(for: segment)
        }
    }

    private var segments: [InlineSegment] {
        InlineSegment.parse(content)
    }

    private func text(for segment: InlineSegment) -> Text {
        switch segment {
        case let .plain(text):
            if let attributed = try? AttributedString(markdown: text) {
                return Text(attributed)
            }
            return Text(text)
        case let .trend(token):
            return Text(Image(systemName: token.systemImage))
        case let .link(title, destination):
            var attributed = AttributedString(title)
            attributed.link = URL(string: "trio-ai://\(destination.deepLinkID)")
            attributed.font = .subheadline.bold()
            attributed.foregroundColor = .accentColor
            attributed.underlineStyle = .single
            return Text(attributed)
        }
    }

    private func destination(for id: String) -> AIInsights.ChatAction.Destination? {
        AIInsights.ChatAction.Destination(inlineLinkID: id)
    }
}

private enum InlineSegment {
    case plain(String)
    case trend(TrendToken)
    case link(String, AIInsights.ChatAction.Destination)

    static func parse(_ content: String) -> [InlineSegment] {
        let pattern = #"\((arrowUp|arrowDown|arrowFlat|arrowDoubleUp|arrowDoubleDown|arrowUpRight|arrowDownRight)\)|\b(basal rates|basal rate|basaalwaarden|basaalwaarde|ISF|insulin sensitivity|insulinegevoeligheid|carb ratios|carb ratio|koolhydraatratio'?s?|overrides?|temporary targets?|temp targets?|tijdelijke streefdoelen|tijdelijk streefdoel)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return [.plain(content)]
        }

        let nsRange = NSRange(content.startIndex ..< content.endIndex, in: content)
        let matches = regex.matches(in: content, range: nsRange)
        guard !matches.isEmpty else { return [.plain(content)] }

        var result: [InlineSegment] = []
        var cursor = content.startIndex

        for match in matches {
            guard let range = Range(match.range, in: content) else { continue }
            if cursor < range.lowerBound {
                result.append(.plain(String(content[cursor ..< range.lowerBound])))
            }

            let matchedText = String(content[range])
            if let trendRange = Range(match.range(at: 1), in: content),
               let token = TrendToken(named: String(content[trendRange]))
            {
                result.append(.trend(token))
            } else if let destination = AIInsights.ChatAction.Destination(inlineTerm: matchedText) {
                result.append(.link(matchedText, destination))
            } else {
                result.append(.plain(matchedText))
            }

            cursor = range.upperBound
        }

        if cursor < content.endIndex {
            result.append(.plain(String(content[cursor ..< content.endIndex])))
        }

        return result
    }
}

private enum TrendToken: String {
    case arrowUp
    case arrowDown
    case arrowFlat
    case arrowDoubleUp
    case arrowDoubleDown
    case arrowUpRight
    case arrowDownRight

    init?(named value: String) {
        switch value.lowercased() {
        case "arrowup": self = .arrowUp
        case "arrowdown": self = .arrowDown
        case "arrowflat": self = .arrowFlat
        case "arrowdoubleup": self = .arrowDoubleUp
        case "arrowdoubledown": self = .arrowDoubleDown
        case "arrowupright": self = .arrowUpRight
        case "arrowdownright": self = .arrowDownRight
        default: return nil
        }
    }

    var systemImage: String {
        switch self {
        case .arrowUp: return "arrow.up.circle.fill"
        case .arrowDown: return "arrow.down.circle.fill"
        case .arrowFlat: return "arrow.right.circle.fill"
        case .arrowDoubleUp: return "arrow.up.to.line.circle.fill"
        case .arrowDoubleDown: return "arrow.down.to.line.circle.fill"
        case .arrowUpRight: return "arrow.up.right.circle.fill"
        case .arrowDownRight: return "arrow.down.right.circle.fill"
        }
    }
}

private struct ChatTherapySuggestionCard: View {
    let suggestion: AIInsights.Suggestion
    var onApply: () -> Void
    var onEdit: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: settingIcon)
                    .foregroundStyle(settingColor)
                Text(suggestion.settingType.localizedTitle)
                    .font(.caption.bold())
                Spacer()
                confidenceBadge
            }

            Label(suggestion.timeBlock, systemImage: "clock")
                .font(.caption2)
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                valueColumn(title: String(localized: "Current", comment: "Current setting value"), value: suggestion.currentValue)
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                valueColumn(title: String(localized: "Proposed", comment: "Proposed setting value"), value: suggestion.proposedValue)
            }

            Text(suggestion.reasoning)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(settingColor.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(settingColor.opacity(0.25), lineWidth: 1))
        .swipeActions(edge: .leading) {
            Button(String(localized: "Apply", comment: "Apply suggestion"), systemImage: "checkmark.circle") {
                onApply()
            }
            .tint(.green)
        }
        .swipeActions(edge: .trailing) {
            Button(String(localized: "Dismiss", comment: "Dismiss suggestion"), systemImage: "xmark.circle", role: .destructive) {
                onDismiss()
            }
            Button(String(localized: "Edit", comment: "Edit therapy settings"), systemImage: "pencil") {
                onEdit()
            }
            .tint(.blue)
        }
    }

    private func valueColumn(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.caption.bold())
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var settingIcon: String {
        switch suggestion.settingType {
        case .basalRate: return "waveform.path.ecg.rectangle.fill"
        case .isf: return "syringe"
        case .carbRatio: return "fork.knife"
        }
    }

    private var settingColor: Color {
        switch suggestion.settingType {
        case .basalRate: return .blue
        case .isf: return .purple
        case .carbRatio: return .orange
        }
    }

    private var confidenceBadge: some View {
        Text(String(format: "%.0f%%", suggestion.confidence * 100))
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(confidenceColor.opacity(0.15)))
            .foregroundStyle(confidenceColor)
    }

    private var confidenceColor: Color {
        switch suggestion.confidence {
        case 0.7...: return .green
        case 0.4 ..< 0.7: return .orange
        default: return .red
        }
    }
}

private struct ChatAdjustmentSuggestionCard: View {
    let suggestion: AIInsights.AdjustmentSuggestion
    let units: GlucoseUnits
    var onAddPreset: () -> Void
    var onStart: () -> Void
    var onEdit: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        Button(action: onStart) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: suggestion.kind.icon)
                        .foregroundStyle(Color.accentColor)
                    Text(suggestion.name)
                        .font(.caption.bold())
                        .foregroundColor(.primary)
                    Spacer()
                    Image(systemName: "line.3.horizontal")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 5) {
                    ForEach(labels, id: \.self) { label in
                        Text(label)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        if label != labels.last {
                            Divider()
                                .frame(width: 1, height: 14)
                        }
                    }
                    Spacer(minLength: 0)
                }

                Text(suggestion.reasoning)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.chart.opacity(0.75)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.insulin.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading) {
            Button(String(localized: "Add Preset", comment: "Add adjustment suggestion to presets"), systemImage: "plus.circle") {
                onAddPreset()
            }
            .tint(.green)
        }
        .swipeActions(edge: .trailing) {
            Button(String(localized: "Dismiss", comment: "Dismiss suggestion"), systemImage: "xmark.circle", role: .destructive) {
                onDismiss()
            }
            Button(String(localized: "Edit", comment: "Edit adjustment suggestion"), systemImage: "pencil") {
                onEdit()
            }
            .tint(.blue)
        }
    }

    private var labels: [String] {
        var values: [String] = [suggestion.kind.localizedTitle]
        if suggestion.durationMinutes > 0 {
            values.append(String(localized: "\(suggestion.durationMinutes) min", comment: "Adjustment suggestion duration"))
        }
        if let percentage = suggestion.percentage, percentage != 100 {
            values.append("\(Int(percentage))%\(scopeSuffix)")
        }
        if let target = suggestion.targetValue {
            values.append("\(target) \(units.rawValue)")
        }
        if suggestion.smbIsOff {
            values.append(String(localized: "SMBs Off", comment: "Override label for disabled SMBs"))
        }
        return values
    }

    private var scopeSuffix: String {
        switch (suggestion.isf, suggestion.cr) {
        case (true, true): return " ISF/CR"
        case (true, false): return " ISF"
        case (false, true): return " CR"
        default: return ""
        }
    }
}

private extension AIInsights.ChatAction.Destination {
    var deepLinkID: String {
        rawValue
    }

    init?(inlineLinkID: String) {
        self.init(rawValue: inlineLinkID)
    }

    init?(inlineTerm: String) {
        let normalized = inlineTerm.lowercased()
        if normalized.contains("basal") || normalized.contains("basaal") {
            self = .basalSettings
        } else if normalized == "isf" || normalized.contains("sensitivity") || normalized.contains("gevoelig") {
            self = .isfSettings
        } else if normalized.contains("carb") || normalized.contains("koolhydraat") || normalized.contains("ratio") {
            self = .carbRatioSettings
        } else if normalized.contains("override") || normalized.contains("temporary") || normalized.contains("temp target") || normalized.contains("streefdoel") {
            self = .adjustmentSettings
        } else {
            return nil
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


