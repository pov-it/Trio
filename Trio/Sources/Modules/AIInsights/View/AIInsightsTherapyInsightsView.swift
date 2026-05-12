import SwiftUI
import Swinject

extension AIInsights {
    struct TherapyInsightsView: View {
        var body: some View {
            VStack {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 60))
                    .foregroundStyle(.purple)
                Text("Therapy Insights")
                    .font(.title)
                    .fontWeight(.bold)
                    .padding(.top)
                Text("Coming soon...")
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("Insights")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
