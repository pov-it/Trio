//
//  FoodShortcutWidgets.swift
//  LiveActivityExtension
//
//  Lock-screen (accessory) and home-screen shortcut widgets that deep-link
//  straight into FoodFinder and the Caffeine tracker. Tapping a widget opens
//  the Trio app via the registered "Trio://" URL scheme; TrioApp.handleURL
//  routes the host ("foodfinder" / "caffeine") to the matching modal screen.
//

import SwiftUI
import WidgetKit

// MARK: - Timeline (static, single entry — these widgets never change state)

private struct ShortcutEntry: TimelineEntry {
    let date: Date
}

private struct ShortcutProvider: TimelineProvider {
    func placeholder(in _: Context) -> ShortcutEntry { ShortcutEntry(date: Date()) }

    func getSnapshot(in _: Context, completion: @escaping (ShortcutEntry) -> Void) {
        completion(ShortcutEntry(date: Date()))
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<ShortcutEntry>) -> Void) {
        // Never reload — the content is fully static.
        completion(Timeline(entries: [ShortcutEntry(date: Date())], policy: .never))
    }
}

// MARK: - Shared shortcut view

private struct ShortcutWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let icon: String
    let title: String
    let subtitle: String
    let tint: Color
    let url: URL?

    var body: some View {
        content
            .widgetURL(url)
            .containerBackground(for: .widget) {
                switch family {
                case .systemSmall,
                     .systemMedium:
                    LinearGradient(
                        colors: [tint.opacity(0.85), tint.opacity(0.5)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                default:
                    // Lock-screen accessory families render on the system's
                    // own material; keep the container transparent.
                    Color.clear
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: icon)
                    .font(.title2)
            }
        case .accessoryRectangular:
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        case .accessoryInline:
            Label(title, systemImage: icon)
        default:
            // systemSmall (and any larger fallback)
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(8)
        }
    }
}

// MARK: - FoodFinder shortcut

struct FoodFinderShortcutWidget: Widget {
    let kind = "FoodFinderShortcutWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ShortcutProvider()) { _ in
            ShortcutWidgetView(
                icon: "fork.knife",
                title: String(localized: "FoodFinder", comment: "FoodFinder widget title"),
                subtitle: String(localized: "Log a meal", comment: "FoodFinder widget subtitle"),
                tint: Color(red: 0.262_745_098, green: 0.733_333_333_3, blue: 0.913_725_490_2),
                url: URL(string: "Trio://foodfinder")
            )
        }
        .configurationDisplayName(String(localized: "FoodFinder", comment: "FoodFinder widget display name"))
        .description(String(localized: "Open FoodFinder to log a meal in one tap.", comment: "FoodFinder widget description"))
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .systemSmall])
    }
}

// MARK: - Caffeine shortcut

struct CaffeineShortcutWidget: Widget {
    let kind = "CaffeineShortcutWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ShortcutProvider()) { _ in
            ShortcutWidgetView(
                icon: "cup.and.saucer.fill",
                title: String(localized: "Caffeine", comment: "Caffeine widget title"),
                subtitle: String(localized: "Log intake", comment: "Caffeine widget subtitle"),
                tint: Color(red: 0.3, green: 0.7, blue: 0.4),
                url: URL(string: "Trio://caffeine")
            )
        }
        .configurationDisplayName(String(localized: "Caffeine Tracker", comment: "Caffeine widget display name"))
        .description(String(localized: "Open the caffeine tracker to log intake in one tap.", comment: "Caffeine widget description"))
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .systemSmall])
    }
}
