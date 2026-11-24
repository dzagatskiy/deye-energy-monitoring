import Foundation

/// Result of integrating power over a time window.
/// Power is in W, energy in Wh/kWh — never mix them.
public struct PowerWindowStats: Sendable, Equatable {
    public var interval: DateInterval
    public var energyWh: Double
    /// Part of the interval actually backed by data (gaps > maxGap are excluded), s.
    public var coveredDuration: TimeInterval
    public var maxPowerW: Double?
    /// Number of measured points inside the interval.
    public var sampleCount: Int

    public var energyKWh: Double { energyWh / 1000 }

    /// Time-weighted average power over the covered part, W.
    public var averagePowerW: Double? {
        coveredDuration > 0 ? energyWh / (coveredDuration / 3600) : nil
    }

    public var uncoveredDuration: TimeInterval { max(0, interval.duration - coveredDuration) }
    public var isComplete: Bool { uncoveredDuration < 1 }
}

/// Integrates power samples over time with the trapezoidal rule.
///
/// `Energy(Wh) = Σ (P_i + P_{i+1}) / 2 × Δt_hours`, so uneven sampling intervals are handled naturally.
/// Segments longer than `maxGap` are treated as missing data and skipped (not interpolated).
public struct EnergyIntegrator: Sendable {
    public var maxGap: TimeInterval

    public init(maxGap: TimeInterval = 15 * 60) {
        self.maxGap = maxGap
    }

    public func integrate(
        _ samples: [TelemetrySample],
        over interval: DateInterval,
        power: (TelemetrySample) -> Double?
    ) -> PowerWindowStats {
        let points: [(t: Date, p: Double)] = samples
            .compactMap { s in power(s).map { (s.timestamp, $0) } }
            .sorted { $0.t < $1.t }

        var energyWh = 0.0
        var covered: TimeInterval = 0
        var maxPower: Double?
        var count = 0

        func note(_ p: Double) { maxPower = max(maxPower ?? p, p) }

        for point in points where interval.contains(point.t) {
            count += 1
            note(point.p)
        }

        // Pairs of consecutive points, clipped to the interval with linear interpolation.
        for (a, b) in zip(points, points.dropFirst()) {
            let dt = b.t.timeIntervalSince(a.t)
            guard dt > 0, dt <= maxGap else { continue }
            let start = max(a.t, interval.start)
            let end = min(b.t, interval.end)
            guard end > start else { continue }
            let pStart = a.p + (b.p - a.p) * start.timeIntervalSince(a.t) / dt
            let pEnd = a.p + (b.p - a.p) * end.timeIntervalSince(a.t) / dt
            let seconds = end.timeIntervalSince(start)
            energyWh += (pStart + pEnd) / 2 * seconds / 3600
            covered += seconds
            if count == 0 { note(pStart); note(pEnd) }
        }

        // Edges outside the data range: hold the nearest value if it is close enough.
        if let first = points.first, interval.start < first.t {
            let end = min(first.t, interval.end)
            let seconds = end.timeIntervalSince(interval.start)
            if seconds > 0, first.t.timeIntervalSince(interval.start) <= maxGap {
                energyWh += first.p * seconds / 3600
                covered += seconds
                note(first.p)
            }
        }
        if let last = points.last, interval.end > last.t {
            let start = max(last.t, interval.start)
            let seconds = interval.end.timeIntervalSince(start)
            if seconds > 0, interval.end.timeIntervalSince(last.t) <= maxGap {
                energyWh += last.p * seconds / 3600
                covered += seconds
                note(last.p)
            }
        }

        return PowerWindowStats(
            interval: interval,
            energyWh: energyWh,
            coveredDuration: covered,
            maxPowerW: maxPower,
            sampleCount: count
        )
    }

    /// Convenience: load power stats (what the house consumed).
    public func loadStats(_ samples: [TelemetrySample], over interval: DateInterval) -> PowerWindowStats {
        integrate(samples, over: interval) { $0.loadPower }
    }

    /// Relative difference between our integrated energy and the inverter's own counter (0.1 = 10%).
    /// Returns nil when either value is unavailable or the counter is zero.
    public static func counterDeviation(integratedKWh: Double, counterKWh: Double?) -> Double? {
        guard let counterKWh, counterKWh > 0 else { return nil }
        return abs(integratedKWh - counterKWh) / counterKWh
    }
}
