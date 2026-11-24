import Foundation

/// Everything a widget or the dashboard needs for one inverter, precomputed by `SnapshotBuilder`.
/// The widget never runs business logic on its own: it renders this struct.
public struct EnergySnapshot: Sendable, Codable, Equatable {
    public struct OutageInfo: Sendable, Codable, Equatable {
        public var startedAt: Date
        public var endedAt: Date?
        public var energyKWh: Double
        public var isApproximate: Bool
    }

    public var inverterId: InverterID
    public var name: String
    public var generatedAt: Date
    /// Time of the measurement shown (not the time of the request).
    public var measuredAt: Date?
    public var source: SourceKind?
    public var isStale: Bool

    public var gridState: GridState
    public var batterySOC: Double?
    public var batteryPowerW: Double?
    public var loadPowerW: Double?
    public var pvPowerW: Double?
    public var gridPowerW: Double?

    /// Set while the grid is off; the UI counts up from here in real time.
    public var currentOutage: OutageInfo?
    public var lastOutage: OutageInfo?
    public var autonomy: AutonomyEstimate

    public var todayOutageCount: Int
    public var todayOutageDuration: TimeInterval
    public var todayOutageEnergyKWh: Double
    public var todayMaxLoadW: Double?

    /// Last refresh error, shown next to "Оновлено …".
    public var lastError: String?
    /// When Deye Cloud was last asked successfully (may be later than `measuredAt`: no new frame yet).
    public var checkedAt: Date? = nil

    public var batteryFlow: BatteryFlow { BatteryFlow(batteryPower: batteryPowerW) }

    public static func placeholder(name: String = "Дача") -> EnergySnapshot {
        let now = Date()
        return EnergySnapshot(
            inverterId: InverterID("placeholder"), name: name, generatedAt: now, measuredAt: now, source: .cloud,
            isStale: false, gridState: .off, batterySOC: 82, batteryPowerW: -1250, loadPowerW: 1250, pvPowerW: 0,
            gridPowerW: 0,
            currentOutage: OutageInfo(startedAt: now.addingTimeInterval(-(3 * 3600 + 42 * 60)), endedAt: nil, energyKWh: 4.65, isApproximate: false),
            lastOutage: nil, autonomy: .estimate(5 * 3600 + 20 * 60),
            todayOutageCount: 2, todayOutageDuration: 5 * 3600, todayOutageEnergyKWh: 5.9, todayMaxLoadW: 3100, lastError: nil
        )
    }
}

extension BatteryFlow: Codable {}

/// Builds `EnergySnapshot` from stored samples. Shared by the app, background refresh and the widget.
public struct SnapshotBuilder: Sendable {
    public var freshness = FreshnessPolicy()

    public init() {}

    public func build(
        descriptorName: String,
        profile: InverterProfile,
        samples: [TelemetrySample],
        now: Date,
        lastError: String? = nil,
        checkedAt: Date? = nil
    ) -> EnergySnapshot {
        let series = SampleSeries.normalize(samples)
        let latest = series.last
        let tracker = OutageTracker()
        let outages = tracker.outages(from: series, now: now)

        let day = OutageStatistics.day(containing: now, timeZone: profile.timeZone)
        let today = OutageStatistics.summary(of: outages, in: day, now: now)
        let todayLoad = tracker.integrator.loadStats(series, over: DateInterval(start: day.start, end: max(day.start, now)))

        func info(_ o: Outage) -> EnergySnapshot.OutageInfo {
            EnergySnapshot.OutageInfo(
                startedAt: o.startedAt, endedAt: o.endedAt, energyKWh: o.energyKWh,
                isApproximate: o.hasDataGaps || o.startUncertainty == nil
            )
        }
        let ongoing = outages.last.flatMap { $0.isOngoing ? $0 : nil }
        let finished = outages.last(where: { !$0.isOngoing })

        let estimator = AutonomyEstimator(battery: profile.battery)
        let isStale: Bool
        if case .stale = freshness.evaluate(latest, now: now) { isStale = true } else { isStale = latest == nil }

        return EnergySnapshot(
            inverterId: profile.id,
            name: profile.customName ?? descriptorName,
            generatedAt: now,
            measuredAt: latest?.timestamp,
            source: latest?.source,
            isStale: isStale,
            gridState: latest?.gridState ?? .unknown,
            batterySOC: latest?.batterySOC,
            batteryPowerW: latest?.batteryPower,
            loadPowerW: latest?.loadPower,
            pvPowerW: latest?.pvPower,
            gridPowerW: latest?.gridPower,
            currentOutage: ongoing.map(info),
            lastOutage: finished.map(info),
            autonomy: estimator.estimate(latest: latest, history: series, now: now),
            todayOutageCount: today.count,
            todayOutageDuration: today.totalDuration,
            todayOutageEnergyKWh: today.energyKWh,
            todayMaxLoadW: todayLoad.maxPowerW,
            lastError: lastError,
            checkedAt: checkedAt
        )
    }
}
