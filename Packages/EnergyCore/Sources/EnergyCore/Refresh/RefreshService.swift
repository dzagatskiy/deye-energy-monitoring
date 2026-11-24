import Foundation

/// Non-secret account configuration, stored as JSON in the App Group (secrets live in the Keychain).
public struct AccountSettings: Sendable, Codable, Equatable {
    public var region: DeyeRegion
    public var inverters: [InverterDescriptor]
    public var profiles: [InverterProfile]
    /// Inverter shown in the app and in widgets without an explicit choice.
    public var selectedInverter: InverterID?
    /// Foreground polling interval, s. Deye recommends polling every 1–2 min (data itself changes every ~5 min).
    public var refreshInterval: TimeInterval

    /// Choices offered in Settings; the default is 2 min.
    public static let refreshIntervalChoices: [TimeInterval] = [60, 120, 300]
    public static let defaultRefreshInterval: TimeInterval = 120

    /// Stored value clamped to 1…10 min, so an old or hand-edited setting can never poll faster than Deye allows.
    public var effectiveRefreshInterval: TimeInterval { min(max(refreshInterval, 60), 600) }

    public static let fileName = "settings.json"

    public init(
        region: DeyeRegion = .eu, inverters: [InverterDescriptor] = [], profiles: [InverterProfile] = [],
        selectedInverter: InverterID? = nil, refreshInterval: TimeInterval = AccountSettings.defaultRefreshInterval
    ) {
        self.region = region
        self.inverters = inverters
        self.profiles = profiles
        self.selectedInverter = selectedInverter
        self.refreshInterval = refreshInterval
    }

    public func profile(for id: InverterID) -> InverterProfile {
        profiles.first { $0.id == id } ?? InverterProfile(id: id)
    }

    public func descriptor(for id: InverterID) -> InverterDescriptor? {
        inverters.first { $0.id == id }
    }

    /// Explicit choice → saved selection → first (online-first) inverter.
    public func resolve(_ requested: InverterID?) -> InverterID? {
        if let requested, inverters.contains(where: { $0.id == requested }) { return requested }
        if let selectedInverter, inverters.contains(where: { $0.id == selectedInverter }) { return selectedInverter }
        return inverters.first?.id
    }

    /// Replaces the inverter list, keeping existing profiles and creating defaults for new inverters.
    public mutating func updateInverters(_ discovered: [InverterDescriptor], suggestedBattery: [InverterID: BatteryConfiguration] = [:]) {
        inverters = discovered
        for d in discovered where !profiles.contains(where: { $0.id == d.id }) {
            profiles.append(InverterProfile(id: d.id, battery: suggestedBattery[d.id] ?? .default))
        }
    }
}

/// Per-inverter bookkeeping for history backfill.
public struct SyncState: Sendable, Codable, Equatable {
    public var lastHistoryFetchAt: Date?
    /// Last successful `/device/latest` for this inverter, by any process (app, widget, BGTask).
    public var lastSuccessAt: Date?
    public var lastError: String?

    public init(lastHistoryFetchAt: Date? = nil, lastSuccessAt: Date? = nil, lastError: String? = nil) {
        self.lastHistoryFetchAt = lastHistoryFetchAt
        self.lastSuccessAt = lastSuccessAt
        self.lastError = lastError
    }

    static func fileName(_ id: InverterID) -> String { "sync-\(id.rawValue).json" }
}

/// When to reuse stored data instead of asking Deye Cloud again.
///
/// The store and sync state live in the App Group, so this cache is shared by the app, the widget
/// and the background task: whoever fetched last saves the others a request.
public struct FetchCachePolicy: Sendable, Equatable {
    /// Never ask for `/device/latest` more often than this for one inverter (Deye: poll every 1–2 min).
    public var minFetchInterval: TimeInterval
    /// Deye gets a new frame from the logger about every 5.7 min (median 343 s observed). Until the next
    /// frame is due, a new request would most likely return the same sample.
    public var expectedUploadInterval: TimeInterval
    /// Upper bound for waiting on the next frame, in case the logger's interval differs.
    public var maxReuse: TimeInterval

    public init(minFetchInterval: TimeInterval = 60, expectedUploadInterval: TimeInterval = 350, maxReuse: TimeInterval = 420) {
        self.minFetchInterval = minFetchInterval
        self.expectedUploadInterval = expectedUploadInterval
        self.maxReuse = maxReuse
    }

    public static let `default` = FetchCachePolicy()
    /// No caching (pull-to-refresh).
    public static let bypass = FetchCachePolicy(minFetchInterval: 0, expectedUploadInterval: 0, maxReuse: 0)

    public func shouldFetchLatest(lastFetchAt: Date?, latest: TelemetrySample?, now: Date) -> Bool {
        guard let lastFetchAt, lastFetchAt <= now else { return true }
        let sinceFetch = now.timeIntervalSince(lastFetchAt)
        if sinceFetch < minFetchInterval { return false }
        if let latest, latest.source == .cloud, lastFetchAt >= latest.timestamp,
           now < latest.timestamp.addingTimeInterval(expectedUploadInterval), sinceFetch < maxReuse {
            return false
        }
        return true
    }
}

/// The single update path used by the app (foreground), BGAppRefreshTask and the widget timeline provider.
///
/// 1. Latest sample for each inverter (one `/device/latest` call for up to 10 inverters).
/// 2. History backfill since the last fetch (≤ `maxBackfillDays`), at most every `historyInterval`:
///    this recovers outages that happened while iOS kept the app suspended.
/// 3. Recompute and save `EnergySnapshot` per inverter.
public actor RefreshService {
    public typealias SourcesFactory = @Sendable (InverterProfile) -> [any InverterDataSource]
    /// Delivers notifications (UNUserNotificationCenter in the app and the widget; nil in tests that don't care).
    public typealias Notifier = @Sendable ([EnergyNotification]) async -> Void

    private let store: TelemetryStore
    private let makeSources: SourcesFactory
    private let builder = SnapshotBuilder()
    private let notifier: Notifier?
    private let evaluator = NotificationEvaluator()
    public let historyInterval: TimeInterval
    /// The widget has a few seconds per update, so it backfills less than the app / BGTask.
    public let maxBackfillDays: Double
    /// How much history the snapshot needs: today + the outage that may have started yesterday.
    public let snapshotWindow: TimeInterval = 48 * 3600
    public let retentionDays = 90

    public init(
        store: TelemetryStore,
        historyInterval: TimeInterval = 30 * 60,
        maxBackfillDays: Double = 7,
        notifier: Notifier? = nil,
        makeSources: @escaping SourcesFactory
    ) {
        self.store = store
        self.notifier = notifier
        self.historyInterval = historyInterval
        self.maxBackfillDays = maxBackfillDays
        self.makeSources = makeSources
    }

    public static func snapshotFileName(_ id: InverterID) -> String { "snapshot-\(id.rawValue).json" }

    @discardableResult
    public func refresh(
        _ ids: [InverterID],
        settings: AccountSettings,
        now: Date = Date(),
        includeHistory: Bool = true,
        cache: FetchCachePolicy = .default
    ) async -> [InverterID: EnergySnapshot] {
        var result: [InverterID: EnergySnapshot] = [:]
        for id in ids {
            let profile = settings.profile(for: id)
            var sync = await store.load(SyncState.self, from: SyncState.fileName(id)) ?? SyncState()
            let router = SourceRouter(sources: makeSources(profile))
            var errors: [String] = []
            var contacted = false

            let stored = await store.latest(id, now: now)
            if cache.shouldFetchLatest(lastFetchAt: sync.lastSuccessAt, latest: stored, now: now) {
                contacted = true
                do {
                    let routed = try await router.fetchLatest()
                    var sample = routed.sample
                    sample.inverterId = id
                    try await store.append([sample])
                    sync.lastSuccessAt = now
                } catch {
                    errors.append(Self.describe(error))
                }
            }

            if includeHistory, now.timeIntervalSince(sync.lastHistoryFetchAt ?? .distantPast) >= historyInterval {
                contacted = true
                let from = max(sync.lastHistoryFetchAt?.addingTimeInterval(-3600) ?? .distantPast,
                               now.addingTimeInterval(-maxBackfillDays * 86_400))
                do {
                    let history = try await router.fetchHistory(DateInterval(start: from, end: now))
                    try await store.append(history.map { var s = $0; s.inverterId = id; return s })
                    sync.lastHistoryFetchAt = now
                } catch {
                    errors.append(Self.describe(error))
                }
            }

            // A cache hit says nothing new about the connection: keep the previous error, if any.
            if contacted { sync.lastError = errors.first }
            try? await store.save(sync, as: SyncState.fileName(id))

            let samples = await store.samples(id, in: DateInterval(start: now.addingTimeInterval(-snapshotWindow), end: now))
            let snapshot = builder.build(
                descriptorName: settings.descriptor(for: id)?.displayName ?? id.rawValue,
                profile: profile, samples: samples, now: now, lastError: sync.lastError, checkedAt: sync.lastSuccessAt
            )
            try? await store.save(snapshot, as: Self.snapshotFileName(id))
            result[id] = snapshot

            if let notifier {
                let outages = OutageTracker().outages(from: samples, now: now)
                let previous = await store.load(NotificationState.self, from: NotificationState.fileName(id)) ?? NotificationState()
                let (notifications, state) = evaluator.evaluate(
                    snapshot: snapshot, outages: outages, profile: profile, state: previous, now: now)
                try? await store.save(state, as: NotificationState.fileName(id))
                if !notifications.isEmpty { await notifier(notifications) }
            }
        }
        try? await store.prune(olderThan: retentionDays, now: now)
        return result
    }

    /// Snapshot as last saved, recomputed against `now` so timers and staleness are current.
    public func cachedSnapshot(_ id: InverterID, settings: AccountSettings, now: Date = Date()) async -> EnergySnapshot? {
        let samples = await store.samples(id, in: DateInterval(start: now.addingTimeInterval(-snapshotWindow), end: now))
        guard !samples.isEmpty else { return await store.load(EnergySnapshot.self, from: Self.snapshotFileName(id)) }
        let sync = await store.load(SyncState.self, from: SyncState.fileName(id))
        return builder.build(
            descriptorName: settings.descriptor(for: id)?.displayName ?? id.rawValue,
            profile: settings.profile(for: id), samples: samples, now: now, lastError: sync?.lastError,
            checkedAt: sync?.lastSuccessAt
        )
    }

    /// Outages over an arbitrary period (history screen).
    public func outages(_ id: InverterID, in range: DateInterval, now: Date = Date()) async -> [Outage] {
        let samples = await store.samples(id, in: range)
        return OutageTracker().outages(from: samples, now: now)
    }

    public static func describe(_ error: Error) -> String {
        switch error {
        case DataSourceError.unauthorized: "Помилка авторизації Deye Cloud"
        case DataSourceError.loginRequired: "Сесія Deye Cloud завершилась, увійдіть знову"
        case DataSourceError.rateLimited: "Перевищено ліміт запитів Deye Cloud"
        case DataSourceError.unavailable: "Логер недоступний"
        case DataSourceError.emptyResponse: "Порожня відповідь Deye Cloud"
        case DataSourceError.network(let m): "Немає зв'язку: \(m)"
        case DataSourceError.invalidResponse(let m): "Некоректна відповідь: \(m)"
        case SourceRouterError.allSourcesFailed(let failures): failures.last.map { describe($0.error) } ?? "Немає джерел даних"
        case SourceRouterError.noSourcesConfigured: "Джерело даних не налаштоване"
        default: error.localizedDescription
        }
    }
}
