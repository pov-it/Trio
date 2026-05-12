import SwiftUI
import Swinject

extension AIInsights {
    struct HubView: BaseView {
        let resolver: Resolver
        @State var state = StateModel()

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        var body: some View {
            ScrollView {
                VStack(spacing: 24) {
                    // Header
                    VStack(spacing: 8) {
                        Image(systemName: "sparkles")
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
                        
                        Text(String(localized: "AI Hub", comment: "AI Hub title"))
                            .font(.largeTitle.bold())
                        
                        Text(String(localized: "How can I help you today?", comment: "AI Hub subtitle"))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 40)
                    .padding(.bottom, 20)

                    // Menu Options
                    VStack(spacing: 16) {
                        HubMenuCard(
                            icon: "bubble.left.and.bubble.right.fill",
                            title: String(localized: "AI Chat", comment: "AI Chat feature name"),
                            description: String(localized: "Ask questions about your data and settings.", comment: "AI Chat description"),
                            gradientColors: [
                                Color(red: 0.7215686275, green: 0.3411764706, blue: 1),
                                Color(red: 0.4862745098, green: 0.5450980392, blue: 0.9529411765)
                            ],
                            destination: AnyView(AIInsights.ChatView(resolver: resolver))
                        )

                        HubMenuCard(
                            icon: "chart.line.uptrend.xyaxis",
                            title: String(localized: "Therapy Insights", comment: "Therapy Insights feature name"),
                            description: String(localized: "Automated analysis of your basal, ISF, and CR.", comment: "Therapy Insights description"),
                            gradientColors: [
                                Color(red: 0.4862745098, green: 0.5450980392, blue: 0.9529411765),
                                Color(red: 0.3411764706, green: 0.6666666667, blue: 0.9254901961)
                            ],
                            destination: AnyView(AIInsights.TherapyInsightsView(resolver: resolver))
                        )

                        HubMenuCard(
                            icon: "fork.knife.circle.fill",
                            title: String(localized: "FoodFinder", comment: "FoodFinder feature name"),
                            description: String(localized: "Identify meals and estimate carbs using AI.", comment: "FoodFinder description"),
                            gradientColors: [
                                Color(red: 0.3411764706, green: 0.6666666667, blue: 0.9254901961),
                                Color(red: 0.262745098, green: 0.7333333333, blue: 0.9137254902)
                            ],
                            destination: AnyView(AIInsights.FoodFinderView(resolver: resolver))
                        )
                    }
                    .padding(.horizontal)

                    Spacer(minLength: 40)
                }
            }
            .background(appState.trioBackgroundColor(for: colorScheme))
            .navigationTitle(String(localized: "AI Hub", comment: "Nav title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        AISettingsView(resolver: resolver)
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .onAppear(perform: configureView)
        }
    }
}

private struct HubMenuCard: View {
    let icon: String
    let title: String
    let description: String
    let gradientColors: [Color]
    let destination: AnyView

    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 16) {
                // Icon Container
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: gradientColors,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 50, height: 50)
                    
                    Image(systemName: icon)
                        .font(.system(size: 24))
                        .foregroundStyle(.white)
                }

                // Text Content
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(colorScheme == .dark ? .white : .primary)
                    
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
                    .font(.caption.bold())
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 16)
                    // Glassmorphism effect background
                    .fill(colorScheme == .dark ? Color.bgDarkerDarkBlue.opacity(0.8) : Color.white.opacity(0.8))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(colorScheme == .dark ? Color.white.opacity(0.1) : Color.gray.opacity(0.2), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 4)
        }
    }
}
