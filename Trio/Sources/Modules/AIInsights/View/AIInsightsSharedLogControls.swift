//
//  AIInsightsSharedLogControls.swift
//  Trio
//
//  Shared UI bits used by tracker views (caffeine + alcohol):
//    • LogTimeRow — Bolus-calculator-style time row: clock icon, "Now"
//      tap-to-expand, then -15min / DatePicker / +15min.
//    • GlucoseEffectInfoSheet — sheet body for the (i) toolbar button.
//

import SwiftUI

/// Time picker styled after Trio's bolus calculator. Defaults to "Now"
/// label until the user wants to back-date — then expands to −15min /
/// inline DatePicker / +15min controls.
///
/// Usage:
///     @State var timestamp = Date()
///     LogTimeRow(timestamp: $timestamp)
///
/// Parent should reset `timestamp = Date()` in `.onAppear` so the picker
/// always opens on the current time (matches bolus calculator UX).
struct AIInsightsLogTimeRow: View {
    @Binding var timestamp: Date
    @State private var expanded: Bool = false

    var body: some View {
        HStack {
            Image(systemName: "clock")
                .foregroundColor(.secondary)
            Spacer()
            if !expanded {
                Button {
                    expanded = true
                } label: {
                    Text(timestampLabel)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .padding(.trailing, 5)
            } else {
                Button {
                    timestamp = timestamp.addingTimeInterval(-15 * 60)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .tint(.blue)
                .buttonStyle(.borderless)

                DatePicker(
                    "",
                    selection: $timestamp,
                    in: ...Date().addingTimeInterval(60),
                    displayedComponents: [.hourAndMinute]
                )
                .controlSize(.mini)
                .labelsHidden()

                Button {
                    let proposed = timestamp.addingTimeInterval(15 * 60)
                    // Don't allow future timestamps beyond +1 minute slack.
                    if proposed.timeIntervalSinceNow <= 60 {
                        timestamp = proposed
                    }
                } label: {
                    Image(systemName: "plus.circle")
                }
                .tint(.blue)
                .buttonStyle(.borderless)
            }
        }
    }

    private var timestampLabel: String {
        if abs(timestamp.timeIntervalSinceNow) < 60 {
            return String(localized: "Now", comment: "Tracker entry time = now")
        }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }
}

/// Sheet body for the "how X affects your glucose" toolbar (i) info button.
struct AIInsightsGlucoseEffectSheet: View {
    let title: String
    let paragraphs: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph)
                            .font(.body)
                            .foregroundColor(.primary)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(String(localized: "Done", comment: "Dismiss info sheet")) {
                        dismiss()
                    }
                }
            }
        }
    }
}
