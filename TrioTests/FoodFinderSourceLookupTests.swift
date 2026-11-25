import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Trio

@Suite("FoodFinder source lookup")
struct FoodFinderSourceLookupTests {
    @Test("A barcode page replaces the estimate even when the names do not overlap")
    func barcodeMatchBypassesWeakName() {
        var item = AIInsights.FoodItem(
            name: "Dinner pasta",
            portion: "200 g",
            carbs: 70,
            fat: 4,
            protein: 10,
            fiber: 2,
            calories: 400,
            barcode: "8076802085738"
        )
        let lookup = AIInsights.FoodLookupResult(
            sourceID: .openFoodFacts,
            name: "Rigatoni 89",
            brand: "Example",
            portion: "100 g",
            portionGrams: 100,
            carbs: 30,
            fat: 1,
            protein: 5,
            fiber: 2,
            calories: 160,
            sourceURL: URL(string: "https://world.openfoodfacts.org/product/8076802085738"),
            verifiedScore: 0.35,
            imageURL: nil
        )
        #expect(AIInsights.FoodFinderSourceMerge.confirmsBarcode(item, lookup))
        item = AIInsights.FoodFinderSourceMerge.applying(lookups: [lookup], webItems: [], webCitations: [], to: item)
        #expect(item.source == .openFoodFacts)
        #expect(item.carbs == 60)
        #expect(item.sourceVerified)
        #expect((item.sourceScore ?? 0) >= 0.92)

        let web = AIInsights.FoodFinderWebNutritionItem(
            name: "Dinner pasta",
            carbsPer100g: 80,
            fatPer100g: 1,
            proteinPer100g: 1,
            fiberPer100g: 0,
            kcalPer100g: 330,
            sourceURL: URL(string: "https://recipes.example.com/pasta")
        )
        let withWeb = AIInsights.FoodFinderSourceMerge.applying(
            lookups: [lookup],
            webItems: [web],
            webCitations: [],
            to: AIInsights.FoodItem(
                name: "Dinner pasta",
                portion: "200 g",
                carbs: 70,
                fat: 4,
                protein: 10,
                fiber: 2,
                calories: 400,
                barcode: "8076802085738"
            )
        )
        #expect(withWeb.source == .openFoodFacts)
        #expect(withWeb.carbs == 60)
        #expect(withWeb.sourceVerified)
    }

    @Test("Search-a-licious queries drop words and retry the name alone")
    func searchQueriesShrink() {
        let queries = AIInsights.FoodFinderSearchQuery.attempts(brand: "Barilla", name: "pumpkin rigatoni")
        #expect(queries.first == "barilla pumpkin rigatoni")
        #expect(queries.contains("barilla pumpkin"))
        #expect(queries.contains("barilla"))
        #expect(queries.last == "pumpkin rigatoni")
    }

    @Test("Search-a-licious URL carries the query and Dutch language")
    func searchURL() throws {
        let url = try #require(AIInsights.FoodFinderSearchALicious.url(query: "pumpkin rigatoni", langs: "nl"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "q" }?.value == "pumpkin rigatoni")
        #expect(items.first { $0.name == "langs" }?.value == "nl")
        #expect(url.host == "search.openfoodfacts.org")
    }

    @Test("Search-a-licious hits become per-100 g Open Food Facts results")
    func parsesNutriments() {
        let product: [String: Any] = [
            "code": "123",
            "product_name": "Example rigatoni",
            "brands": "Example",
            "completeness": 0.8,
            "nutriments": [
                "carbohydrates_100g": 62.0,
                "fat_100g": 2.0,
                "proteins_100g": 12.0,
                "fiber_100g": 3.0,
                "energy-kcal_100g": 320.0
            ]
        ]
        let result = AIInsights.FoodFinderSearchALicious.lookupResult(from: product, fallbackName: "pasta")
        #expect(result?.carbs == 62)
        #expect(result?.portionGrams == 100)
        #expect(result?.sourceID == .openFoodFacts)
        #expect(result?.sourceURL?.absoluteString == "https://world.openfoodfacts.org/product/123")
        #expect(AIInsights.FoodFinderSearchALicious.lookupResult(from: ["product_name": "Empty"], fallbackName: "pasta") == nil)
    }

    @Test("Grounding chunks become source URLs and domains")
    func parsesGrounding() {
        let json: [String: Any] = [
            "candidates": [[
                "groundingMetadata": [
                    "groundingChunks": [[
                        "web": [
                            "uri": "https://www.example.com/pasta",
                            "title": "Example pasta"
                        ]
                    ]]
                ],
                "urlContextMetadata": [
                    "urlMetadata": [["retrievedUrl": "https://notes.example.org/dish"]]
                ]
            ]]
        ]
        let citations = AIInsights.FoodFinderGrounding.citations(from: json)
        #expect(citations.count == 2)
        #expect(citations[0].domain == "example.com")
        #expect(citations[1].domain == "notes.example.org")
    }

    @Test("A redirect grounding host uses the page title as the badge")
    func redirectHostUsesTitle() throws {
        let url = try #require(URL(string: "https://vertexaisearch.cloud.google.com/grounding-api-redirect/abc"))
        #expect(AIInsights.FoodFinderGrounding.badgeDomain(url: url, title: "Jumbo recipe") == "Jumbo recipe")
    }

    @Test("A better Open Food Facts match replaces the AI estimate and keeps the citation")
    func mergeAppliesLookup() {
        var item = AIInsights.FoodItem(
            name: "Example rigatoni",
            portion: "200 g",
            carbs: 70,
            fat: 4,
            protein: 10,
            fiber: 2,
            calories: 400
        )
        let lookup = AIInsights.FoodLookupResult(
            sourceID: .openFoodFacts,
            name: "Example rigatoni",
            brand: "Example",
            portion: "100 g",
            portionGrams: 100,
            carbs: 30,
            fat: 1,
            protein: 5,
            fiber: 2,
            calories: 160,
            sourceURL: URL(string: "https://world.openfoodfacts.org/product/123"),
            verifiedScore: 0.9,
            imageURL: nil
        )
        item = AIInsights.FoodFinderSourceMerge.applying(lookups: [lookup], webItems: [], webCitations: [], to: item)
        #expect(item.source == .openFoodFacts)
        #expect(item.carbs == 60)
        #expect(item.citations.contains { $0.source == .openFoodFacts })
        #expect(item.displayCitations.first?.badgeTitle == "OFF")
    }

    @Test("Web nutrition scales per 100 g onto the eaten weight")
    func mergeScalesWebNutrition() {
        let item = AIInsights.FoodItem(
            name: "Example sauce",
            portion: "50 g",
            carbs: 4,
            fat: 1,
            protein: 1,
            fiber: 0,
            calories: 30
        )
        let web = AIInsights.FoodFinderWebNutritionItem(
            name: "Example sauce",
            carbsPer100g: 10,
            fatPer100g: 2,
            proteinPer100g: 3,
            fiberPer100g: 1,
            kcalPer100g: 80,
            sourceURL: URL(string: "https://recipes.example.com/sauce")
        )
        let updated = AIInsights.FoodFinderSourceMerge.applying(lookups: [], webItems: [web], webCitations: [], to: item)
        #expect(updated.carbs == 5)
        #expect(updated.source == .web)
        #expect(updated.citations.first?.domain == "recipes.example.com")
    }

    @Test("Web nutrition JSON is read from a fenced reply")
    func parsesWebJSON() {
        let text = """
        ```json
        {"items":[{"name":"Example sauce","carbs_100g":10,"fat_100g":2,"protein_100g":3,"fiber_100g":1,"kcal_100g":80,"source_url":"https://recipes.example.com/sauce"}]}
        ```
        """
        let items = AIInsights.FoodFinderWebNutrition.items(from: text)
        #expect(items.count == 1)
        #expect(items.first?.carbsPer100g == 10)
        #expect(items.first?.sourceURL?.host == "recipes.example.com")
    }

    @Test("Cloud photo setting does not also start on-device")
    func photoPlanRespectsSetting() {
        let cloud = AIInsights.FoodFinderPhotoPlan.make(preference: .cloud, hasAPIKey: true, onDeviceReady: true)
        #expect(cloud.runsCloud)
        #expect(!cloud.runsOnDevice)
        let device = AIInsights.FoodFinderPhotoPlan.make(preference: .onDevice, hasAPIKey: true, onDeviceReady: true)
        #expect(!device.runsCloud)
        #expect(device.runsOnDevice)
        let automatic = AIInsights.FoodFinderPhotoPlan.make(preference: .automatic, hasAPIKey: true, onDeviceReady: false)
        #expect(automatic.runsCloud)
        #expect(!automatic.runsOnDevice)
    }

    @Test("Dragging up increases the portion multiplier")
    func dragMath() {
        let up = AIInsights.PortionDragMath.multiplier(start: 1, translationY: -56, range: 0.25 ... 10)
        #expect(abs(up - 1.2) < 0.001)
        let down = AIInsights.PortionDragMath.multiplier(start: 1, translationY: 28, range: 0.25 ... 10)
        #expect(abs(down - 0.9) < 0.001)
        let floor = AIInsights.PortionDragMath.multiplier(start: 0.25, translationY: 200, range: 0.25 ... 10)
        #expect(floor == 0.25)
    }

    @Test("Albert Heijn token stays in the query because the route does not document a bearer header")
    func ahTokenPlacement() throws {
        #expect(!AIInsights.FoodFinderAHRequest.acceptsAuthorizationHeader)
        let query = try #require(AIInsights.FoodFinderAHRequest.nutritionRequest(query: "kaas", token: "example-token"))
        #expect(query.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(query.url?.query?.contains("token=example-token") == true)

        let header = try #require(
            AIInsights.FoodFinderAHRequest.nutritionRequest(
                query: "kaas",
                token: "example-token",
                useAuthorizationHeader: true
            )
        )
        #expect(header.value(forHTTPHeaderField: "Authorization") == "Bearer example-token")
        #expect(header.url?.query?.contains("token=") == false)
    }

    @Test("Fast estimate images are capped around 1280 px")
    func downscalesWideImage() throws {
        let source = try jpeg(width: 2400, height: 800)
        let scaled = AIInsights.FoodFinderImagePrep.jpegData(from: source, maxPixel: 1280)
        let image = try #require(CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(scaled as CFData, nil)!, 0, nil))
        #expect(max(image.width, image.height) <= 1280)
        #expect(image.width > image.height)
    }

    private func jpeg(width: Int, height: Int) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        )
        context.setFillColor(CGColor(red: 0.9, green: 0.4, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
