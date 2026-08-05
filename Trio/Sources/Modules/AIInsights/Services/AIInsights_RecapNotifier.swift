//
//  AIInsights_RecapNotifier.swift
//  Trio
//
//  Local notification + foreground catch-up trigger for the MONTHLY periodic
//  recap (Feature R).
//
//  Two responsibilities live here:
//    1. `RecapNotifier` — a tiny wrapper around UNUserNotificationCenter that
//       requests notification authorization on first use and posts an immediate
//       local notification when a monthly recap has been generated. It uses a
//       DISTINCT identifier/category (`ai_insights_recap`) so it never touches
//       the app's glucose-alert / not-looping notification categories.
//    2. `RecapForegroundCoordinator` — the launch / return-to-foreground hook.
//       It runs a cheap calendar-month gate first and only spins up the recap
//       pipeline (reusing RecapStateModel so the AI config source is identical
//       to the recap screen) when a monthly recap is actually due this month.
//
//  This path is FOREGROUND CATCH-UP ONLY — no BGTaskScheduler, no background
//  modes, no Info.plist / entitlement changes (those would touch the signed
//  pump build). It only ever reads/analyzes data and posts an informational
//  notification; it never influences dosing.
//

import Foundation
import Swinject
import UserNotifications

extension AIInsights {

    /// Thin wrapper around UNUserNotificationCenter for the monthly-recap
    /// notification. Uses a dedicated identifier/category so it is fully
    /// isolated from the glucose-alert notification categories.
    enum RecapNotifier {

        /// Distinct category/identifier prefix — must NOT collide with any of
        /// the app's existing (glucose / not-looping) notification categories.
        static let categoryIdentifier = "ai_insights_recap"
        private static let requestIdentifier = "ai_insights_recap_notification"

        /// Request notification authorization once, only when the current status
        /// is `.notDetermined`. If the user has denied notifications we silently
        /// no-op (we never re-prompt, and we never post). Returns whether we are
        /// authorized to post after the check.
        @discardableResult
        static func requestAuthorizationIfNeeded() async -> Bool {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                return true
            case .denied:
                return false
            case .notDetermined:
                let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
                return granted
            @unknown default:
                return false
            }
        }

        /// Post an immediate local notification for a freshly generated monthly
        /// recap. `trigger: nil` delivers it right away. Does nothing if the app
        /// is not authorized to post notifications.
        static func postMonthlyRecapNotification(title recapTitle: String, body recapBody: String) async {
            guard await requestAuthorizationIfNeeded() else { return }

            let content = UNMutableNotificationContent()
            content.title = String(localized: "Maandelijkse recap", comment: "Monthly recap notification title")
            content.body = summaryLine(title: recapTitle, body: recapBody)
            content.sound = .default
            content.categoryIdentifier = categoryIdentifier

            // A stable identifier means a newer monthly recap replaces any still
            // pending one instead of stacking up.
            let request = UNNotificationRequest(
                identifier: requestIdentifier,
                content: content,
                trigger: nil
            )
            try? await UNUserNotificationCenter.current().add(request)
        }

        /// Build the notification body: prefer the recap title, otherwise the
        /// first non-empty line of the recap body, truncated to ~120 chars.
        private static func summaryLine(title recapTitle: String, body recapBody: String) -> String {
            let trimmedTitle = recapTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate: String
            if !trimmedTitle.isEmpty {
                candidate = trimmedTitle
            } else {
                let firstLine = recapBody
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .first { !$0.isEmpty } ?? ""
                candidate = firstLine
            }
            return truncate(candidate, to: 120)
        }

        private static func truncate(_ text: String, to maxLength: Int) -> String {
            guard text.count > maxLength else { return text }
            let end = text.index(text.startIndex, offsetBy: maxLength)
            return String(text[text.startIndex..<end]).trimmingCharacters(in: .whitespaces) + "…"
        }
    }

    /// Launch / return-to-foreground hook for the monthly recap catch-up.
    ///
    /// Wired from `TrioApp`'s `scenePhase == .active` branch inside a detached
    /// Task so it never blocks launch. It performs a cheap calendar-month gate
    /// before doing anything expensive; only when a monthly recap is genuinely
    /// due does it construct a `RecapStateModel` (which reads the exact same AI
    /// provider/apiKey/baseURL/model config the recap screen uses) and generate.
    enum RecapForegroundCoordinator {

        /// Runs the monthly catch-up if — and only if — a monthly recap is due
        /// for the current calendar month. On successful generation it fires the
        /// local notification. Silent on any failure (mirrors the recap screen's
        /// auto-generate path). Safe to call repeatedly (idempotent per month).
        @MainActor
        static func runMonthlyCatchUpIfDue(resolver: Resolver, at now: Date = Date()) async {
            // Cheap gate first: avoid resolving services / building context when
            // there is nothing to do (the common case on most launches).
            guard PeriodicRecapService.shared.isMonthlyRecapDueThisMonth(at: now) else { return }

            // Reuse the recap screen's state model so the AI configuration source
            // (keychain `ai_insights_api_key`, settings aiProvider/aiBaseURL/
            // aiModel) is identical — assigning `resolver` wires the provider and
            // calls `subscribe()`.
            let state = RecapStateModel()
            state.resolver = resolver
            await state.generateMonthlyRecapIfDueThisMonth(at: now)
        }
    }
}
