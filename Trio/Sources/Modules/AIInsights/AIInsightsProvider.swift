import Foundation
import Swinject

extension AIInsights {
    final class Provider: BaseProvider, Injectable {
        @Injected() var keychain: Keychain!
        @Injected() var nightscoutManager: NightscoutManager!
        
        init(resolver: Resolver) {
            super.init()
            injectServices(resolver)
        }
        
        func fetchGlucose(since date: Date) async -> [BloodGlucose] {
            return await nightscoutManager.fetchGlucose(since: date)
        }
        
        func fetchCarbs() async -> [CarbsEntry] {
            return await nightscoutManager.fetchCarbs()
        }
    }
}
