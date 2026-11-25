import SwiftUI
import UIKit

struct MealTitleMinYKey: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

extension AIInsights {
    /// Hold, then drag up or down. The track sits beside the control, never across it.
    struct PortionDragControl<Label: View>: View {
        var multiplier: Double
        var range: ClosedRange<Double> = FoodAnalysisResult.mealPortionRange
        var step: Double = 0.1
        var onTap: (() -> Void)?
        var onChange: (Double) -> Void
        var hintColor: Color = .white
        /// Photo controls draw a light track. Rows on a card draw a dark track.
        var trackOnPhoto: Bool = true
        @ViewBuilder var label: () -> Label

        @State private var armed = false
        @State private var origin: Double?
        @State private var live: Double = 1
        @State private var touchTick = 0
        @State private var stepTick = 0
        @State private var pressed = false
        @State private var hintPulse = false
        @State private var touchTravel: CGFloat = 0
        @State private var touchStarted: Date?
        @State private var anchorY: CGFloat?
        @State private var latestY: CGFloat?
        @State private var holdTask: Task<Void, Never>?
        /// Bumped when a touch is finished, so a deferred cancellation reset cannot also fire the tap.
        @State private var touchEpoch = 0
        /// Resets when a scroll view cancels the drag, which does not call `onEnded`.
        @GestureState private var fingerDown = false

        var body: some View {
            label()
                .scaleEffect(pressed ? 1.06 : 1)
                .overlay {
                    if !armed {
                        Circle()
                            .stroke(hintColor.opacity(hintPulse ? 0 : 0.55), lineWidth: 2)
                            .scaleEffect(hintPulse ? 1.22 : 0.92)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if armed {
                        PortionDragTrack(multiplier: live, range: range, onPhoto: trackOnPhoto)
                            .fixedSize()
                            .offset(x: -84)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .contentShape(Rectangle())
                .simultaneousGesture(pointer)
                .onAppear {
                    live = multiplier
                    withAnimation(.easeOut(duration: 1.05).repeatCount(3, autoreverses: false)) {
                        hintPulse = true
                    }
                }
                .onChange(of: multiplier) { _, newValue in
                    if !armed { live = newValue }
                }
                .onChange(of: fingerDown) { _, down in
                    if down {
                        beginHold()
                    } else {
                        // A scroll cancellation never calls `onEnded`. Wait one turn so a real
                        // lift can claim the tap first; if it does not, only reset the control.
                        let epoch = touchEpoch
                        Task { @MainActor in
                            await Task.yield()
                            guard epoch == touchEpoch else { return }
                            finishTouch(allowTap: false)
                        }
                    }
                }
                .sensoryFeedback(.impact(weight: .light, intensity: 0.55), trigger: touchTick)
                .sensoryFeedback(.selection, trigger: stepTick)
                .accessibilityElement(children: .combine)
                .accessibilityAdjustableAction { direction in
                    let next: Double
                    switch direction {
                    case .increment:
                        next = min(range.upperBound, multiplier + step)
                    case .decrement:
                        next = max(range.lowerBound, multiplier - step)
                    @unknown default:
                        return
                    }
                    onChange(next)
                }
        }

        /// Follows the finger without taking the scroll. The hold timer, not this drag, arms the control.
        private var pointer: some Gesture {
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .updating($fingerDown) { _, state, _ in
                    state = true
                }
                .onChanged { value in
                    latestY = value.location.y
                    touchTravel = max(touchTravel, hypot(value.translation.width, value.translation.height))
                    guard armed, let origin else { return }
                    if anchorY == nil {
                        anchorY = value.location.y
                        return
                    }
                    guard let anchorY else { return }
                    let next = PortionDragMath.multiplier(
                        start: origin,
                        translationY: value.location.y - anchorY,
                        step: step,
                        range: range
                    )
                    if abs(next - live) > 0.001 {
                        stepTick += 1
                        live = next
                        onChange(next)
                    }
                }
                .onEnded { _ in
                    finishTouch(allowTap: true)
                }
        }

        /// Starts a fresh hold. `LongPressGesture.onChanged` runs at touch-down, so the arm waits on this timer instead.
        private func beginHold() {
            holdTask?.cancel()
            touchTravel = 0
            touchStarted = Date()
            origin = nil
            anchorY = nil
            armed = false
            pressed = true
            touchTick += 1
            holdTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled, fingerDown, touchTravel < 24 else { return }
                origin = multiplier
                live = multiplier
                anchorY = latestY
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    armed = true
                }
            }
        }

        /// Clears every touch flag. Only a real finger-lift may open the editor or the bolus calculator.
        private func finishTouch(allowTap: Bool) {
            guard pressed || armed || holdTask != nil else { return }
            holdTask?.cancel()
            holdTask = nil
            let travel = touchTravel
            let wasArmed = armed
            let elapsed = touchStarted.map { Date().timeIntervalSince($0) } ?? 0
            touchEpoch += 1
            touchStarted = nil
            touchTravel = 0
            latestY = nil
            origin = nil
            anchorY = nil
            withAnimation(.easeOut(duration: 0.18)) {
                armed = false
                pressed = false
            }
            if allowTap, !wasArmed, travel < 12, elapsed < 0.32 {
                onTap?()
            }
        }
    }

    /// Separate vertical scale shown while a portion drag is active.
    struct PortionDragTrack: View {
        var multiplier: Double
        var range: ClosedRange<Double>
        var onPhoto: Bool = true

        var body: some View {
            VStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.caption2.weight(.bold))
                Text(String(localized: "MORE", comment: "Portion drag increase"))
                    .font(.system(size: 9, weight: .bold))
                Capsule()
                    .fill(Color.white.opacity(0.35))
                    .frame(width: 3, height: 36)
                Text("× \(Self.label(multiplier))")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white))
                    .foregroundStyle(.black)
                Capsule()
                    .fill(Color.white.opacity(0.35))
                    .frame(width: 3, height: 36)
                Text(String(localized: "LESS", comment: "Portion drag decrease"))
                    .font(.system(size: 9, weight: .bold))
                Image(systemName: "minus")
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(onPhoto ? Color.white : Color.primary)
            .padding(.vertical, 10)
            .padding(.horizontal, 8)
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(onPhoto ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color(UIColor.secondarySystemBackground)))
            }
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.primary.opacity(onPhoto ? 0.28 : 0.12), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            .accessibilityHidden(true)
        }

        static func label(_ value: Double) -> String {
            if abs(value - value.rounded()) < 0.05 {
                return String(format: "%.0f", value)
            }
            return String(format: "%.1f", value)
        }
    }

    struct FoodSourceBadgeIcon: View {
        var source: FoodSourceID
        var size: CGFloat = 14

        var body: some View {
            switch source {
            case .openFoodFacts:
                FoodSourceMark(letters: "OFF", fill: Color(red: 0.13, green: 0.55, blue: 0.24))
                    .frame(width: size + 10, height: size)
            case .usda:
                FoodSourceMark(letters: "USDA", fill: Color(red: 0.12, green: 0.27, blue: 0.55))
                    .frame(width: size + 16, height: size)
            case .ah:
                FoodSourceMark(letters: "AH", fill: Color(red: 0.0, green: 0.36, blue: 0.72))
                    .frame(width: size + 6, height: size)
            case .web:
                Image(systemName: "globe")
                    .font(.system(size: size - 2, weight: .semibold))
            case .aiEstimate:
                Image(systemName: "sparkles")
                    .font(.system(size: size - 2, weight: .semibold))
            }
        }
    }

    private struct FoodSourceMark: View {
        var letters: String
        var fill: Color

        var body: some View {
            Text(letters)
                .font(.system(size: 8, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(fill, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                .accessibilityHidden(true)
        }
    }

    struct MealMacroOverlay: View {
        var carbs: Double
        var fat: Double
        var protein: Double
        var fiber: Double
        var calories: Double

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(PortionDragTrack.label(carbs))
                        .font(.system(size: 52, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0.36, green: 0.62, blue: 0.98))
                    Text(String(localized: "g carbs", comment: "FoodFinder carbs hero unit"))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                }
                HStack(spacing: 12) {
                    labeled(String(localized: "Fat", comment: "Fat macro"), fat, Color(red: 0.98, green: 0.78, blue: 0.22))
                    labeled(String(localized: "Protein", comment: "Protein macro"), protein, Color(red: 0.96, green: 0.45, blue: 0.45))
                    labeled(String(localized: "Fiber", comment: "Fiber macro"), fiber, Color(red: 0.45, green: 0.82, blue: 0.55))
                    Text("\(Int(calories.rounded())) kcal")
                        .foregroundStyle(.white)
                }
                .font(.subheadline.weight(.semibold))
            }
            .shadow(color: .black.opacity(0.55), radius: 6, y: 2)
        }

        private func labeled(_ title: String, _ value: Double, _ color: Color) -> some View {
            HStack(spacing: 3) {
                Text(PortionDragTrack.label(value))
                Text(title)
            }
            .foregroundStyle(color)
        }
    }

    struct MealGlassIconButton: View {
        var systemImage: String
        var filled: Bool = false
        var accessibilityLabel: String

        var body: some View {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background {
                    if filled {
                        Circle().fill(Color(red: 0.18, green: 0.48, blue: 0.95))
                    } else {
                        Circle().fill(.ultraThinMaterial)
                    }
                }
                .overlay(Circle().stroke(Color.white.opacity(filled ? 0 : 0.35), lineWidth: 0.6))
                .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
                .accessibilityLabel(accessibilityLabel)
        }
    }

    struct MealPhotoViewer: View {
        let image: UIImage
        let title: String
        var subtitle: String?
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            ZStack {
                Color.black.ignoresSafeArea()
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack {
                    HStack {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(width: 40, height: 40)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .accessibilityLabel(String(localized: "Close photo", comment: "Close the full-screen meal photo"))
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    Spacer()
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.title3.bold())
                            .foregroundStyle(.white)
                        if let subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .background(
                        LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .top, endPoint: .bottom)
                    )
                }
            }
        }
    }

    struct GramAmountEditor: View {
        let name: String
        @State var text: String
        var onSave: (Double) -> Void
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            NavigationStack {
                Form {
                    Section {
                        TextField("0", text: $text)
                            .keyboardType(.decimalPad)
                    } header: {
                        Text(name)
                    } footer: {
                        Text(String(localized: "Grams of carbohydrate for this ingredient.", comment: "Ingredient gram editor footer"))
                    }
                }
                .navigationTitle(String(localized: "Amount", comment: "Ingredient gram editor title"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Cancel", comment: "Cancel gram edit")) { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Done", comment: "Save gram edit")) {
                            let parsed = Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0
                            onSave(max(0, parsed))
                            dismiss()
                        }
                    }
                }
            }
            .presentationDetents([.height(220)])
        }
    }
}
