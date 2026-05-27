//
//  AIInsightsKeyboardAdaptive.swift
//  Trio
//
//  Keyboard-avoidance helper used by the AI chat and FoodFinder input bars.
//
//  Why this exists:
//  SwiftUI's built-in keyboard avoidance lifts the entire view that owns a
//  focused TextField. When the view is wrapped inside a NavigationStack
//  presented from a sheet (TreatmentsRootView → FoodFinder) or has a
//  `.background()` that extends beyond the safe area, the auto-lift can
//  fail silently — the keyboard then covers the input field with no visible
//  recovery. Observing the keyboard frame via NotificationCenter and
//  applying it as bottom-padding is the reliable iOS-13-style fallback.
//

import Combine
import SwiftUI
import UIKit

extension View {
    /// Apply this near the root of a view that contains a TextField at the
    /// bottom (chat input, FoodFinder composer, etc.) so the input remains
    /// visible while the keyboard is up.
    func aiInsightsKeyboardAdaptive() -> some View {
        modifier(AIInsightsKeyboardAdaptive())
    }
}

private struct AIInsightsKeyboardAdaptive: ViewModifier {
    @State private var keyboardHeight: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .padding(.bottom, keyboardHeight)
            // Tell SwiftUI not to also try its own avoidance — otherwise it
            // sometimes double-applies and pushes content off-screen.
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .animation(.easeOut(duration: 0.25), value: keyboardHeight)
            .onAppear(perform: subscribe)
    }

    private func subscribe() {
        let center = NotificationCenter.default
        center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification,
                           object: nil, queue: .main) { note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let screenH = UIScreen.main.bounds.height
            // When the keyboard is hidden iOS reports an off-screen frame
            // (origin.y == screenH). Anything above that is the visible
            // keyboard portion we need to pad for.
            let visible = max(0, screenH - frame.origin.y)
            let bottomInset = currentBottomSafeInset()
            self.keyboardHeight = max(0, visible - bottomInset)
        }
        center.addObserver(forName: UIResponder.keyboardWillHideNotification,
                           object: nil, queue: .main) { _ in
            self.keyboardHeight = 0
        }
    }

    /// The current bottom safe-area inset (home-indicator area). The
    /// keyboard frame already includes this region, so subtracting it
    /// avoids over-padding the input bar.
    private func currentBottomSafeInset() -> CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: \.isKeyWindow)?
            .safeAreaInsets.bottom ?? 0
    }
}
