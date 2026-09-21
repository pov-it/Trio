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
//  applying it as bottom-padding is the reliable fallback.
//
//  Transient-frame debounce:
//  The keyboard frame iOS reports includes the QuickType suggestion bar.
//  During the expand→collapse focus swap (the expanded TextEditor hands off
//  to the compact TextField while the keyboard stays up) iOS briefly fires a
//  *shrink* notification as the QuickType bar momentarily drops. If that
//  transient short frame is the last value we read the bar is under-padded
//  by roughly the suggestion-bar height (~44 pt) and tucks under the keyboard.
//  Growth is applied immediately; shrinks are deferred 0.25 s. A shrink
//  followed by the keyboard returning to full height within that window is
//  discarded, so the bar holds its position through the swap.
//
//  Implementation note — why @State, not @StateObject:
//  The modifier is applied from a shared call-site with a parameter that
//  changes (bottomSpacing flips with isComposerExpanded). Using @StateObject
//  here caused the view to become non-responsive or have its input bar
//  disappear in certain presentation paths (via Treatments View sheet,
//  AI Hub navigation, or widget deep-link). Keeping keyboard height in plain
//  @State keeps the update cycle local to the modifier and is stable across
//  all presentation contexts. The debounce work item is held in a tiny
//  reference-type box stored inside @State so it survives re-renders without
//  triggering additional SwiftUI invalidations.
//

import SwiftUI
import UIKit

// MARK: - Public extension

extension View {
    /// Apply this near the root of a view that contains a TextField at the
    /// bottom (chat input, FoodFinder composer, etc.) so the input remains
    /// visible while the keyboard is up.
    func aiInsightsKeyboardAdaptive(bottomSpacing: CGFloat = 0) -> some View {
        modifier(AIInsightsKeyboardAdaptive(bottomSpacing: bottomSpacing))
    }
}

// MARK: - ViewModifier

private struct AIInsightsKeyboardAdaptive: ViewModifier {
    let bottomSpacing: CGFloat

    @State private var keyboardHeight: CGFloat = 0
    @State private var hasSubscribed = false
    @State private var debounce = ShrinkDebounce()

    func body(content: Content) -> some View {
        content
            .padding(.bottom, max(0, keyboardHeight - bottomSpacing))
            // Tell SwiftUI not to also try its own avoidance — otherwise it
            // sometimes double-applies and pushes content off-screen.
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .animation(.easeOut(duration: 0.25), value: keyboardHeight)
            .onAppear(perform: subscribeOnce)
    }

    // MARK: Subscription

    private func subscribeOnce() {
        guard !hasSubscribed else { return }
        hasSubscribed = true

        // Use the fully-qualified Foundation type because Trio defines its own
        // `NotificationCenter` protocol (for DI) that shadows the Foundation
        // class at module scope.
        let center = Foundation.NotificationCenter.default

        // willChange tracks the keyboard live; didChange/didShow fire after it
        // has settled. Registering all three ensures we catch both the live
        // frame and the final resting frame across all keyboard transitions,
        // including the momentary shrink during a focus hand-off.
        for name in [
            UIResponder.keyboardWillChangeFrameNotification,
            UIResponder.keyboardDidChangeFrameNotification,
            UIResponder.keyboardDidShowNotification
        ] {
            center.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
                else { return }
                let screenH = UIScreen.main.bounds.height
                // iOS reports an off-screen frame (origin.y == screenH) when the
                // keyboard is hidden — visible is 0 in that case.
                let visible = max(0, screenH - frame.origin.y)
                let inset = currentBottomSafeInset()
                applyHeight(max(0, visible - inset))
            }
        }

        center.addObserver(forName: UIResponder.keyboardWillHideNotification,
                           object: nil, queue: .main) { _ in
            applyHeight(0)
        }
    }

    // MARK: Height management

    /// Apply `newHeight`, immediately for growth, deferred for shrinks.
    ///
    /// The deferred path handles the transient QuickType-bar drop that fires
    /// during the expand→collapse focus swap: if the keyboard returns to full
    /// height within 0.25 s the pending shrink is cancelled and the bar stays
    /// put. Real keyboard dismissals settle after the delay.
    private func applyHeight(_ newHeight: CGFloat) {
        debounce.pending?.cancel()
        debounce.pending = nil

        if newHeight >= keyboardHeight {
            // Growth or same height — commit immediately.
            keyboardHeight = newHeight
            return
        }

        // Shrink — defer so a transient drop can be discarded.
        let work = DispatchWorkItem { keyboardHeight = newHeight }
        debounce.pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    // MARK: Helpers

    /// Returns the bottom safe-area inset (home-indicator area). The keyboard
    /// frame already covers this region, so subtracting it avoids over-padding.
    private func currentBottomSafeInset() -> CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: \.isKeyWindow)?
            .safeAreaInsets.bottom ?? 0
    }
}

// MARK: - Debounce box

/// A tiny reference-type container held in `@State` so the pending work item
/// survives SwiftUI re-renders without triggering additional invalidations.
/// Mutations go through the reference, never through @State's setter.
private final class ShrinkDebounce {
    var pending: DispatchWorkItem?
}
