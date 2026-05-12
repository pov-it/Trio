import SwiftUI
import Swinject

extension AIInsights {
    struct FoodFinderView: View {
        var body: some View {
            VStack {
                Image(systemName: "camera.macro")
                    .font(.system(size: 60))
                    .foregroundStyle(.green)
                Text("FoodFinder")
                    .font(.title)
                    .fontWeight(.bold)
                    .padding(.top)
                Text("Coming soon...")
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("FoodFinder")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
