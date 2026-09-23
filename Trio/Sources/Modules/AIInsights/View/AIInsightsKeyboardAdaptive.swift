//
//  AIInsightsKeyboardAdaptive.swift
//  Trio
//
//  Keyboard-avoidance helper used by the AI chat input bar.
//  FoodFinder does not use this modifier or the old view-frame dock. It pads
//  the composer from the window keyboard layout guide (see
//  `AIInsightsComposerKeyboardProbe`) so the first show after launch and a
//  finger drag do not fight SwiftUI's keyboard safe area.
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
    /// bottom (chat input) so the input remains visible while the keyboard is
    /// up. FoodFinder uses `aiInsightsComposerKeyboardLift` instead: the chat
    /// modifier ignores the keyboard safe area, which double-lifted the
    /// FoodFinder bar.
    func aiInsightsKeyboardAdaptive(bottomSpacing: CGFloat = 0) -> some View {
        modifier(AIInsightsKeyboardAdaptive(bottomSpacing: bottomSpacing))
    }

    /// Report the keyboard lift for a bottom composer.
    ///
    /// The lift is the keyboard's overlap with the window, minus the
    /// home-indicator inset measured while the keyboard is hidden. It does
    /// not read this view's frame, so padding the composer cannot feed back
    /// into the next measurement (that loop flickered drag-down).
    ///
    /// Pass `isDragging: true` while a finger is moving the bar. Updates are
    /// held and delivered once when the drag ends.
    func aiInsightsComposerKeyboardLift(
        isDragging: Bool,
        onLift: @escaping (CGFloat) -> Void
    ) -> some View {
        background {
            AIInsightsComposerKeyboardProbe(isDragging: isDragging, onLift: onLift)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// Drop keyboard safe area on every enclosing hosting controller.
    ///
    /// FoodFinder then has one lift (the composer pad above), including the
    /// Treatments sheet whose host is created after the root scene-active
    /// strip. Hub's root host is already `.container`; setting it again is a
    /// no-op.
    func aiInsightsStripKeyboardSafeArea() -> some View {
        background(alignment: .topLeading) {
            AIInsightsKeyboardSafeAreaStrip()
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
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

// MARK: - Keyboard lift math

/// Pure keyboard-lift math shared by the FoodFinder composer probe and tests.
///
/// `overlap` is the old view-frame dock. FoodFinder no longer applies it:
/// measuring the padded view and writing that measurement back as padding
/// flickered while the bar was dragged, and the first layout after a cold
/// launch often still had a zero frame so the lift stayed 0.
enum AIInsightsKeyboardDockMath {
    static func overlap(
        viewFrame: CGRect,
        keyboardFrame: CGRect,
        appliedPad: CGFloat = 0
    ) -> CGFloat? {
        guard viewFrame.width > 1 else { return nil }
        guard keyboardFrame.height > 1 else { return 0 }
        let unpaddedMaxY = viewFrame.maxY + max(0, appliedPad)
        if keyboardFrame.minY >= unpaddedMaxY - 1 { return 0 }
        return max(0, unpaddedMaxY - keyboardFrame.minY)
    }

    /// Distance from the keyboard's top to the bottom of the window.
    /// A hidden keyboard and a frame taller than the window (bad coordinate
    /// space on the first notification) report 0.
    static func windowCover(keyboardMinY: CGFloat, keyboardHeight: CGFloat, windowHeight: CGFloat) -> CGFloat {
        guard windowHeight > 1, keyboardHeight > 1 else { return 0 }
        if keyboardMinY >= windowHeight - 1 { return 0 }
        let cover = windowHeight - keyboardMinY
        guard cover > 0, cover <= windowHeight else { return 0 }
        return cover
    }

    /// Extra pad for a composer that already sits above the home indicator.
    ///
    /// `restingBottomInset` must be the home-indicator inset from while the
    /// keyboard was hidden. Reading `safeAreaInsets.bottom` while the keyboard
    /// is up can return the keyboard height and cancel the lift — that was
    /// the cold-start miss.
    static func composerLift(windowCover: CGFloat, restingBottomInset: CGFloat) -> CGFloat {
        let cover = max(0, windowCover)
        let inset = max(0, restingBottomInset)
        if cover <= inset + 1 { return 0 }
        return cover - inset
    }

    /// Home-indicator sized covers update the resting inset. Keyboard-sized
    /// covers do not, so a keyboard show cannot overwrite it.
    static func restingBottomInset(current: CGFloat, windowCover: CGFloat, safeAreaBottom: CGFloat) -> CGFloat {
        guard windowCover < 80 else { return max(0, current) }
        if windowCover > 1 { return windowCover }
        if safeAreaBottom > 0, safeAreaBottom < 80 { return safeAreaBottom }
        return max(0, current)
    }
}

// MARK: - Composer keyboard probe

/// Tracks `UIWindow.keyboardLayoutGuide` and keyboard notifications, and
/// reports a single composer lift. Dragging freezes delivery so the finger
/// is the only thing moving the bar.
struct AIInsightsComposerKeyboardProbe: UIViewRepresentable {
    var isDragging: Bool
    var onLift: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.coordinator = context.coordinator
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        context.coordinator.onLift = onLift
        context.coordinator.isDragging = isDragging
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        let wasDragging = context.coordinator.isDragging
        context.coordinator.onLift = onLift
        context.coordinator.isDragging = isDragging
        uiView.coordinator = context.coordinator
        if wasDragging && !isDragging {
            context.coordinator.flush()
        }
    }

    static func dismantleUIView(_ uiView: ProbeView, coordinator: Coordinator) {
        uiView.teardown()
    }

    final class Coordinator {
        var onLift: (CGFloat) -> Void = { _ in }
        var isDragging = false
        var restingBottomInset: CGFloat = 0
        fileprivate var latestLift: CGFloat = 0
        private var lastEmitted: CGFloat = -1
        private var guideCover: CGFloat = 0
        private var notificationCover: CGFloat = 0
        private var guideHasTrackedKeyboard = false
        private var holdingFallback = false
        private var emitScheduled = false
        private var fallbackToken = UUID()

        func noteSafeArea(bottom: CGFloat, windowCover: CGFloat) {
            restingBottomInset = AIInsightsKeyboardDockMath.restingBottomInset(
                current: restingBottomInset,
                windowCover: windowCover,
                safeAreaBottom: bottom
            )
        }

        func guideMoved(cover: CGFloat, safeAreaBottom: CGFloat) {
            noteSafeArea(bottom: safeAreaBottom, windowCover: cover)
            guideCover = max(0, cover)
            if guideCover > restingBottomInset + 20 {
                guideHasTrackedKeyboard = true
            }
            publishGuide()
        }

        /// `didHide` forces the lift to zero. Other hide notifications only
        /// cancel a pending first-show fallback so the layout guide can track
        /// the keyboard down. Show notifications arm that fallback; they do
        /// not jump the bar to the end frame ahead of the guide.
        func notificationMoved(cover: CGFloat, safeAreaBottom: CGFloat, phase: KeyboardPhase) {
            switch phase {
            case .hide:
                fallbackToken = UUID()
                notificationCover = 0
                holdingFallback = false
            case .didHide:
                fallbackToken = UUID()
                notificationCover = 0
                guideCover = 0
                guideHasTrackedKeyboard = false
                holdingFallback = false
                schedule(0)
            case .change:
                guard cover > 1 else { return }
                noteSafeArea(bottom: safeAreaBottom, windowCover: cover)
                notificationCover = cover
            case .show:
                guard cover > 1 else { return }
                noteSafeArea(bottom: safeAreaBottom, windowCover: cover)
                notificationCover = cover
                armFirstShowFallback()
            }
        }

        func flush() {
            schedule(latestLift)
        }

        private func armFirstShowFallback() {
            let token = UUID()
            fallbackToken = token
            let cover = notificationCover
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self, self.fallbackToken == token else { return }
                // The guide already moved the bar. Don't yank it to the
                // notification's end frame and then back.
                guard self.latestLift < 1 else { return }
                let lift = self.composerLift(for: cover)
                guard lift > 1 else { return }
                self.holdingFallback = true
                self.schedule(lift)
            }
        }

        private func publishGuide() {
            let lift = composerLift(for: guideCover)
            if holdingFallback {
                // Keep the first-show fallback until the guide actually
                // arrives at the keyboard. Early resting frames must not
                // pull the bar back under it.
                if lift + 24 >= latestLift || notificationCover <= 1 {
                    holdingFallback = false
                    schedule(lift)
                }
                return
            }
            // While a show notification is pending and the guide is still
            // resting, keep the last lift. A resting guide reporting 0 must
            // not cancel the first-show fallback.
            if guideHasTrackedKeyboard || lift > 1 || notificationCover <= 1 {
                schedule(lift)
            }
        }

        private func composerLift(for cover: CGFloat) -> CGFloat {
            AIInsightsKeyboardDockMath.composerLift(
                windowCover: cover,
                restingBottomInset: restingBottomInset
            )
        }

        private func schedule(_ lift: CGFloat) {
            latestLift = lift
            guard !isDragging else { return }
            guard abs(lift - lastEmitted) > 0.5 else { return }
            guard !emitScheduled else { return }
            emitScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.emitScheduled = false
                guard !self.isDragging else { return }
                let lift = self.latestLift
                guard abs(lift - self.lastEmitted) > 0.5 else { return }
                self.lastEmitted = lift
                let callback = self.onLift
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    callback(lift)
                }
            }
        }
    }

    enum KeyboardPhase {
        case change
        case show
        case hide
        case didHide
    }

    final class ProbeView: UIView {
        weak var coordinator: Coordinator?
        private let tracker = HeightTracker()
        private var observations: [NSObjectProtocol] = []
        private var installedWindow: UIWindow?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                teardown()
                return
            }
            stripEnclosingHosts()
            installIfNeeded()
        }

        /// Hosting controllers above this probe keep keyboard safe area unless
        /// told otherwise. Strip them as soon as the probe is on screen, which
        /// is before the first focus, so SwiftUI does not also inset the bar.
        private func stripEnclosingHosts() {
            var responder: UIResponder? = self
            while let current = responder {
                (current as? KeyboardSafeAreaExcludable)?.excludeKeyboardFromSafeArea()
                responder = current.next
            }
        }

        func teardown() {
            let center = Foundation.NotificationCenter.default
            for token in observations {
                center.removeObserver(token)
            }
            observations.removeAll()
            tracker.removeFromSuperview()
            installedWindow = nil
        }

        private func installIfNeeded() {
            guard let window, installedWindow !== window else { return }
            teardown()
            installedWindow = window

            tracker.isUserInteractionEnabled = false
            tracker.backgroundColor = .clear
            tracker.alpha = 0
            tracker.isAccessibilityElement = false
            window.addSubview(tracker)
            tracker.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                tracker.leadingAnchor.constraint(equalTo: window.leadingAnchor),
                tracker.trailingAnchor.constraint(equalTo: window.trailingAnchor),
                tracker.bottomAnchor.constraint(equalTo: window.bottomAnchor),
                tracker.topAnchor.constraint(equalTo: window.keyboardLayoutGuide.topAnchor)
            ])
            tracker.onHeight = { [weak self] height in
                guard let self, let window = self.window ?? self.installedWindow else { return }
                self.coordinator?.guideMoved(cover: height, safeAreaBottom: window.safeAreaInsets.bottom)
            }
            // Seed the home-indicator inset while the keyboard is still hidden
            // so the first show does not treat that inset as zero and over-pad,
            // or — if UIKit has already folded the keyboard into the safe area —
            // subtract the keyboard away.
            coordinator?.noteSafeArea(bottom: window.safeAreaInsets.bottom, windowCover: 0)

            let center = Foundation.NotificationCenter.default
            let names: [(Notification.Name, KeyboardPhase)] = [
                (UIResponder.keyboardWillChangeFrameNotification, .change),
                (UIResponder.keyboardDidChangeFrameNotification, .change),
                (UIResponder.keyboardWillShowNotification, .show),
                (UIResponder.keyboardDidShowNotification, .show),
                (UIResponder.keyboardWillHideNotification, .hide),
                (UIResponder.keyboardDidHideNotification, .didHide)
            ]
            for (name, phase) in names {
                let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    self?.handle(note, phase: phase)
                }
                observations.append(token)
            }
        }

        private func handle(_ note: Notification, phase: KeyboardPhase) {
            guard let window = window ?? installedWindow else { return }
            let cover: CGFloat
            switch phase {
            case .hide, .didHide:
                cover = 0
            case .change, .show:
                guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
                let inWindow = window.convert(frame, from: nil)
                cover = AIInsightsKeyboardDockMath.windowCover(
                    keyboardMinY: inWindow.minY,
                    keyboardHeight: inWindow.height,
                    windowHeight: window.bounds.height
                )
            }
            coordinator?.notificationMoved(
                cover: cover,
                safeAreaBottom: window.safeAreaInsets.bottom,
                phase: phase
            )
        }
    }

    final class HeightTracker: UIView {
        var onHeight: ((CGFloat) -> Void)?
        private var last: CGFloat = -1

        override func layoutSubviews() {
            super.layoutSubviews()
            let height = bounds.height
            guard abs(height - last) > 0.5 else { return }
            last = height
            onHeight?(height)
        }
    }
}

/// Walks up from a zero-size child and strips keyboard safe area from every
/// enclosing `UIHostingController`.
struct AIInsightsKeyboardSafeAreaStrip: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> StripController {
        let controller = StripController()
        controller.view.isUserInteractionEnabled = false
        controller.view.backgroundColor = .clear
        return controller
    }

    func updateUIViewController(_ controller: StripController, context: Context) {
        controller.stripEnclosingHosts()
    }

    final class StripController: UIViewController {
        override func viewDidLoad() {
            super.viewDidLoad()
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            stripEnclosingHosts()
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            stripEnclosingHosts()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            stripEnclosingHosts()
            // The sheet host is sometimes not the parent until the present
            // transition attaches it. One more pass covers the first focus.
            DispatchQueue.main.async { [weak self] in
                self?.stripEnclosingHosts()
            }
        }

        func stripEnclosingHosts() {
            var current: UIViewController? = parent
            while let controller = current {
                (controller as? KeyboardSafeAreaExcludable)?.excludeKeyboardFromSafeArea()
                current = controller.parent
            }
        }
    }
}
