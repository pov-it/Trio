import Foundation
import SwiftUI
import Swinject

extension AIInsights {
    struct ChatView: BaseView {
        let resolver: Resolver
        @State var state = ChatStateModel()

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState
        @FocusState private var isTextFieldFocused: Bool
        @State private var showConversationPicker = false
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
                                    onRevertTherapySuggestion: { suggestion in
                                        Task { await state.revertLatestMatchingSuggestion(suggestion) }
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
                ToolbarItem(placement: .principal) {
                    Button {
                        showConversationPicker = true
                    } label: {
                        HStack(spacing: 4) {
                            Text(currentConversationTitle)
                                .font(.headline)
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.caption.bold())
                        }
                        .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        AISettingsView(resolver: resolver)
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .popover(isPresented: $showConversationPicker, arrowEdge: .top) {
                conversationPicker
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

        private var currentConversationTitle: String {
            state.conversations.first(where: { $0.id == state.activeConversationID })?.title
                ?? String(localized: "AI Chat", comment: "Navigation title for AI chat")
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

        private var conversationPicker: some View {
            NavigationStack {
                List {
                    Button {
                        state.startNewConversation()
                        showConversationPicker = false
                    } label: {
                        Label(String(localized: "New Chat", comment: "New chat button"), systemImage: "square.and.pencil")
                    }

                    Section(header: Text(String(localized: "Chat History", comment: "Chat history section header"))) {
                        ForEach(state.filteredConversations(searchText: conversationSearchText)) { conversation in
                            Button {
                                state.selectConversation(conversation)
                                showConversationPicker = false
                            } label: {
                                HStack(spacing: 10) {
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
                                    Spacer(minLength: 8)
                                    if conversation.id == state.activeConversationID {
                                        Image(systemName: "checkmark")
                                            .font(.caption.bold())
                                            .foregroundStyle(Color.accentColor)
                                    }
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

                    Button(role: .destructive) {
                        state.clearChat()
                        showConversationPicker = false
                    } label: {
                        Label(String(localized: "Delete Current Chat", comment: "Menu item"), systemImage: "trash")
                    }
                    .disabled(state.messages.isEmpty)
                }
                .searchable(text: $conversationSearchText, prompt: String(localized: "Search chats...", comment: "Chat search prompt"))
                .navigationTitle(String(localized: "AI Chat", comment: "Navigation title for AI chat"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Close", comment: "Close button")) {
                            showConversationPicker = false
                        }
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .frame(minWidth: 320, idealWidth: 380, minHeight: 420)
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
            HStack {
                HStack(spacing: 8) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: colorScheme == .dark ? .white : .primary))
                    Text(String(localized: "Analyzing...", comment: "AI generating state"))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(colorScheme == .dark ? Color.bgDarkerDarkBlue.opacity(0.8) : Color.insulin.opacity(0.1))
                )
                Spacer(minLength: 60)
            }
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
    var onRevertTherapySuggestion: (AIInsights.Suggestion) -> Void = { _ in }
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
            ZStack(alignment: .bottomTrailing) {
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
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)

                    if let suggestions = message.therapySuggestions, !suggestions.isEmpty {
                        VStack(spacing: 8) {
                            ForEach(suggestions) { suggestion in
                                ChatTherapySuggestionCard(
                                    suggestion: suggestion,
                                    onApply: { onApplyTherapySuggestion(suggestion) },
                                    onRevert: { onRevertTherapySuggestion(suggestion) },
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
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 24)

                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.trailing, 12)
                    .padding(.bottom, 7)
            }
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(bubbleBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(message.isUser ? AIChatStyle.gradient : AIChatStyle.clearGradient, lineWidth: message.isUser ? 1.5 : 0)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
            if !message.isUser { Spacer(minLength: 60) }
        }
    }

    private var bubbleBackground: some ShapeStyle {
        AnyShapeStyle(
            colorScheme == .dark ? Color.bgDarkerDarkBlue.opacity(0.8) : Color.insulin.opacity(0.1)
        )
    }
}

private enum AIChatStyle {
    static let gradient = LinearGradient(
        colors: [
            Color(red: 0.7215686275, green: 0.3411764706, blue: 1),
            Color(red: 0.262745098, green: 0.7333333333, blue: 0.9137254902)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let clearGradient = LinearGradient(
        colors: [.clear, .clear],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

private struct InlineMessageText: View {
    let content: String
    let isUser: Bool
    var onNavigate: (AIInsights.ChatAction.Destination) -> Void

    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                switch line {
                case let .text(text):
                    renderedText(for: text)
                        .fixedSize(horizontal: false, vertical: true)
                case let .bullet(text, level):
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                            .frame(width: 10, alignment: .leading)
                        renderedText(for: text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(level) * 14)
                }
            }
        }
            .font(.subheadline)
            .foregroundStyle(colorScheme == .dark ? .white : .primary)
            .lineLimit(nil)
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

    private var lines: [InlineMessageLine] {
        InlineMessageLine.parse(AIChatTextNormalizer.normalize(content))
    }

    private func renderedText(for rawText: String) -> Text {
        InlineSegment.parse(rawText).reduce(Text("")) { partial, segment in
            partial + renderedSegment(for: segment)
        }
    }

    private func renderedSegment(for segment: InlineSegment) -> Text {
        switch segment {
        case let .plain(text):
            let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            if let attributed = try? AttributedString(markdown: text, options: options) {
                return Text(attributed)
            }
            return Text(text)
        case let .trend(token):
            return Text(" ") + Text(Image(systemName: token.systemImage)) + Text(" ")
        case let .link(title, destination):
            var attributed = AttributedString(localizedLinkTitle(for: title, destination: destination))
            attributed.link = URL(string: "trio-ai://\(destination.deepLinkID)")
            attributed.foregroundColor = .accentColor
            return Text(" ") + Text(attributed).bold() + Text(" ")
        }
    }

    private func destination(for id: String) -> AIInsights.ChatAction.Destination? {
        AIInsights.ChatAction.Destination(inlineLinkID: id)
    }

    private func localizedLinkTitle(for title: String, destination: AIInsights.ChatAction.Destination) -> String {
        let normalized = title.lowercased()
        switch destination {
        case .basalSettings:
            return String(localized: "basal rates", comment: "Inline AI chat link to basal settings")
        case .carbRatioSettings:
            return String(localized: "carb ratios", comment: "Inline AI chat link to carb ratio settings")
        case .adjustmentSettings where normalized.contains("temporary") || normalized.contains("target") || normalized.contains("streef"):
            return String(localized: "temporary targets", comment: "Inline AI chat link to temporary target settings")
        default:
            return title
        }
    }
}

private enum InlineMessageLine {
    case text(String)
    case bullet(String, level: Int)

    static func parse(_ content: String) -> [InlineMessageLine] {
        content
            .replacingOccurrences(of: "\\s+•\\s+", with: "\n• ", options: .regularExpression)
            .replacingOccurrences(of: #"([.!?])\s+[-*]\s+"#, with: "$1\n• ", options: .regularExpression)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { rawLine in
                let line = String(rawLine)
                guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }

                let leadingWhitespace = line.prefix { $0 == " " || $0 == "\t" }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let level = leadingWhitespace.reduce(0) { partial, character in
                    partial + (character == "\t" ? 2 : 1)
                } / 2

                for marker in ["• ", "â€¢ ", "- ", "* "] where trimmed.hasPrefix(marker) {
                    return .bullet(String(trimmed.dropFirst(marker.count)), level: level)
                }

                return .text(trimmed)
            }
    }
}

private enum InlineSegment {
    case plain(String)
    case trend(TrendToken)
    case link(String, AIInsights.ChatAction.Destination)

    static func parse(_ content: String) -> [InlineSegment] {
        let trendPattern = #"\((arrowUp|arrowDown|arrowFlat|arrowDoubleUp|arrowDoubleDown|arrowUpRight|arrowDownRight)\)"#
        let rightArrow = NSRegularExpression.escapedPattern(for: String(UnicodeScalar(0x2192)!))
        let arrowPattern = "(->|\(rightArrow))"
        let termPattern = #"\b(basal rates|basal rate|basaalwaarden|basaalwaarde|ISF|insulin sensitivity|insulinegevoeligheid|carb ratios|carb ratio|koolhydraatratio'?s?|overrides?|temporary targets?|temp targets?|tijdelijke streefdoelen|tijdelijk streefdoel)\b"#
        let pattern = "\(trendPattern)|\(arrowPattern)|\(termPattern)"
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
            } else if Range(match.range(at: 2), in: content) != nil {
                result.append(.trend(.arrowRight))
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

private enum AIChatTextNormalizer {
    static func normalize(_ content: String) -> String {
        var text = content
            .replacingOccurrences(of: "\\r\\n", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "-----", with: "\n\n")
            .replacingOccurrences(of: "_____", with: "\n\n")

        for marker in ["<TRIO_SUGGESTIONS>", "<KNOWLEDGE>"] {
            if let range = text.range(of: marker) {
                text.removeSubrange(range.lowerBound ..< text.endIndex)
            }
        }

        text = regexReplace(text, pattern: #"(?m)^\s*[-_—]{3,}\s*$"#, template: "\n")
        text = regexReplace(text, pattern: #"\s+[*•]\s+"#, template: "\n• ")
        text = regexReplace(text, pattern: #"(?m)^\s*[-*]\s+"#, template: "• ")
        text = regexReplace(text, pattern: #"([.!?])([A-ZÀ-ÖØ-Þ])"#, template: "$1 $2")

        let rightArrow = NSRegularExpression.escapedPattern(for: String(UnicodeScalar(0x2192)!))
        let arrow = "(?:->|\(rightArrow))"
        let value = #"\d+(?:[,.]\d+)?\s*(?:mmol/L|%|U/hr|g/U|U|g)?"#
        text = regexReplace(
            text,
            pattern: "(\(value)\\s*\(arrow)\\s*\(value))\\s*\(arrow)\\s+(?=\\p{Ll})",
            template: "$1, "
        )

        text = regexReplace(text, pattern: #"[ \t]{2,}"#, template: " ")
        text = regexReplace(text, pattern: #"[ \t]+\n"#, template: "\n")
        text = regexReplace(text, pattern: #"\n{3,}"#, template: "\n\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func regexReplace(_ text: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
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
    case arrowRight

    init?(named value: String) {
        switch value.lowercased() {
        case "arrowup": self = .arrowUp
        case "arrowdown": self = .arrowDown
        case "arrowflat": self = .arrowFlat
        case "arrowdoubleup": self = .arrowDoubleUp
        case "arrowdoubledown": self = .arrowDoubleDown
        case "arrowupright": self = .arrowUpRight
        case "arrowdownright": self = .arrowDownRight
        case "arrowright": self = .arrowRight
        default: return nil
        }
    }

    var systemImage: String {
        switch self {
        case .arrowUp: return "arrow.up"
        case .arrowDown: return "arrow.down"
        case .arrowFlat: return "arrow.right"
        case .arrowDoubleUp: return "arrow.up.to.line"
        case .arrowDoubleDown: return "arrow.down.to.line"
        case .arrowUpRight: return "arrow.up.right"
        case .arrowDownRight: return "arrow.down.right"
        case .arrowRight: return "arrow.right"
        }
    }
}

private struct ChatTherapySuggestionCard: View {
    let suggestion: AIInsights.Suggestion
    var onApply: () -> Void
    var onRevert: () -> Void
    var onEdit: () -> Void
    var onDismiss: () -> Void

    @Environment(\.colorScheme) var colorScheme
    @State private var isExpanded = false

    var body: some View {
        ChatSwipeActionContainer(
            leadingActions: leadingActions,
            trailingActions: [
                ChatSwipeAction(
                    title: String(localized: "Edit", comment: "Edit therapy settings"),
                    systemImage: "pencil",
                    tint: .blue,
                    action: onEdit
                )
            ]
        ) {
            cardContent
        }
        .shadow(color: isExpanded ? Color.black.opacity(colorScheme == .dark ? 0.25 : 0.12) : .clear, radius: 10, y: 4)
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: settingIcon)
                    .foregroundStyle(settingColor)
                Text(suggestion.settingType.localizedTitle)
                    .font(.caption.bold())
                Spacer()
                statusBadge
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
                .lineLimit(isExpanded ? nil : 3)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 92)
        .background(RoundedRectangle(cornerRadius: 12).fill(cardBackground))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(colorScheme == .dark ? Color.white.opacity(0.08) : Color.gray.opacity(0.16), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onLongPressGesture(minimumDuration: 0.35) {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                isExpanded.toggle()
            }
        }
    }

    private func valueColumn(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.caption.bold())
                .lineLimit(nil)
        }
    }

    private var cardBackground: Color {
        colorScheme == .dark ? Color.bgDarkerDarkBlue.opacity(0.9) : Color.white
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

    private var leadingActions: [ChatSwipeAction] {
        if latestHistoryStatus == .applied {
            return [
                ChatSwipeAction(
                    title: String(localized: "Revert", comment: "Revert suggestion"),
                    systemImage: "arrow.uturn.backward",
                    tint: .orange,
                    action: onRevert
                )
            ]
        }

        return [
            ChatSwipeAction(
                title: String(localized: "Apply", comment: "Apply suggestion"),
                systemImage: "checkmark.circle",
                tint: .green,
                action: onApply
            )
        ]
    }

    private var statusBadge: some View {
        Text(statusBadgeText)
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(statusBadgeColor.opacity(0.15)))
            .foregroundStyle(statusBadgeColor)
    }

    private var statusBadgeText: String {
        if let latestHistoryStatus {
            return latestHistoryStatus.localizedTitle
        }
        return String(format: "%.0f%%", suggestion.confidence * 100)
    }

    private var statusBadgeColor: Color {
        switch latestHistoryStatus {
        case .applied: return .green
        case .reverted: return .orange
        case .dismissed: return .gray
        case nil: return confidenceColor
        }
    }

    private var latestHistoryStatus: AIInsights.SuggestionHistoryRecord.Status? {
        AIInsights.SuggestionHistoryStore.load().first { record in
            record.suggestion.id == suggestion.id ||
                (record.suggestion.settingType == suggestion.settingType &&
                    record.suggestion.timeBlock == suggestion.timeBlock &&
                    record.suggestion.proposedValue == suggestion.proposedValue)
        }?.status
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

    @Environment(\.colorScheme) var colorScheme
    @State private var isExpanded = false

    var body: some View {
        ChatSwipeActionContainer(
            leadingActions: [
                ChatSwipeAction(
                    title: String(localized: "Accept", comment: "Accept adjustment suggestion"),
                    systemImage: "checkmark.circle",
                    tint: .green,
                    action: onStart
                )
            ],
            trailingActions: [
                ChatSwipeAction(
                    title: String(localized: "Save", comment: "Save adjustment suggestion as preset"),
                    systemImage: "tray.and.arrow.down.fill",
                    tint: .orange,
                    action: onAddPreset
                ),
                ChatSwipeAction(
                    title: String(localized: "Edit", comment: "Edit adjustment suggestion"),
                    systemImage: "pencil",
                    tint: .blue,
                    action: onEdit
                )
            ]
        ) {
            cardContent
        }
        .shadow(color: isExpanded ? Color.black.opacity(colorScheme == .dark ? 0.25 : 0.12) : .clear, radius: 10, y: 4)
    }

    private var cardContent: some View {
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
                .lineLimit(isExpanded ? nil : 3)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 92)
        .background(RoundedRectangle(cornerRadius: 12).fill(cardBackground))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(colorScheme == .dark ? Color.white.opacity(0.08) : Color.gray.opacity(0.16), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onLongPressGesture(minimumDuration: 0.35) {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                isExpanded.toggle()
            }
        }
    }

    private var cardBackground: Color {
        colorScheme == .dark ? Color.bgDarkerDarkBlue.opacity(0.9) : Color.white
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

private struct ChatSwipeAction: Identifiable {
    var id = UUID()
    let title: String
    let systemImage: String
    let tint: Color
    let action: () -> Void
}

private struct ChatSwipeActionContainer<Content: View>: View {
    let leadingActions: [ChatSwipeAction]
    let trailingActions: [ChatSwipeAction]
    let content: Content

    @State private var offset: CGFloat = 0
    @State private var settledOffset: CGFloat = 0

    init(
        leadingActions: [ChatSwipeAction] = [],
        trailingActions: [ChatSwipeAction] = [],
        @ViewBuilder content: () -> Content
    ) {
        self.leadingActions = leadingActions
        self.trailingActions = trailingActions
        self.content = content()
    }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                ForEach(leadingActions) { action in
                    actionButton(action)
                }
                Spacer(minLength: 0)
                ForEach(trailingActions) { action in
                    actionButton(action)
                }
            }

            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .offset(x: offset)
                .gesture(dragGesture)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: offset)
    }

    private var leadingWidth: CGFloat {
        CGFloat(leadingActions.count) * 74
    }

    private var trailingWidth: CGFloat {
        CGFloat(trailingActions.count) * 74
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                let proposed = settledOffset + value.translation.width
                offset = min(max(proposed, -trailingWidth), leadingWidth)
            }
            .onEnded { value in
                let proposed = settledOffset + value.translation.width
                let predicted = settledOffset + value.predictedEndTranslation.width
                if leadingWidth > 0, (proposed > leadingWidth * 0.85 || predicted > leadingWidth * 1.05),
                   let action = leadingActions.first
                {
                    perform(action)
                    return
                }
                if trailingWidth > 0, (proposed < -trailingWidth * 0.85 || predicted < -trailingWidth * 1.05),
                   let action = trailingActions.last
                {
                    perform(action)
                    return
                }

                let threshold: CGFloat = 38
                if proposed > threshold, leadingWidth > 0 {
                    settledOffset = leadingWidth
                } else if proposed < -threshold, trailingWidth > 0 {
                    settledOffset = -trailingWidth
                } else {
                    settledOffset = 0
                }
                offset = settledOffset
            }
    }

    private func actionButton(_ action: ChatSwipeAction) -> some View {
        Button {
            perform(action)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: action.systemImage)
                    .font(.caption.bold())
                Text(action.title)
                    .font(.caption2.bold())
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.white)
            .frame(width: 74)
            .frame(maxHeight: .infinity)
            .padding(.vertical, 10)
            .background(action.tint)
        }
        .buttonStyle(.plain)
    }

    private func perform(_ action: ChatSwipeAction) {
        action.action()
        settledOffset = 0
        offset = 0
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


