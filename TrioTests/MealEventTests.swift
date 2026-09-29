import Foundation
import Testing

@testable import Trio

private typealias MealEvent = AIInsights.MealEvent
private typealias BolusRow = AIInsights.MealEventBolusObservation

private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

private func minutes(_ value: Double, from date: Date = t0) -> Date {
    date.addingTimeInterval(value * 60)
}

private func makeDraft(
    id: UUID = UUID(),
    name: String = "Pasta pesto",
    foodResultID: UUID = UUID(),
    mealTime: Date = t0,
    recordedAt: Date = t0,
    carbs: Double = 60,
    fat: Double = 20,
    protein: Double = 15,
    fpuID: UUID? = UUID(),
    entered: Double = 4
) -> AIInsights.MealEventDraft {
    let key = AIInsights.MealEventIdentity.mealKey(mealName: name, itemNames: [], resultID: foodResultID)
    return AIInsights.MealEventDraft(
        id: id,
        recordedAt: recordedAt,
        mealTime: mealTime,
        mealSlot: .dinner,
        meal: AIInsights.MealEventMeal(
            mealID: AIInsights.MealEventIdentity.mealID(forKey: key),
            mealKey: key,
            name: name,
            foodResultID: foodResultID,
            analysisAt: mealTime.addingTimeInterval(-120),
            source: "aiCamera",
            photoEngine: "gemini"
        ),
        nutrition: AIInsights.MealEventNutrition(
            carbs: carbs,
            fat: fat,
            protein: protein,
            fpu: AIInsights.MealEventNutrition.fpu(fat: fat, protein: protein),
            fiber: 4,
            kcal: 600,
            foodFinderCarbs: carbs,
            foodFinderFat: fat,
            foodFinderProtein: protein,
            carbLowerRatio: 0.8,
            carbUpperRatio: 1.3
        ),
        fpuID: fpuID,
        calculator: AIInsights.MealEventCalculator(
            wholeUnits: 5,
            factoredUnits: 4,
            recommendedUnits: 4,
            fraction: 0.8,
            usedFattyMealFactor: false,
            fattyMealFactor: nil,
            usedSuperBolus: false,
            superBolusUnits: nil,
            reducedBolusSuggested: false,
            enteredUnits: entered,
            amountSource: AIInsights.MealEventCalculator.amountSource(entered: entered, recommended: 4),
            isExternalInsulin: false,
            currentBG: 120,
            deltaBG: 3,
            iob: 0.5,
            cob: 0,
            target: 100,
            isf: 50,
            carbRatio: 10,
            minPredBG: 90,
            eventualBG: 110,
            targetDifferenceUnits: 0.4,
            iobReductionUnits: -0.5,
            cobUnits: 6,
            fifteenMinuteUnits: 0.1
        ),
        dosingMode: "closed"
    )
}

private func makeEvent(
    mealTime: Date = t0,
    request units: Double? = 4,
    kind: AIInsights.MealEventBolus.Kind = .pump,
    requestedAt: Date = t0
) -> MealEvent {
    var event = MealEvent(draft: makeDraft(mealTime: mealTime, recordedAt: mealTime))
    if let units {
        AIInsights.MealEventLinker.request(&event, units: units, kind: kind, at: requestedAt)
    }
    return event
}

private func row(
    _ id: String,
    _ change: BolusRow.Change = .inserted,
    at date: Date = minutes(1),
    programmed: Double? = 4,
    amount: Double? = 4,
    mutable: Bool = true,
    external: Bool = false,
    smb: Bool = false
) -> BolusRow {
    BolusRow(
        change: change,
        pumpEventID: id,
        timestamp: date,
        programmedUnits: programmed,
        amountUnits: amount,
        isMutable: mutable,
        isExternal: external,
        isSMB: smb
    )
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("MealEventTests-\(UUID().uuidString)", isDirectory: true)
}

@Suite("FoodFinder meal identity") struct MealEventIdentityTests {
    @Test("The meal key folds case, accents and spacing, and falls back to the ingredients")
    func mealKeyNormalization() {
        let id = UUID()
        let named = AIInsights.MealEventIdentity.mealKey(mealName: "  Crème  Brûlée ", itemNames: ["x"], resultID: id)
        #expect(named == "creme brulee")
        #expect(AIInsights.MealEventIdentity.mealKey(mealName: "CREME BRULEE", itemNames: [], resultID: UUID()) == named)

        let items = AIInsights.MealEventIdentity.mealKey(mealName: " ", itemNames: ["Rice", "Chicken"], resultID: id)
        #expect(items == "rice, chicken")

        let unnamed = AIInsights.MealEventIdentity.mealKey(mealName: nil, itemNames: [], resultID: id)
        #expect(unnamed == "result:" + id.uuidString.lowercased())
    }

    @Test("The meal id is the same for the same meal and differs between meals")
    func mealIDIsStable() {
        let pasta = AIInsights.MealEventIdentity.mealID(forKey: "pasta pesto")
        #expect(pasta == AIInsights.MealEventIdentity.mealID(forKey: "pasta pesto"))
        #expect(pasta != AIInsights.MealEventIdentity.mealID(forKey: "pasta carbonara"))

        let bytes = pasta.uuid
        #expect(bytes.6 >> 4 == 0x8)
        #expect(bytes.8 >> 6 == 0b10)
    }
}

@Suite("FoodFinder meal bolus linking") struct MealEventLinkerTests {
    @Test("A pump bolus claims the manual row inserted after the request")
    func pumpRowIsClaimed() {
        var events = [makeEvent(mealTime: minutes(5))]
        let changed = AIInsights.MealEventLinker.apply([row("a", at: minutes(1), amount: 4)], to: &events)

        let bolus = events[0].bolus
        #expect(changed == [events[0].id])
        #expect(bolus.status == .linked)
        #expect(bolus.records.map(\.pumpEventID) == ["a"])
        #expect(bolus.deliveredUnits == 4)
        #expect(!bolus.isDeliveryFinal)
        #expect(bolus.preBolusMinutes == 4)
    }

    @Test("The finished pump report replaces the programmed amount with the delivered amount")
    func finalizedRowUpdatesDelivery() {
        var events = [makeEvent()]
        AIInsights.MealEventLinker.apply([row("a", amount: 4)], to: &events)
        AIInsights.MealEventLinker.apply([row("a", .updated, amount: 3.2, mutable: false)], to: &events)

        #expect(events[0].bolus.deliveredUnits == 3.2)
        #expect(events[0].bolus.isDeliveryFinal)
        #expect(events[0].bolus.records[0].programmedUnits == 4)

        let unchanged = AIInsights.MealEventLinker.apply([row("a", .updated, amount: 3.2, mutable: false)], to: &events)
        #expect(unchanged.isEmpty)
    }

    @Test("SMBs, external doses, other amounts and rows outside the window are not claimed")
    func nonMatchingRowsAreIgnored() {
        var events = [makeEvent()]
        let rows = [
            row("smb", smb: true),
            row("external", external: true),
            row("other amount", programmed: 2.5, amount: 2.5),
            row("too early", at: minutes(-11)),
            row("too late", at: minutes(31))
        ]
        #expect(AIInsights.MealEventLinker.apply(rows, to: &events).isEmpty)
        #expect(events[0].bolus.status == .pending)

        AIInsights.MealEventLinker.apply([row("rounded", at: minutes(-9), programmed: 4.15)], to: &events)
        #expect(events[0].bolus.records.map(\.pumpEventID) == ["rounded"])
    }

    @Test("A meal without a bolus request claims nothing")
    func noRequestNoClaim() {
        var events = [makeEvent(request: nil)]
        #expect(AIInsights.MealEventLinker.apply([row("a")], to: &events).isEmpty)
        #expect(events[0].bolus.status == .none)
    }

    @Test("A purged pending row frees the request for the row that replaces it")
    func purgedRowIsReplaced() {
        var events = [makeEvent()]
        AIInsights.MealEventLinker.apply([row("pending")], to: &events)
        AIInsights.MealEventLinker.apply(
            [row("final", at: minutes(1.5), amount: 4, mutable: false), row("pending", .deleted)],
            to: &events
        )

        #expect(events[0].bolus.records.map(\.pumpEventID) == ["final"])
        #expect(events[0].bolus.isDeliveryFinal)

        AIInsights.MealEventLinker.apply([row("final", .deleted)], to: &events)
        #expect(events[0].bolus.status == .pending)
        #expect(events[0].bolus.deliveredUnits == nil)
    }

    @Test("A failed enact still links a row that appears later, and an unanswered request expires")
    func failedEnactAndExpiry() {
        var failed = makeEvent()
        AIInsights.MealEventLinker.enactFinished(&failed, success: false, at: minutes(1))
        #expect(failed.bolus.status == .enactFailed)

        var events = [failed, makeEvent(request: 2, requestedAt: minutes(2))]
        AIInsights.MealEventLinker.apply([row("late", at: minutes(3))], to: &events)
        #expect(events[0].bolus.status == .linked)
        #expect(events[1].bolus.status == .pending)

        let now = minutes(2 + 6 * 60 + 1)
        let expired = AIInsights.MealEventLinker.expire(&events, now: now)
        #expect(expired == [events[1].id])
        #expect(events[1].bolus.status == .notFound)
        #expect(events[0].bolus.status == .linked)
    }

    @Test("Each row goes to the closest open request and is claimed only once")
    func closestRequestWins() {
        var events = [makeEvent(requestedAt: t0), makeEvent(requestedAt: minutes(10))]
        AIInsights.MealEventLinker.apply([row("second", at: minutes(10.5))], to: &events)
        #expect(events[0].bolus.records.isEmpty)
        #expect(events[1].bolus.records.map(\.pumpEventID) == ["second"])

        AIInsights.MealEventLinker.apply([row("second", at: minutes(10.5))], to: &events)
        #expect(events[0].bolus.records.isEmpty)

        AIInsights.MealEventLinker.apply([row("first", at: minutes(0.5))], to: &events)
        #expect(events[0].bolus.records.map(\.pumpEventID) == ["first"])
    }

    @Test("External insulin links only to an external row at the logged time")
    func externalInsulin() {
        var events = [makeEvent(request: 3, kind: .external, requestedAt: minutes(-20))]
        let rows = [
            row("pump", at: minutes(-20), programmed: 3),
            row("far", at: minutes(-17), programmed: 3, external: true),
            row("pen", at: minutes(-20), programmed: 3, amount: 3, mutable: false, external: true)
        ]
        AIInsights.MealEventLinker.apply(rows, to: &events)

        #expect(events[0].bolus.records.map(\.pumpEventID) == ["pen"])
        #expect(events[0].bolus.isDeliveryFinal)
        #expect(events[0].bolus.preBolusMinutes == 20)
    }

    @Test("Amount source tells a changed bolus from the recommendation")
    func amountSource() {
        #expect(AIInsights.MealEventCalculator.amountSource(entered: 0, recommended: 3) == .none)
        #expect(AIInsights.MealEventCalculator.amountSource(entered: 3, recommended: 3) == .recommendation)
        #expect(AIInsights.MealEventCalculator.amountSource(entered: 2.5, recommended: 3) == .edited)
    }
}

@Suite("FoodFinder meal loop snapshot") struct MealEventSnapshotTests {
    @Test("Glucose deltas use the reading closest to 5, 15 and 30 minutes earlier")
    func glucoseDeltas() {
        let readings = [
            PostMealGlucoseReading(mgdl: 100, date: minutes(-31)),
            PostMealGlucoseReading(mgdl: 110, date: minutes(-15)),
            PostMealGlucoseReading(mgdl: 118, date: minutes(-5)),
            PostMealGlucoseReading(mgdl: 125, date: minutes(0)),
            PostMealGlucoseReading(mgdl: 300, date: minutes(2))
        ]
        let glucose = AIInsights.MealEventGlucose.make(readings: readings, direction: "FortyFiveUp", at: minutes(1))

        #expect(glucose?.mgdl == 125)
        #expect(glucose?.date == t0)
        #expect(glucose?.direction == "FortyFiveUp")
        #expect(glucose?.delta5 == 7)
        #expect(glucose?.delta15 == 15)
        #expect(glucose?.delta30 == 25)

        let sparse = AIInsights.MealEventGlucose.make(readings: [readings[0], readings[3]], direction: nil, at: t0)
        #expect(sparse?.delta5 == nil)
        #expect(sparse?.delta30 == 25)
        #expect(AIInsights.MealEventGlucose.make(readings: [], direction: nil, at: t0) == nil)
    }

    @Test("Predictions keep every 15 minutes up to 4 hours")
    func predictionsAreDownsampled() {
        let curve = Array(0 ..< 60)
        let predictions = AIInsights.MealEventPredictions.downsampled(iob: curve, cob: nil, uam: [], zt: [7])

        #expect(predictions?.stepMinutes == 15)
        #expect(predictions?.iob == Array(stride(from: 0, through: 48, by: 3)))
        #expect(predictions?.cob == nil)
        #expect(predictions?.uam == nil)
        #expect(predictions?.zt == [7])
        #expect(AIInsights.MealEventPredictions.downsampled(iob: nil, cob: [], uam: nil, zt: nil) == nil)
    }
}

@Suite("FoodFinder meal event store") struct MealEventStoreTests {
    @Test("Events round-trip through the file")
    func roundTrip() throws {
        let store = AIInsights.MealEventStore(directory: temporaryDirectory())
        var events = [makeEvent()]
        AIInsights.MealEventLinker.apply([row("a")], to: &events)
        events[0].loop = AIInsights.MealEventLoopSnapshot(reference: t0)
        let event = events[0]
        try store.save([event])

        let loaded = try store.load()
        #expect(loaded.events == [event])
        #expect(!loaded.isReadOnly)
        #expect(loaded.note == nil)

        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any]
        #expect(object?["schemaVersion"] as? Int == AIInsights.MealEventStore.schemaVersion)
    }

    @Test("A missing file loads as empty")
    func missingFile() throws {
        let loaded = try AIInsights.MealEventStore(directory: temporaryDirectory()).load()
        #expect(loaded.events.isEmpty)
        #expect(!loaded.isReadOnly)
    }

    @Test("Retention keeps two years and at most the newest events")
    func retention() {
        let now = minutes(0)
        let old = makeEvent(mealTime: now.addingTimeInterval(-AIInsights.MealEventStore.retention - 60))
        let recent = makeEvent(mealTime: now.addingTimeInterval(-89 * 24 * 60 * 60))
        #expect(AIInsights.MealEventStore.pruned([recent, old], now: now).map(\.id) == [recent.id])

        let many = (0 ..< AIInsights.MealEventStore.maxEvents + 2).map { makeEvent(mealTime: minutes(Double(-$0))) }
        let kept = AIInsights.MealEventStore.pruned(many, now: now)
        #expect(kept.count == AIInsights.MealEventStore.maxEvents)
        #expect(kept.last?.id == many[0].id)
        #expect(!kept.contains { $0.id == many.last?.id })
    }

    @Test("An unreadable file is moved aside instead of being overwritten")
    func unreadableFileIsMovedAside() throws {
        let directory = temporaryDirectory()
        let store = AIInsights.MealEventStore(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.fileURL)

        let loaded = try store.load()
        #expect(loaded.events.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names.contains { $0.hasPrefix("meal-events.unreadable-") })
    }

    @Test("Events that no longer decode are dropped after a backup copy")
    func lossyDecoding() throws {
        let directory = temporaryDirectory()
        let store = AIInsights.MealEventStore(directory: directory)
        let event = makeEvent()
        try store.save([event])

        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any] ?? [:]
        var events = object["events"] as? [Any] ?? []
        events.append(["id": "broken"])
        object["events"] = events
        try JSONSerialization.data(withJSONObject: object).write(to: store.fileURL)

        let loaded = try store.load()
        #expect(loaded.events == [event])
        #expect(loaded.note != nil)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names.contains { $0.hasPrefix("meal-events.backup-") })
    }

    @Test("A file from a newer schema is read-only")
    func newerSchemaIsReadOnly() throws {
        let store = AIInsights.MealEventStore(directory: temporaryDirectory())
        try store.save([makeEvent()])
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any] ?? [:]
        object["schemaVersion"] = AIInsights.MealEventStore.schemaVersion + 1
        try JSONSerialization.data(withJSONObject: object).write(to: store.fileURL)

        let loaded = try store.load()
        #expect(loaded.isReadOnly)
        #expect(loaded.events.count == 1)
    }
}

private actor FakeMealEventData: MealEventDataSource {
    var carbRows: [(id: UUID, date: Date, carbs: Double, isFPU: Bool, fpuID: UUID?)] = []
    var determinations: [AIInsights.MealEventDetermination] = []
    var bolusRowsByID: [String: BolusRow] = [:]
    var snapshot: AIInsights.MealEventLoopSnapshot?
    var failLookups = false

    func addCarbRow(id: UUID = UUID(), date: Date, carbs: Double, isFPU: Bool = false, fpuID: UUID? = nil) {
        carbRows.append((id: id, date: date, carbs: carbs, isFPU: isFPU, fpuID: fpuID))
    }

    func removeCarbRow(_ id: UUID) {
        carbRows.removeAll { $0.id == id }
    }

    func addDetermination(at date: Date, eventualBG: Double) {
        determinations.append(AIInsights.MealEventDetermination(date: date, eventualBG: eventualBG))
    }

    func setSnapshot(_ value: AIInsights.MealEventLoopSnapshot?) {
        snapshot = value
    }

    func setBolusRow(_ observation: BolusRow) {
        bolusRowsByID[observation.pumpEventID] = observation
    }

    func removeBolusRow(_ id: String) {
        bolusRowsByID[id] = nil
    }

    func setFailLookups(_ value: Bool) {
        failLookups = value
    }

    func carbMatch(fpuID: UUID?, mealTime: Date, carbs: Double, excluding: Set<UUID>) async -> AIInsights.MealEventCarbMatch? {
        guard !failLookups else { return nil }
        if let fpuID {
            let rows = carbRows.filter { $0.fpuID == fpuID }
            let meal = rows.filter { !$0.isFPU && !excluding.contains($0.id) }.map(\.id)
            guard !meal.isEmpty else { return nil }
            let equivalents = rows.filter(\.isFPU)
            return AIInsights.MealEventCarbMatch(
                method: .fpuID,
                carbEntryIDs: meal,
                fpuEntryIDs: equivalents.map(\.id),
                fpuCarbs: equivalents.isEmpty ? nil : equivalents.map(\.carbs).reduce(0, +),
                fpuFrom: equivalents.map(\.date).min(),
                fpuUntil: equivalents.map(\.date).max()
            )
        }
        let match = carbRows.first {
            !$0.isFPU && !excluding.contains($0.id) && abs($0.date.timeIntervalSince(mealTime)) <= 1
                && abs($0.carbs - carbs) < 0.05
        }
        return match.map {
            AIInsights.MealEventCarbMatch(method: .date, carbEntryIDs: [$0.id], fpuEntryIDs: [], fpuCarbs: nil, fpuFrom: nil, fpuUntil: nil)
        }
    }

    func loopSnapshot(at _: Date) async -> AIInsights.MealEventLoopSnapshot? {
        snapshot
    }

    func firstDetermination(after date: Date, until limit: Date) async -> AIInsights.MealEventDetermination? {
        determinations.filter { $0.date > date && $0.date <= limit }.min { $0.date < $1.date }
    }

    func bolusRows(pumpEventIDs: [String]) async -> [BolusRow]? {
        guard !failLookups else { return nil }
        return pumpEventIDs.compactMap { bolusRowsByID[$0] }
    }

    func existingCarbEntryIDs(among ids: [UUID]) async -> Set<UUID>? {
        guard !failLookups else { return nil }
        return Set(ids.filter { id in carbRows.contains { $0.id == id } })
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ date: Date) {
        current = date
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(minutes value: Double) {
        lock.lock()
        current = current.addingTimeInterval(value * 60)
        lock.unlock()
    }
}

extension AIInsights.MealEventDetermination {
    fileprivate init(date: Date, eventualBG: Double) {
        self.init(
            date: date,
            glucose: nil,
            iob: nil,
            cob: nil,
            sensitivityRatio: nil,
            eventualBG: eventualBG,
            minPredBG: nil,
            insulinReq: nil,
            isf: nil,
            carbRatio: nil,
            target: nil,
            rate: nil,
            durationMinutes: nil,
            smbUnits: nil,
            scheduledBasal: nil,
            enacted: nil,
            predictions: nil
        )
    }
}

@Suite("FoodFinder meal event recorder") struct MealEventRecorderTests {
    private func makeRecorder(
        directory: URL = temporaryDirectory(),
        data: FakeMealEventData,
        clock: TestClock
    ) -> AIInsights.MealEventRecorder {
        AIInsights.MealEventRecorder(
            store: AIInsights.MealEventStore(directory: directory),
            dataSource: data,
            followUpDelays: [],
            clock: { clock.now }
        )
    }

    @Test("A saved meal links its carb entry, loop state and pump bolus")
    func endToEnd() async throws {
        let data = FakeMealEventData()
        let clock = TestClock(t0)
        let directory = temporaryDirectory()
        let recorder = makeRecorder(directory: directory, data: data, clock: clock)
        let draft = makeDraft()
        let carbEntry = UUID()
        await data.addCarbRow(id: carbEntry, date: t0, carbs: 60, fpuID: draft.fpuID)
        await data.addCarbRow(date: minutes(60), carbs: 12, isFPU: true, fpuID: draft.fpuID)
        await data.addCarbRow(date: minutes(90), carbs: 11, isFPU: true, fpuID: draft.fpuID)
        await data.setSnapshot(AIInsights.MealEventLoopSnapshot(reference: t0))

        recorder.record(draft)
        recorder.requestBolus(eventID: draft.id, units: 4, kind: .pump, at: t0)
        recorder.observe([row("bolus", at: minutes(0.2), amount: 4)])
        recorder.bolusEnactFinished(eventID: draft.id, success: true, at: minutes(0.3))
        recorder.observe([row("bolus", .updated, at: minutes(0.2), amount: 4, mutable: false)])
        await data.setBolusRow(row("bolus", .updated, at: minutes(0.2), amount: 4, mutable: false))
        await data.addDetermination(at: minutes(0.1), eventualBG: 200)
        await data.addDetermination(at: minutes(0.5), eventualBG: 150)
        recorder.refresh()
        await recorder.waitUntilIdle()

        let event = try #require(await recorder.allEvents().first)
        #expect(event.carbLink.status == .linked)
        #expect(event.carbLink.method == .fpuID)
        #expect(event.carbLink.carbEntryIDs == [carbEntry])
        #expect(event.carbLink.fpuEntryIDs.count == 2)
        #expect(event.carbLink.fpuCarbs == 23)
        #expect(event.carbLink.fpuFrom == minutes(60))
        #expect(event.loop?.dosingMode == "closed")
        #expect(event.bolus.status == .linked)
        #expect(event.bolus.enactedAt == minutes(0.3))
        #expect(event.bolus.deliveredUnits == 4)
        #expect(event.bolus.isDeliveryFinal)
        #expect(event.firstLoopAfter?.eventualBG == 150)

        await recorder.finish()
        let reloaded = try AIInsights.MealEventStore(directory: directory).load()
        #expect(reloaded.events == [event])
    }

    @Test("A meal without fat or protein links by exact date, and a missing entry times out")
    func dateLinkAndTimeout() async throws {
        let data = FakeMealEventData()
        let clock = TestClock(t0)
        let recorder = makeRecorder(data: data, clock: clock)
        let lean = makeDraft(carbs: 45, fat: 0, protein: 0, fpuID: nil)
        let missing = makeDraft(mealTime: minutes(-30), carbs: 20, fat: 0, protein: 0, fpuID: nil)
        let carbEntry = UUID()

        recorder.record(lean)
        recorder.record(missing)
        await recorder.waitUntilIdle()
        #expect(await recorder.allEvents().map(\.carbLink.status) == [.pending, .pending])

        await data.addCarbRow(id: carbEntry, date: t0.addingTimeInterval(0.4), carbs: 45)
        clock.advance(minutes: 61)
        recorder.refresh()
        await recorder.waitUntilIdle()

        let events = await recorder.allEvents()
        #expect(events[0].carbLink.status == .linked)
        #expect(events[0].carbLink.method == .date)
        #expect(events[0].carbLink.carbEntryIDs == [carbEntry])
        #expect(events[1].carbLink.status == .notFound)
        await recorder.finish()
    }

    @Test("A deleted carb entry drops the meal from its occurrences")
    func deletedCarbEntry() async throws {
        let data = FakeMealEventData()
        let clock = TestClock(t0)
        let recorder = makeRecorder(data: data, clock: clock)
        let first = makeDraft(mealTime: minutes(-2 * 24 * 60), recordedAt: minutes(-2 * 24 * 60), fpuID: UUID())
        let second = makeDraft(fpuID: UUID())
        let firstEntry = UUID()
        await data.addCarbRow(id: firstEntry, date: first.mealTime, carbs: 60, fpuID: first.fpuID)
        await data.addCarbRow(date: second.mealTime, carbs: 60, fpuID: second.fpuID)

        recorder.record(first)
        recorder.record(second)
        await recorder.waitUntilIdle()
        let mealID = first.meal.mealID
        #expect(await recorder.occurrences(mealID: mealID, foodResultID: nil, since: minutes(-90 * 24 * 60), limit: 20).count == 2)

        await data.removeCarbRow(firstEntry)
        recorder.refresh()
        await recorder.waitUntilIdle()

        let occurrences = await recorder.occurrences(mealID: mealID, foodResultID: nil, since: minutes(-90 * 24 * 60), limit: 20)
        #expect(occurrences.map(\.id) == [second.id])
        #expect(await recorder.allEvents().first?.carbLink.status == .deleted)
        await recorder.finish()
    }

    @Test("Occurrences match the meal across analyses, newest first, within the period")
    func occurrencesAcrossAnalyses() {
        let old = MealEvent(draft: makeDraft(mealTime: minutes(-100 * 24 * 60)))
        let earlier = MealEvent(draft: makeDraft(mealTime: minutes(-3 * 24 * 60)))
        let latest = MealEvent(draft: makeDraft(name: "PASTA  pesto", mealTime: minutes(-60)))
        let other = MealEvent(draft: makeDraft(name: "Soup", mealTime: minutes(-30)))
        let events = [old, earlier, latest, other]

        let found = MealEvent.occurrences(
            in: events,
            mealID: earlier.meal.mealID,
            foodResultID: nil,
            since: minutes(-90 * 24 * 60),
            limit: 20
        )
        #expect(found.map(\.id) == [latest.id, earlier.id])

        let byResult = MealEvent.occurrences(
            in: events,
            mealID: UUID(),
            foodResultID: other.meal.foodResultID,
            since: .distantPast,
            limit: 1
        )
        #expect(byResult.map(\.id) == [other.id])
    }

    @Test("A meal never saved from the bolus calculator is timed from its analysis")
    func unsavedMealUsesAnalysisTime() {
        let plan = FoodFinderPostMealSummary.occurrences(saved: [], analysisTime: t0, analysisCarbs: 45)
        #expect(plan.basis == .analysisTime)
        #expect(plan.occurrences == [FoodFinderPostMealOccurrence(mealTime: t0, carbs: 45, fpuID: nil)])
    }

    @Test("Saved meals are pooled from their carb entry times, with the equivalents of the latest one")
    func savedMealsArePooled() {
        let fpuID = UUID()
        let earlier = MealEvent(draft: makeDraft(mealTime: minutes(-2 * 24 * 60), carbs: 50, fpuID: nil))
        let latest = MealEvent(draft: makeDraft(mealTime: minutes(-5 * 60), carbs: 60, fpuID: fpuID))
        let plan = FoodFinderPostMealSummary.occurrences(saved: [latest, earlier], analysisTime: t0, analysisCarbs: 45)
        #expect(plan.basis == .loggedMeals)
        #expect(plan.occurrences.map(\.mealTime) == [latest.mealTime, earlier.mealTime])
        #expect(plan.occurrences.map(\.carbs) == [60, 50])
        #expect(plan.occurrences.first?.fpuID == fpuID.uuidString)

        func readings(_ mgdl: Int, after start: Date) -> [PostMealGlucoseReading] {
            stride(from: 0, through: 240, by: 5).map {
                PostMealGlucoseReading(mgdl: mgdl, date: minutes(Double($0), from: start))
            }
        }
        let equivalentsUntil = minutes(150, from: latest.mealTime)
        let summary = FoodFinderPostMealSummary.make(
            occurrences: plan.occurrences,
            basis: plan.basis,
            readings: readings(120, after: earlier.mealTime) + readings(200, after: latest.mealTime),
            now: t0,
            carbEntries: [PostMealCarbEntry(date: equivalentsUntil, carbs: 10, isFPU: true, fpuID: fpuID.uuidString)]
        )
        #expect(summary.basis == .loggedMeals)
        #expect(summary.occurrenceCount == 2)
        #expect(summary.zeroToTwoHours.occurrenceCount == 2)
        #expect(summary.zeroToTwoHours.timeInRangePercent == 50)
        #expect(summary.zeroToTwoHours.timeAboveRangePercent == 50)
        #expect(summary.zeroToTwoHours.highOccurrenceCount == 1)
        #expect(summary.latestMealTime == latest.mealTime)
        #expect(summary.fpu == .insideFourHourWindow(until: equivalentsUntil))
    }

    @Test("A pump bolus that was never accepted does not hold back the first loop run forever")
    func firstLoopWaitsForEnact() async throws {
        let data = FakeMealEventData()
        let clock = TestClock(t0)
        let recorder = makeRecorder(data: data, clock: clock)
        let draft = makeDraft()
        await data.addDetermination(at: minutes(2), eventualBG: 140)

        recorder.record(draft)
        recorder.requestBolus(eventID: draft.id, units: 4, kind: .pump, at: t0)
        clock.advance(minutes: 5)
        recorder.refresh()
        await recorder.waitUntilIdle()
        #expect(await recorder.allEvents().first?.firstLoopAfter == nil)

        clock.advance(minutes: 30)
        recorder.refresh()
        await recorder.waitUntilIdle()
        #expect(await recorder.allEvents().first?.firstLoopAfter?.eventualBG == 140)
        await recorder.finish()
    }

    @Test("The first loop run is still found when the next refresh comes hours later")
    func firstLoopFoundLate() async throws {
        let data = FakeMealEventData()
        let clock = TestClock(t0)
        let recorder = makeRecorder(data: data, clock: clock)
        let draft = makeDraft()
        await data.addDetermination(at: minutes(4), eventualBG: 160)
        await data.addDetermination(at: minutes(9), eventualBG: 150)

        recorder.record(draft)
        recorder.requestBolus(eventID: draft.id, units: 3, kind: .external, at: t0)
        clock.advance(minutes: 3 * 60)
        recorder.refresh()
        await recorder.waitUntilIdle()
        #expect(await recorder.allEvents().first?.firstLoopAfter?.eventualBG == 160)
        await recorder.finish()
    }

    @Test("A bolus deleted from the treatment history no longer counts as given")
    func deletedBolusIsReleased() async throws {
        let data = FakeMealEventData()
        let clock = TestClock(t0)
        let recorder = makeRecorder(data: data, clock: clock)
        let draft = makeDraft()

        recorder.record(draft)
        recorder.requestBolus(eventID: draft.id, units: 3, kind: .external, at: t0)
        recorder.observe([row("pen", at: t0, programmed: 3, amount: 3, mutable: false, external: true)])
        await data.setBolusRow(row("pen", .updated, at: t0, programmed: 3, amount: 3, mutable: false, external: true))
        recorder.refresh()
        await recorder.waitUntilIdle()
        #expect(await recorder.allEvents().first?.bolus.deliveredUnits == 3)

        await data.removeBolusRow("pen")
        clock.advance(minutes: 5)
        recorder.refresh()
        await recorder.waitUntilIdle()
        #expect(await recorder.allEvents().first?.bolus.status == .linked)

        clock.advance(minutes: 6 * 60)
        recorder.refresh()
        await recorder.waitUntilIdle()
        let bolus = try #require(await recorder.allEvents().first?.bolus)
        #expect(bolus.records.isEmpty)
        #expect(bolus.deliveredUnits == nil)
        #expect(bolus.status == .notFound)
        await recorder.finish()
    }

    @Test("Refresh picks up a finished or purged bolus row the recorder missed")
    func refreshReadsBolusRows() async throws {
        let data = FakeMealEventData()
        let clock = TestClock(t0)
        let recorder = makeRecorder(data: data, clock: clock)
        let first = makeDraft()
        let second = makeDraft(mealTime: minutes(1), recordedAt: minutes(1))

        recorder.record(first)
        recorder.record(second)
        recorder.requestBolus(eventID: first.id, units: 4, kind: .pump, at: t0)
        recorder.requestBolus(eventID: second.id, units: 2, kind: .pump, at: minutes(1))
        recorder.observe([row("a", at: minutes(0.5)), row("b", at: minutes(1.5), programmed: 2, amount: 2)])
        await data.setBolusRow(row("a", .updated, at: minutes(0.5), amount: 3.5, mutable: false))
        recorder.refresh()
        await recorder.waitUntilIdle()

        let events = await recorder.allEvents()
        #expect(events[0].bolus.deliveredUnits == 3.5)
        #expect(events[0].bolus.isDeliveryFinal)
        #expect(events[1].bolus.status == .pending)
        #expect(events[1].bolus.records.isEmpty)
        await recorder.finish()
    }

    @Test("A store that cannot be read is retried and never overwritten")
    func unreadableStoreIsRetried() async throws {
        let directory = temporaryDirectory()
        let store = AIInsights.MealEventStore(directory: directory)
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: true)

        let data = FakeMealEventData()
        let clock = TestClock(t0)
        let recorder = makeRecorder(directory: directory, data: data, clock: clock)
        let draft = makeDraft()
        recorder.record(draft)
        await recorder.waitUntilIdle()

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)

        try FileManager.default.removeItem(at: store.fileURL)
        recorder.requestBolus(eventID: draft.id, units: 4, kind: .pump, at: t0)
        await recorder.waitUntilIdle()
        await recorder.finish()

        let saved = try store.load()
        #expect(saved.events.map(\.id) == [draft.id])
        #expect(saved.events.first?.bolus.status == .pending)
    }

    @Test("A newer store is read but left untouched")
    func newerStoreIsNotWritten() async throws {
        let directory = temporaryDirectory()
        let store = AIInsights.MealEventStore(directory: directory)
        try store.save([MealEvent(draft: makeDraft())])
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any] ?? [:]
        object["schemaVersion"] = AIInsights.MealEventStore.schemaVersion + 1
        let newer = try JSONSerialization.data(withJSONObject: object)
        try newer.write(to: store.fileURL)

        let recorder = makeRecorder(directory: directory, data: FakeMealEventData(), clock: TestClock(t0))
        recorder.record(makeDraft())
        await recorder.waitUntilIdle()
        #expect(await recorder.allEvents().count == 2)
        await recorder.finish()

        #expect(try Data(contentsOf: store.fileURL) == newer)
    }
}
