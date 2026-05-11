import Foundation
import Swinject

extension AIInsights {
    final class Provider: BaseProvider {
        @Injected() var keychain: Keychain!
        @Injected() var nightscoutManager: NightscoutManager!
        @Injected() var settingsManager: SettingsManager!

        var settings: TrioSettings {
            get { settingsManager.settings }
            set { settingsManager.settings = newValue }
        }
        
        func fetchGlucose(since date: Date) async -> [BloodGlucose] {
            return await nightscoutManager.fetchGlucose(since: date)
        }
        
        func fetchCarbs() async -> [CarbsEntry] {
            return await nightscoutManager.fetchCarbs()
        }
    }
}
