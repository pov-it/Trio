import Foundation
import Swinject

extension AIInsights {
    final class Provider: BaseProvider, Injectable {
        @Injected() var keychain: Keychain!
        
        init(resolver: Resolver) {
            super.init()
            injectServices(resolver)
        }
    }
}
