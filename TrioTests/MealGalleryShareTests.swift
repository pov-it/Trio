import Foundation
import Testing

@testable import Trio

@Suite("Meal gallery filters, groups, and companion-share privacy")
struct MealGalleryShareTests {

    private func amsterdamCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return calendar
    }

    private func date(hour: Int, minute: Int = 0, calendar: Calendar) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 21
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)!
    }

    // MARK: - Meal slots (Europe/Amsterdam-friendly local hours)

    @Test("Breakfast is 05:00–10:59 local")
    func breakfastSlot() {
        let calendar = amsterdamCalendar()
        #expect(AIInsights.MealSlot.from(date: date(hour: 5, calendar: calendar), calendar: calendar) == .breakfast)
        #expect(AIInsights.MealSlot.from(date: date(hour: 8, calendar: calendar), calendar: calendar) == .breakfast)
        #expect(AIInsights.MealSlot.from(date: date(hour: 10, minute: 59, calendar: calendar), calendar: calendar) == .breakfast)
        #expect(AIInsights.MealSlot.from(date: date(hour: 4, minute: 59, calendar: calendar), calendar: calendar) != .breakfast)
        #expect(AIInsights.MealSlot.from(date: date(hour: 11, calendar: calendar), calendar: calendar) != .breakfast)
    }

    @Test("Lunch is 11:00–15:59 local")
    func lunchSlot() {
        let calendar = amsterdamCalendar()
        #expect(AIInsights.MealSlot.from(date: date(hour: 11, calendar: calendar), calendar: calendar) == .lunch)
        #expect(AIInsights.MealSlot.from(date: date(hour: 15, minute: 59, calendar: calendar), calendar: calendar) == .lunch)
    }

    @Test("Dinner is 16:00–21:59 local")
    func dinnerSlot() {
        let calendar = amsterdamCalendar()
        #expect(AIInsights.MealSlot.from(date: date(hour: 16, calendar: calendar), calendar: calendar) == .dinner)
        #expect(AIInsights.MealSlot.from(date: date(hour: 19, calendar: calendar), calendar: calendar) == .dinner)
        #expect(AIInsights.MealSlot.from(date: date(hour: 21, minute: 59, calendar: calendar), calendar: calendar) == .dinner)
    }

    @Test("Other is 22:00–04:59 local")
    func otherSlot() {
        let calendar = amsterdamCalendar()
        #expect(AIInsights.MealSlot.from(date: date(hour: 22, calendar: calendar), calendar: calendar) == .other)
        #expect(AIInsights.MealSlot.from(date: date(hour: 23, calendar: calendar), calendar: calendar) == .other)
        #expect(AIInsights.MealSlot.from(date: date(hour: 0, calendar: calendar), calendar: calendar) == .other)
        #expect(AIInsights.MealSlot.from(date: date(hour: 4, calendar: calendar), calendar: calendar) == .other)
    }

    // MARK: - Filters

    private func item(
        name: String,
        date: Date = Date(),
        carbs: Double = 40,
        tags: [String] = [],
        itemNames: [String] = []
    ) -> AIInsights.MealGalleryStore.GalleryItem {
        AIInsights.MealGalleryStore.GalleryItem(
            id: UUID(),
            date: date,
            mealName: name,
            totalCarbs: carbs,
            thumbnailFilename: "\(UUID().uuidString).jpg",
            tags: tags,
            items: itemNames.map {
                AIInsights.GalleryFoodSnapshot(
                    name: $0,
                    portion: "1",
                    carbs: carbs,
                    fat: 0,
                    protein: 0,
                    fiber: 0,
                    calories: 0
                )
            }
        )
    }

    @Test("Name search matches meal title and ingredient names")
    func nameSearch() {
        let stokbrood = item(name: "Halve stokbroodjes", itemNames: ["stokbrood", "kaas"])
        let pasta = item(name: "Pasta", itemNames: ["penne"])
        var filter = AIInsights.GalleryFilter()
        filter.nameQuery = "stokbrood"
        #expect(filter.matches(stokbrood))
        #expect(!filter.matches(pasta))
    }

    @Test("Carb range is inclusive")
    func carbRange() {
        let low = item(name: "Snack", carbs: 12)
        let mid = item(name: "Meal", carbs: 45)
        let high = item(name: "Feast", carbs: 90)
        var filter = AIInsights.GalleryFilter()
        filter.minCarbs = 30
        filter.maxCarbs = 60
        #expect(!filter.matches(low))
        #expect(filter.matches(mid))
        #expect(!filter.matches(high))
    }

    @Test("Date range uses local calendar days")
    func dateRange() {
        let calendar = amsterdamCalendar()
        let start = calendar.startOfDay(for: date(hour: 8, calendar: calendar))
        let inRange = item(name: "In", date: date(hour: 12, calendar: calendar))
        let before = item(name: "Before", date: calendar.date(byAdding: .day, value: -1, to: start)!)
        var filter = AIInsights.GalleryFilter()
        filter.startDate = start
        filter.endDate = start
        #expect(filter.matches(inRange, calendar: calendar))
        #expect(!filter.matches(before, calendar: calendar))
    }

    @Test("Tag filter is case-insensitive OR")
    func tagFilter() {
        let tagged = item(name: "Brood", tags: ["halve stokbroodjes"])
        let other = item(name: "Soep", tags: ["lunch box"])
        var filter = AIInsights.GalleryFilter()
        filter.tags = ["Halve Stokbroodjes"]
        #expect(filter.matches(tagged))
        #expect(!filter.matches(other))
    }

    @Test("Meal-slot filter uses local hour of date")
    func slotFilter() {
        let calendar = amsterdamCalendar()
        let breakfast = item(name: "Eggs", date: date(hour: 8, calendar: calendar))
        let dinner = item(name: "Stamppot", date: date(hour: 19, calendar: calendar))
        var filter = AIInsights.GalleryFilter()
        filter.mealSlot = .breakfast
        #expect(filter.matches(breakfast, calendar: calendar))
        #expect(!filter.matches(dinner, calendar: calendar))
    }

    // MARK: - Index compatibility + bolus reuse

    @Test("Legacy gallery index JSON still decodes")
    func legacyIndexDecodes() throws {
        struct Legacy: Codable {
            let id: UUID
            let date: Date
            let mealName: String?
            let totalCarbs: Double
            let thumbnailFilename: String
        }
        let legacy = Legacy(
            id: UUID(),
            date: Date(),
            mealName: "Toast",
            totalCarbs: 22,
            thumbnailFilename: "toast.jpg"
        )
        let data = try JSONEncoder().encode(legacy)
        let item = try JSONDecoder().decode(AIInsights.MealGalleryStore.GalleryItem.self, from: data)
        #expect(item.mealName == "Toast")
        #expect(item.totalCarbs == 22)
        #expect(item.tags.isEmpty)
        #expect(item.items.isEmpty)
        #expect(item.totalFat == 0)
        #expect(item.canReuseForBolus)
    }

    @Test("Gallery snapshot rebuilds FoodFinder macros for bolus handoff")
    func galleryItemRebuildsMacros() {
        let snapshot = AIInsights.GalleryFoodSnapshot(
            name: "Stokbrood",
            portion: "1 half",
            carbs: 30,
            fat: 4,
            protein: 8,
            fiber: 2,
            calories: 180,
            portionMultiplier: 2
        )
        let item = AIInsights.MealGalleryStore.GalleryItem(
            id: UUID(),
            date: Date(),
            mealName: "Halve stokbroodjes",
            totalCarbs: 60,
            thumbnailFilename: "x.jpg",
            totalFat: 8,
            totalProtein: 16,
            items: [snapshot]
        )
        let result = item.toFoodAnalysisResult()
        #expect(result.totalCarbs == 60)
        #expect(result.totalFat == 8)
        #expect(result.totalProtein == 16)
        #expect(result.items.count == 1)
        #expect(result.items[0].name == "Stokbrood")

        let handoff = AIInsights.FoodBolusHandoff(
            carbs: result.totalCarbs,
            fat: result.totalFat,
            protein: result.totalProtein,
            note: result.items.map(\.name).joined(separator: ", "),
            createdAt: Date(),
            useReducedBolus: AIInsights.foodFinderReducedBolusRecommended(fat: result.totalFat, protein: result.totalProtein)
        )
        #expect(handoff.carbs == 60)
        #expect(handoff.fat == 8)
        #expect(handoff.protein == 16)
        #expect(handoff.note == "Stokbrood")
    }

    @Test("Manual group names de-duplicate case-insensitively")
    func groupNameCatalog() {
        let suite = "MealGalleryShareTests.groups.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = AIInsights.MealGalleryStore(defaults: defaults)
        #expect(store.addGroupName("halve stokbroodjes") == "halve stokbroodjes")
        #expect(store.addGroupName("Halve Stokbroodjes") == "halve stokbroodjes")
        #expect(store.loadGroupNames() == ["halve stokbroodjes"])
        defaults.removePersistentDomain(forName: suite)
    }

    // MARK: - Companion share privacy

    @Test("Share toggle defaults off")
    func shareDefaultsOff() {
        let suite = "MealGalleryShareTests.share.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        #expect(AIInsights.MealCompanionShareSettings.isEnabled(defaults) == false)
        defaults.removePersistentDomain(forName: suite)
    }

    @Test("Companion payload JSON is meal-only")
    func payloadAllowList() throws {
        let payload = AIInsights.SharedMealPayload(
            id: UUID(),
            date: Date(),
            mealName: "Halve stokbroodjes",
            thumbnailFilename: "meal.jpg",
            carbs: 42
        )
        #expect(AIInsights.MealSharePrivacy.rejectReason(for: payload) == nil)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        let json = try JSONSerialization.jsonObject(with: data)
        let keys = Set(AIInsights.MealSharePrivacy.objectKeys(in: json))
        #expect(keys.isSubset(of: AIInsights.MealSharePrivacy.allowedKeys))
        #expect(keys.isDisjoint(with: AIInsights.MealSharePrivacy.forbiddenKeys))

        let text = String(decoding: data, as: UTF8.self).lowercased()
        #expect(!text.contains("glucose"))
        #expect(!text.contains("\"iob\""))
        #expect(!text.contains("\"cob\""))
        #expect(!text.contains("nightscout"))
        #expect(!text.contains("token"))
        #expect(!text.contains("insulin"))
    }

    @Test("Privacy walker flags forbidden nested keys")
    func forbiddenKeyWalker() {
        let dirty: [String: Any] = [
            "id": "x",
            "nested": ["glucose": 90, "iob": 1.2]
        ]
        let keys = Set(AIInsights.MealSharePrivacy.objectKeys(in: dirty))
        #expect(keys.contains("glucose"))
        #expect(keys.contains("iob"))
    }

    @Test("Trio therapy App Group is refused as companion suite")
    func refusesTrioAppGroup() {
        let suite = "MealGalleryShareTests.appgroup.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set("group.org.nightscout.TEAMID.trio.trio-app-group", forKey: AIInsights.MealCompanionShareSettings.companionAppGroupKey)
        #expect(AIInsights.MealCompanionShareSettings.companionAppGroupIdentifier(defaults) == nil)
        defaults.set("group.org.nightscout.TEAMID.trio.companion-meals", forKey: AIInsights.MealCompanionShareSettings.companionAppGroupKey)
        #expect(AIInsights.MealCompanionShareSettings.companionAppGroupIdentifier(defaults) == "group.org.nightscout.TEAMID.trio.companion-meals")
        defaults.removePersistentDomain(forName: suite)
    }

    @Test("Outbox writes meal-only JSON and skips glucose fields")
    func outboxWritesAllowListedJSON() async throws {
        let suite = "MealGalleryShareTests.outbox.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let transport = AIInsights.SharedMealsOutboxTransport(defaults: defaults, directory: dir)
        let id = UUID()
        let payload = AIInsights.SharedMealPayload(
            id: id,
            date: Date(),
            mealName: "Lunch",
            thumbnailFilename: nil,
            carbs: 33
        )
        await transport.publish(AIInsights.SharedMealRecord(payload: payload, thumbnailJPEG: nil))
        let loaded = transport.loadPayload(id: id)
        #expect(loaded?.mealName == "Lunch")
        #expect(loaded?.carbs == 33)
        let jsonURL = dir.appendingPathComponent("\(id.uuidString).json")
        let text = (try String(contentsOf: jsonURL, encoding: .utf8)).lowercased()
        #expect(!text.contains("glucose"))
        #expect(!text.contains("nightscout"))
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("CloudKit container is iCloud.org.pov-it.<TEAM>.meals")
    func cloudKitContainerMatchesCompanion() {
        #expect(
            AIInsights.MealCloudKitContract.containerIdentifier(teamID: "Q6QCL8J6FN")
                == "iCloud.org.pov-it.Q6QCL8J6FN.meals"
        )
        #expect(AIInsights.MealCloudKitContract.containerIdentifier(teamID: "TEAMID") == nil)
        #expect(AIInsights.MealCloudKitContract.containerIdentifier(teamID: "$(DEVELOPMENT_TEAM)") == nil)
        #expect(AIInsights.MealCloudKitContract.containerIdentifier(teamID: "  ") == nil)
    }

    @Test("CloudKit Meal / MealFeed contract matches meals-companion")
    func cloudKitRecordContract() {
        #expect(AIInsights.MealCloudKitContract.zoneName == "MealsZone")
        #expect(AIInsights.MealCloudKitContract.mealRecordType == "Meal")
        #expect(AIInsights.MealCloudKitContract.feedRecordType == "MealFeed")
        #expect(AIInsights.MealCloudKitContract.titleKey == "title")
        #expect(AIInsights.MealCloudKitContract.photographedAtKey == "photographedAt")
        #expect(AIInsights.MealCloudKitContract.photoKey == "photo")
        #expect(AIInsights.MealCloudKitContract.ownerDisplayNameKey == "ownerDisplayName")
        #expect(!AIInsights.MealCloudKitContract.mealFieldKeys.contains("carbs"))
        #expect(!AIInsights.MealCloudKitContract.mealFieldKeys.contains("glucose"))
        #expect(!AIInsights.MealCloudKitContract.mealFieldKeys.contains("SharedMeal"))
    }

    @Test("UserDefaults override wins over derived CloudKit container")
    func cloudKitContainerOverride() {
        let suite = "MealGalleryShareTests.ck.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set("iCloud.org.pov-it.EXAMPLE.meals", forKey: AIInsights.MealCompanionShareSettings.cloudKitContainerKey)
        #expect(
            AIInsights.MealCompanionShareSettings.cloudKitContainerIdentifier(defaults)
                == "iCloud.org.pov-it.EXAMPLE.meals"
        )
        defaults.removePersistentDomain(forName: suite)
    }

    @Test("User-visible container never contains TEAM placeholder")
    func displayContainerNeverShowsPlaceholder() {
        let suite = "MealGalleryShareTests.display.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let missingTeam = AIInsights.MealCompanionShareSettings.displayContainerIdentifier(
            defaults,
            signingTeamID: ""
        )
        #expect(missingTeam == "iCloud.org.pov-it.Q6QCL8J6FN.meals")
        #expect(!missingTeam.contains("<TEAM>"))
        #expect(!missingTeam.contains("TEAMID"))
        #expect(!missingTeam.contains("$("))

        let fromSigning = AIInsights.MealCompanionShareSettings.displayContainerIdentifier(
            defaults,
            signingTeamID: "Q6QCL8J6FN"
        )
        #expect(fromSigning == "iCloud.org.pov-it.Q6QCL8J6FN.meals")
        defaults.removePersistentDomain(forName: suite)
    }

    @Test("Resolved team falls back to Q6QCL8J6FN")
    func resolvedTeamFallback() {
        #expect(AIInsights.MealCompanionShareSettings.resolvedTeamID(signingTeamID: "") == "Q6QCL8J6FN")
        #expect(AIInsights.MealCompanionShareSettings.resolvedTeamID(signingTeamID: "TEAMID") == "Q6QCL8J6FN")
        #expect(AIInsights.MealCompanionShareSettings.resolvedTeamID(signingTeamID: "Q6QCL8J6FN") == "Q6QCL8J6FN")
    }

    @Test("Invite URLs must be https iCloud share links")
    func inviteURLValidation() {
        let accept = [
            "https://www.icloud.com/share/ABC123",
            "https://share.icloud.com/share/xyz",
            "https://icloud.com/share/0a1b2c"
        ]
        for raw in accept {
            #expect(AIInsights.MealCompanionShareSettings.validatedICloudShareURL(from: raw) != nil)
        }

        let reject = [
            "",
            "   ",
            "not a url",
            "http://www.icloud.com/share/ABC",
            "https://example.com/share/ABC",
            "https://www.icloud.com/",
            "https://www.icloud.com",
            "file:///tmp/share",
            "cloudkit-share://abc",
            "https://evil-icloud.com.example/share/x"
        ]
        for raw in reject {
            #expect(AIInsights.MealCompanionShareSettings.validatedICloudShareURL(from: raw) == nil)
        }
    }

    @Test("Stored invite URL ignores invalid values and never invents a link")
    func storedShareURLIgnoresInvalidAndDoesNotInvent() {
        let suite = "MealGalleryShareTests.shareurl.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        #expect(AIInsights.MealCompanionShareSettings.shareURLString(defaults) == nil)

        defaults.set("garbage", forKey: AIInsights.MealCompanionShareSettings.shareURLKey)
        #expect(AIInsights.MealCompanionShareSettings.shareURLString(defaults) == nil)

        AIInsights.MealCompanionShareSettings.persistShareURLString("https://example.com/nope", defaults: defaults)
        #expect(AIInsights.MealCompanionShareSettings.shareURLString(defaults) == nil)

        AIInsights.MealCompanionShareSettings.persistShareURL(nil, defaults: defaults)
        #expect(AIInsights.MealCompanionShareSettings.shareURLString(defaults) == nil)

        let real = "https://www.icloud.com/share/MarijnToken"
        AIInsights.MealCompanionShareSettings.persistShareURLString(real, defaults: defaults)
        #expect(AIInsights.MealCompanionShareSettings.shareURLString(defaults) == real)

        defaults.removePersistentDomain(forName: suite)
    }

    @Test("Keyboard dock overlap is zero when the view is already above the keyboard")
    func keyboardDockNoDoublePadWhenAlreadyLifted() {
        let view = CGRect(x: 0, y: 0, width: 390, height: 508)
        let keyboard = CGRect(x: 0, y: 508, width: 390, height: 336)
        #expect(AIInsightsKeyboardDockMath.overlap(viewFrame: view, keyboardFrame: keyboard) == 0)
    }

    @Test("Keyboard dock overlap matches keyboard coverage on an unlifted view")
    func keyboardDockPadsUnliftedView() {
        let view = CGRect(x: 0, y: 0, width: 390, height: 844)
        let keyboard = CGRect(x: 0, y: 508, width: 390, height: 336)
        #expect(AIInsightsKeyboardDockMath.overlap(viewFrame: view, keyboardFrame: keyboard) == 336)
    }

    @Test("Keyboard dock overlap is zero when the keyboard is hidden")
    func keyboardDockHiddenKeyboard() {
        let view = CGRect(x: 0, y: 0, width: 390, height: 844)
        #expect(AIInsightsKeyboardDockMath.overlap(viewFrame: view, keyboardFrame: .zero) == 0)
        let offscreen = CGRect(x: 0, y: 844, width: 390, height: 336)
        #expect(AIInsightsKeyboardDockMath.overlap(viewFrame: view, keyboardFrame: offscreen) == 0)
    }

    @Test("Keyboard dock overlap stays stable after applying pad")
    func keyboardDockOverlapIgnoresOwnPad() {
        let keyboard = CGRect(x: 0, y: 508, width: 390, height: 336)
        let unpadded = CGRect(x: 0, y: 0, width: 390, height: 844)
        #expect(
            AIInsightsKeyboardDockMath.overlap(viewFrame: unpadded, keyboardFrame: keyboard, appliedPad: 0) == 336
        )
        let padded = CGRect(x: 0, y: 0, width: 390, height: 508)
        #expect(
            AIInsightsKeyboardDockMath.overlap(viewFrame: padded, keyboardFrame: keyboard, appliedPad: 336) == 336
        )
        #expect(
            AIInsightsKeyboardDockMath.overlap(viewFrame: .zero, keyboardFrame: keyboard, appliedPad: 0) == nil
        )
    }

    @Test("Unentitled CloudKit container is refused")
    func unentitledContainerRefused() {
        #expect(
            AIInsights.MealCloudKitEntitlement.isContainerEntitled(
                "iCloud.org.pov-it.Q6QCL8J6FN.meals",
                signedIdentifiers: []
            ) == false
        )
        #expect(
            AIInsights.MealCloudKitEntitlement.isContainerEntitled(
                "iCloud.org.pov-it.OTHER.meals",
                signedIdentifiers: ["iCloud.org.pov-it.Q6QCL8J6FN.meals"]
            ) == false
        )
    }

    @Test("Provision plist lists the meals CloudKit container")
    func provisionPlistListsMealsContainer() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Entitlements</key>
            <dict>
                <key>com.apple.developer.icloud-container-identifiers</key>
                <array>
                    <string>iCloud.org.pov-it.Q6QCL8J6FN.meals</string>
                </array>
                <key>com.apple.developer.icloud-services</key>
                <array>
                    <string>CloudKit</string>
                </array>
            </dict>
        </dict>
        </plist>
        """
        let ids = AIInsights.MealCloudKitEntitlement.iCloudContainerIdentifiers(
            fromProvisioningProfile: Data(xml.utf8)
        )
        #expect(ids == ["iCloud.org.pov-it.Q6QCL8J6FN.meals"])
        #expect(
            AIInsights.MealCloudKitEntitlement.isContainerEntitled(
                "iCloud.org.pov-it.Q6QCL8J6FN.meals",
                signedIdentifiers: ids
            )
        )
    }

    @Test("Unreadable signing entitlements are not a false not-entitled")
    func unreadableSigningIsUnknownNotDenied() {
        let container = "iCloud.org.pov-it.Q6QCL8J6FN.meals"
        #expect(
            AIInsights.MealCloudKitEntitlement.check(container, source: .unreadable) == .unreadable
        )
        #expect(
            AIInsights.MealCloudKitEntitlement.check(
                container,
                source: .readable([])
            ) == .missing
        )
        #expect(
            AIInsights.MealCloudKitEntitlement.check(
                container,
                source: .readable([container])
            ) == .entitled
        )
        #expect(
            AIInsights.MealCloudKitEntitlement.isContainerEntitled(container, signedIdentifiers: []) == false
        )
        let unreadable = AIInsights.MealCompanionShareError.unreadableSigningEntitlements.localizedDescription
        #expect(unreadable.localizedCaseInsensitiveContains("signing entitlements"))
        #expect(!unreadable.localizedCaseInsensitiveContains("not entitled"))
    }

    @Test("Entitlements dict lists the meals CloudKit container")
    func entitlementsDictListsMealsContainer() {
        let ids = AIInsights.MealCloudKitEntitlement.iCloudContainerIdentifiers(
            fromEntitlements: [
                "com.apple.developer.icloud-container-identifiers": [
                    "iCloud.org.pov-it.Q6QCL8J6FN.meals"
                ]
            ]
        )
        #expect(ids == ["iCloud.org.pov-it.Q6QCL8J6FN.meals"])
    }

    @Test("Production schema missing MealFeed is worded for Dashboard deploy")
    func productionSchemaMissingMealFeedCopy() {
        let raw = "Error saving record <CKRecordID: 0x7d9534e680; recordName=MealFeedRoot, zoneID=MealsZone:__defaultOwner__> to server: Cannot create new type MealFeed in production schema"
        #expect(AIInsights.MealCompanionShareError.isProductionSchemaMissing(description: raw))
        let mapped = AIInsights.MealCompanionShareError.productionSchemaMissing.localizedDescription
        #expect(mapped.contains("CloudKit Production schema missing MealFeed"))
        #expect(mapped.contains("CloudKit Dashboard"))
        #expect(!mapped.contains("CKRecordID"))
        #expect(!mapped.contains("0x7d9534e680"))
        #expect(
            AIInsights.MealCompanionShareError.isProductionSchemaMissing(description: "network timeout") == false
        )
        let schemaError = NSError(domain: "CKErrorDomain", code: 15, userInfo: [
            NSLocalizedDescriptionKey: raw
        ])
        let fromError = AIInsights.MealCompanionShareError.fromCloudKit(schemaError).localizedDescription
        #expect(fromError.contains("CloudKit Dashboard"))
        #expect(!fromError.contains("No invite link yet"))
        #expect(!fromError.contains("0x7d9534e680"))
    }

    @Test("Create failure shows CKError code and short message, not the idle invite line")
    func inviteFailureSurfacesCloudKitCode() {
        let idle = AIInsights.MealCompanionShareError.shareURLMissing.localizedDescription
        #expect(idle.contains("No invite link yet"))

        let failed = AIInsights.MealCompanionShareError.inviteCreateFailed(
            "CloudKit saved MealFeedRoot but CKShare.url was empty."
        ).localizedDescription
        #expect(failed.hasPrefix("Invite create failed:"))
        #expect(failed.contains("CKShare.url was empty"))
        #expect(!failed.contains("No invite link yet"))

        let raw = "Error saving record <CKRecordID: 0x7d9534e680; recordName=MealFeedRoot, zoneID=MealsZone:__defaultOwner__> to server: Zone was busy"
        let busy = NSError(domain: "CKErrorDomain", code: 23, userInfo: [
            NSLocalizedDescriptionKey: raw
        ])
        let summary = AIInsights.MealCompanionShareError.diagnosticSummary(busy)
        #expect(summary.contains("CKError 23"))
        #expect(summary.contains("zoneBusy"))
        #expect(summary.contains("Zone was busy"))
        #expect(!summary.contains("0x7d9534e680"))
        #expect(!summary.contains("No invite link yet"))
        #expect(AIInsights.MealCompanionShareError.userFacingMessage(for: busy) == summary)

        let signedOut = NSError(domain: "CKErrorDomain", code: 9, userInfo: [
            NSLocalizedDescriptionKey: "The operation couldn’t be completed. (CKErrorDomain error 9.)",
            NSLocalizedFailureReasonErrorKey: "Not signed in to iCloud"
        ])
        let auth = AIInsights.MealCompanionShareError.diagnosticSummary(signedOut)
        #expect(auth.contains("CKError 9"))
        #expect(auth.contains("notAuthenticated"))
        #expect(auth.contains("Not signed in to iCloud"))
        #expect(!auth.contains("couldn’t be completed"))

        let inner = NSError(domain: "CKErrorDomain", code: 15, userInfo: [
            NSLocalizedDescriptionKey: "Server rejected the share URL"
        ])
        let partial = NSError(domain: "CKErrorDomain", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "The operation couldn’t be completed. (CKErrorDomain error 2.)",
            "CKPartialErrors": ["MealFeedRoot": inner]
        ])
        let partialSummary = AIInsights.MealCompanionShareError.diagnosticSummary(partial)
        #expect(partialSummary.contains("CKError 2"))
        #expect(partialSummary.contains("partialFailure"))
        #expect(partialSummary.contains("CKError 15"))
        #expect(partialSummary.contains("serverRejectedRequest"))
        #expect(partialSummary.contains("Server rejected the share URL"))
        #expect(!partialSummary.contains("No invite link yet"))
    }

    @Test("Stuck share without a URL is replaced; a usable share is kept")
    func stuckShareRecoveryPlan() {
        #expect(AIInsights.MealShareInviteRecovery.plan(for: .noShare) == .createShare)
        #expect(AIInsights.MealShareInviteRecovery.plan(for: .usableURL) == .keepExistingShare)
        #expect(AIInsights.MealShareInviteRecovery.plan(for: .shareWithoutURL) == .replaceBrokenShare)
        #expect(AIInsights.MealShareInviteRecovery.plan(for: .danglingShareReference) == .replaceBrokenShare)
        #expect(
            AIInsights.MealShareInviteRecovery.linkState(
                hasShareReference: true,
                shareRecordMissing: false,
                validatedURL: nil
            ) == .shareWithoutURL
        )
        #expect(
            AIInsights.MealShareInviteRecovery.plan(
                for: AIInsights.MealShareInviteRecovery.linkState(
                    hasShareReference: true,
                    shareRecordMissing: false,
                    validatedURL: nil
                )
            ) == .replaceBrokenShare
        )
        #expect(
            AIInsights.MealShareInviteRecovery.linkState(
                hasShareReference: true,
                shareRecordMissing: false,
                validatedURL: ""
            ) == .shareWithoutURL
        )
        #expect(
            AIInsights.MealShareInviteRecovery.linkState(
                hasShareReference: true,
                shareRecordMissing: true,
                validatedURL: nil
            ) == .danglingShareReference
        )
        #expect(
            AIInsights.MealShareInviteRecovery.linkState(
                hasShareReference: true,
                shareRecordMissing: false,
                validatedURL: "https://www.icloud.com/share/Token"
            ) == .usableURL
        )
        #expect(
            AIInsights.MealShareInviteRecovery.linkState(
                hasShareReference: false,
                shareRecordMissing: false,
                validatedURL: nil
            ) == .noShare
        )

        #expect(
            AIInsights.MealShareInviteRecovery.shouldReplaceShare(
                afterFailureCode: 30,
                description: "record is already shared"
            )
        )
        #expect(
            AIInsights.MealShareInviteRecovery.shouldReplaceShare(
                afterFailureCode: 31,
                description: "share reference could not be found"
            )
        )
        #expect(
            AIInsights.MealShareInviteRecovery.shouldReplaceShare(
                afterFailureCode: 15,
                description: "Cannot create new type MealFeed in production schema"
            ) == false
        )
        #expect(
            AIInsights.MealShareInviteRecovery.shouldReplaceShare(
                afterFailureCode: 9,
                description: "Not signed in to iCloud"
            ) == false
        )
        #expect(
            AIInsights.MealShareInviteRecovery.shouldReplaceShare(
                afterFailureCode: 4,
                description: "network failure"
            ) == false
        )
        #expect(
            AIInsights.MealShareInviteRecovery.shouldReplaceShare(
                afterFailureCode: 2,
                partialCodes: [30],
                description: "partial failure"
            )
        )
        #expect(
            AIInsights.MealShareInviteRecovery.shouldReplaceShare(
                afterFailureCode: 2,
                partialCodes: [9],
                description: "partial failure"
            ) == false
        )

        let schemaInner = NSError(domain: "CKErrorDomain", code: 15, userInfo: [
            NSLocalizedDescriptionKey: "Cannot create new type MealFeed in production schema"
        ])
        let schemaPartial = NSError(domain: "CKErrorDomain", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "The operation couldn’t be completed. (CKErrorDomain error 2.)",
            "CKPartialErrors": ["MealFeedRoot": schemaInner]
        ])
        #expect(AIInsights.MealShareInviteRecovery.shouldReplaceShare(after: schemaPartial) == false)
        let dashboard = AIInsights.MealCompanionShareError.fromCloudKit(schemaPartial).localizedDescription
        #expect(dashboard.contains("CloudKit Dashboard"))
        #expect(!dashboard.contains("No invite link yet"))
    }

    @Test("Owner display name defaults to Trio, not the Meal placeholder")
    func ownerDisplayNameIsNotMealPlaceholder() {
        let suite = "MealGalleryShareTests.owner.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        #expect(AIInsights.MealCompanionShareSettings.ownerDisplayName(defaults) == "Trio")
        #expect(
            AIInsights.MealCompanionShareSettings.ownerDisplayNameForSave(
                existingCloudValue: "Meal",
                defaults: defaults
            ) == "Trio"
        )
        #expect(
            AIInsights.MealCompanionShareSettings.ownerDisplayNameForSave(
                existingCloudValue: "Marijn",
                defaults: defaults
            ) == "Marijn"
        )
        AIInsights.MealCompanionShareSettings.setOwnerDisplayName("Alex", defaults: defaults)
        #expect(
            AIInsights.MealCompanionShareSettings.ownerDisplayNameForSave(
                existingCloudValue: "Meal",
                defaults: defaults
            ) == "Alex"
        )
        AIInsights.MealCompanionShareSettings.setOwnerDisplayName("  ", defaults: defaults)
        #expect(AIInsights.MealCompanionShareSettings.storedOwnerDisplayName(defaults).isEmpty)
        #expect(AIInsights.MealShareInviteRecovery.iCloudAccountStatusName(1) == "available")
        #expect(AIInsights.MealShareInviteRecovery.iCloudAccountStatusName(3) == "noAccount")
        #expect(AIInsights.MealShareInviteRecovery.plan(for: .noShare) == .createShare)
        defaults.removePersistentDomain(forName: suite)
    }

    @Test("gemini-flash-latest omits thinkingLevel MINIMAL")
    func geminiFlashLatestOmitsUnsupportedThinking() {
        #expect(
            AIInsights.AIServiceAdapter.geminiThinkingConfigWhenDisabling(model: "gemini-flash-latest") == nil
        )
        let gemini3 = AIInsights.AIServiceAdapter.geminiThinkingConfigWhenDisabling(model: "gemini-3.5-flash")
        #expect(gemini3?["thinkingLevel"] as? String == "minimal")
        let gemini25 = AIInsights.AIServiceAdapter.geminiThinkingConfigWhenDisabling(model: "gemini-2.5-flash")
        #expect(gemini25?["thinkingBudget"] as? Int == 0)
    }
}
