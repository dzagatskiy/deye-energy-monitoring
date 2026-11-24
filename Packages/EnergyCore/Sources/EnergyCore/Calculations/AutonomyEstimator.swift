import Foundation

public enum AutonomyEstimate: Sendable, Equatable, Codable {
    /// Remaining runtime on battery down to the minimum SOC.
    case estimate(TimeInterval)
    /// Load varies too much between windows; show a range instead of one number.
    case unstable(lower: TimeInterval, upper: TimeInterval)
    case insufficientData
    case gridAvailable
    case charging
    case belowMinimum
    case negligibleLoad
}

/// Estimates battery runtime from SOC, configured capacity and recent battery drain.
///
/// Effective power is a weighted average over the last 15/30/60 min (0.5/0.3/0.2),
/// renormalized over the windows that have enough data. The 15-min window is mandatory.
public struct AutonomyEstimator: Sendable {
    public var battery: BatteryConfiguration
    public var integrator: EnergyIntegrator
    /// Fraction of each window that must be backed by data.
    public var minimumCoverageRatio: Double
    /// max(window avg) / min(window avg) above this means the load is unstable.
    public var instabilityRatio: Double
    /// Below this the runtime is effectively unbounded, W.
    public var negligibleLoadW: Double
    /// Battery power above this means the battery is charging (e.g. from PV during an outage), W.
    public var chargingThresholdW: Double

    public static let windows: [(minutes: Double, weight: Double)] = [(15, 0.5), (30, 0.3), (60, 0.2)]

    public init(
        battery: BatteryConfiguration,
        integrator: EnergyIntegrator = EnergyIntegrator(),
        minimumCoverageRatio: Double = 2.0 / 3.0,
        instabilityRatio: Double = 2.0,
        negligibleLoadW: Double = 30,
        chargingThresholdW: Double = 50
    ) {
        self.battery = battery
        self.integrator = integrator
        self.minimumCoverageRatio = minimumCoverageRatio
        self.instabilityRatio = instabilityRatio
        self.negligibleLoadW = negligibleLoadW
        self.chargingThresholdW = chargingThresholdW
    }

    public func estimate(latest: TelemetrySample?, history: [TelemetrySample], now: Date) -> AutonomyEstimate {
        guard let latest, let soc = latest.batterySOC else { return .insufficientData }
        if latest.gridState == .on { return .gridAvailable }
        if let p = latest.batteryPower, p > chargingThresholdW { return .charging }
        if soc <= battery.minimumSOC { return .belowMinimum }

        var averages: [(avg: Double, weight: Double)] = []
        for window in Self.windows {
            let seconds = window.minutes * 60
            let interval = DateInterval(start: now.addingTimeInterval(-seconds), end: now)
            let stats = integrator.integrate(history, over: interval) { $0.batteryDrainPower }
            guard stats.coveredDuration >= seconds * minimumCoverageRatio, let avg = stats.averagePowerW else {
                if window.minutes == 15 { return .insufficientData }
                continue
            }
            averages.append((avg, window.weight))
        }

        let totalWeight = averages.reduce(0) { $0 + $1.weight }
        let effective = averages.reduce(0) { $0 + $1.avg * $1.weight } / totalWeight
        if effective < negligibleLoadW { return .negligibleLoad }

        let usableWh = battery.usableEnergyWh(atSOC: soc)
        func runtime(_ watts: Double) -> TimeInterval { usableWh / max(watts, negligibleLoadW) * 3600 }

        let values = averages.map(\.avg)
        if let lo = values.min(), let hi = values.max(), max(lo, negligibleLoadW) * instabilityRatio < hi {
            return .unstable(lower: runtime(hi), upper: runtime(lo))
        }
        return .estimate(runtime(effective))
    }
}
