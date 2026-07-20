import CoreData
import Foundation
import LoopKit
import Swinject

extension AIInsights {
    final class Provider: BaseProvider {
        @Injected() var keychain: Keychain!
        @Injected() var nightscoutManager: NightscoutManager!
        @Injected() var glucoseStorage: GlucoseStorage!
        @Injected() var carbsStorage: CarbsStorage!
        @Injected() var settingsManager: SettingsManager!
        @Injected() var iobService: IOBService!
        @Injected() var broadcaster: Broadcaster!
        @Injected() var overrideStorage: OverrideStorage!
        @Injected() var tempTargetsStorage: TempTargetsStorage!
        @Injected() var apsManager: APSManager!

        private let coreDataContext = CoreDataStack.shared.newTaskContext()

        var settings: TrioSettings {
            get { settingsManager.settings }
            set { settingsManager.settings = newValue }
        }

        var units: GlucoseUnits { settingsManager.settings.units }

        // MARK: - Data Access (via OpenAPS file storage, same pattern as Home)

        func getBasalProfile() async -> [BasalProfileEntry] {
            await storage.retrieveAsync(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self)
                ?? [BasalProfileEntry](from: OpenAPS.defaults(for: OpenAPS.Settings.basalProfile))
                ?? []
        }

        func getInsulinSensitivities() async -> InsulinSensitivities {
            await storage.retrieveAsync(OpenAPS.Settings.insulinSensitivities, as: InsulinSensitivities.self)
                ?? InsulinSensitivities(from: OpenAPS.defaults(for: OpenAPS.Settings.insulinSensitivities))
                ?? InsulinSensitivities(units: .mgdL, userPreferredUnits: .mgdL, sensitivities: [])
        }

        func getCarbRatios() async -> CarbRatios {
            await storage.retrieveAsync(OpenAPS.Settings.carbRatios, as: CarbRatios.self)
                ?? CarbRatios(from: OpenAPS.defaults(for: OpenAPS.Settings.carbRatios))
                ?? CarbRatios(units: .grams, schedule: [])
        }

        func getBGTargets() async -> BGTargets {
            await storage.retrieveAsync(OpenAPS.Settings.bgTargets, as: BGTargets.self)
                ?? BGTargets(from: OpenAPS.defaults(for: OpenAPS.Settings.bgTargets))
                ?? BGTargets(units: .mgdL, userPreferredUnits: .mgdL, targets: [])
        }

        func getISF() async -> Decimal {
            let isf = await getInsulinSensitivities()
            return isf.sensitivities.first?.sensitivity ?? settingsManager.settings.high
        }

        func getCR() async -> Decimal {
            let cr = await getCarbRatios()
            return cr.schedule.first?.ratio ?? 10
        }

        func getTarget() async -> Decimal {
            let targets = await getBGTargets()
            return targets.targets.first?.low ?? 100
        }

        func getISFDescription() async -> String {
            let isf = await getInsulinSensitivities()
            let entries = isf.sensitivities.map { entry in
                let value = units == .mmolL ? entry.sensitivity.asMmolL : entry.sensitivity
                return "\(entry.start) - \(value) \(units.rawValue)/U"
            }
            return entries.isEmpty ? "\(await getISF()) \(units.rawValue)/U" : entries.joined(separator: "\n")
        }

        func getCRDescription() async -> String {
            let cr = await getCarbRatios()
            let entries = cr.schedule.map { entry in
                "\(entry.start) - \(entry.ratio) g/U"
            }
            return entries.isEmpty ? "\(await getCR()) g/U" : entries.joined(separator: "\n")
        }

        func getTargetDescription() async -> String {
            let targets = await getBGTargets()
            let entries = targets.targets.map { entry in
                let low = units == .mmolL ? entry.low.asMmolL : entry.low
                let high = units == .mmolL ? entry.high.asMmolL : entry.high
                return "\(entry.start) - \(low)-\(high) \(units.rawValue)"
            }
            return entries.isEmpty ? "\(await getTarget()) \(units.rawValue)" : entries.joined(separator: "\n")
        }

        // MARK: - Therapy Writes

        func captureTherapySnapshot() async -> TherapySnapshot {
            let basalProfile = await getBasalProfile()
            let isfValues = await getInsulinSensitivities()
            let carbRatios = await getCarbRatios()
            let bgTargets = await getBGTargets()

            return TherapySnapshot(
                basalProfile: basalProfile,
                isfSensitivity: isfValues.sensitivities.first?.sensitivity ?? settingsManager.settings.high,
                carbRatio: carbRatios.schedule.first?.ratio ?? 10,
                target: bgTargets.targets.first?.low ?? 100,
                capturedAt: Date(),
                insulinSensitivities: isfValues,
                carbRatios: carbRatios,
                bgTargets: bgTargets
            )
        }

        func applySuggestion(_ suggestion: Suggestion) async throws {
            guard let proposedValue = decimalValue(from: suggestion.proposedValue) else {
                throw TherapySuggestionApplyError.missingProposedValue
            }
            guard let range = timeRange(from: suggestion.timeBlock) else {
                throw TherapySuggestionApplyError.missingTimeRange
            }

            switch suggestion.settingType {
            case .basalRate:
                let profile = applyBasalRate(proposedValue, to: await getBasalProfile(), range: range)
                await MainActor.run { self.saveBasalProfile(profile) }
            case .isf:
                let profile = applyISF(proposedValue, to: await getInsulinSensitivities(), range: range)
                await MainActor.run { self.saveInsulinSensitivities(profile) }
            case .carbRatio:
                let profile = applyCarbRatio(proposedValue, to: await getCarbRatios(), range: range)
                await MainActor.run { self.saveCarbRatios(profile) }
            }

            let nightscoutManager = self.nightscoutManager
            Task.detached(priority: .low) {
                try? await nightscoutManager?.uploadProfiles()
            }
        }

        func restoreSnapshot(_ snapshot: TherapySnapshot, for settingType: Suggestion.SettingType) async throws {
            switch settingType {
            case .basalRate:
                await MainActor.run { self.saveBasalProfile(snapshot.basalProfile) }
            case .isf:
                if let insulinSensitivities = snapshot.insulinSensitivities {
                    await MainActor.run { self.saveInsulinSensitivities(insulinSensitivities) }
                } else {
                    throw TherapySuggestionApplyError.missingSnapshot
                }
            case .carbRatio:
                if let carbRatios = snapshot.carbRatios {
                    await MainActor.run { self.saveCarbRatios(carbRatios) }
                } else {
                    throw TherapySuggestionApplyError.missingSnapshot
                }
            }

            let nightscoutManager = self.nightscoutManager
            Task.detached(priority: .low) {
                try? await nightscoutManager?.uploadProfiles()
            }
        }

        // MARK: - Adjustment Suggestions

        func addAdjustmentSuggestionToPresets(_ suggestion: AdjustmentSuggestion) async throws {
            switch suggestion.kind {
            case .override:
                try await overrideStorage.storeOverride(override: override(from: suggestion, enabled: false, isPreset: true))
                try? await nightscoutManager.uploadProfiles()
            case .tempTarget:
                try await tempTargetsStorage.storeTempTarget(tempTarget: tempTarget(from: suggestion, enabled: false, isPreset: true))
            }
        }

        func startAdjustmentSuggestion(_ suggestion: AdjustmentSuggestion) async throws {
            switch suggestion.kind {
            case .override:
                try await overrideStorage.storeOverride(override: override(from: suggestion, enabled: true, isPreset: false))
            case .tempTarget:
                let tempTarget = try tempTarget(from: suggestion, enabled: true, isPreset: false)
                try await tempTargetsStorage.storeTempTarget(tempTarget: tempTarget)
                tempTargetsStorage.saveTempTargetsToStorage([tempTarget])
            }

            try? await apsManager.determineBasalSync()
        }

        private func override(from suggestion: AdjustmentSuggestion, enabled: Bool, isPreset: Bool) -> Override {
            let target = storedGlucoseValue(suggestion.targetValue ?? 0)
            let shouldOverrideTarget = target > 0
            let adjustsISFOrCR = suggestion.isf || suggestion.cr

            return Override(
                name: suggestion.name,
                enabled: enabled,
                date: Date(),
                duration: Decimal(suggestion.durationMinutes),
                indefinite: suggestion.durationMinutes <= 0,
                percentage: suggestion.percentage ?? 100,
                smbIsOff: suggestion.smbIsOff,
                isPreset: isPreset,
                id: UUID().uuidString,
                overrideTarget: shouldOverrideTarget,
                target: target,
                advancedSettings: suggestion.smbIsOff || adjustsISFOrCR,
                isfAndCr: suggestion.isf && suggestion.cr,
                isf: suggestion.isf,
                cr: suggestion.cr,
                smbIsScheduledOff: false,
                start: 0,
                end: 0,
                smbMinutes: 0,
                uamMinutes: 0
            )
        }

        private func tempTarget(from suggestion: AdjustmentSuggestion, enabled: Bool, isPreset: Bool) throws -> TempTarget {
            guard let targetValue = suggestion.targetValue else {
                throw NSError(
                    domain: "AIInsightsAdjustmentSuggestion",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: String(
                            localized: "The suggested temporary target does not include a target value.",
                            comment: "AI adjustment apply error"
                        )
                    ]
                )
            }

            let target = storedGlucoseValue(targetValue)
            return TempTarget(
                name: suggestion.name,
                createdAt: Date(),
                targetTop: target,
                targetBottom: target,
                duration: Decimal(suggestion.durationMinutes),
                enteredBy: TempTarget.local,
                reason: TempTarget.custom,
                isPreset: isPreset,
                enabled: enabled,
                halfBasalTarget: nil
            )
        }

        private func storedGlucoseValue(_ displayValue: Decimal) -> Decimal {
            units == .mmolL ? displayValue.asMgdL : displayValue
        }

        private func saveBasalProfile(_ profile: [BasalProfileEntry]) {
            storage.save(profile, as: OpenAPS.Settings.basalProfile)

            let syncValues = profile.map {
                RepeatingScheduleValue(startTime: TimeInterval($0.minutes * 60), value: Double($0.rate))
            }
            deviceManager.pumpManager?.syncBasalRateSchedule(items: syncValues) { result in
                if case let .failure(error) = result {
                    debug(.default, "AI Insights: basal profile saved locally, pump sync failed: \(error)")
                }
            }

            broadcaster.notify(BasalProfileObserver.self, on: .main) {
                $0.basalProfileDidChange(profile)
            }
        }

        private func saveInsulinSensitivities(_ profile: InsulinSensitivities) {
            storage.save(profile, as: OpenAPS.Settings.insulinSensitivities)
        }

        private func saveCarbRatios(_ profile: CarbRatios) {
            storage.save(profile, as: OpenAPS.Settings.carbRatios)
        }

        private func applyBasalRate(
            _ value: Decimal,
            to profile: [BasalProfileEntry],
            range: TimeRange
        ) -> [BasalProfileEntry] {
            let fallback = profile.isEmpty ? [BasalProfileEntry(start: formatTime(0), minutes: 0, rate: value)] : profile
            let updated = applyRanges(to: fallback.map { (minute: $0.minutes, value: $0.rate) }, range: range, value: value)
            return updated.map { BasalProfileEntry(start: formatTime($0.minute), minutes: $0.minute, rate: $0.value) }
        }

        private func applyISF(
            _ displayValue: Decimal,
            to profile: InsulinSensitivities,
            range: TimeRange
        ) -> InsulinSensitivities {
            let storedValue = units == .mmolL ? displayValue * Decimal(18.0182) : displayValue
            let fallback = profile.sensitivities.isEmpty
                ? [(minute: 0, value: storedValue)]
                : profile.sensitivities.map { (minute: $0.offset, value: $0.sensitivity) }
            let updated = applyRanges(to: fallback, range: range, value: storedValue)
            return InsulinSensitivities(
                units: .mgdL,
                userPreferredUnits: .mgdL,
                sensitivities: updated.map {
                    InsulinSensitivityEntry(sensitivity: $0.value, offset: $0.minute, start: formatTime($0.minute))
                }
            )
        }

        private func applyCarbRatio(
            _ value: Decimal,
            to profile: CarbRatios,
            range: TimeRange
        ) -> CarbRatios {
            let fallback = profile.schedule.isEmpty
                ? [(minute: 0, value: value)]
                : profile.schedule.map { (minute: $0.offset, value: $0.ratio) }
            let updated = applyRanges(to: fallback, range: range, value: value)
            return CarbRatios(
                units: .grams,
                schedule: updated.map {
                    CarbRatioEntry(start: formatTime($0.minute), offset: $0.minute, ratio: $0.value)
                }
            )
        }

        private typealias SchedulePoint = (minute: Int, value: Decimal)

        private struct TimeRange {
            let start: Int
            let end: Int
        }

        private func applyRanges(
            to schedule: [SchedulePoint],
            range: TimeRange,
            value: Decimal
        ) -> [SchedulePoint] {
            let ranges: [TimeRange]
            if range.end <= range.start {
                ranges = [TimeRange(start: range.start, end: 24 * 60), TimeRange(start: 0, end: range.end)]
            } else {
                ranges = [range]
            }

            var points = normalize(schedule)
            for range in ranges where range.start != range.end {
                let restoreValue = valueAt(minute: range.end % (24 * 60), in: points)
                points = points.map { point in
                    guard point.minute >= range.start, point.minute < range.end else { return point }
                    return (minute: point.minute, value: value)
                }
                points = upsert(points, minute: range.start, value: value)
                if range.end < 24 * 60 {
                    points = upsert(points, minute: range.end, value: restoreValue)
                }
                points = normalize(points)
            }

            return points
        }

        private func normalize(_ schedule: [SchedulePoint]) -> [SchedulePoint] {
            var byMinute: [Int: Decimal] = [:]
            for point in schedule {
                byMinute[max(0, min(24 * 60 - 1, point.minute))] = point.value
            }

            if byMinute[0] == nil {
                byMinute[0] = schedule.sorted { $0.minute < $1.minute }.first?.value ?? 0
            }

            let sorted = byMinute
                .map { (minute: $0.key, value: $0.value) }
                .sorted { $0.minute < $1.minute }

            return sorted.reduce(into: [SchedulePoint]()) { result, point in
                if let last = result.last, last.value == point.value, point.minute != 0 {
                    return
                }
                result.append(point)
            }
        }

        private func upsert(_ schedule: [SchedulePoint], minute: Int, value: Decimal) -> [SchedulePoint] {
            var points = schedule.filter { $0.minute != minute }
            points.append((minute: minute, value: value))
            return points.sorted { $0.minute < $1.minute }
        }

        private func valueAt(minute: Int, in schedule: [SchedulePoint]) -> Decimal {
            let sorted = normalize(schedule)
            return sorted.last(where: { $0.minute <= minute })?.value ?? sorted.last?.value ?? 0
        }

        private func decimalValue(from text: String) -> Decimal? {
            let normalized = text.replacingOccurrences(of: ",", with: ".")
            var token = ""

            for character in normalized {
                if character.isNumber || character == "." || character == "-" {
                    token.append(character)
                } else if !token.isEmpty {
                    break
                }
            }

            return Decimal(string: token, locale: Locale(identifier: "en_US_POSIX"))
        }

        private func timeRange(from text: String) -> TimeRange? {
            let normalized = text
                .replacingOccurrences(of: "—", with: "-")
                .replacingOccurrences(of: "–", with: "-")
                .replacingOccurrences(of: "to", with: "-", options: .caseInsensitive)

            let parts = normalized
                .split(separator: "-", maxSplits: 1)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

            guard parts.count == 2,
                  let start = minutes(from: parts[0]),
                  let end = minutes(from: parts[1])
            else {
                return nil
            }

            return TimeRange(start: start, end: end)
        }

        private func minutes(from timeString: String) -> Int? {
            var value = timeString
                .uppercased()
                .replacingOccurrences(of: ".", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let isPM = value.contains("PM")
            let isAM = value.contains("AM")
            value = value
                .replacingOccurrences(of: "AM", with: "")
                .replacingOccurrences(of: "PM", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let components = value.split(separator: ":")
            guard let hour = Int(components.first ?? "") else { return nil }
            let minute = components.count > 1 ? Int(components[1]) ?? 0 : 0

            var normalizedHour = hour
            if isPM, normalizedHour < 12 {
                normalizedHour += 12
            } else if isAM, normalizedHour == 12 {
                normalizedHour = 0
            }

            guard (0 ... 24).contains(normalizedHour), (0 ..< 60).contains(minute) else { return nil }
            return (normalizedHour % 24) * 60 + minute
        }

        private func formatTime(_ minutes: Int) -> String {
            String(format: "%02d:%02d:00", minutes / 60, minutes % 60)
        }

        // MARK: - Live Status

        var currentIOB: Double? {
            iobService.currentIOB.map { Double($0) }
        }

        // MARK: - Data Fetch (CoreData primary, Nightscout fallback)

        /// Fetches glucose from CoreData (local device storage) which is the canonical
        /// source regardless of CGM type (Dexcom, Libre, Nightscout, etc.).
        /// Falls back to Nightscout API if CoreData returns empty.
        func fetchGlucose(since date: Date) async -> [BloodGlucose] {
            // 1. Try CoreData first — this is where ALL glucose ends up regardless of source
            let coreDataGlucose = await fetchGlucoseFromCoreData(since: date)
            if !coreDataGlucose.isEmpty {
                return coreDataGlucose
            }

            // 2. Fallback: Nightscout API (e.g. if CoreData is empty after a fresh install)
            return await nightscoutManager.fetchGlucose(since: date)
        }

        /// Reads glucose directly from CoreData (`GlucoseStored` entity).
        /// This is the same data source that Home, Stats, and Treatments use.
        private func fetchGlucoseFromCoreData(since date: Date) async -> [BloodGlucose] {
            do {
                let predicate = NSPredicate(format: "date >= %@", date as NSDate)
                let results = try await CoreDataStack.shared.fetchEntitiesAsync(
                    ofType: GlucoseStored.self,
                    onContext: coreDataContext,
                    predicate: predicate,
                    key: "date",
                    ascending: true,
                    batchSize: 50
                )

                return await coreDataContext.perform {
                    guard let glucoseObjects = results as? [GlucoseStored] else { return [] }

                    return glucoseObjects.map { stored in
                        BloodGlucose(
                            id: stored.id?.uuidString ?? UUID().uuidString,
                            sgv: Int(stored.glucose),
                            direction: BloodGlucose.Direction(from: stored.direction ?? ""),
                            date: Decimal(stored.date?.timeIntervalSince1970 ?? Date().timeIntervalSince1970) * 1000,
                            dateString: stored.date ?? Date(),
                            glucose: Int(stored.glucose)
                        )
                    }
                }
            } catch {
                debug(.default, "AI Provider: failed to fetch glucose from CoreData: \(error)")
                return []
            }
        }

        /// Fetches carbs from CoreData first, falls back to Nightscout.
        func fetchCarbs(since date: Date? = nil) async -> [CarbsEntry] {
            // Try CoreData first
            let coreDataCarbs = await fetchCarbsFromCoreData(since: date)
            if !coreDataCarbs.isEmpty {
                return coreDataCarbs
            }
            // Fallback to Nightscout API
            return await nightscoutManager.fetchCarbs()
        }

        /// Reads carbs directly from CoreData (`CarbEntryStored` entity).
        private func fetchCarbsFromCoreData(since date: Date?) async -> [CarbsEntry] {
            do {
                let since = date ?? Date().addingTimeInterval(-30 * 24 * 3600)
                let predicate = NSPredicate(format: "date >= %@", since as NSDate)
                let results = try await CoreDataStack.shared.fetchEntitiesAsync(
                    ofType: CarbEntryStored.self,
                    onContext: coreDataContext,
                    predicate: predicate,
                    key: "date",
                    ascending: false,
                    batchSize: 50
                )

                return await coreDataContext.perform {
                    guard let carbObjects = results as? [CarbEntryStored] else { return [] }

                    return carbObjects.compactMap { stored -> CarbsEntry? in
                        guard !stored.isFPU else { return nil } // Skip FPU equivalents
                        return CarbsEntry(
                            id: stored.id?.uuidString,
                            createdAt: stored.date ?? Date(),
                            actualDate: stored.date,
                            carbs: Decimal(stored.carbs),
                            fat: Decimal(stored.fat),
                            protein: Decimal(stored.protein),
                            note: stored.note,
                            enteredBy: CarbsEntry.local,
                            isFPU: stored.isFPU,
                            fpuID: stored.fpuID?.uuidString
                        )
                    }
                }
            } catch {
                debug(.default, "AI Provider: failed to fetch carbs from CoreData: \(error)")
                return []
            }
        }
    }
}
