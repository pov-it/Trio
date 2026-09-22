//
//  AIInsights_MealCompanionShare.swift
//  Trio
//
//  Opt-in publisher that can hand a meal-ONLY payload to a companion app.
//  Default OFF. Local-first: writes an on-disk outbox and never
//  blocks FoodFinder / gallery archive on network or CloudKit.
//
//  Privacy boundary (enforced in `SharedMealPayload` + `MealSharePrivacy`):
//    ALLOWED: id, date, mealName, thumbnail (bytes or filename), optional carbs
//    FORBIDDEN: glucose, IOB, COB, Nightscout URL/token, pump, insulin, API keys
//
//  The Trio App Group (`trio-app-group` / `$(APP_GROUP_ID)`) is NOT used.
//  A dedicated companion App Group would be registered separately by the
//  Apple Team; until that identifier is configured this publisher stays in
//  Application Support and never copies Nightscout secrets anywhere.
//
//  CloudKit publisher matches pov-it/meals-companion:
//    container iCloud.org.pov-it.<TEAMID>.meals
//    zone MealsZone, records Meal + MealFeed
//    fields title / photographedAt / photo / ownerDisplayName (never glucose).
//  See DeveloperDocs/MealCompanionShare.md.
//

import Foundation
import Darwin
#if canImport(CloudKit)
    import CloudKit
#endif

extension AIInsights {

    // MARK: - Payload (meal-only)

    /// Companion-safe meal record. Codable keys are an explicit allow-list;
    /// do not add therapy, CGM, or Nightscout fields here.
    struct SharedMealPayload: Codable, Equatable, Sendable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let id: UUID
        let date: Date
        let mealName: String?
        let thumbnailFilename: String?
        let carbs: Double?

        enum CodingKeys: String, CodingKey {
            case schemaVersion
            case id
            case date
            case mealName
            case thumbnailFilename
            case carbs
        }

        init(
            id: UUID,
            date: Date,
            mealName: String?,
            thumbnailFilename: String?,
            carbs: Double?,
            schemaVersion: Int = SharedMealPayload.currentSchemaVersion
        ) {
            self.schemaVersion = schemaVersion
            self.id = id
            self.date = date
            self.mealName = mealName
            self.thumbnailFilename = thumbnailFilename
            self.carbs = carbs
        }

        init(item: MealGalleryStore.GalleryItem, includeCarbs: Bool = true) {
            self.init(
                id: item.id,
                date: item.date,
                mealName: item.mealName,
                thumbnailFilename: item.thumbnailFilename,
                carbs: includeCarbs ? item.totalCarbs : nil
            )
        }

        init(result: FoodAnalysisResult, thumbnailFilename: String?, includeCarbs: Bool = true) {
            self.init(
                id: result.id,
                date: result.timestamp,
                mealName: result.mealName,
                thumbnailFilename: thumbnailFilename,
                carbs: includeCarbs ? result.totalCarbs : nil
            )
        }
    }

    /// Static allow / deny lists used before any bytes hit disk or CloudKit.
    enum MealSharePrivacy {
        /// JSON object keys that may appear in a companion payload.
        static let allowedKeys: Set<String> = [
            "schemaVersion",
            "id",
            "date",
            "mealName",
            "thumbnailFilename",
            "carbs"
        ]

        /// JSON object keys that must never appear, even nested.
        static let forbiddenKeys: Set<String> = [
            "glucose", "sgv", "bg", "bloodglucose", "bloodGlucose",
            "iob", "cob", "insulin", "insulinOnBoard", "carbsOnBoard",
            "nightscout", "nightscoutURL", "nightscoutUrl", "nsUrl", "nsurl",
            "token", "secret", "apiKey", "api_key", "accesstoken", "accessToken",
            "pump", "direction", "delta", "predicted", "forecast"
        ]

        static func objectKeys(in json: Any, prefix: String = "") -> [String] {
            if let dict = json as? [String: Any] {
                return dict.flatMap { key, value -> [String] in
                    let path = prefix.isEmpty ? key : "\(prefix).\(key)"
                    return [key] + objectKeys(in: value, prefix: path)
                }
            }
            if let array = json as? [Any] {
                return array.flatMap { objectKeys(in: $0, prefix: prefix) }
            }
            return []
        }

        /// Returns nil when the payload is companion-safe; otherwise a reason.
        static func rejectReason(for payload: SharedMealPayload) -> String? {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(payload),
                  let json = try? JSONSerialization.jsonObject(with: data)
            else {
                return "payload did not encode"
            }
            let keys = Set(objectKeys(in: json))
            if let forbidden = keys.first(where: { forbiddenKeys.contains($0) }) {
                return "forbidden key: \(forbidden)"
            }
            if let extra = keys.first(where: { !allowedKeys.contains($0) }) {
                return "unexpected key: \(extra)"
            }
            return nil
        }
    }

    struct SharedMealRecord: Sendable {
        let payload: SharedMealPayload
        let thumbnailJPEG: Data?
    }

    protocol MealCompanionTransport: Sendable {
        func publish(_ record: SharedMealRecord) async
    }

    // MARK: - Settings (opt-in, default OFF)

    /// CloudKit record contract for `pov-it/meals-companion`. Keep field names
    /// in lockstep with `MealsKit/MealModels.swift` in that repo.
    enum MealCloudKitContract {
        static let zoneName = "MealsZone"
        static let mealRecordType = "Meal"
        static let feedRecordType = "MealFeed"
        static let feedRecordName = "MealFeedRoot"
        static let titleKey = "title"
        static let photographedAtKey = "photographedAt"
        static let photoKey = "photo"
        static let ownerDisplayNameKey = "ownerDisplayName"
        static let mealFieldKeys: [String] = [
            titleKey, photographedAtKey, photoKey, ownerDisplayNameKey
        ]
        static let containerBundleBase = "org.pov-it"
        static let containerSuffix = "meals"
        /// pov-it Apple Team ID. Used when Info.plist `TeamID` is still a
        /// placeholder so user-visible copy never shows `<TEAM>`.
        static let knownPovItTeamID = "Q6QCL8J6FN"

        /// `iCloud.org.pov-it.<TEAMID>.meals`. Nil when the team id is missing
        /// or still a build placeholder (`TEAMID`, `$(DEVELOPMENT_TEAM)`).
        static func containerIdentifier(teamID: String) -> String? {
            let trimmed = teamID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let upper = trimmed.uppercased()
            if upper == "TEAMID" || trimmed.contains("$(") || trimmed.contains("<") { return nil }
            return "iCloud.\(containerBundleBase).\(trimmed).\(containerSuffix)"
        }
    }

    enum MealCompanionShareError: LocalizedError {
        case cloudKitUnavailable
        case missingContainer
        case missingCloudKitEntitlement
        case unreadableSigningEntitlements
        case shareURLMissing
        case productionSchemaMissing
        case underlying(String)

        var errorDescription: String? {
            switch self {
            case .cloudKitUnavailable:
                return String(localized: "CloudKit is not available on this device.", comment: "Companion share CloudKit unavailable")
            case .missingContainer:
                return String(localized: "The meals CloudKit container is not configured.", comment: "Companion share missing container")
            case .missingCloudKitEntitlement:
                return String(
                    localized: "Meals CloudKit container not entitled on this build. Refresh signing profiles and install a new build.",
                    comment: "Companion share missing CloudKit entitlement"
                )
            case .unreadableSigningEntitlements:
                return String(
                    localized: "Couldn't read signing entitlements on this build, so the meals CloudKit container cannot be confirmed.",
                    comment: "Companion share could not read code-signing entitlements"
                )
            case .shareURLMissing:
                // Idle empty state only. Create / refresh failures use
                // `inviteCreateFailed` or `diagnosticSummary` so TestFlight
                // does not show this line after a CloudKit attempt.
                return String(localized: "No invite link yet. Sign in to iCloud and tap Create invite, or publish one meal first.", comment: "Companion share URL missing")
            case .productionSchemaMissing:
                return String(
                    localized: "CloudKit Production schema missing MealFeed — deploy from CloudKit Dashboard",
                    comment: "Companion share CloudKit production schema not deployed"
                )
            case let .underlying(message):
                return message
            }
        }

        static func isProductionSchemaMissing(_ error: Error) -> Bool {
            isProductionSchemaMissing(description: flattenedCloudKitText(error))
        }

        static func isProductionSchemaMissing(description: String) -> Bool {
            let lowered = description.lowercased()
            guard lowered.contains("production schema") else { return false }
            return lowered.contains("cannot create new type")
                || lowered.contains("create new type")
        }

        static func flattenedCloudKitText(_ error: Error) -> String {
            var parts: [String] = [error.localizedDescription]
            let ns = error as NSError
            if let reason = ns.localizedFailureReason { parts.append(reason) }
            if let recovery = ns.localizedRecoverySuggestion { parts.append(recovery) }
            for key in [NSUnderlyingErrorKey, "CKErrorDescription", "NSDebugDescription"] {
                if let value = ns.userInfo[key] {
                    parts.append(String(describing: value))
                }
            }
            for inner in partialNSErrors(in: error) {
                parts.append(flattenedCloudKitText(inner))
            }
            return parts.joined(separator: "\n")
        }

        /// Create / refresh failure. Distinct from the idle “No invite link yet” copy.
        static func inviteCreateFailed(_ detail: String) -> MealCompanionShareError {
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return .underlying("Invite create failed: \(trimmed)")
        }

        /// Settings row text. CloudKit failures include the numeric code, the
        /// code name, and a short server message — not the idle empty-state line.
        static func userFacingMessage(for error: Error) -> String {
            if let typed = error as? MealCompanionShareError {
                return typed.localizedDescription ?? diagnosticSummary(error)
            }
            if isProductionSchemaMissing(error) {
                return productionSchemaMissing.localizedDescription
            }
            return diagnosticSummary(error)
        }

        static func fromCloudKit(_ error: Error) -> MealCompanionShareError {
            if let typed = error as? MealCompanionShareError {
                return typed
            }
            if isProductionSchemaMissing(error) {
                return .productionSchemaMissing
            }
            return .underlying(diagnosticSummary(error))
        }

        /// `CKError 15 (serverRejectedRequest): …`. Strips `CKRecordID` pointer dumps.
        static func diagnosticSummary(_ error: Error) -> String {
            summarize(error, depth: 0)
        }

        static func cloudKitCodeName(_ code: Int) -> String {
            switch code {
            case 1: return "internalError"
            case 2: return "partialFailure"
            case 3: return "networkUnavailable"
            case 4: return "networkFailure"
            case 5: return "badContainer"
            case 6: return "serviceUnavailable"
            case 7: return "requestRateLimited"
            case 8: return "missingEntitlement"
            case 9: return "notAuthenticated"
            case 10: return "permissionFailure"
            case 11: return "unknownItem"
            case 12: return "invalidArguments"
            case 13: return "resultsTruncated"
            case 14: return "serverRecordChanged"
            case 15: return "serverRejectedRequest"
            case 16: return "assetFileNotFound"
            case 17: return "assetFileModified"
            case 18: return "incompatibleVersion"
            case 19: return "constraintViolation"
            case 20: return "operationCancelled"
            case 21: return "changeTokenExpired"
            case 22: return "batchRequestFailed"
            case 23: return "zoneBusy"
            case 24: return "badDatabase"
            case 25: return "quotaExceeded"
            case 26: return "zoneNotFound"
            case 27: return "limitExceeded"
            case 28: return "userDeletedZone"
            case 29: return "tooManyParticipants"
            case 30: return "alreadyShared"
            case 31: return "referenceViolation"
            case 32: return "managedAccountRestricted"
            case 33: return "participantMayNeedVerification"
            case 34: return "serverResponseLost"
            case 35: return "assetNotAvailable"
            default: return "code\(code)"
            }
        }

        static func partialNSErrors(in error: Error) -> [NSError] {
            #if canImport(CloudKit)
                if let ck = error as? CKError, let partials = ck.partialErrorsByItemID {
                    return partials.values.map { $0 as NSError }
                }
            #endif
            let ns = error as NSError
            for key in ["CKPartialErrorsByItemIDKey", "CKPartialErrors"] {
                if let dict = ns.userInfo[key] as? [String: NSError], !dict.isEmpty {
                    return Array(dict.values)
                }
                if let dict = ns.userInfo[key] as? [AnyHashable: NSError], !dict.isEmpty {
                    return Array(dict.values)
                }
                if let dict = ns.userInfo[key] as? [AnyHashable: Any] {
                    let errors = dict.values.compactMap { $0 as? NSError }
                    if !errors.isEmpty { return errors }
                }
                if let dict = ns.userInfo[key] as? NSDictionary {
                    let errors = dict.allValues.compactMap { $0 as? NSError }
                    if !errors.isEmpty { return errors }
                }
            }
            return []
        }

        private static func summarize(_ error: Error, depth: Int) -> String {
            let ns = error as NSError
            var detail = bestShortMessage(ns)
            if detail.isEmpty, let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
                detail = bestShortMessage(underlying)
            }
            if depth < 2, let first = partialNSErrors(in: error).first {
                let inner = summarize(first, depth: depth + 1)
                if detail.isEmpty {
                    detail = inner
                } else if !inner.isEmpty, !detail.contains(inner) {
                    detail = "\(detail) — \(inner)"
                }
            }
            return prefixed(ns, detail: detail)
        }

        private static func prefixed(_ error: NSError, detail: String) -> String {
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            if error.domain == "CKErrorDomain" {
                let label = cloudKitCodeName(error.code)
                if trimmed.isEmpty { return "CKError \(error.code) (\(label))" }
                return "CKError \(error.code) (\(label)): \(trimmed)"
            }
            if trimmed.isEmpty { return "\(error.domain) \(error.code)" }
            return "\(error.domain) \(error.code): \(trimmed)"
        }

        private static func bestShortMessage(_ error: NSError) -> String {
            let candidates: [String?] = [
                error.userInfo["CKErrorDescription"] as? String,
                error.localizedFailureReason,
                error.userInfo[NSLocalizedDescriptionKey] as? String,
                error.localizedDescription,
                error.userInfo["NSDebugDescription"] as? String
            ]
            var best = ""
            for raw in candidates {
                guard let raw else { continue }
                let cleaned = condenseCloudKitText(raw)
                guard !cleaned.isEmpty, !isWrapper(cleaned) else { continue }
                if cleaned.count > best.count { best = cleaned }
            }
            return best
        }

        private static func isWrapper(_ text: String) -> Bool {
            let lowered = text.lowercased()
            return lowered.contains("operation couldn’t be completed")
                || lowered.contains("operation couldn't be completed")
        }

        /// Drops `CKRecordID` pointer dumps and the "Error saving record … to server:" prefix.
        static func condenseCloudKitText(_ raw: String) -> String {
            var text = raw
            if let regex = try? NSRegularExpression(pattern: "<CKRecordID:[^>]*>", options: []) {
                let range = NSRange(text.startIndex ..< text.endIndex, in: text)
                text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
            }
            if let regex = try? NSRegularExpression(pattern: "\\(CKErrorDomain error \\d+\\.\\)", options: []) {
                let range = NSRange(text.startIndex ..< text.endIndex, in: text)
                text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
            }
            if let marker = text.range(of: "to server:") {
                text = String(text[marker.upperBound...])
            }
            text = text.replacingOccurrences(of: "The operation couldn’t be completed.", with: "")
            text = text.replacingOccurrences(of: "The operation couldn't be completed.", with: "")
            text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count > 180 {
                let end = text.index(text.startIndex, offsetBy: 177)
                text = String(text[..<end]) + "..."
            }
            return text
        }
    }

    /// What to do when Create / refresh finds `MealFeedRoot`'s current share.
    /// A usable https iCloud URL is kept. A share with no URL, or a root whose
    /// share record is gone, is deleted and replaced. Healthy shares are not.
    enum MealShareInviteRecovery {
        enum LinkState: Equatable {
            case noShare
            case usableURL
            case shareWithoutURL
            case danglingShareReference
        }

        enum Plan: Equatable {
            case createShare
            case keepExistingShare
            case replaceBrokenShare
        }

        static func plan(for state: LinkState) -> Plan {
            switch state {
            case .noShare:
                return .createShare
            case .usableURL:
                return .keepExistingShare
            case .shareWithoutURL, .danglingShareReference:
                return .replaceBrokenShare
            }
        }

        /// Second attempt after an atomic save failed. Schema, auth, and network
        /// errors stay on screen; only "already shared" / dangling-reference style
        /// failures delete the share and try once more.
        static func shouldReplaceShare(
            afterFailureCode code: Int,
            partialCodes: [Int] = [],
            description: String
        ) -> Bool {
            if MealCompanionShareError.isProductionSchemaMissing(description: description) {
                return false
            }
            let recoverable: Set<Int> = [14, 22, 30, 31]
            if recoverable.contains(code) { return true }
            if code == 2 {
                return partialCodes.contains { recoverable.contains($0) }
            }
            return false
        }

        static func shouldReplaceShare(after error: Error) -> Bool {
            let ns = error as NSError
            return shouldReplaceShare(
                afterFailureCode: ns.code,
                partialCodes: MealCompanionShareError.partialNSErrors(in: error).map(\.code),
                description: MealCompanionShareError.flattenedCloudKitText(error)
            )
        }

        /// `CKAccountStatus` raw values. Used when Create / refresh cannot start a share.
        static func iCloudAccountStatusName(_ rawValue: Int) -> String {
            switch rawValue {
            case 0: return "couldNotDetermine"
            case 1: return "available"
            case 2: return "restricted"
            case 3: return "noAccount"
            case 4: return "temporarilyUnavailable"
            default: return "code\(rawValue)"
            }
        }
    }

    /// Runtime check for the **signed** iCloud CloudKit entitlement.
    /// `CKContainer(identifier:)` traps (`EXC_BREAKPOINT`) when the container
    /// is missing from the profile — never call it without this preflight.
    ///
    /// TestFlight / App Store often strip `embedded.mobileprovision`. An absent
    /// provision file is **unknown**, not “not entitled”. Read the code
    /// signature via `SecCodeCopySelf` / `SecStaticCodeCreateWithPath` +
    /// `SecCodeCopySigningInformation` (not `SecTaskCreateFromSelf`).
    /// Only report “not entitled” when a source was readable and lacks the
    /// meals container. Never call `CKContainer` unless the check is `.entitled`.
    enum MealCloudKitEntitlement {
        static let containerIdentifiersKey = "com.apple.developer.icloud-container-identifiers"
        /// `kSecCSSigningInformation` (1 << 1).
        private static let signingInformationFlags: UInt32 = 1 << 1
        private static let entitlementsDictKey = "entitlements-dict"
        private static let entitlementsBlobKey = "entitlements"

        enum SignedSource: Equatable {
            case readable([String])
            case unreadable
        }

        enum Check: Equatable {
            case entitled
            case missing
            case unreadable
        }

        static func isContainerEntitled(
            _ identifier: String,
            signedIdentifiers: [String]? = nil
        ) -> Bool {
            let source = signedIdentifiers.map { SignedSource.readable($0) }
            return check(identifier, source: source) == .entitled
        }

        static func check(
            _ identifier: String,
            source: SignedSource? = nil
        ) -> Check {
            let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .missing }
            switch source ?? signedSource() {
            case let .readable(ids):
                return ids.contains(trimmed) ? .entitled : .missing
            case .unreadable:
                return .unreadable
            }
        }

        static func signedSource() -> SignedSource {
            if let fromProvision = readIdentifiersFromEmbeddedProvision() {
                return .readable(fromProvision)
            }
            if let fromSignature = readIdentifiersFromCodeSignature() {
                return .readable(fromSignature)
            }
            return .unreadable
        }

        static func readSignedICloudContainerIdentifiers() -> [String] {
            switch signedSource() {
            case let .readable(ids): return ids
            case .unreadable: return []
            }
        }

        static func iCloudContainerIdentifiers(fromProvisioningProfile data: Data) -> [String] {
            parsedICloudContainerIdentifiers(fromProvisioningProfile: data) ?? []
        }

        private static func parsedICloudContainerIdentifiers(fromProvisioningProfile data: Data) -> [String]? {
            guard let plist = provisioningPlist(from: data),
                  let entitlements = plist["Entitlements"] as? [String: Any]
            else { return nil }
            return iCloudContainerIdentifiers(fromEntitlements: entitlements)
        }

        static func iCloudContainerIdentifiers(fromEntitlements entitlements: [String: Any]) -> [String] {
            if let list = entitlements[containerIdentifiersKey] as? [String] {
                return list
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
            if let list = entitlements[containerIdentifiersKey] as? [Any] {
                return list.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
            if let one = entitlements[containerIdentifiersKey] as? String {
                let trimmed = one.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? [] : [trimmed]
            }
            return []
        }

        private static func readIdentifiersFromEmbeddedProvision() -> [String]? {
            guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
                  let data = try? Data(contentsOf: url)
            else { return nil }
            return parsedICloudContainerIdentifiers(fromProvisioningProfile: data)
        }

        private static func readIdentifiersFromCodeSignature() -> [String]? {
            guard let entitlements = entitlementsFromCodeSignature() else { return nil }
            return iCloudContainerIdentifiers(fromEntitlements: entitlements)
        }

        /// Signed entitlements dict from this process / this bundle. Returns
        /// nil when the signature cannot be read (unknown), not when the dict
        /// is empty. Resolved with `dlsym` so this compiles when the iOS SDK
        /// does not export `SecCode*` headers (same class of gap as `SecTask*`).
        static func entitlementsFromCodeSignature() -> [String: Any]? {
            if let fromSelf = entitlementsFromSecCodeSelf() {
                return fromSelf
            }
            return entitlementsFromStaticCode(at: Bundle.main.bundleURL)
        }

        private static func entitlementsFromSecCodeSelf() -> [String: Any]? {
            typealias CopySelf = @convention(c) (UInt32, UnsafeMutablePointer<OpaquePointer?>) -> Int32
            typealias CopyStatic = @convention(c) (OpaquePointer, UInt32, UnsafeMutablePointer<OpaquePointer?>) -> Int32
            guard let copySelf = dlsymProc("SecCodeCopySelf", as: CopySelf.self),
                  let copyStatic = dlsymProc("SecCodeCopyStaticCode", as: CopyStatic.self)
            else { return nil }
            var code: OpaquePointer?
            guard copySelf(0, &code) == 0, let code else { return nil }
            var staticCode: OpaquePointer?
            guard copyStatic(code, 0, &staticCode) == 0, let staticCode else { return nil }
            return entitlements(fromStaticCodeRef: staticCode)
        }

        private static func entitlementsFromStaticCode(at url: URL) -> [String: Any]? {
            typealias CreateWithPath = @convention(c) (CFURL, UInt32, UnsafeMutablePointer<OpaquePointer?>) -> Int32
            guard let create = dlsymProc("SecStaticCodeCreateWithPath", as: CreateWithPath.self) else {
                return nil
            }
            var staticCode: OpaquePointer?
            guard create(url as CFURL, 0, &staticCode) == 0, let staticCode else { return nil }
            return entitlements(fromStaticCodeRef: staticCode)
        }

        private static func entitlements(fromStaticCodeRef staticCode: OpaquePointer) -> [String: Any]? {
            if let entitlements = entitlements(fromStaticCodeRef: staticCode, flags: signingInformationFlags) {
                return entitlements
            }
            return entitlements(fromStaticCodeRef: staticCode, flags: 0)
        }

        private static func entitlements(fromStaticCodeRef staticCode: OpaquePointer, flags: UInt32) -> [String: Any]? {
            typealias CopyInfo = @convention(c) (
                OpaquePointer,
                UInt32,
                UnsafeMutablePointer<Unmanaged<CFDictionary>?>
            ) -> Int32
            guard let copyInfo = dlsymProc("SecCodeCopySigningInformation", as: CopyInfo.self) else {
                return nil
            }
            var info: Unmanaged<CFDictionary>?
            guard copyInfo(staticCode, flags, &info) == 0, let unmanaged = info else { return nil }
            let ns = unmanaged.takeRetainedValue() as NSDictionary
            var dictionary: [String: Any] = [:]
            ns.enumerateKeysAndObjects { key, value, _ in
                if let key = key as? String {
                    dictionary[key] = value
                }
            }
            if let entitlements = dictionary[entitlementsDictKey] as? [String: Any] {
                return entitlements
            }
            if let nsEntitlements = dictionary[entitlementsDictKey] as? NSDictionary {
                return stringKeyedDictionary(nsEntitlements)
            }
            for (key, value) in dictionary where key.lowercased().contains("entitlements-dict") {
                if let entitlements = value as? [String: Any] {
                    return entitlements
                }
            }
            if let blob = dictionary[entitlementsBlobKey] as? Data {
                return entitlementsPlist(from: blob)
            }
            return nil
        }

        private static func stringKeyedDictionary(_ ns: NSDictionary) -> [String: Any] {
            var dictionary: [String: Any] = [:]
            ns.enumerateKeysAndObjects { key, value, _ in
                if let key = key as? String {
                    dictionary[key] = value
                }
            }
            return dictionary
        }

        private static func dlsymProc<T>(_ name: String, as _: T.Type) -> T? {
            guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
            return unsafeBitCast(symbol, to: T.self)
        }

        private static func entitlementsPlist(from data: Data) -> [String: Any]? {
            if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
               let dictionary = plist as? [String: Any]
            {
                return dictionary
            }
            return provisioningPlist(from: data)
        }

        private static func provisioningPlist(from data: Data) -> [String: Any]? {
            if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
               let dictionary = plist as? [String: Any]
            {
                return dictionary
            }
            let xmlProlog = data.range(of: Data("<?xml".utf8))
            let plistTag = data.range(of: Data("<plist".utf8))
            let plistEnd = Data("</plist>".utf8)
            guard let start = xmlProlog ?? plistTag,
                  let end = data.range(of: plistEnd, in: start.lowerBound ..< data.endIndex)
            else { return nil }
            let plistData = data[start.lowerBound ..< end.upperBound]
            guard let plist = try? PropertyListSerialization.propertyList(
                from: Data(plistData),
                options: [],
                format: nil
            ) else { return nil }
            return plist as? [String: Any]
        }
    }

    enum MealCompanionShareSettings {
        static let enabledKey = "ai_meal_companion_share_enabled"
        /// Optional override. Empty means derive `iCloud.org.pov-it.<TEAMID>.meals`.
        static let cloudKitContainerKey = "ai_meal_companion_cloudkit_container"
        /// Optional companion App Group identifier. MUST NOT be `trio-app-group`.
        /// Empty (the default) means we never touch an App Group suite.
        static let companionAppGroupKey = "ai_meal_companion_app_group"
        static let ownerDisplayNameKey = "ai_meal_companion_owner_display_name"
        static let shareURLKey = "ai_meal_companion_share_url"

        /// Hard-coded Trio therapy App Group suffix — never used for meals.
        static let forbiddenTrioAppGroupSuffix = "trio-app-group"

        static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
            defaults.bool(forKey: enabledKey)
        }

        static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
            defaults.set(enabled, forKey: enabledKey)
        }

        static func shareURLString(_ defaults: UserDefaults = .standard) -> String? {
            validatedICloudShareURL(from: defaults.string(forKey: shareURLKey))?.absoluteString
        }

        /// Persist only a real https iCloud share URL. Never invents or writes
        /// a placeholder — `CKShare.url` exists only after CloudKit creates the share.
        static func persistShareURL(_ url: URL?, defaults: UserDefaults = .standard) {
            guard let url = validatedICloudShareURL(url) else { return }
            defaults.set(url.absoluteString, forKey: shareURLKey)
        }

        static func persistShareURLString(_ raw: String?, defaults: UserDefaults = .standard) {
            persistShareURL(validatedICloudShareURL(from: raw), defaults: defaults)
        }

        /// CloudKit invite links are `https` URLs on an `icloud.com` host with a path
        /// (typically `/share/<token>`). Anything else is unsafe to copy or present.
        static func validatedICloudShareURL(from raw: String?) -> URL? {
            let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return validatedICloudShareURL(URL(string: trimmed))
        }

        static func validatedICloudShareURL(_ url: URL?) -> URL? {
            guard let url else { return nil }
            guard let scheme = url.scheme?.lowercased(), scheme == "https" else { return nil }
            guard let host = url.host?.lowercased() else { return nil }
            let isICloudHost = host == "icloud.com" || host.hasSuffix(".icloud.com")
            guard isICloudHost else { return nil }
            let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !path.isEmpty else { return nil }
            return url
        }

        /// Signing team if valid; otherwise pov-it's `Q6QCL8J6FN`.
        static func resolvedTeamID(signingTeamID: String = MealCompanionShareSettings.signingTeamID) -> String {
            if MealCloudKitContract.containerIdentifier(teamID: signingTeamID) != nil {
                return signingTeamID.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return MealCloudKitContract.knownPovItTeamID
        }

        static func cloudKitContainerIdentifier(
            _ defaults: UserDefaults = .standard,
            signingTeamID: String = MealCompanionShareSettings.signingTeamID
        ) -> String {
            let override = (defaults.string(forKey: cloudKitContainerKey) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !override.isEmpty { return override }
            return MealCloudKitContract.containerIdentifier(teamID: resolvedTeamID(signingTeamID: signingTeamID)) ?? ""
        }

        /// User-visible container id. Never contains `<TEAM>` / `TEAMID` / `$(...)`.
        static func displayContainerIdentifier(
            _ defaults: UserDefaults = .standard,
            signingTeamID: String = MealCompanionShareSettings.signingTeamID
        ) -> String {
            let raw = cloudKitContainerIdentifier(defaults, signingTeamID: signingTeamID)
            if let valid = MealCloudKitContract.containerIdentifier(teamID: teamID(fromContainer: raw)) {
                return valid
            }
            if raw.contains("<") || raw.contains("$(") || raw.uppercased().contains("TEAMID") || raw.isEmpty {
                return MealCloudKitContract.containerIdentifier(teamID: MealCloudKitContract.knownPovItTeamID) ?? raw
            }
            return raw
        }

        private static func teamID(fromContainer identifier: String) -> String {
            // iCloud.org.pov-it.<TEAMID>.meals
            let parts = identifier.split(separator: ".")
            guard parts.count >= 5 else { return "" }
            return String(parts[parts.count - 2])
        }

        /// `TeamID` is substituted from `$(DEVELOPMENT_TEAM)` in Info.plist.
        static var signingTeamID: String {
            let fromInfo = Bundle.main.object(forInfoDictionaryKey: "TeamID") as? String
            let fromBundle = Bundle.main.object(forInfoDictionaryKey: "DEVELOPMENT_TEAM") as? String
            return (fromInfo ?? fromBundle ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// CloudKit `ownerDisplayName` when the user has not set one.
        /// "Meal" was a placeholder and showed up as the sharer's name.
        static let defaultOwnerDisplayName = "Trio"
        static let placeholderOwnerDisplayName = "Meal"

        static func ownerDisplayName(_ defaults: UserDefaults = .standard) -> String {
            ownerDisplayNameForSave(existingCloudValue: nil, defaults: defaults)
        }

        static func setOwnerDisplayName(_ name: String?, defaults: UserDefaults = .standard) {
            let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                defaults.removeObject(forKey: ownerDisplayNameKey)
            } else {
                defaults.set(trimmed, forKey: ownerDisplayNameKey)
            }
        }

        static func storedOwnerDisplayName(_ defaults: UserDefaults = .standard) -> String {
            (defaults.string(forKey: ownerDisplayNameKey) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// Prefer a name the user typed. Otherwise keep a real CloudKit value.
        /// Replace an empty value or the old "Meal" placeholder with "Trio".
        static func ownerDisplayNameForSave(
            existingCloudValue: String?,
            defaults: UserDefaults = .standard
        ) -> String {
            let stored = storedOwnerDisplayName(defaults)
            if !stored.isEmpty, !isPlaceholderOwnerDisplayName(stored) {
                return stored
            }
            let cloud = (existingCloudValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !cloud.isEmpty, !isPlaceholderOwnerDisplayName(cloud) {
                return cloud
            }
            return defaultOwnerDisplayName
        }

        static func isPlaceholderOwnerDisplayName(_ name: String) -> Bool {
            name.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(placeholderOwnerDisplayName) == .orderedSame
        }

        static func companionAppGroupIdentifier(_ defaults: UserDefaults = .standard) -> String? {
            let raw = (defaults.string(forKey: companionAppGroupKey) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return nil }
            if raw.lowercased().contains(forbiddenTrioAppGroupSuffix) {
                return nil
            }
            return raw
        }
    }

    // MARK: - Publisher

    final class MealCompanionPublisher: @unchecked Sendable {
        static let shared = MealCompanionPublisher()

        private let defaults: UserDefaults
        private let fileManager: FileManager
        private let overrideOutbox: URL?
        private let ioQueue = DispatchQueue(label: "trio.ai.mealshare.io", qos: .utility)
        private var transports: [any MealCompanionTransport]

        var isShareEnabled: Bool {
            get { MealCompanionShareSettings.isEnabled(defaults) }
            set { MealCompanionShareSettings.setEnabled(newValue, defaults: defaults) }
        }

        convenience init() {
            self.init(defaults: .standard, fileManager: .default, outboxDirectory: nil)
        }

        init(
            defaults: UserDefaults,
            fileManager: FileManager = .default,
            outboxDirectory: URL? = nil,
            transports: [any MealCompanionTransport]? = nil
        ) {
            self.defaults = defaults
            self.fileManager = fileManager
            self.overrideOutbox = outboxDirectory
            if let transports {
                self.transports = transports
            } else {
                let outbox = SharedMealsOutboxTransport(
                    defaults: defaults,
                    fileManager: fileManager,
                    directory: outboxDirectory
                )
                self.transports = [
                    outbox,
                    CloudKitMealShareTransport(defaults: defaults)
                ]
            }
        }

        var outboxDirectoryURL: URL? {
            if let overrideOutbox { return overrideOutbox }
            guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                return nil
            }
            return base.appendingPathComponent("SharedMealsOutbox", isDirectory: true)
        }

        /// Called from gallery archive (has thumbnail) and from FoodFinder
        /// `saveRecentResults` (may not). No-op unless the user opted in.
        /// Never throws into the caller; never includes glucose fields.
        func publish(item: MealGalleryStore.GalleryItem, thumbnailJPEG: Data?) {
            publish(payload: SharedMealPayload(item: item), thumbnailJPEG: thumbnailJPEG)
        }

        func publish(result: FoodAnalysisResult, thumbnailJPEG: Data?) {
            publish(
                payload: SharedMealPayload(result: result, thumbnailFilename: nil),
                thumbnailJPEG: thumbnailJPEG
            )
        }

        func publish(payload: SharedMealPayload, thumbnailJPEG: Data?) {
            guard isShareEnabled else { return }
            if let reason = MealSharePrivacy.rejectReason(for: payload) {
                assertionFailure("Refusing to publish companion meal: \(reason)")
                return
            }
            let record = SharedMealRecord(payload: payload, thumbnailJPEG: thumbnailJPEG)
            let transports = self.transports
            ioQueue.async {
                Task {
                    for transport in transports {
                        await transport.publish(record)
                    }
                }
            }
        }

        func storedShareURLString() -> String? {
            MealCompanionShareSettings.shareURLString(defaults)
        }

        /// Creates or refreshes the `CKShare` on `MealFeed` without publishing a meal
        /// (and never writes glucose / IOB / COB / Nightscout).
        func ensureInviteShare() async -> Result<String, Error> {
            let transport = transports.compactMap { $0 as? CloudKitMealShareTransport }.first
                ?? CloudKitMealShareTransport(defaults: defaults)
            return await transport.ensureInviteShare()
        }
    }

    // MARK: - Outbox (offline-first, works without CloudKit / App Group)

    final class SharedMealsOutboxTransport: MealCompanionTransport, @unchecked Sendable {
        private let defaults: UserDefaults
        private let fileManager: FileManager
        private let overrideDirectory: URL?
        private static let publishedIDsKey = "ai_meal_companion_outbox_ids"

        init(defaults: UserDefaults = .standard, fileManager: FileManager = .default, directory: URL? = nil) {
            self.defaults = defaults
            self.fileManager = fileManager
            self.overrideDirectory = directory
        }

        private var directoryURL: URL? {
            if let overrideDirectory { return overrideDirectory }
            guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                return nil
            }
            return base.appendingPathComponent("SharedMealsOutbox", isDirectory: true)
        }

        func publish(_ record: SharedMealRecord) async {
            guard let dir = ensureDirectory() else { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            encoder.dateEncodingStrategy = .iso8601
            guard let json = try? encoder.encode(record.payload) else { return }
            if let reason = MealSharePrivacy.rejectReason(for: record.payload) {
                assertionFailure("Outbox refused companion meal: \(reason)")
                return
            }

            let jsonURL = dir.appendingPathComponent("\(record.payload.id.uuidString).json", isDirectory: false)
            if fileManager.fileExists(atPath: jsonURL.path), record.thumbnailJPEG == nil {
                return
            }
            try? json.write(to: jsonURL, options: .atomic)

            if let jpeg = record.thumbnailJPEG, !jpeg.isEmpty {
                let jpgURL = dir.appendingPathComponent("\(record.payload.id.uuidString).jpg", isDirectory: false)
                try? jpeg.write(to: jpgURL, options: .atomic)
            }

            var ids = defaults.stringArray(forKey: Self.publishedIDsKey) ?? []
            let idString = record.payload.id.uuidString
            if !ids.contains(idString) {
                ids.append(idString)
                defaults.set(ids, forKey: Self.publishedIDsKey)
            }

            writeCompanionAppGroupIndexIfConfigured(record.payload)
        }

        func loadPublishedIDs() -> [String] {
            defaults.stringArray(forKey: Self.publishedIDsKey) ?? []
        }

        func loadPayload(id: UUID) -> SharedMealPayload? {
            guard let dir = directoryURL else { return nil }
            let url = dir.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
            guard let data = try? Data(contentsOf: url) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(SharedMealPayload.self, from: data)
        }

        private func ensureDirectory() -> URL? {
            guard let dir = directoryURL else { return nil }
            if !fileManager.fileExists(atPath: dir.path) {
                try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            return dir
        }

        /// Optional mirror of the meal-only JSON into a dedicated companion
        /// App Group. Refuses `trio-app-group` so Nightscout/CGM App Group
        /// state cannot be mixed into the companion suite.
        private func writeCompanionAppGroupIndexIfConfigured(_ payload: SharedMealPayload) {
            guard let suiteName = MealCompanionShareSettings.companionAppGroupIdentifier(defaults),
                  let suite = UserDefaults(suiteName: suiteName)
            else { return }
            guard let data = try? JSONEncoder().encode(payload) else { return }
            if MealSharePrivacy.rejectReason(for: payload) != nil { return }
            suite.set(data, forKey: "sharedMeal.\(payload.id.uuidString)")
        }
    }

    // MARK: - CloudKit (Meal / MealFeed in iCloud.org.pov-it.<TEAMID>.meals)

    final class CloudKitMealShareTransport: MealCompanionTransport, @unchecked Sendable {
        private let defaults: UserDefaults
        private let fileManager: FileManager

        init(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
            self.defaults = defaults
            self.fileManager = fileManager
        }

        func publish(_ record: SharedMealRecord) async {
            if MealSharePrivacy.rejectReason(for: record.payload) != nil { return }
            let containerID = MealCompanionShareSettings.cloudKitContainerIdentifier(defaults)
            guard !containerID.isEmpty else { return }
            guard MealCloudKitEntitlement.check(containerID) == .entitled else { return }

            #if canImport(CloudKit)
                do {
                    try await saveToCloudKit(record, containerID: containerID)
                } catch {
                    // Local outbox already holds the meal; CloudKit can catch up later.
                }
            #endif
        }

        func ensureInviteShare() async -> Result<String, Error> {
            #if canImport(CloudKit)
                let containerID = MealCompanionShareSettings.cloudKitContainerIdentifier(defaults)
                guard !containerID.isEmpty else { return .failure(MealCompanionShareError.missingContainer) }
                switch MealCloudKitEntitlement.check(containerID) {
                case .entitled:
                    break
                case .missing:
                    return .failure(MealCompanionShareError.missingCloudKitEntitlement)
                case .unreadable:
                    return .failure(MealCompanionShareError.unreadableSigningEntitlements)
                }
                do {
                    let url = try await createOrRefreshShare(containerID: containerID)
                    if let validated = MealCompanionShareSettings.validatedICloudShareURL(from: url) {
                        return .success(validated.absoluteString)
                    }
                    let shown = url.count > 120 ? String(url.prefix(117)) + "..." : url
                    return .failure(
                        MealCompanionShareError.inviteCreateFailed(
                            "CloudKit returned \"\(shown)\" which is not an https iCloud share link."
                        )
                    )
                } catch let error as MealCompanionShareError {
                    return .failure(error)
                } catch {
                    return .failure(MealCompanionShareError.fromCloudKit(error))
                }
            #else
                return .failure(MealCompanionShareError.cloudKitUnavailable)
            #endif
        }

        #if canImport(CloudKit)
            /// The only `CKContainer(identifier:)` call site. `_checkRequiredEntitlements`
            /// is a SIGTRAP, not a Swift error — never reach it without the preflight.
            private func entitledPrivateDatabase(containerID: String) throws -> CKDatabase {
                switch MealCloudKitEntitlement.check(containerID) {
                case .entitled:
                    return CKContainer(identifier: containerID).privateCloudDatabase
                case .missing:
                    throw MealCompanionShareError.missingCloudKitEntitlement
                case .unreadable:
                    throw MealCompanionShareError.unreadableSigningEntitlements
                }
            }

            private func saveToCloudKit(_ record: SharedMealRecord, containerID: String) async throws {
                let database = try entitledPrivateDatabase(containerID: containerID)
                let feed = try await ensureFeed(database: database)
                let zoneID = feed.recordID.zoneID

                let owner = MealCompanionShareSettings.ownerDisplayName(defaults)
                let mealID = CKRecord.ID(recordName: record.payload.id.uuidString, zoneID: zoneID)
                let meal = CKRecord(recordType: MealCloudKitContract.mealRecordType, recordID: mealID)
                meal.parent = CKRecord.Reference(recordID: feed.recordID, action: .none)
                meal[MealCloudKitContract.titleKey] = (record.payload.mealName ?? "Meal") as NSString
                meal[MealCloudKitContract.photographedAtKey] = record.payload.date as NSDate
                meal[MealCloudKitContract.ownerDisplayNameKey] = owner as NSString
                if let jpeg = record.thumbnailJPEG, !jpeg.isEmpty,
                   let asset = try? ckAsset(from: jpeg, id: record.payload.id)
                {
                    meal[MealCloudKitContract.photoKey] = asset
                }
                // Never write carbs / glucose / IOB / COB / Nightscout onto Meal.
                _ = try await database.save(meal)

                if MealCompanionShareSettings.shareURLString(defaults) == nil {
                    _ = try? await ensureShare(database: database, feed: feed)
                }
            }

            private struct ShareSavedWithoutURL: Error {
                var summary: String

                func detail(previous: String?) -> String {
                    var text = "CloudKit returned no share URL (\(summary))"
                    if let previous, !previous.isEmpty {
                        text += " after \(previous)"
                    }
                    return text
                }
            }

            private struct ShareInspection {
                var state: MealShareInviteRecovery.LinkState
                var url: String?
                var shareID: CKRecord.ID?
                var reason: String?
            }

            private func createOrRefreshShare(containerID: String) async throws -> String {
                try await requireAvailableICloudAccount(containerID: containerID)
                let database = try entitledPrivateDatabase(containerID: containerID)
                let feed = try await ensureFeed(database: database)
                let named = await repairPlaceholderOwnerName(database: database, feed: feed)
                // No share on the server is the common Production case: create one.
                // A lookup error must surface; it must not become the idle
                // "No invite link yet" line.
                if let existing = try await existingShareURL(database: database, feed: named) {
                    MealCompanionShareSettings.persistShareURLString(existing, defaults: defaults)
                    return existing
                }
                do {
                    return try await ensureShare(database: database, feed: named)
                } catch {
                    if let existing = try? await existingShareURL(database: database, feed: named) {
                        MealCompanionShareSettings.persistShareURLString(existing, defaults: defaults)
                        return existing
                    }
                    throw error
                }
            }

            private func requireAvailableICloudAccount(containerID: String) async throws {
                switch MealCloudKitEntitlement.check(containerID) {
                case .entitled:
                    break
                case .missing:
                    throw MealCompanionShareError.missingCloudKitEntitlement
                case .unreadable:
                    throw MealCompanionShareError.unreadableSigningEntitlements
                }
                let status: CKAccountStatus
                do {
                    status = try await CKContainer(identifier: containerID).accountStatus()
                } catch {
                    throw MealCompanionShareError.fromCloudKit(error)
                }
                guard status == .available else {
                    let name = MealShareInviteRecovery.iCloudAccountStatusName(status.rawValue)
                    throw MealCompanionShareError.inviteCreateFailed(
                        "iCloud account \(name) (\(status.rawValue)). Sign in to iCloud and try Create invite again."
                    )
                }
            }

            /// Rewrites ownerDisplayName "Meal" (the old empty-setting placeholder)
            /// before the share save. A rename failure does not block the invite.
            private func repairPlaceholderOwnerName(database: CKDatabase, feed: CKRecord) async -> CKRecord {
                let existing = feed[MealCloudKitContract.ownerDisplayNameKey] as? String
                let resolved = MealCompanionShareSettings.ownerDisplayNameForSave(
                    existingCloudValue: existing,
                    defaults: defaults
                )
                guard (existing ?? "") != resolved else { return feed }
                feed[MealCloudKitContract.ownerDisplayNameKey] = resolved as NSString
                do {
                    return try await database.save(feed)
                } catch {
                    return feed
                }
            }

            private func ensureFeed(database: CKDatabase) async throws -> CKRecord {
                let zoneID = CKRecordZone.ID(zoneName: MealCloudKitContract.zoneName, ownerName: CKCurrentUserDefaultName)
                try await ensureZone(database: database, zoneID: zoneID)
                let feedID = CKRecord.ID(
                    recordName: MealCloudKitContract.feedRecordName,
                    zoneID: zoneID
                )
                do {
                    return try await database.record(for: feedID)
                } catch let error as CKError where error.code == .unknownItem {
                    return try await database.save(makeUnsavedFeed(recordID: feedID))
                } catch {
                    throw MealCompanionShareError.fromCloudKit(error)
                }
            }

            /// Network and auth errors propagate. `unknownItem` on the share record
            /// means the root's link is dangling and the caller may replace it.
            private func existingShareURL(database: CKDatabase, feed: CKRecord) async throws -> String? {
                let latest: CKRecord
                do {
                    latest = try await database.record(for: feed.recordID)
                } catch let error as CKError where error.code == .unknownItem {
                    latest = feed
                }
                guard let shareRef = latest.share else { return nil }
                do {
                    let record = try await database.record(for: shareRef.recordID)
                    guard let share = record as? CKShare else { return nil }
                    return MealCompanionShareSettings.validatedICloudShareURL(share.url)?.absoluteString
                } catch let error as CKError where error.code == .unknownItem {
                    return nil
                }
            }

            private func ensureZone(database: CKDatabase, zoneID: CKRecordZone.ID) async throws {
                let zone = CKRecordZone(zoneID: zoneID)
                do {
                    _ = try await database.save(zone)
                } catch let error as CKError where error.code == .serverRecordChanged || error.code == .zoneNotFound {
                    // zoneNotFound on save is unexpected; serverRecordChanged means it exists.
                } catch let error as CKError where error.code == .networkFailure || error.code == .networkUnavailable {
                    throw error
                } catch {
                    // Zone may already exist.
                }
            }

            /// Primary path: `MealFeedRoot` has no share (what Production dashboard
            /// showed). Save the root and a new `CKShare` together. `changedKeys`
            /// first, then one `ifServerRecordUnchanged` retry on a fresh fetch.
            /// A root that already points at a share with no https iCloud URL is
            /// detached once, then saved the same way. Failures keep the CKError.
            @discardableResult
            private func ensureShare(database: CKDatabase, feed: CKRecord) async throws -> String {
                let current = try await refreshedFeed(database: database, feed: feed)
                let inspection = try await classifyShare(database: database, feed: current)
                switch MealShareInviteRecovery.plan(for: inspection.state) {
                case .keepExistingShare:
                    guard let url = inspection.url else {
                        throw MealCompanionShareError.inviteCreateFailed(
                            "MealFeed share was marked usable but had no iCloud URL."
                        )
                    }
                    MealCompanionShareSettings.persistShareURLString(url, defaults: defaults)
                    return url
                case .replaceBrokenShare:
                    let cleared = try await clearStuckShare(
                        database: database,
                        feed: current,
                        shareID: inspection.shareID
                    )
                    return try await createShareOnUnsharedRoot(database: database, feed: cleared)
                case .createShare:
                    return try await createShareOnUnsharedRoot(database: database, feed: current)
                }
            }

            /// No share reference on the root. Do not delete `MealFeedRoot`.
            private func createShareOnUnsharedRoot(database: CKDatabase, feed: CKRecord) async throws -> String {
                let root = feed.share == nil
                    ? feed
                    : try await clearStuckShare(database: database, feed: feed, shareID: feed.share?.recordID)
                do {
                    return try await saveRootAndShare(
                        database: database,
                        feed: root,
                        savePolicy: .changedKeys
                    )
                } catch let first as ShareSavedWithoutURL {
                    let clean = try await refreshedFeed(database: database, feed: root)
                    let retryRoot = clean.share == nil
                        ? clean
                        : try await clearStuckShare(database: database, feed: clean, shareID: clean.share?.recordID)
                    do {
                        return try await saveRootAndShare(
                            database: database,
                            feed: retryRoot,
                            savePolicy: .ifServerRecordUnchanged
                        )
                    } catch let second as ShareSavedWithoutURL {
                        throw MealCompanionShareError.inviteCreateFailed(
                            second.detail(previous: first.summary)
                        )
                    } catch {
                        throw wrappedShareSaveError(error)
                    }
                } catch {
                    if let recoveredURL = try await urlIfConflictHasShare(
                        database: database,
                        feed: root,
                        error: error
                    ) {
                        MealCompanionShareSettings.persistShareURLString(recoveredURL, defaults: defaults)
                        return recoveredURL
                    }
                    guard MealShareInviteRecovery.shouldReplaceShare(after: error) else {
                        throw wrappedShareSaveError(error)
                    }
                    let latest = try await recordOrUnsaved(
                        database: database,
                        recordID: root.recordID,
                        ownerFrom: root
                    )
                    let retryRoot = latest.share == nil
                        ? latest
                        : try await clearStuckShare(database: database, feed: latest, shareID: latest.share?.recordID)
                    do {
                        return try await saveRootAndShare(
                            database: database,
                            feed: retryRoot,
                            savePolicy: .ifServerRecordUnchanged
                        )
                    } catch let second as ShareSavedWithoutURL {
                        throw MealCompanionShareError.inviteCreateFailed(
                            second.detail(previous: MealCompanionShareError.diagnosticSummary(error))
                        )
                    } catch {
                        throw wrappedShareSaveError(error)
                    }
                }
            }

            private func wrappedShareSaveError(_ error: Error) -> Error {
                MealCompanionShareError.fromCloudKit(error)
            }

            private func refreshedFeed(database: CKDatabase, feed: CKRecord) async throws -> CKRecord {
                do {
                    let latest = try await database.record(for: feed.recordID)
                    guard latest.recordType == MealCloudKitContract.feedRecordType else {
                        throw MealCompanionShareError.inviteCreateFailed(
                            "expected record type MealFeed, found \(latest.recordType)."
                        )
                    }
                    return latest
                } catch let error as CKError where error.code == .unknownItem {
                    return makeUnsavedFeed(recordID: feed.recordID, copying: feed)
                } catch let error as MealCompanionShareError {
                    throw error
                } catch {
                    throw MealCompanionShareError.fromCloudKit(error)
                }
            }

            private func classifyShare(database: CKDatabase, feed: CKRecord) async throws -> ShareInspection {
                let latest: CKRecord
                do {
                    latest = try await database.record(for: feed.recordID)
                } catch let error as CKError where error.code == .unknownItem {
                    latest = feed
                } catch let error as MealCompanionShareError {
                    throw error
                } catch {
                    throw MealCompanionShareError.fromCloudKit(error)
                }
                if latest.recordChangeTag != nil, latest.recordType != MealCloudKitContract.feedRecordType {
                    throw MealCompanionShareError.inviteCreateFailed(
                        "expected record type MealFeed, found \(latest.recordType)."
                    )
                }
                guard let shareRef = latest.share else {
                    return ShareInspection(state: .noShare, url: nil, shareID: nil, reason: nil)
                }
                do {
                    let record = try await database.record(for: shareRef.recordID)
                    guard let share = record as? CKShare else {
                        return ShareInspection(
                            state: .shareWithoutURL,
                            url: nil,
                            shareID: shareRef.recordID,
                            reason: "linked record \(record.recordID.recordName) is \(record.recordType), not a share"
                        )
                    }
                    if let url = MealCompanionShareSettings.validatedICloudShareURL(share.url)?.absoluteString {
                        return ShareInspection(state: .usableURL, url: url, shareID: share.recordID, reason: nil)
                    }
                    let raw = share.url?.absoluteString ?? "nil"
                    let shown = raw.count > 80 ? String(raw.prefix(77)) + "..." : raw
                    return ShareInspection(
                        state: .shareWithoutURL,
                        url: nil,
                        shareID: share.recordID,
                        reason: "CKShare.url unusable (\(shown))"
                    )
                } catch let error as CKError where error.code == .unknownItem {
                    return ShareInspection(
                        state: .danglingShareReference,
                        url: nil,
                        shareID: shareRef.recordID,
                        reason: "CKShare record missing (CKError 11 unknownItem)"
                    )
                } catch let error as MealCompanionShareError {
                    throw error
                } catch {
                    throw MealCompanionShareError.fromCloudKit(error)
                }
            }

            /// Deletes the broken share. If `MealFeedRoot` still points at a share,
            /// deletes that root too and returns an unsaved replacement with the
            /// same record name so child `Meal` parent refs stay valid. The caller
            /// saves the replacement together with a new `CKShare`.
            private func clearStuckShare(
                database: CKDatabase,
                feed: CKRecord,
                shareID: CKRecord.ID?
            ) async throws -> CKRecord {
                if let shareID {
                    try await deleteIfPresent(database: database, recordID: shareID)
                }
                let latest: CKRecord
                do {
                    latest = try await database.record(for: feed.recordID)
                } catch let error as CKError where error.code == .unknownItem {
                    return makeUnsavedFeed(recordID: feed.recordID, copying: feed)
                } catch {
                    throw MealCompanionShareError.fromCloudKit(error)
                }
                if latest.share == nil {
                    return latest
                }
                if let leftover = latest.share?.recordID, leftover != shareID {
                    try await deleteIfPresent(database: database, recordID: leftover)
                }
                do {
                    let refetched = try await database.record(for: feed.recordID)
                    if refetched.share == nil {
                        return refetched
                    }
                } catch let error as CKError where error.code == .unknownItem {
                    return makeUnsavedFeed(recordID: feed.recordID, copying: latest)
                } catch {
                    throw MealCompanionShareError.fromCloudKit(error)
                }
                try await deleteIfPresent(database: database, recordID: latest.recordID)
                return makeUnsavedFeed(recordID: feed.recordID, copying: latest)
            }

            private func saveRootAndShare(
                database: CKDatabase,
                feed: CKRecord,
                savePolicy: CKModifyRecordsOperation.RecordSavePolicy
            ) async throws -> String {
                if feed.share != nil {
                    throw MealCompanionShareError.inviteCreateFailed(
                        "MealFeedRoot still has a share reference, so a new CKShare was not saved."
                    )
                }
                applyOwnerDisplayName(to: feed)
                let share = CKShare(rootRecord: feed)
                // readOnly: the copied iCloud link is the invite. `.none` only
                // admits participants added by Apple ID, which this screen does not collect.
                share.publicPermission = .readOnly
                share[CKShare.SystemFieldKey.title] = "Meals" as NSString
                let outcome = try await database.modifyRecords(
                    saving: [feed, share],
                    deleting: [],
                    savePolicy: savePolicy,
                    atomically: true
                )
                try throwIfAnySaveFailed(outcome.saveResults)
                if let url = firstValidatedShareURL(in: outcome.saveResults, fallback: share) {
                    MealCompanionShareSettings.persistShareURLString(url, defaults: defaults)
                    return url
                }
                var summary = saveResultSummary(outcome.saveResults, policy: savePolicy)
                if feed.recordChangeTag != nil || feed.creationDate != nil {
                    do {
                        let inspection = try await classifyShare(database: database, feed: feed)
                        if inspection.state == .usableURL, let url = inspection.url {
                            MealCompanionShareSettings.persistShareURLString(url, defaults: defaults)
                            return url
                        }
                    } catch {
                        summary += "; refetch \(MealCompanionShareError.diagnosticSummary(error))"
                    }
                }
                throw ShareSavedWithoutURL(summary: summary)
            }

            private func applyOwnerDisplayName(to feed: CKRecord) {
                let existing = feed[MealCloudKitContract.ownerDisplayNameKey] as? String
                let resolved = MealCompanionShareSettings.ownerDisplayNameForSave(
                    existingCloudValue: existing,
                    defaults: defaults
                )
                guard (existing ?? "") != resolved else { return }
                feed[MealCloudKitContract.ownerDisplayNameKey] = resolved as NSString
            }

            private func saveResultSummary(
                _ saveResults: [CKRecord.ID: Result<CKRecord, any Error>],
                policy: CKModifyRecordsOperation.RecordSavePolicy
            ) -> String {
                let policyName: String
                switch policy {
                case .changedKeys: policyName = "changedKeys"
                case .allKeys: policyName = "allKeys"
                case .ifServerRecordUnchanged: policyName = "ifServerRecordUnchanged"
                @unknown default: policyName = "savePolicy"
                }
                if saveResults.isEmpty {
                    return "\(policyName), saveResults empty, MealFeedRoot.share still unset"
                }
                var parts = ["\(policyName)"]
                for (id, result) in saveResults {
                    switch result {
                    case let .success(record):
                        if let savedShare = record as? CKShare {
                            let raw = savedShare.url?.absoluteString ?? "nil"
                            let shown = raw.count > 80 ? String(raw.prefix(77)) + "..." : raw
                            parts.append("CKShare \(id.recordName) url=\(shown)")
                        } else {
                            let linked = record.share == nil ? "no share ref" : "share ref set"
                            parts.append("\(record.recordType) \(linked)")
                        }
                    case let .failure(error):
                        parts.append(MealCompanionShareError.diagnosticSummary(error))
                    }
                }
                return parts.joined(separator: "; ")
            }

            private func urlIfConflictHasShare(
                database: CKDatabase,
                feed: CKRecord,
                error: Error
            ) async throws -> String? {
                guard let ck = error as? CKError, isShareConflict(ck) else { return nil }
                return try await existingShareURLAfterConflict(database: database, feed: feed, error: ck)
            }

            private func recordOrUnsaved(
                database: CKDatabase,
                recordID: CKRecord.ID,
                ownerFrom: CKRecord
            ) async throws -> CKRecord {
                do {
                    return try await database.record(for: recordID)
                } catch let error as CKError where error.code == .unknownItem {
                    return makeUnsavedFeed(recordID: recordID, copying: ownerFrom)
                } catch {
                    throw MealCompanionShareError.fromCloudKit(error)
                }
            }

            private func makeUnsavedFeed(recordID: CKRecord.ID, copying ownerFrom: CKRecord? = nil) -> CKRecord {
                let feed = CKRecord(recordType: MealCloudKitContract.feedRecordType, recordID: recordID)
                let copied = (ownerFrom?[MealCloudKitContract.ownerDisplayNameKey] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let owner = (copied?.isEmpty == false ? copied : nil)
                    ?? MealCompanionShareSettings.ownerDisplayName(defaults)
                feed[MealCloudKitContract.ownerDisplayNameKey] = owner as NSString
                return feed
            }

            private func deleteIfPresent(database: CKDatabase, recordID: CKRecord.ID) async throws {
                do {
                    let outcome = try await database.modifyRecords(
                        saving: [],
                        deleting: [recordID],
                        savePolicy: .ifServerRecordUnchanged,
                        atomically: true
                    )
                    for (_, result) in outcome.deleteResults {
                        if case let .failure(error) = result {
                            if let ck = error as? CKError, deleteIsAlreadyGone(ck) { continue }
                            throw error
                        }
                    }
                } catch let error as CKError where deleteIsAlreadyGone(error) {
                    return
                }
            }

            private func deleteIsAlreadyGone(_ error: CKError) -> Bool {
                if error.code == .unknownItem { return true }
                guard error.code == .partialFailure || error.code == .batchRequestFailed,
                      let partials = error.partialErrorsByItemID,
                      !partials.isEmpty
                else { return false }
                return partials.values.allSatisfy { inner in
                    (inner as? CKError)?.code == .unknownItem
                }
            }

            private func throwIfAnySaveFailed(
                _ saveResults: [CKRecord.ID: Result<CKRecord, any Error>]
            ) throws {
                let failures: [Error] = saveResults.compactMap { _, result in
                    if case let .failure(error) = result { return error }
                    return nil
                }
                guard let first = failures.first else { return }
                if failures.count == 1 {
                    throw first
                }
                let details = failures.map { MealCompanionShareError.diagnosticSummary($0) }.joined(separator: " — ")
                throw MealCompanionShareError.inviteCreateFailed(details)
            }

            private func firstValidatedShareURL(
                in saveResults: [CKRecord.ID: Result<CKRecord, any Error>],
                fallback: CKShare
            ) -> String? {
                for (_, result) in saveResults {
                    if case let .success(record) = result,
                       let savedShare = record as? CKShare,
                       let url = MealCompanionShareSettings.validatedICloudShareURL(savedShare.url)
                    {
                        return url.absoluteString
                    }
                }
                return MealCompanionShareSettings.validatedICloudShareURL(fallback.url)?.absoluteString
            }

            private func isShareConflict(_ error: CKError) -> Bool {
                switch error.code {
                case .alreadyShared, .serverRecordChanged, .partialFailure, .batchRequestFailed, .referenceViolation:
                    return true
                default:
                    return false
                }
            }

            private func existingShareURLAfterConflict(
                database: CKDatabase,
                feed: CKRecord,
                error: CKError
            ) async throws -> String? {
                if let existing = try await existingShareURL(database: database, feed: feed) {
                    return existing
                }
                if let serverRecord = error.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord {
                    if let share = serverRecord as? CKShare,
                       let url = MealCompanionShareSettings.validatedICloudShareURL(share.url)
                    {
                        return url.absoluteString
                    }
                    if let existing = try await existingShareURL(database: database, feed: serverRecord) {
                        return existing
                    }
                }
                if let partials = error.partialErrorsByItemID {
                    for (_, inner) in partials {
                        guard let innerCK = inner as? CKError else { continue }
                        if let url = try await existingShareURLAfterConflict(
                            database: database,
                            feed: feed,
                            error: innerCK
                        ) {
                            return url
                        }
                    }
                }
                return nil
            }

            private func ckAsset(from jpeg: Data, id: UUID) throws -> CKAsset {
                let dir = fileManager.temporaryDirectory.appendingPathComponent("MealCompanionCK", isDirectory: true)
                if !fileManager.fileExists(atPath: dir.path) {
                    try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
                }
                let url = dir.appendingPathComponent("\(id.uuidString).jpg")
                try jpeg.write(to: url, options: .atomic)
                return CKAsset(fileURL: url)
            }
        #endif
    }
}
