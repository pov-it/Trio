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
//  Transient-frame debounce:
//  The keyboard frame iOS reports includes the QuickType / autocorrect
//  suggestion bar. During a focus hand-off where the keyboard stays up but the
//  first responder swaps (FoodFinder expand → collapse moves focus between the
//  expanded TextEditor and the compact TextField), iOS briefly fires a *shrink*
//  — the suggestion bar drops for a frame and then returns. If that transient
//  short frame is the last value we read, the bar is under-padded by roughly the
//  suggestion-bar height and tucks under the keyboard. We therefore apply growth
//  immediately but defer shrinks slightly; a shrink that is followed by the
//  keyboard returning to full height is discarded.
//

import Combine
import SwiftUI
import UIKit

extension View {
    /// Apply this near the root of a view that contains a TextField at the
    /// bottom (chat input, FoodFinder composer, etc.) so the input remains
    /// visible while the keyboard is up.
    func aiInsightsKeyboardAdaptive(bottomSpacing: CGFloat = 0) -> some View {
        modifier(AIInsightsKeyboardAdaptive(bottomSpacing: bottomSpacing))
    }
}

private struct AIInsightsKeyboardAdaptive: ViewModifier {
    let bottomSpacing: CGFloat
    @StateObject private var tracker = KeyboardTracker()

    func body(content: Content) -> some View {
        content
            .padding(.bottom, max(0, tracker.height - bottomSpacing))
            // Tell SwiftUI not to also try its own avoidance — otherwise it
            // sometimes double-applies and pushes content off-screen.
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .animation(.easeOut(duration: 0.25), value: tracker.height)
            .onAppear { tracker.subscribe() }
    }
}

/// Observes the system keyboard frame and exposes the height the input bar must
/// clear, debouncing transient shrinks (see file header).
private final class KeyboardTracker: ObservableObject {
    @Published var height: CGFloat = 0

    private var observers: [NSObjectProtocol] = []
    private var pendingShrink: DispatchWorkItem?
    private var subscribed = false

    func subscribe() {
        guard !subscribed else { return }
        subscribed = true

        // Use the fully-qualified Foundation type because Trio defines its own
        // `NotificationCenter` protocol (for DI) that shadows the Foundation
        // class at module scope.
        let center = Foundation.NotificationCenter.default

        // willChange tracks the keyboard live as it animates; didChange/didShow
        // fire once it has settled. Observing all three keeps the height honest
        // across the focus hand-off described in the file header.
        let frameNotifications: [Notification.Name] = [
            UIResponder.keyboardWillChangeFrameNotification,
            UIResponder.keyboardDidChangeFrameNotification,
            UIResponder.keyboardDidShowNotification
        ]
        for name in frameNotifications {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    self?.handleFrame(note)
                }
            )
        }
        observers.append(
            center.addObserver(
                forName: UIResponder.keyboardWillHideNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.requestHeight(0)
            }
        )
    }

    private func handleFrame(_ note: Notification) {
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let screenH = UIScreen.main.bounds.height
        // When the keyboard is hidden iOS reports an off-screen frame
        // (origin.y == screenH). Anything above that is the visible keyboard
        // portion (including the QuickType bar) we need to pad for.
        let visible = max(0, screenH - frame.origin.y)
        let bottomInset = Self.currentBottomSafeInset()
        requestHeight(max(0, visible - bottomInset))
    }

    private func requestHeight(_ newHeight: CGFloat) {
        pendingShrink?.cancel()
        pendingShrink = nil

        // Grow immediately so the bar never lags behind a rising keyboard.
        if newHeight >= height {
            height = newHeight
            return
        }

        // Defer shrinks: a real dismiss settles after the delay, while a
        // transient drop during a focus swap is cancelled by the next growth.
        let work = DispatchWorkItem { [weak self] in self?.height = newHeight }
        pendingShrink = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// The current bottom safe-area inset (home-indicator area). The keyboard
    /// frame already includes this region, so subtracting it avoids
    /// over-padding the input bar.
    private static func currentBottomSafeInset() -> CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: \.isKeyWindow)?
            .safeAreaInsets.bottom ?? 0
    }

    deinit {
        let center = Foundation.NotificationCenter.default
        observers.forEach { center.removeObserver($0) }
    }
}
