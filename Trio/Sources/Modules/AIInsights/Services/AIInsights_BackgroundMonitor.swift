import Foundation
import UserNotifications

// MARK: - AI Background Monitor

/// Periodically checks glucose data and sends AI-driven notifications when
/// concerning patterns are detected. Runs within Trio's existing loop cycle.
extension AIInsights {
    final class BackgroundMonitor {
        // MARK: - Configuration

        static let shared = BackgroundMonitor()

        private let monitorInterval: TimeInterval = 30 * 60 // 30 minutes
        private var lastCheckDate: Date?
        private var isEnabled: Bool = false

        private init() {}

        // MARK: - Public API

        /// Call this from Trio's main loop cycle (e.g. DeviceDataManager) to check
        /// if a background AI analysis should be triggered.
        func checkIfNeeded(
            glucose: [BloodGlucose],
            units: GlucoseUnits,
            lowThreshold: Decimal,
            highThreshold: Decimal,
            apiKey: String,
            provider: AIProvider,
            model: String,
            baseURL: String,
            enabled: Bool
        ) {
            guard enabled, !apiKey.isEmpty else { return }
            isEnabled = enabled

            let now = Date()
            if let lastCheck = lastCheckDate, now.timeIntervalSince(lastCheck) < monitorInterval {
                return // Too soon
            }

            lastCheckDate = now

            // Run pattern check on background queue
            Task.detached(priority: .utility) {
                await self.analyzePatterns(
                    glucose: glucose,
                    units: units,
                    lowThreshold: lowThreshold,
                    highThreshold: highThreshold,
                    apiKey: apiKey,
                    provider: provider,
                    model: model,
                    baseURL: baseURL
                )
            }
        }

        // MARK: - Pattern Analysis

        private func analyzePatterns(
            glucose: [BloodGlucose],
            units: GlucoseUnits,
            lowThreshold: Decimal,
            highThreshold: Decimal,
            apiKey: String,
            provider: AIProvider,
            model: String,
            baseURL: String
        ) async {
            // Only look at last 4 hours of data
            let fourHoursAgo = Date().addingTimeInterval(-4 * 3600)
            let recentGlucose = glucose.filter { $0.dateString >= fourHoursAgo }

            guard recentGlucose.count >= 6 else { return } // Need at least 30 minutes

            // Build glucose values
            let values: [Double] = recentGlucose.compactMap { gl in
                guard let val = gl.glucose ?? gl.sgv else { return nil }
                return units == .mmolL ? Double(Decimal(val).asMmolL) : Double(val)
            }

            guard !values.isEmpty else { return }

            // Check for concerning patterns locally first (cheap check before AI call)
            let alerts = detectLocalAlerts(
                values: values,
                units: units,
                low: Double(lowThreshold),
                high: Double(highThreshold)
            )

            guard !alerts.isEmpty else { return }

            // If local checks flag something, ask AI for a concise insight
            let insightText = await fetchAIInsight(
                alerts: alerts,
                values: values,
                units: units,
                apiKey: apiKey,
                provider: provider,
                model: model,
                baseURL: baseURL
            )

            if let insightText {
                await sendNotification(title: alerts.first?.title ?? "AI Insight", body: insightText)
            }
        }

        // MARK: - Local Pattern Detection (cheap, no API call)

        private struct LocalAlert {
            let type: AlertType
            let title: String

            enum AlertType {
                case rapidDrop
                case rapidRise
                case prolongedHigh
                case persistentLow
            }
        }

        private func detectLocalAlerts(values: [Double], units: GlucoseUnits, low: Double, high: Double) -> [LocalAlert] {
            var alerts: [LocalAlert] = []
            let lowThresh = units == .mmolL ? Double(Decimal(low).asMmolL) : low
            let highThresh = units == .mmolL ? Double(Decimal(high).asMmolL) : high

            // Rapid drop: last 3 readings trending down by more than 3 mg/dL per reading (or ~0.17 mmol/L)
            if values.count >= 3 {
                let last3 = Array(values.suffix(3))
                let drop = last3.first! - last3.last!
                let dropThreshold = units == .mmolL ? 1.5 : 30.0
                if drop > dropThreshold {
                    alerts.append(LocalAlert(
                        type: .rapidDrop,
                        title: String(localized: "Rapid Glucose Drop", comment: "Background alert")
                    ))
                }
            }

            // Rapid rise
            if values.count >= 3 {
                let last3 = Array(values.suffix(3))
                let rise = last3.last! - last3.first!
                let riseThreshold = units == .mmolL ? 2.0 : 40.0
                if rise > riseThreshold {
                    alerts.append(LocalAlert(
                        type: .rapidRise,
                        title: String(localized: "Rapid Glucose Rise", comment: "Background alert")
                    ))
                }
            }

            // Prolonged high: last 6+ readings all above high threshold
            if values.count >= 6 {
                let last6 = Array(values.suffix(6))
                if last6.allSatisfy({ $0 > highThresh }) {
                    alerts.append(LocalAlert(
                        type: .prolongedHigh,
                        title: String(localized: "Prolonged High", comment: "Background alert")
                    ))
                }
            }

            // Persistent low: 3+ readings below low threshold
            if values.count >= 3 {
                let last3 = Array(values.suffix(3))
                if last3.allSatisfy({ $0 < lowThresh }) {
                    alerts.append(LocalAlert(
                        type: .persistentLow,
                        title: String(localized: "Persistent Low", comment: "Background alert")
                    ))
                }
            }

            return alerts
        }

        // MARK: - AI Insight (lightweight call)

        private func fetchAIInsight(
            alerts: [LocalAlert],
            values: [Double],
            units: GlucoseUnits,
            apiKey: String,
            provider: AIProvider,
            model: String,
            baseURL: String
        ) async -> String? {
            let unitsStr = units.rawValue
            let alertNames = alerts.map(\.title).joined(separator: ", ")
            let recentValues = values.suffix(6).map { String(format: "%.0f", $0) }.joined(separator: ", ")

            let prompt = """
            You are a diabetes management assistant. Give a BRIEF (1-2 sentence) actionable insight.

            DETECTED PATTERN: \(alertNames)
            RECENT READINGS (\(unitsStr)): \(recentValues)

            Be concise and practical. No disclaimers needed — this is an informational notification.
            """

            let request = AIServiceAdapter.AIRequest(
                model: model,
                messages: [
                    AIServiceAdapter.ChatMessagePayload(role: .user, content: prompt)
                ],
                temperature: 0.3,
                topP: nil,
                topK: nil,
                maxTokens: 100
            )

            do {
                let response = try await AIServiceAdapter.send(
                    request: request,
                    provider: provider,
                    baseURL: baseURL,
                    apiKey: apiKey
                )
                return response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                // Silently fail — background monitoring should never crash or annoy the user
                return nil
            }
        }

        // MARK: - Notification

        @MainActor
        private func sendNotification(title: String, body: String) {
            let center = UNUserNotificationCenter.current()

            let content = UNMutableNotificationContent()
            content.title = "🤖 " + title
            content.body = body
            content.sound = .default
            content.categoryIdentifier = "AI_INSIGHT"

            // Deduplicate — only one AI notification at a time
            center.removePendingNotificationRequests(withIdentifiers: ["ai_background_insight"])
            center.removeDeliveredNotifications(withIdentifiers: ["ai_background_insight"])

            let request = UNNotificationRequest(
                identifier: "ai_background_insight",
                content: content,
                trigger: nil // Deliver immediately
            )

            center.add(request) { error in
                if let error {
                    debug(.default, "AI BackgroundMonitor: failed to send notification: \(error.localizedDescription)")
                }
            }
        }
    }
}
