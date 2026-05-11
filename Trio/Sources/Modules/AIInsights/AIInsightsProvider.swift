import Foundation
import Swinject

extension AIInsights {
    final class Provider: BaseProvider {
        @Injected() var keychain: Keychain!
        @Injected() var nightscoutManager: NightscoutManager!
        @Injected() var settingsManager: SettingsManager!
        @Injected() var iobService: IOBService!

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

        // MARK: - Nightscout Data Fetch

        func fetchGlucose(since date: Date) async -> [BloodGlucose] {
            return await nightscoutManager.fetchGlucose(since: date)
        }

        func fetchCarbs() async -> [CarbsEntry] {
            return await nightscoutManager.fetchCarbs()
        }
    }
}
