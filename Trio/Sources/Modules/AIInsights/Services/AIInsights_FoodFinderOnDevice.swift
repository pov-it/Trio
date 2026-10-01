import Foundation
#if compiler(>=6.4)
    #if canImport(FoundationModels)
        import FoundationModels
        import ImageIO
        import UIKit
    #endif
#endif

extension AIInsights {
    /// Where a meal-photo estimate came from. Older saved meals leave this nil.
    enum FoodFinderPhotoEngine: String, Codable, Sendable {
        case gemini
        case onDevice

        var columnTitle: String {
            switch self {
            case .gemini:
                return String(localized: "Gemini", comment: "FoodFinder Gemini column title")
            case .onDevice:
                return String(localized: "On-device", comment: "FoodFinder on-device column title")
            }
        }

        var localizedCaption: String {
            switch self {
            case .gemini:
                return String(
                    localized: "Cloud estimate. Edit the numbers before you use them.",
                    comment: "FoodFinder Gemini photo estimate caption"
                )
            case .onDevice:
                return String(
                    localized: "On-device estimate. Edit the numbers before you use them.",
                    comment: "FoodFinder on-device photo estimate caption"
                )
            }
        }
    }

    /// Kept so older settings still decode. Meal photos always run both engines
    /// when they can; this value no longer hides a column.
    enum FoodFinderPhotoEnginePreference: String, CaseIterable, Identifiable, Codable, JSON, Sendable {
        case automatic
        case cloud
        case onDevice

        var id: String { rawValue }

        var localizedTitle: String {
            switch self {
            case .automatic:
                return String(localized: "Automatic", comment: "FoodFinder photo engine automatic")
            case .cloud:
                return String(localized: "Gemini", comment: "FoodFinder photo engine Gemini")
            case .onDevice:
                return String(localized: "On this iPhone", comment: "FoodFinder photo engine on device")
            }
        }
    }

    /// Why `SystemLanguageModel` cannot accept a meal photo right now.
    enum FoodFinderOnDeviceBlocker: Equatable, Sendable {
        case appleIntelligenceNotEnabled
        case available
        case deviceNotEligible
        case modelNotReady
        case operatingSystem
        case other
        case sdk

        var localizedMessage: String {
            switch self {
            case .appleIntelligenceNotEnabled:
                return String(
                    localized: "Turn on Apple Intelligence to analyze meal photos on this iPhone.",
                    comment: "FoodFinder on-device Apple Intelligence off"
                )
            case .available:
                return String(localized: "On-device model is ready.", comment: "FoodFinder on-device ready status")
            case .deviceNotEligible:
                return String(
                    localized: "This iPhone can't analyze meal photos on-device.",
                    comment: "FoodFinder on-device device ineligible"
                )
            case .modelNotReady:
                return String(
                    localized: "The on-device model is still downloading.",
                    comment: "FoodFinder on-device model not ready"
                )
            case .operatingSystem:
                return String(
                    localized: "On-device meal photos need iOS 27.",
                    comment: "FoodFinder on-device OS requirement"
                )
            case .other:
                return String(
                    localized: "On-device meal photos are unavailable right now.",
                    comment: "FoodFinder on-device unavailable"
                )
            case .sdk:
                return String(
                    localized: "This build was made with an older Xcode, so meal photos use Gemini.",
                    comment: "FoodFinder on-device SDK unavailable"
                )
            }
        }
    }

    /// One engine's meal-photo estimate, including a visible failure.
    struct FoodFinderPhotoSide: Codable, Sendable {
        enum Outcome: String, Codable, Sendable {
            case failed
            case ready
            case unavailable
            /// Still running; the meal already shows the other engine's estimate.
            case pending
        }

        var outcome: Outcome
        var message: String?
        var mealName: String?
        var mealPortion: String?
        var items: [FoodItem]
        var carbs: Double
        var fat: Double
        var protein: Double
        var fiber: Double
        var calories: Double

        var macros: FoodFinderPhotoAgreement.Macros {
            FoodFinderPhotoAgreement.Macros(
                name: mealName ?? "",
                carbs: carbs,
                fat: fat,
                protein: protein,
                calories: calories
            )
        }

        static func ready(mealName: String?, mealPortion: String?, items: [FoodItem]) -> Self {
            Self(
                outcome: .ready,
                message: nil,
                mealName: mealName,
                mealPortion: mealPortion,
                items: items,
                carbs: items.reduce(0) { $0 + $1.adjustedCarbs },
                fat: items.reduce(0) { $0 + $1.adjustedFat },
                protein: items.reduce(0) { $0 + $1.adjustedProtein },
                fiber: items.reduce(0) { $0 + $1.adjustedFiber },
                calories: items.reduce(0) { $0 + $1.adjustedCalories }
            )
        }

        static func unavailable(_ message: String) -> Self {
            Self(
                outcome: .unavailable,
                message: message,
                mealName: nil,
                mealPortion: nil,
                items: [],
                carbs: 0,
                fat: 0,
                protein: 0,
                fiber: 0,
                calories: 0
            )
        }

        static let pending = FoodFinderPhotoSide(
            outcome: .pending,
            message: nil,
            mealName: nil,
            mealPortion: nil,
            items: [],
            carbs: 0,
            fat: 0,
            protein: 0,
            fiber: 0,
            calories: 0
        )

        static func failed(_ message: String) -> Self {
            Self(
                outcome: .failed,
                message: message,
                mealName: nil,
                mealPortion: nil,
                items: [],
                carbs: 0,
                fat: 0,
                protein: 0,
                fiber: 0,
                calories: 0
            )
        }
    }

    /// Both photo estimates plus the agreement of their macros.
    /// The logged meal starts as Gemini when that side succeeded.
    struct FoodFinderPhotoComparison: Codable, Sendable {
        var onDevice: FoodFinderPhotoSide
        var gemini: FoodFinderPhotoSide
        /// 0...100 when both sides are ready. Nil means agreement is not available.
        var agreementPercent: Int?
        var adoptedEngine: FoodFinderPhotoEngine
        var geminiLowerBound: Double?
        var geminiUpperBound: Double?
        var geminiUncertaintyUnits: Double?
        var geminiCandidateCount: Int?
        var geminiDoseGuardApplied: Bool?

        static func make(onDevice: FoodFinderPhotoSide, gemini: FoodFinderPhotoSide) -> Self? {
            let adopted: FoodFinderPhotoEngine
            if gemini.outcome == .ready {
                adopted = .gemini
            } else if onDevice.outcome == .ready {
                adopted = .onDevice
            } else {
                return nil
            }
            let agreement: Int?
            if onDevice.outcome == .ready, gemini.outcome == .ready {
                agreement = FoodFinderPhotoAgreement.percent(onDevice.macros, gemini.macros)
            } else {
                agreement = nil
            }
            return Self(
                onDevice: onDevice,
                gemini: gemini,
                agreementPercent: agreement,
                adoptedEngine: adopted,
                geminiLowerBound: nil,
                geminiUpperBound: nil,
                geminiUncertaintyUnits: nil,
                geminiCandidateCount: nil,
                geminiDoseGuardApplied: nil
            )
        }

        /// Fills in the on-device side once it finishes, keeping the adopted engine and Gemini's diagnostics.
        mutating func completeOnDevice(_ side: FoodFinderPhotoSide) {
            onDevice = side
            if onDevice.outcome == .ready, gemini.outcome == .ready {
                agreementPercent = FoodFinderPhotoAgreement.percent(onDevice.macros, gemini.macros)
            } else {
                agreementPercent = nil
            }
        }

        /// A side left pending when the app stopped cannot finish any more.
        mutating func settleInterruptedSides() -> Bool {
            let message = String(
                localized: "Stopped before it finished.",
                comment: "FoodFinder photo side that was still running when the app stopped"
            )
            var changed = false
            if onDevice.outcome == .pending {
                onDevice = .failed(message)
                changed = true
            }
            if gemini.outcome == .pending {
                gemini = .failed(message)
                changed = true
            }
            return changed
        }
    }

    /// How close two meal-photo estimates are. This is not a confidence the model reports about itself.
    ///
    /// For each macro, closeness is 1 when the numbers match and 0 when the relative gap is total:
    ///   gap = |a - b| / max(a, b, floor)
    ///   closeness = 1 - min(1, gap)
    /// Both values at or below the floor (1 g, or 10 kcal) count as a match, so two zeros agree.
    ///
    /// Name similarity is the Jaccard overlap of lowercase word tokens.
    /// When either name has no tokens, that 0.10 weight moves onto carbs.
    ///
    /// With both names: 0.40 carbs + 0.20 fat + 0.20 protein + 0.10 kcal + 0.10 name.
    /// The result is that weighted sum times 100, rounded, clamped to 0...100.
    enum FoodFinderPhotoAgreement {
        static let gramFloor = 1.0
        static let calorieFloor = 10.0

        struct Macros: Equatable, Sendable {
            var name: String
            var carbs: Double
            var fat: Double
            var protein: Double
            var calories: Double
        }

        static func percent(_ lhs: Macros, _ rhs: Macros) -> Int {
            let carbs = closeness(lhs.carbs, rhs.carbs, floor: gramFloor)
            let fat = closeness(lhs.fat, rhs.fat, floor: gramFloor)
            let protein = closeness(lhs.protein, rhs.protein, floor: gramFloor)
            let calories = closeness(lhs.calories, rhs.calories, floor: calorieFloor)
            let weighted: Double
            if let name = nameSimilarity(lhs.name, rhs.name) {
                weighted = (0.40 * carbs) + (0.20 * fat) + (0.20 * protein) + (0.10 * calories) + (0.10 * name)
            } else {
                weighted = (0.50 * carbs) + (0.20 * fat) + (0.20 * protein) + (0.10 * calories)
            }
            return min(100, max(0, Int((weighted * 100).rounded())))
        }

        static func closeness(_ lhs: Double, _ rhs: Double, floor: Double) -> Double {
            let left = lhs.isFinite ? max(0, lhs) : 0
            let right = rhs.isFinite ? max(0, rhs) : 0
            if left <= floor, right <= floor { return 1 }
            let gap = abs(left - right) / max(left, right, floor)
            return 1 - min(1, gap)
        }

        static func nameSimilarity(_ lhs: String, _ rhs: String) -> Double? {
            let left = tokens(lhs)
            let right = tokens(rhs)
            if left.isEmpty || right.isEmpty { return nil }
            let union = left.union(right)
            guard !union.isEmpty else { return nil }
            return Double(left.intersection(right).count) / Double(union.count)
        }

        static func tokens(_ text: String) -> Set<String> {
            Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        }
    }

    struct FoodFinderOnDeviceEstimate: Equatable, Sendable {
        struct Item: Equatable, Sendable {
            var name: String
            var portion: String
            var carbs: Double
            var fat: Double
            var protein: Double
            var fiber: Double
            var calories: Double
        }

        var mealName: String?
        var mealPortion: String?
        var confidence: Double?
        var items: [Item]
        var rawJSON: String
    }

    enum FoodFinderOnDeviceFailure: Error, Equatable {
        case emptyResult
        case generationFailed
        case unavailable(FoodFinderOnDeviceBlocker)
        case unreadableImage
    }

    /// Builds the same object shape Gemini is asked to return, so a photo estimate
    /// can be stored on `FoodAnalysisResult` without a second parser.
    enum FoodFinderOnDeviceJSON {
        static func string(from estimate: FoodFinderOnDeviceEstimate) -> String {
            let items = estimate.items.map { item -> [String: Any] in
                [
                    "calories": item.calories,
                    "carbs": item.carbs,
                    "fat": item.fat,
                    "fiber": item.fiber,
                    "name": item.name,
                    "portion": item.portion,
                    "protein": item.protein
                ]
            }
            var object: [String: Any] = ["items": items]
            if let mealName = estimate.mealName {
                object["mealName"] = mealName
            }
            if let mealPortion = estimate.mealPortion {
                object["mealPortion"] = mealPortion
            }
            if let confidence = estimate.confidence {
                object["confidence"] = confidence
            }
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                  let text = String(data: data, encoding: .utf8)
            else {
                return "{\"items\":[]}"
            }
            return text
        }
    }

    enum FoodFinderOnDeviceNumbers {
        static func grams(_ value: Double) -> Double {
            guard value.isFinite else { return 0 }
            return max(0, value)
        }

        static func confidence(_ value: Double) -> Double {
            guard value.isFinite else { return 0.4 }
            // 82 means 82%. A score just above 1 is an over-eager 0...1 value.
            if value >= 2, value <= 100 {
                return min(1, value / 100)
            }
            return min(1, max(0, value))
        }

        static func item(
            name: String,
            portion: String,
            carbs: Double,
            fat: Double,
            protein: Double,
            fiber: Double,
            calories: Double
        ) -> FoodFinderOnDeviceEstimate.Item? {
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else { return nil }
            let trimmedPortion = portion.trimmingCharacters(in: .whitespacesAndNewlines)
            return FoodFinderOnDeviceEstimate.Item(
                name: trimmedName,
                portion: trimmedPortion.isEmpty ? "1 serving" : trimmedPortion,
                carbs: grams(carbs),
                fat: grams(fat),
                protein: grams(protein),
                fiber: grams(fiber),
                calories: grams(calories)
            )
        }
    }

    enum FoodFinderOnDeviceAnalyzer {
        static var blocker: FoodFinderOnDeviceBlocker {
            #if compiler(>=6.4) && canImport(FoundationModels)
                guard #available(iOS 27, *) else { return .operatingSystem }
                return FoodFinderOnDeviceModelGate.blocker()
            #else
                return .sdk
            #endif
        }

        static var isReady: Bool { blocker == .available }

        static var statusText: String { blocker.localizedMessage }

        static func analyze(
            images: [Data],
            description: String,
            extraContext: String
        ) async throws -> FoodFinderOnDeviceEstimate {
            #if compiler(>=6.4) && canImport(FoundationModels)
                guard #available(iOS 27, *) else {
                    throw FoodFinderOnDeviceFailure.unavailable(.operatingSystem)
                }
                return try await FoodFinderOnDeviceModelGate.analyze(
                    images: images,
                    description: description,
                    extraContext: extraContext
                )
            #else
                throw FoodFinderOnDeviceFailure.unavailable(.sdk)
            #endif
        }
    }
}

#if compiler(>=6.4)
    #if canImport(FoundationModels)
        // iOS 27 Foundation Models vision: `LanguageModelSession` + `Attachment`
        // image input, with `@Generable` so the reply matches FoodFinder's meal schema.
        // Compiled only with the Xcode 27 / Swift 6.4 SDK. Older Xcode keeps Gemini.

        @available(iOS 27.0, *)
        @Generable
        struct FoodFinderOnDeviceMealItemEstimate {
            @Guide(description: "Food name")
            var name: String

            @Guide(description: "Portion with an approximate weight in grams, such as 1 serving (150 g)")
            var portion: String

            @Guide(description: "Carbohydrates in grams for this portion")
            var carbs: Double

            @Guide(description: "Fat in grams for this portion")
            var fat: Double

            @Guide(description: "Protein in grams for this portion")
            var protein: Double

            @Guide(description: "Fiber in grams for this portion")
            var fiber: Double

            @Guide(description: "Energy in kilocalories for this portion")
            var calories: Double
        }

        @available(iOS 27.0, *)
        @Generable
        struct FoodFinderOnDeviceMealEstimate {
            @Guide(description: "Short name for the whole meal")
            var mealName: String

            @Guide(description: "Overall portion, such as 1 plate (450 g)")
            var mealPortion: String

            @Guide(description: "Confidence from 0 to 1")
            var confidence: Double

            @Guide(description: "Foods visible in the meal. Empty when the food cannot be identified.")
            var items: [FoodFinderOnDeviceMealItemEstimate]
        }

        @available(iOS 27.0, *)
        enum FoodFinderOnDeviceModelGate {
            static func blocker() -> AIInsights.FoodFinderOnDeviceBlocker {
                switch SystemLanguageModel.default.availability {
                case .available:
                    return .available
                case let .unavailable(reason):
                    switch reason {
                    case .appleIntelligenceNotEnabled:
                        return .appleIntelligenceNotEnabled
                    case .deviceNotEligible:
                        return .deviceNotEligible
                    case .modelNotReady:
                        return .modelNotReady
                    @unknown default:
                        return .other
                    }
                }
            }

            static func analyze(
                images: [Data],
                description: String,
                extraContext: String
            ) async throws -> AIInsights.FoodFinderOnDeviceEstimate {
                let readiness = blocker()
                guard readiness == .available else {
                    throw AIInsights.FoodFinderOnDeviceFailure.unavailable(readiness)
                }

                let bitmaps = try bitmapImages(from: images)
                guard !bitmaps.isEmpty else {
                    throw AIInsights.FoodFinderOnDeviceFailure.unreadableImage
                }

                let session = LanguageModelSession(
                    model: SystemLanguageModel.default,
                    instructions: instructionText
                )
                let prompt = promptText(description: description, imageCount: bitmaps.count, extraContext: extraContext)
                do {
                    let meal = try await mealEstimate(session: session, prompt: prompt, bitmaps: bitmaps)
                    return try estimate(from: meal)
                } catch let failure as AIInsights.FoodFinderOnDeviceFailure {
                    throw failure
                } catch {
                    throw AIInsights.FoodFinderOnDeviceFailure.generationFailed
                }
            }

            /// One `Attachment` per photo, matching the documented prompt-builder shape.
            /// FoodFinder caps a draft at six images.
            private static func mealEstimate(
                session: LanguageModelSession,
                prompt: String,
                bitmaps: [CGImage]
            ) async throws -> FoodFinderOnDeviceMealEstimate {
                let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 1200)
                switch bitmaps.count {
                case 1:
                    return try await session.respond(generating: FoodFinderOnDeviceMealEstimate.self, options: options) {
                        prompt
                        Attachment(bitmaps[0], orientation: CGImagePropertyOrientation.up)
                    }.content
                case 2:
                    return try await session.respond(generating: FoodFinderOnDeviceMealEstimate.self, options: options) {
                        prompt
                        Attachment(bitmaps[0], orientation: CGImagePropertyOrientation.up)
                        Attachment(bitmaps[1], orientation: CGImagePropertyOrientation.up)
                    }.content
                case 3:
                    return try await session.respond(generating: FoodFinderOnDeviceMealEstimate.self, options: options) {
                        prompt
                        Attachment(bitmaps[0], orientation: CGImagePropertyOrientation.up)
                        Attachment(bitmaps[1], orientation: CGImagePropertyOrientation.up)
                        Attachment(bitmaps[2], orientation: CGImagePropertyOrientation.up)
                    }.content
                case 4:
                    return try await session.respond(generating: FoodFinderOnDeviceMealEstimate.self, options: options) {
                        prompt
                        Attachment(bitmaps[0], orientation: CGImagePropertyOrientation.up)
                        Attachment(bitmaps[1], orientation: CGImagePropertyOrientation.up)
                        Attachment(bitmaps[2], orientation: CGImagePropertyOrientation.up)
                        Attachment(bitmaps[3], orientation: CGImagePropertyOrientation.up)
                    }.content
                case 5:
                    return try await session.respond(generating: FoodFinderOnDeviceMealEstimate.self, options: options) {
                        prompt
                        Attachment(bitmaps[0], orientation: CGImagePropertyOrientation.up)
                        Attachment(bitmaps[1], orientation: CGImagePropertyOrientation.up)
                        Attachment(bitmaps[2], orientation: CGImagePropertyOrientation.up)
                        Attachment(bitmaps[3], orientation: CGImagePropertyOrientation.up)
                        Attachment(bitmaps[4], orientation: CGImagePropertyOrientation.up)
                    }.content
                case 6...:
                    return try await session.respond(generating: FoodFinderOnDeviceMealEstimate.self, options: options) {
                        prompt
                        Attachment(bitmaps[0], orientation: CGImagePropertyOrientation.up)
                        Attachment(bitmaps[1], orientation: CGImagePropertyOrientation.up)
                        Attachment(bitmaps[2], orientation: CGImagePropertyOrientation.up)
                        Attachment(bitmaps[3], orientation: CGImagePropertyOrientation.up)
                        Attachment(bitmaps[4], orientation: CGImagePropertyOrientation.up)
                        Attachment(bitmaps[5], orientation: CGImagePropertyOrientation.up)
                    }.content
                default:
                    throw AIInsights.FoodFinderOnDeviceFailure.unreadableImage
                }
            }

            private static var instructionText: String {
                """
                You estimate nutrition from meal photos for a food log.
                The person will edit every number. Do not give insulin doses, and do not describe the estimate as exact.
                Prefer a smaller plausible portion when the amount is unclear.
                Break one plate into separate foods.
                Put an approximate weight in grams in every portion, such as "1 serving (150 g)".
                Treat salt, pepper, herbs, plain water, black coffee, and plain tea as about zero carbs, fat, and protein.
                If you cannot tell what the food is, set the meal name to Unknown, confidence to 0.1, and return no items.
                \(AIInsights.responseLanguageInstruction())
                """
            }

            private static func promptText(description: String, imageCount: Int, extraContext: String) -> String {
                let photos = imageCount > 1 ? "These \(imageCount) photos are one meal." : "This photo is one meal."
                let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
                let context = trimmed.isEmpty ? "The person did not add a description." : "The person wrote: \(trimmed)"
                let extra = extraContext.trimmingCharacters(in: .whitespacesAndNewlines)
                let scanned = extra.isEmpty ? "" : "\n\(extra)"
                return """
                \(photos) \(context)
                List each food you can see. Carbs, fat, protein, and fiber are grams for that portion. Calories are kilocalories.
                \(scanned)
                """
            }

            private static func bitmapImages(from images: [Data]) throws -> [CGImage] {
                let rendered = images.compactMap { data -> CGImage? in
                    guard let image = UIImage(data: data) else { return nil }
                    return uprightBitmap(image, maxPixel: 1024)
                }
                if rendered.isEmpty, !images.isEmpty {
                    throw AIInsights.FoodFinderOnDeviceFailure.unreadableImage
                }
                return rendered
            }

            /// Draws the photo upright and caps the long edge so the on-device context stays small.
            private static func uprightBitmap(_ image: UIImage, maxPixel: CGFloat) -> CGImage? {
                let size = image.size
                guard size.width > 1, size.height > 1 else { return nil }
                let longest = max(size.width, size.height)
                let scale = longest > maxPixel ? maxPixel / longest : 1
                let target = CGSize(
                    width: max(1, floor(size.width * scale)),
                    height: max(1, floor(size.height * scale))
                )
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                format.opaque = true
                let renderer = UIGraphicsImageRenderer(size: target, format: format)
                return renderer.image { _ in
                    image.draw(in: CGRect(origin: .zero, size: target))
                }.cgImage
            }

            private static func estimate(
                from meal: FoodFinderOnDeviceMealEstimate
            ) throws -> AIInsights.FoodFinderOnDeviceEstimate {
                let items = meal.items.compactMap {
                    AIInsights.FoodFinderOnDeviceNumbers.item(
                        name: $0.name,
                        portion: $0.portion,
                        carbs: $0.carbs,
                        fat: $0.fat,
                        protein: $0.protein,
                        fiber: $0.fiber,
                        calories: $0.calories
                    )
                }
                guard !items.isEmpty else {
                    throw AIInsights.FoodFinderOnDeviceFailure.emptyResult
                }
                let mealName = meal.mealName.trimmingCharacters(in: .whitespacesAndNewlines)
                let mealPortion = meal.mealPortion.trimmingCharacters(in: .whitespacesAndNewlines)
                var estimate = AIInsights.FoodFinderOnDeviceEstimate(
                    mealName: mealName.isEmpty ? nil : mealName,
                    mealPortion: mealPortion.isEmpty ? nil : mealPortion,
                    confidence: AIInsights.FoodFinderOnDeviceNumbers.confidence(meal.confidence),
                    items: items,
                    rawJSON: ""
                )
                estimate.rawJSON = AIInsights.FoodFinderOnDeviceJSON.string(from: estimate)
                return estimate
            }
        }
    #endif
#endif
