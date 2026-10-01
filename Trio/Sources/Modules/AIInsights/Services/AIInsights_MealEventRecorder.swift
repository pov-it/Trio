import Foundation

/// Read access to Trio's stores for `AIInsights.MealEventRecorder`. Every lookup returns nil when it fails,
/// so a failed lookup is retried rather than read as "not there".
protocol MealEventDataSource: Sendable {
    /// The carb rows Trio stored for a meal: by `fpuID` when there is one, else by exact date and carbs.
    func carbMatch(fpuID: UUID?, mealTime: Date, carbs: Double, excluding: Set<UUID>) async -> AIInsights.MealEventCarbMatch?
    func loopSnapshot(at reference: Date) async -> AIInsights.MealEventLoopSnapshot?
    func firstDetermination(after date: Date, until limit: Date) async -> AIInsights.MealEventDetermination?
    /// Current state of the given bolus rows as `.updated` observations; rows that are missing were deleted.
    func bolusRows(pumpEventIDs: [String]) async -> [AIInsights.MealEventBolusObservation]?
    /// The subset of `ids` that still exist.
    func existingCarbEntryIDs(among ids: [UUID]) async -> Set<UUID>?
}

extension AIInsights {
    /// Records FoodFinder meals saved from the bolus calculator and keeps their links up to date.
    ///
    /// Callers send commands without waiting; they run one at a time in the order they were sent, so a bolus
    /// request is always handled after its meal and before any pump history rows that follow it. Changes are
    /// written once per burst of commands rather than once per command.
    actor MealEventRecorder {
        enum Command: Sendable {
            case record(MealEventDraft)
            case requestBolus(eventID: UUID, units: Double, kind: MealEventBolus.Kind, at: Date)
            case bolusEnactFinished(eventID: UUID, success: Bool, at: Date)
            case observe([MealEventBolusObservation])
            case storeAnalyses([MealEventAnalysis])
            case refresh
            case save
            case barrier(CheckedContinuation<Void, Never>)
        }

        private enum LoadState {
            case notLoaded
            case loaded
            case readOnly
        }

        static let defaultFollowUpDelays: [TimeInterval] = [3 * 60, 12 * 60, 35 * 60]
        static let carbLinkTimeout: TimeInterval = 60 * 60
        /// `firstLoopAfter` is the first loop run within this long after the bolus.
        static let firstLoopTimeout: TimeInterval = 2 * 60 * 60
        /// A pump bolus that is neither accepted nor failed after this long no longer holds back `firstLoopAfter`.
        static let enactWait: TimeInterval = 30 * 60
        /// Meals recorded within this long are still followed up: their first loop run and unfinished bolus rows.
        static let followUpWindow: TimeInterval = 24 * 60 * 60
        static let deletionCheckWindow: TimeInterval = 7 * 24 * 60 * 60
        static let deletionCheckInterval: TimeInterval = 10 * 60

        private let store: MealEventStore
        private let dataSource: MealEventDataSource
        private let followUpDelays: [TimeInterval]
        private let clock: @Sendable () -> Date
        private let log: @Sendable (String) -> Void
        private let commands: AsyncStream<Command>
        private let continuation: AsyncStream<Command>.Continuation
        private var worker: Task<Void, Never>?
        private var loadState: LoadState = .notLoaded
        private var events: [MealEvent] = []
        private var hasUnsavedChanges = false
        private var isSaveQueued = false
        private var lastDeletionCheck: Date?

        init(
            store: MealEventStore,
            dataSource: MealEventDataSource,
            followUpDelays: [TimeInterval] = MealEventRecorder.defaultFollowUpDelays,
            clock: @escaping @Sendable () -> Date = { Date() },
            log: @escaping @Sendable (String) -> Void = { _ in }
        ) {
            self.store = store
            self.dataSource = dataSource
            self.followUpDelays = followUpDelays
            self.clock = clock
            self.log = log
            let stream = AsyncStream.makeStream(of: Command.self)
            commands = stream.stream
            continuation = stream.continuation
        }

        // MARK: - Commands

        nonisolated func record(_ draft: MealEventDraft) {
            send(.record(draft))
        }

        nonisolated func requestBolus(eventID: UUID, units: Double, kind: MealEventBolus.Kind, at date: Date) {
            send(.requestBolus(eventID: eventID, units: units, kind: kind, at: date))
        }

        nonisolated func bolusEnactFinished(eventID: UUID, success: Bool, at date: Date) {
            send(.bolusEnactFinished(eventID: eventID, success: success, at: date))
        }

        nonisolated func observe(_ observations: [MealEventBolusObservation]) {
            guard !observations.isEmpty else { return }
            send(.observe(observations))
        }

        nonisolated func refresh() {
            send(.refresh)
        }

        /// Keeps the curve and outcome of meals whose analysis no longer changes.
        nonisolated func storeAnalyses(_ analyses: [MealEventAnalysis]) {
            let finished = analyses.filter(\.isFinal)
            guard !finished.isEmpty else { return }
            send(.storeAnalyses(finished))
        }

        private nonisolated func send(_ command: Command) {
            continuation.yield(command)
        }

        func start() {
            guard worker == nil else { return }
            let commands = self.commands
            worker = Task {
                for await command in commands {
                    await self.handle(command)
                }
            }
        }

        /// Returns once every command sent before this call has been handled and saved.
        func waitUntilIdle() async {
            start()
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                send(.barrier(done))
            }
        }

        /// Handles and saves the remaining commands, then stops the worker.
        func finish() async {
            continuation.finish()
            await worker?.value
            saveIfNeeded()
        }

        // MARK: - Reads

        func allEvents() -> [MealEvent] {
            ensureLoaded()
            return events
        }

        func occurrences(mealID: UUID, foodResultID: UUID?, since: Date, limit: Int) -> [MealEvent] {
            ensureLoaded()
            return MealEvent.occurrences(in: events, mealID: mealID, foodResultID: foodResultID, since: since, limit: limit)
        }

        // MARK: - Handling

        private func handle(_ command: Command) async {
            switch command {
            case let .record(draft):
                await record(draft)
            case let .requestBolus(eventID, units, kind, date):
                mutate(eventID) { MealEventLinker.request(&$0, units: units, kind: kind, at: date) }
            case let .bolusEnactFinished(eventID, success, date):
                mutate(eventID) { MealEventLinker.enactFinished(&$0, success: success, at: date) }
            case let .observe(observations):
                ensureLoaded()
                if !MealEventLinker.apply(observations, to: &events).isEmpty {
                    markChanged()
                }
            case let .storeAnalyses(analyses):
                for analysis in analyses {
                    mutate(analysis.id) { event in
                        event.curve = analysis.curve
                        event.outcome = analysis.outcome
                    }
                }
            case .refresh:
                await refreshEvents()
            case .save:
                saveIfNeeded()
            case let .barrier(done):
                saveIfNeeded()
                done.resume()
            }
        }

        private func record(_ draft: MealEventDraft) async {
            ensureLoaded()
            guard index(of: draft.id) == nil else { return }
            events.append(MealEvent(draft: draft))
            markChanged()
            log("FoodFinder meal events: recorded \(draft.id)")

            _ = await linkCarbs(eventID: draft.id)
            let reference = min(draft.mealTime, draft.recordedAt)
            var snapshot = await dataSource.loopSnapshot(at: reference)
                ?? MealEventLoopSnapshot(reference: reference)
            snapshot.dosingMode = draft.dosingMode
            if let index = index(of: draft.id) {
                events[index].loop = snapshot
            }
            markChanged()
            scheduleFollowUps()
        }

        private func mutate(_ eventID: UUID, _ change: (inout MealEvent) -> Void) {
            ensureLoaded()
            guard let index = index(of: eventID) else { return }
            let previous = events[index]
            change(&events[index])
            if events[index] != previous {
                markChanged()
            }
        }

        private func refreshEvents() async {
            guard ensureLoaded() else { return }
            let now = clock()
            var changed = false

            for event in events where event.carbLink.status == .pending {
                if await linkCarbs(eventID: event.id) { changed = true }
            }
            if await captureFirstLoops(now: now) { changed = true }
            if await refreshBolusRows(now: now) { changed = true }
            if await checkDeletions(now: now) { changed = true }
            if !MealEventLinker.expire(&events, now: now).isEmpty { changed = true }

            if changed {
                markChanged()
            }
        }

        private func linkCarbs(eventID: UUID) async -> Bool {
            guard let event = index(of: eventID).map({ events[$0] }), event.carbLink.status == .pending else { return false }
            let claimed = Set(events.filter { $0.id != eventID }.flatMap(\.carbLink.carbEntryIDs))
            let match = await dataSource.carbMatch(
                fpuID: event.carbLink.fpuID,
                mealTime: event.mealTime,
                carbs: event.nutrition.carbs,
                excluding: claimed
            )
            guard let index = index(of: eventID) else { return false }
            if let match {
                events[index].carbLink.apply(match)
                return true
            }
            guard clock().timeIntervalSince(events[index].recordedAt) > Self.carbLinkTimeout else { return false }
            events[index].carbLink.status = .notFound
            return true
        }

        /// Trio edits a carb entry by replacing it, so a linked entry that disappears means the meal changed. A bolus
        /// deleted from the treatment history no longer counts as given.
        private func checkDeletions(now: Date) async -> Bool {
            if let last = lastDeletionCheck, now.timeIntervalSince(last) < Self.deletionCheckInterval { return false }
            let recent = events.filter { now.timeIntervalSince($0.mealTime) < Self.deletionCheckWindow }
            let linked = recent.filter { $0.carbLink.status == .linked && !$0.carbLink.carbEntryIDs.isEmpty }
            let carbIDs = linked.flatMap(\.carbLink.carbEntryIDs)
            var changed = false
            var isComplete = true

            if !carbIDs.isEmpty {
                if let existing = await dataSource.existingCarbEntryIDs(among: carbIDs) {
                    for event in linked where event.carbLink.carbEntryIDs.allSatisfy({ !existing.contains($0) }) {
                        guard let index = index(of: event.id), events[index].carbLink.status == .linked else { continue }
                        events[index].carbLink.status = .deleted
                        changed = true
                    }
                } else {
                    isComplete = false
                }
            }

            if let bolusChanged = await reconcileBolusRows(recent.flatMap { $0.bolus.records.map(\.pumpEventID) }) {
                changed = changed || bolusChanged
            } else {
                isComplete = false
            }

            if isComplete {
                lastDeletionCheck = now
            }
            return changed
        }

        private func captureFirstLoops(now: Date) async -> Bool {
            var changed = false
            let waiting = events.filter {
                $0.firstLoopAfter == nil && now.timeIntervalSince($0.recordedAt) < Self.followUpWindow
            }
            for event in waiting {
                guard let after = firstLoopReference(for: event, now: now) else { continue }
                let limit = after.addingTimeInterval(Self.firstLoopTimeout)
                guard let determination = await dataSource.firstDetermination(after: after, until: limit),
                      let index = index(of: event.id)
                else { continue }
                events[index].firstLoopAfter = determination
                changed = true
            }
            return changed
        }

        /// The loop run worth keeping is the first one that saw the bolus as well as the carbs.
        private func firstLoopReference(for event: MealEvent, now: Date) -> Date? {
            let bolus = event.bolus
            guard bolus.kind == .pump, bolus.status != .enactFailed else { return event.recordedAt }
            if let enactedAt = bolus.enactedAt ?? bolus.records.first?.timestamp {
                return max(event.recordedAt, enactedAt)
            }
            let requestedAt = bolus.requestedAt ?? event.recordedAt
            return now.timeIntervalSince(requestedAt) < Self.enactWait ? nil : requestedAt
        }

        /// Unfinished bolus rows of recent meals, until the pump reports what was delivered.
        private func refreshBolusRows(now: Date) async -> Bool {
            let ids = events
                .filter { now.timeIntervalSince($0.recordedAt) < Self.followUpWindow }
                .flatMap { $0.bolus.records.filter { !$0.isFinal }.map(\.pumpEventID) }
            return await reconcileBolusRows(ids) ?? false
        }

        /// Applies the current state of the given bolus rows; rows that no longer exist are released. Returns
        /// whether an event changed, or nil when the rows could not be read.
        private func reconcileBolusRows(_ ids: [String]) async -> Bool? {
            guard !ids.isEmpty else { return false }
            guard let rows = await dataSource.bolusRows(pumpEventIDs: ids) else { return nil }
            let found = Set(rows.map(\.pumpEventID))
            let missing = ids.filter { !found.contains($0) }.map { MealEventBolusObservation.deleted($0) }
            return !MealEventLinker.apply(rows + missing, to: &events).isEmpty
        }

        // MARK: - Storage

        @discardableResult private func ensureLoaded() -> Bool {
            guard loadState == .notLoaded else { return true }
            do {
                let loaded = try store.load()
                var merged = loaded.events
                for event in events {
                    if let index = merged.firstIndex(where: { $0.id == event.id }) {
                        merged[index] = event
                    } else {
                        merged.append(event)
                    }
                }
                events = merged
                loadState = loaded.isReadOnly ? .readOnly : .loaded
                if let note = loaded.note { log(note) }
                return true
            } catch {
                log("FoodFinder meal events: store not readable yet: \(error)")
                return false
            }
        }

        /// Queues one save behind the commands already waiting, so a burst of changes is written once.
        private func markChanged() {
            hasUnsavedChanges = true
            guard !isSaveQueued else { return }
            isSaveQueued = true
            send(.save)
        }

        private func saveIfNeeded() {
            isSaveQueued = false
            guard hasUnsavedChanges, ensureLoaded(), loadState == .loaded else { return }
            events = MealEventStore.pruned(events, now: clock())
            do {
                try store.save(events)
                hasUnsavedChanges = false
            } catch {
                log("FoodFinder meal events: save failed: \(error)")
            }
        }

        private func index(of eventID: UUID) -> Int? {
            events.firstIndex { $0.id == eventID }
        }

        private func scheduleFollowUps() {
            for delay in followUpDelays {
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    self?.refresh()
                }
            }
        }
    }
}

extension AIInsights.MealEventLoopSnapshot {
    init(reference: Date) {
        self.init(
            reference: reference,
            glucose: nil,
            determination: nil,
            tempBasal: nil,
            override: nil,
            tempTarget: nil,
            dosingMode: nil
        )
    }
}
