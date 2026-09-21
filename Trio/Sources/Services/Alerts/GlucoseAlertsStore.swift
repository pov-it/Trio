import Combine
import Foundation

/// Persists the user's `[GlucoseAlert]` list and `GlucoseAlertConfiguration`
/// to `UserDefaults`. SwiftUI views bind to `@Published` properties; mutations
/// flow back to disk on the next runloop.
final class GlucoseAlertsStore: ObservableObject {
    static let shared = GlucoseAlertsStore()

    @Published var alerts: [GlucoseAlert]
    @Published var configuration: GlucoseAlertConfiguration

    private let defaults: UserDefaults
    private let alertsKey: String
    private let configKey: String

    private var subscriptions = Set<AnyCancellable>()

    init(
        defaults: UserDefaults = .standard,
        alertsKey: String = "trio.glucoseAlerts.v1",
        configKey: String = "trio.glucoseAlertConfiguration.v1"
    ) {
        self.defaults = defaults
        self.alertsKey = alertsKey
        self.configKey = configKey
        let loaded = Self.decode([GlucoseAlert].self, from: defaults, key: alertsKey) ?? []
        if loaded.isEmpty {
            alerts = Self.defaultAlerts()
        } else {
            // Backfill alarm types added by later releases so upgrading users
            // get a default-on entry instead of silently missing the type.
            var migrated = loaded
            let presentTypes = Set(loaded.map(\.type))
            for type in GlucoseAlertType.allCases where !presentTypes.contains(type) {
                migrated.append(GlucoseAlert(type: type))
            }
            alerts = migrated
        }
        migrateLowFamilySilenceOverrideIfNeeded()
        configuration = Self.decode(
            GlucoseAlertConfiguration.self,
            from: defaults,
            key: configKey
        ) ?? GlucoseAlertConfiguration()
        bind()
    }

    /// One-time repair after the upstream/dev alert rewrite. Stock Low
    /// alarms were persisted with `overridesSilenceAndDND = false` (only
    /// Urgent Low defaulted on). Those stored flags survive later default
    /// changes, so overnight lows stayed `.timeSensitive` and did not break
    /// through Silent Mode / DND. Urgent Low is included in case an older
    /// payload omitted the field-as-true. High / forecast / carbs-required
    /// are left alone. After this migration the user can still turn the
    /// toggle off in the editor; we will not flip it back.
    private static let lowFamilySilenceOverrideMigrationKey = "trio.glucoseAlerts.lowSilenceOverride.v1"

    private func migrateLowFamilySilenceOverrideIfNeeded() {
        guard !defaults.bool(forKey: Self.lowFamilySilenceOverrideMigrationKey) else { return }
        var changed = false
        for index in alerts.indices {
            let type = alerts[index].type
            guard type == .low || type == .urgentLow else { continue }
            guard type.defaultOverridesSilenceAndDND else { continue }
            if !alerts[index].overridesSilenceAndDND {
                alerts[index].overridesSilenceAndDND = true
                changed = true
            }
        }
        defaults.set(true, forKey: Self.lowFamilySilenceOverrideMigrationKey)
        // bind() uses dropFirst(), so persist now or the repaired flags
        // never hit disk and the next launch would skip migration.
        if changed {
            encode(alerts, to: alertsKey)
        }
    }

    /// Seed every glucose alarm enabled. Users running a stock CGM app for
    /// low/high notifications can disable the duplicates per-alarm; the
    /// safer default is to have Trio alert until the user opts out.
    /// `urgentLow` cannot be disabled from the editor regardless — it's the
    /// safety floor — but the stored flag is kept honest so the UI binding
    /// stays simple.
    private static func defaultAlerts() -> [GlucoseAlert] {
        [
            GlucoseAlert(type: .urgentLow),
            GlucoseAlert(type: .low),
            GlucoseAlert(type: .forecastedLow),
            GlucoseAlert(type: .high),
            GlucoseAlert(type: .carbsRequired)
        ]
    }

    private func bind() {
        $alerts
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] value in self?.encode(value, to: self?.alertsKey ?? "") }
            .store(in: &subscriptions)
        $configuration
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] value in self?.encode(value, to: self?.configKey ?? "") }
            .store(in: &subscriptions)
    }

    // MARK: - Mutators

    func add(_ alert: GlucoseAlert) { alerts.append(alert) }

    func update(_ alert: GlucoseAlert) {
        guard let index = alerts.firstIndex(where: { $0.id == alert.id }) else { return }
        alerts[index] = alert
    }

    func remove(_ alert: GlucoseAlert) {
        guard canDelete(alert) else { return }
        alerts.removeAll { $0.id == alert.id }
    }

    /// At least one alarm of each type must remain so the user always has
    /// urgent-low / low / forecasted-low / high coverage available. They can
    /// disable any alarm via its enabled toggle but not delete the last one.
    func canDelete(_ alert: GlucoseAlert) -> Bool {
        alerts.filter { $0.type == alert.type }.count > 1
    }

    /// `ActiveOption`s a new alarm of `type` could still occupy without
    /// overlapping an existing alarm of the same type. `.always` covers both
    /// windows, so it's removed as soon as either `.day` or `.night` is taken.
    /// Returns the empty set when the type is fully covered (either `.always`
    /// is already present, or both `.day` AND `.night` are present).
    func availableActiveOptions(forNewAlarmOfType type: GlucoseAlertType) -> Set<ActiveOption> {
        availableActiveOptions(forType: type, excludingAlertID: nil)
    }

    /// Variant used when editing an existing alarm — excludes the alarm being
    /// edited from the "taken" set so its current window stays valid.
    func availableActiveOptions(
        forType type: GlucoseAlertType,
        excludingAlertID excludedID: UUID?
    ) -> Set<ActiveOption> {
        let taken = Set(
            alerts
                .filter { $0.type == type && $0.id != excludedID }
                .map(\.activeOption)
        )
        // `.always` covers both windows — fully blocks all additions.
        if taken.contains(.always) { return [] }
        // `.day` + `.night` together also cover everything.
        if taken.contains(.day), taken.contains(.night) { return [] }
        var available = Set(ActiveOption.allCases)
        available.subtract(taken)
        // Anything already taken (even just `.day` or `.night`) makes
        // `.always` redundant — pull it out so it's not an option.
        if !taken.isEmpty { available.remove(.always) }
        return available
    }

    // MARK: - Codable helpers

    private static func decode<T: Decodable>(
        _: T.Type,
        from defaults: UserDefaults,
        key: String
    ) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func encode<T: Encodable>(_ value: T, to key: String) {
        guard !key.isEmpty, let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}
