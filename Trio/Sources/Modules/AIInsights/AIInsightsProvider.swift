import CoreData
import Foundation
import Swinject

extension AIInsights {
    final class Provider: BaseProvider {
        @Injected() var keychain: Keychain!
        @Injected() var nightscoutManager: NightscoutManager!
        @Injected() var glucoseStorage: GlucoseStorage!
        @Injected() var carbsStorage: CarbsStorage!
        @Injected() var settingsManager: SettingsManager!
        @Injected() var iobService: IOBService!

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

        func getISF() async -> Decimal {
            let isf = await storage.retrieveAsync(OpenAPS.Settings.insulinSensitivities, as: InsulinSensitivities.self)
                ?? InsulinSensitivities(from: OpenAPS.defaults(for: OpenAPS.Settings.insulinSensitivities))
                ?? InsulinSensitivities(units: .mgdL, userPreferredUnits: .mgdL, sensitivities: [])
            return isf.sensitivities.first?.sensitivity ?? settingsManager.settings.high
        }

        func getCR() async -> Decimal {
            let cr = await storage.retrieveAsync(OpenAPS.Settings.carbRatios, as: CarbRatios.self)
                ?? CarbRatios(from: OpenAPS.defaults(for: OpenAPS.Settings.carbRatios))
                ?? CarbRatios(units: .grams, schedule: [])
            return cr.schedule.first?.ratio ?? 10
        }

        func getTarget() async -> Decimal {
            let targets = await storage.retrieveAsync(OpenAPS.Settings.bgTargets, as: BGTargets.self)
                ?? BGTargets(from: OpenAPS.defaults(for: OpenAPS.Settings.bgTargets))
                ?? BGTargets(units: .mgdL, userPreferredUnits: .mgdL, targets: [])
            return targets.targets.first?.low ?? 100
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
        func fetchCarbs() async -> [CarbsEntry] {
            // Try CoreData first
            let coreDataCarbs = await fetchCarbsFromCoreData()
            if !coreDataCarbs.isEmpty {
                return coreDataCarbs
            }
            // Fallback to Nightscout API
            return await nightscoutManager.fetchCarbs()
        }

        /// Reads carbs directly from CoreData (`CarbEntryStored` entity).
        private func fetchCarbsFromCoreData() async -> [CarbsEntry] {
            do {
                let since = Date().addingTimeInterval(-30 * 24 * 3600) // last 30 days
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
