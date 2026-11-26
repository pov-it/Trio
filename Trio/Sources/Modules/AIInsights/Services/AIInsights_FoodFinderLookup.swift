import Foundation
import ImageIO
import os
import UniformTypeIdentifiers
import Vision

extension AIInsights {
    /// One place a food's numbers came from. A meal item can carry several.
    struct FoodSourceCitation: Identifiable, Codable, Equatable, Sendable {
        var id: String
        var source: FoodSourceID
        var domain: String
        var url: URL?
        var score: Double
        var title: String?

        var badgeTitle: String {
            switch source {
            case .web, .aiEstimate:
                return domain.isEmpty ? source.shortTitle : domain
            case .openFoodFacts, .usda, .ah:
                return source.shortTitle
            }
        }

        /// Citation built from the single source fields older meals stored.
        static func legacy(from item: FoodItem) -> FoodSourceCitation {
            let url = item.sourceURL
            let domain = url.flatMap { FoodFinderGrounding.domain(of: $0) } ?? item.source.shortTitle
            return FoodSourceCitation(
                id: url?.absoluteString ?? "\(item.source.rawValue)-\(item.id.uuidString)",
                source: item.source,
                domain: domain,
                url: url,
                score: item.sourceScore ?? (item.source == .aiEstimate ? 0.2 : 0.6),
                title: item.sourceName
            )
        }
    }

    /// Which photo engines a scan is allowed to start. `.cloud` does not also run on-device.
    struct FoodFinderPhotoPlan: Equatable, Sendable {
        var runsCloud: Bool
        var runsOnDevice: Bool

        static func make(
            preference: FoodFinderPhotoEnginePreference,
            hasAPIKey: Bool,
            onDeviceReady: Bool
        ) -> FoodFinderPhotoPlan {
            switch preference {
            case .cloud:
                return FoodFinderPhotoPlan(runsCloud: hasAPIKey, runsOnDevice: false)
            case .onDevice:
                return FoodFinderPhotoPlan(runsCloud: false, runsOnDevice: true)
            case .automatic:
                if hasAPIKey {
                    return FoodFinderPhotoPlan(runsCloud: true, runsOnDevice: onDeviceReady)
                }
                return FoodFinderPhotoPlan(runsCloud: false, runsOnDevice: true)
            }
        }
    }

    /// Strict all-words queries for Search-a-licious, longest first.
    enum FoodFinderSearchQuery {
        static func words(_ text: String?) -> [String] {
            guard let text else { return [] }
            return text
                .lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { $0.count > 1 }
        }

        /// Drops a trailing word after each empty result. A brand-plus-name query also retries the name alone.
        static func attempts(brand: String?, name: String) -> [String] {
            let brandWords = words(brand)
            let nameWords = words(name)
            var combined: [String] = []
            var seen = Set<String>()
            for word in brandWords + nameWords where seen.insert(word).inserted {
                combined.append(word)
            }
            guard !combined.isEmpty else { return [] }

            var queries: [String] = []
            var current = combined
            while !current.isEmpty {
                let phrase = current.joined(separator: " ")
                if !queries.contains(phrase) {
                    queries.append(phrase)
                }
                if current.count == 1 { break }
                current.removeLast()
            }
            if !brandWords.isEmpty, !nameWords.isEmpty {
                let namePhrase = nameWords.joined(separator: " ")
                if !queries.contains(namePhrase) {
                    queries.append(namePhrase)
                }
            }
            return queries
        }
    }

    /// Keyless Open Food Facts text search. `/api/v2/search?search_terms` ignores the query string.
    enum FoodFinderSearchALicious {
        static let endpoint = URL(string: "https://search.openfoodfacts.org/search")!

        static func url(query: String, langs: String = "nl", pageSize: Int = 5) -> URL? {
            var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
            components?.queryItems = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "langs", value: langs),
                URLQueryItem(name: "page_size", value: String(pageSize))
            ]
            return components?.url
        }

        static func products(matching name: String, brand: String? = nil, langs: String = "nl") async throws -> [[String: Any]] {
            let attempts = FoodFinderSearchQuery.attempts(brand: brand, name: name)
            let phrases = attempts.isEmpty ? [name] : attempts
            for phrase in phrases {
                let hits = try await FoodFinderSignpost.measure("FoodFinder.searchalicious") {
                    try await fetchProducts(query: phrase, langs: langs)
                }
                if !hits.isEmpty { return hits }
            }
            return []
        }

        static func lookupResults(from products: [[String: Any]], fallbackName: String) -> [FoodLookupResult] {
            products.compactMap { lookupResult(from: $0, fallbackName: fallbackName) }
        }

        static func lookupResult(from product: [String: Any], fallbackName: String) -> FoodLookupResult? {
            let nutriments = product["nutriments"] as? [String: Any] ?? [:]
            guard !nutriments.isEmpty else { return nil }
            let name = string(product["product_name"]) ?? string(product["product_name_nl"]) ?? fallbackName
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let code = string(product["code"]) ?? ""
            let brands = brandsText(product["brands"])
            let completeness = min(1, max(0.35, number(product["completeness"] ?? product["nutrition_data_completeness"])))
            let sourceURL: URL? = {
                if let raw = string(product["url"]), let url = URL(string: raw) { return url }
                if !code.isEmpty { return URL(string: "https://world.openfoodfacts.org/product/\(code)") }
                return nil
            }()
            // Search-a-licious returns per-100 g figures. Store them against 100 g so a later scale uses the eaten weight.
            return FoodLookupResult(
                sourceID: .openFoodFacts,
                name: name,
                brand: brands,
                portion: "100 g",
                portionGrams: 100,
                carbs: number(nutriments["carbohydrates_100g"]),
                fat: number(nutriments["fat_100g"]),
                protein: number(nutriments["proteins_100g"]),
                fiber: number(nutriments["fiber_100g"]),
                calories: number(nutriments["energy-kcal_100g"]),
                sourceURL: sourceURL,
                verifiedScore: completeness,
                imageURL: string(product["image_url"]).flatMap(URL.init(string:))
            )
        }

        private static func fetchProducts(query: String, langs: String) async throws -> [[String: Any]] {
            guard let url = url(query: query, langs: langs) else { return [] }
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue("TrioFoodFinder/1.0 (https://github.com/pov-it/Trio)", forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let data = try await dataWithOneTimeoutRetry(for: request)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
            let hits = json["hits"] as? [[String: Any]] ?? json["products"] as? [[String: Any]] ?? []
            return hits.compactMap { hit in
                if let source = hit["_source"] as? [String: Any] { return source }
                return hit
            }
        }
    }

    /// Nutrition the web-grounded model reports, per 100 g, plus the page it cited.
    struct FoodFinderWebNutritionItem: Equatable, Sendable {
        var name: String
        var carbsPer100g: Double
        var fatPer100g: Double
        var proteinPer100g: Double
        var fiberPer100g: Double
        var kcalPer100g: Double
        var sourceURL: URL?
    }

    enum FoodFinderWebNutrition {
        static func items(from text: String) -> [FoodFinderWebNutritionItem] {
            guard let fragment = jsonFragment(in: text),
                  let data = fragment.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data)
            else { return [] }
            let rows: [[String: Any]]
            if let array = json as? [[String: Any]] {
                rows = array
            } else if let object = json as? [String: Any] {
                rows = object["items"] as? [[String: Any]] ?? []
            } else {
                rows = []
            }
            return rows.compactMap { row in
                let name = (row["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !name.isEmpty else { return nil }
                return FoodFinderWebNutritionItem(
                    name: name,
                    carbsPer100g: number(row["carbs_100g"] ?? row["carbohydrates_100g"] ?? row["carbs"]),
                    fatPer100g: number(row["fat_100g"] ?? row["fat"]),
                    proteinPer100g: number(row["protein_100g"] ?? row["proteins_100g"] ?? row["protein"]),
                    fiberPer100g: number(row["fiber_100g"] ?? row["fiber"]),
                    kcalPer100g: number(row["kcal_100g"] ?? row["energy-kcal_100g"] ?? row["calories"]),
                    sourceURL: (row["source_url"] as? String).flatMap(URL.init(string:))
                )
            }
        }

        static func prompt(for items: [FoodItem]) -> String {
            let lines = items.map { item -> String in
                let brand = item.sourceBrand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let portion = item.portion
                if brand.isEmpty {
                    return "- \(item.name) (\(portion))"
                }
                return "- \(brand) \(item.name) (\(portion))"
            }.joined(separator: "\n")
            return """
            Find published nutrition facts for each food below. Use web search and open the pages that state the numbers. \
            Any website is fine. Do not invent values when a page does not give them. \
            Return ONLY JSON: {"items":[{"name":"","carbs_100g":0,"fat_100g":0,"protein_100g":0,"fiber_100g":0,"kcal_100g":0,"source_url":""}]}
            Foods:
            \(lines)
            """
        }
    }

    enum FoodFinderGrounding {
        struct Citation: Equatable, Sendable {
            var url: URL
            var title: String?
            var domain: String
        }

        static func citations(from responseJSON: [String: Any]) -> [Citation] {
            var found: [Citation] = []
            let candidates = responseJSON["candidates"] as? [[String: Any]] ?? []
            for candidate in candidates {
                let metadata = candidate["groundingMetadata"] as? [String: Any] ?? [:]
                let chunks = metadata["groundingChunks"] as? [[String: Any]] ?? []
                for chunk in chunks {
                    if let web = chunk["web"] as? [String: Any] {
                        append(urlString: web["uri"] as? String, title: web["title"] as? String, to: &found)
                    }
                }
                let urlMetadata = candidate["urlContextMetadata"] as? [String: Any] ?? [:]
                let rows = urlMetadata["urlMetadata"] as? [[String: Any]] ?? []
                for row in rows {
                    let raw = (row["retrievedUrl"] as? String) ?? (row["uri"] as? String) ?? (row["url"] as? String)
                    append(urlString: raw, title: row["title"] as? String, to: &found)
                }
            }
            return found
        }

        static func domain(of url: URL) -> String {
            var host = (url.host ?? "").lowercased()
            if host.hasPrefix("www.") {
                host.removeFirst(4)
            }
            return host
        }

        /// Google Search often returns a redirect host. Prefer a readable site name from the chunk title.
        static func badgeDomain(url: URL, title: String?) -> String {
            let host = domain(of: url)
            let redirected = host.contains("vertexaisearch") || host.contains("grounding-api-redirect")
            if redirected || host.isEmpty {
                let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !trimmed.isEmpty { return trimmed }
            }
            return host.isEmpty ? (title ?? "web") : host
        }

        private static func append(urlString: String?, title: String?, to found: inout [Citation]) {
            guard let urlString, let url = URL(string: urlString), url.scheme?.hasPrefix("http") == true else { return }
            if found.contains(where: { $0.url == url }) { return }
            found.append(Citation(url: url, title: title, domain: badgeDomain(url: url, title: title)))
        }
    }

    enum FoodFinderPortions {
        static func grams(in portion: String) -> Double? {
            let pattern = #"(\d+(?:[.,]\d+)?)\s*(g|gram|grams|ml|milliliter|milliliters)\b"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            let range = NSRange(portion.startIndex ..< portion.endIndex, in: portion)
            guard let match = regex.firstMatch(in: portion, options: [], range: range),
                  match.numberOfRanges >= 2,
                  let valueRange = Range(match.range(at: 1), in: portion)
            else { return nil }
            return Double(String(portion[valueRange]).replacingOccurrences(of: ",", with: "."))
        }
    }

    enum FoodFinderNameMatch {
        static func score(_ query: String, _ candidate: String) -> Double {
            let left = tokens(query)
            let right = tokens(candidate)
            guard !left.isEmpty, !right.isEmpty else { return 0 }
            let overlap = left.intersection(right).count
            if overlap == 0 { return 0.2 }
            let coverage = Double(overlap) / Double(left.count)
            let union = Double(left.union(right).count)
            let jaccard = union > 0 ? Double(overlap) / union : coverage
            return min(1, max(coverage, jaccard))
        }

        static func tokens(_ text: String) -> Set<String> {
            Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 })
        }
    }

    /// Applies database and web hits onto one estimated item. A weak name match keeps the estimate and only adds a link.
    enum FoodFinderSourceMerge {
        static func applying(
            lookups: [FoodLookupResult],
            webItems: [FoodFinderWebNutritionItem],
            webCitations: [FoodFinderGrounding.Citation],
            to item: FoodItem
        ) -> FoodItem {
            var updated = item
            let ranked = lookups
                .map { match -> (FoodLookupResult, Double) in
                    let identity = confirmsBarcode(item, match) ? 1 : FoodFinderNameMatch.score(item.name, match.name)
                    let verified = confirmsBarcode(item, match) ? max(match.verifiedScore, 0.92) : match.verifiedScore
                    return (match, verified * identity)
                }
                .filter { $0.1 >= 0.52 }
                .sorted { $0.1 > $1.1 }

            if var best = ranked.first?.0 {
                if confirmsBarcode(item, best) {
                    best.verifiedScore = max(best.verifiedScore, 0.92)
                }
                updated = applyingLookup(best, to: updated)
            }

            for match in lookups where FoodFinderNameMatch.score(item.name, match.name) >= 0.34 {
                updated.citations = FoodFinderSourceMerge.inserting(citation(from: match), into: updated.citations)
            }

            if let web = bestWebItem(for: item, in: webItems),
               let grams = FoodFinderPortions.grams(in: item.portion),
               grams > 0
            {
                let scale = grams / 100
                let nameScore = FoodFinderNameMatch.score(item.name, web.name)
                if nameScore >= 0.34, web.carbsPer100g > 0 || web.kcalPer100g > 0 {
                    let citation = FoodSourceCitation(
                        id: web.sourceURL?.absoluteString ?? "web-\(web.name)",
                        source: .web,
                        domain: web.sourceURL.map { FoodFinderGrounding.badgeDomain(url: $0, title: web.name) } ?? web.name,
                        url: web.sourceURL,
                        score: min(0.9, 0.55 + nameScore * 0.35),
                        title: web.name
                    )
                    if (updated.sourceScore ?? 0) < citation.score {
                        updated.carbs = web.carbsPer100g * scale
                        updated.fat = web.fatPer100g * scale
                        updated.protein = web.proteinPer100g * scale
                        updated.fiber = web.fiberPer100g * scale
                        updated.calories = web.kcalPer100g * scale
                        updated.basisUnit = .gram
                        updated.basisAmount = grams
                        updated = applyingPrimary(citation, to: updated)
                    }
                    updated.citations = inserting(citation, into: updated.citations)
                }
            }

            for citation in webCitations {
                let haystack = "\(citation.title ?? "") \(citation.domain) \(citation.url.absoluteString)"
                guard FoodFinderNameMatch.score(item.name, haystack) >= 0.34 || webCitations.count == 1 else { continue }
                let attached = FoodSourceCitation(
                    id: citation.url.absoluteString,
                    source: .web,
                    domain: citation.domain,
                    url: citation.url,
                    score: 0.5,
                    title: citation.title
                )
                updated.citations = inserting(attached, into: updated.citations)
                if updated.source == .aiEstimate {
                    updated = applyingPrimary(attached, to: updated)
                }
            }

            if updated.citations.isEmpty, updated.source != .aiEstimate {
                updated.citations = [FoodSourceCitation.legacy(from: updated)]
            }
            return updated
        }

        static func applyingLookup(_ lookup: FoodLookupResult, to item: FoodItem) -> FoodItem {
            let existingGrams = FoodFinderPortions.grams(in: item.portion)
            let lookupGrams = lookup.portionGrams
            let scale: Double
            let portion: String
            if let existingGrams, let lookupGrams, lookupGrams > 0 {
                scale = max(0.05, existingGrams / lookupGrams)
                portion = item.portion
            } else {
                scale = 1
                portion = item.portion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? lookup.portion : item.portion
            }
            let basisGrams: Double = {
                if let existingGrams, let lookupGrams, lookupGrams > 0 { return max(0.05, existingGrams) }
                return lookup.portionGrams ?? 0
            }()
            var updated = item
            updated.portion = portion
            updated.carbs = lookup.carbs * scale
            updated.fat = lookup.fat * scale
            updated.protein = lookup.protein * scale
            updated.fiber = lookup.fiber * scale
            updated.calories = lookup.calories * scale
            updated.basisUnit = basisGrams > 0 ? .gram : item.basisUnit
            updated.basisAmount = basisGrams > 0 ? basisGrams : item.basisAmount
            let primary = citation(from: lookup)
            updated = applyingPrimary(primary, to: updated)
            updated.citations = inserting(primary, into: updated.citations)
            return updated
        }

        static func citation(from lookup: FoodLookupResult) -> FoodSourceCitation {
            let domain = lookup.sourceURL.map { FoodFinderGrounding.domain(of: $0) } ?? lookup.sourceID.shortTitle
            return FoodSourceCitation(
                id: lookup.sourceURL?.absoluteString ?? "\(lookup.sourceID.rawValue)-\(lookup.name)",
                source: lookup.sourceID,
                domain: domain,
                url: lookup.sourceURL,
                score: lookup.verifiedScore,
                title: lookup.name
            )
        }

        static func insertingMany(_ incoming: [FoodSourceCitation], into citations: [FoodSourceCitation]) -> [FoodSourceCitation] {
            incoming.reduce(citations) { inserting($1, into: $0) }
        }

        static func inserting(_ citation: FoodSourceCitation, into citations: [FoodSourceCitation]) -> [FoodSourceCitation] {
            var copy = citations
            if let index = copy.firstIndex(where: { $0.id == citation.id || ($0.url != nil && $0.url == citation.url) }) {
                if citation.score > copy[index].score {
                    copy[index] = citation
                }
            } else {
                copy.append(citation)
            }
            return copy.sorted { $0.score > $1.score }
        }

        static func applyingPrimary(_ citation: FoodSourceCitation, to item: FoodItem) -> FoodItem {
            var updated = item
            updated.source = citation.source
            updated.sourceURL = citation.url
            updated.sourceScore = citation.score
            updated.sourceName = citation.title
            updated.sourceVerified = citation.score >= 0.6 && citation.source != .aiEstimate
            return updated
        }

        /// A product page whose URL contains this item's barcode is that product, even when the names differ.
        static func confirmsBarcode(_ item: FoodItem, _ match: FoodLookupResult) -> Bool {
            guard let code = item.barcode?.filter(\.isNumber), (8 ... 14).contains(code.count) else { return false }
            return match.sourceURL?.absoluteString.contains(code) == true
        }

        private static func bestWebItem(
            for item: FoodItem,
            in webItems: [FoodFinderWebNutritionItem]
        ) -> FoodFinderWebNutritionItem? {
            webItems.max { lhs, rhs in
                FoodFinderNameMatch.score(item.name, lhs.name) < FoodFinderNameMatch.score(item.name, rhs.name)
            }
        }
    }

    enum FoodFinderImagePrep {
        /// Longest edge in pixels for the fast vision call. The saved meal keeps the original photo.
        static let fastEstimateMaxPixel = 1280

        static func jpegData(from data: Data, maxPixel: Int = fastEstimateMaxPixel, quality: CGFloat = 0.72) -> Data {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return data }
            let options: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: NSNumber(value: maxPixel),
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [AnyHashable: Any]
            let pixelWidth = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? Int.max
            let pixelHeight = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? Int.max
            if max(pixelWidth, pixelHeight) <= maxPixel, data.count < 700_000, isJPEG(data) {
                return data
            }
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return data }
            let out = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
                return data
            }
            let compression = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
            CGImageDestinationAddImage(destination, image, compression)
            guard CGImageDestinationFinalize(destination) else { return data }
            return out as Data
        }

        private static func isJPEG(_ data: Data) -> Bool {
            data.count > 3 && data[0] == 0xFF && data[1] == 0xD8
        }
    }

    enum FoodFinderBarcodeScan {
        /// EAN/UPC digits visible in a meal photo. Runs off the caller's actor; Vision does the decode.
        static func codes(in data: Data) -> [String] {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { return [] }
            let request = VNDetectBarcodesRequest()
            request.symbologies = [.ean13, .ean8, .upce, .code128]
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try? handler.perform([request])
            var codes: [String] = []
            for observation in request.results ?? [] {
                let digits = (observation.payloadStringValue ?? "").filter(\.isNumber)
                guard (8 ... 14).contains(digits.count) else { continue }
                if !codes.contains(digits) { codes.append(digits) }
            }
            return codes
        }
    }

    /// Vertical drag math for the portion control. Up increases the multiplier.
    enum PortionDragMath {
        static func multiplier(
            start: Double,
            translationY: CGFloat,
            pointsPerStep: CGFloat = 28,
            step: Double = 0.1,
            range: ClosedRange<Double>
        ) -> Double {
            guard pointsPerStep > 0, step > 0 else { return min(range.upperBound, max(range.lowerBound, start)) }
            let steps = Double(-translationY / pointsPerStep)
            let raw = start + (steps * step)
            let snapped = (raw / step).rounded() * step
            let clamped = min(range.upperBound, max(range.lowerBound, snapped))
            return (clamped * 1000).rounded() / 1000
        }
    }

    enum FoodFinderSignpost {
        private static let poster = OSSignposter(subsystem: "org.nightscout.Trio", category: "FoodFinder")

        static func measure<T>(_ name: StaticString, _ body: () async throws -> T) async rethrows -> T {
            let state = poster.beginInterval(name)
            defer { poster.endInterval(name, state) }
            return try await body()
        }
    }

    /// The nutrition route publishes `token` as a query parameter and no Authorization scheme.
    /// Header-only calls are not a documented contract, so the token stays in the query.
    enum FoodFinderAHRequest {
        static let acceptsAuthorizationHeader = false
        static let baseURL = "https://foodfinder.pov-it.tech"

        static func nutritionRequest(query: String, token: String, limit: Int = 5) -> URLRequest? {
            nutritionRequest(query: query, token: token, limit: limit, useAuthorizationHeader: acceptsAuthorizationHeader)
        }

        static func nutritionRequest(
            query: String,
            token: String,
            limit: Int = 5,
            useAuthorizationHeader: Bool
        ) -> URLRequest? {
            var components = URLComponents(string: "\(baseURL)/nutrition")
            var items = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "limit", value: String(limit))
            ]
            if !useAuthorizationHeader {
                items.append(URLQueryItem(name: "token", value: token))
            }
            components?.queryItems = items
            guard let url = components?.url else { return nil }
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("TrioFoodFinder/1.0 (https://github.com/pov-it/Trio)", forHTTPHeaderField: "User-Agent")
            if useAuthorizationHeader {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            return request
        }
    }
}

func dataWithOneTimeoutRetry(for request: URLRequest) async throws -> Data {
    do {
        return try await load(request)
    } catch {
        guard isTimeout(error) else { throw error }
        return try await load(request)
    }
}

private func load(_ request: URLRequest) async throws -> Data {
    let (data, response) = try await URLSession.shared.data(for: request)
    if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
        return data
    }
    return data
}

private func isTimeout(_ error: Error) -> Bool {
    if let urlError = error as? URLError, urlError.code == .timedOut { return true }
    let nsError = error as NSError
    return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut
}

private func string(_ value: Any?) -> String? {
    guard let text = value as? String else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func brandsText(_ value: Any?) -> String? {
    if let text = string(value) { return text }
    if let list = value as? [String] {
        let joined = list.compactMap(string).joined(separator: ", ")
        return joined.isEmpty ? nil : joined
    }
    return nil
}

private func number(_ value: Any?) -> Double {
    if let number = value as? NSNumber { return number.doubleValue }
    if let text = value as? String { return Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0 }
    return 0
}

private func jsonFragment(in text: String) -> String? {
    let cleaned = text
        .replacingOccurrences(of: "```json", with: "")
        .replacingOccurrences(of: "```JSON", with: "")
        .replacingOccurrences(of: "```", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if cleaned.first == "{" || cleaned.first == "[" { return cleaned }
    if let start = cleaned.firstIndex(of: "{"), let end = cleaned.lastIndex(of: "}"), start < end {
        return String(cleaned[start ... end])
    }
    return nil
}
