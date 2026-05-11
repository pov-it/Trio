import Foundation
import Swinject

extension AIInsights {
    final class Provider: BaseProvider, Injectable {
        @Injected() var keychain: Keychain!
        @Injected() var nightscoutManager: NightscoutManager!
        @Injected() var settingsManager: SettingsManager!
        
        init(resolver: Resolver) {
            super.init()
            injectServices(resolver)
        }
        
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
