import Foundation

/// A single grid outage reconstructed from telemetry.
public struct Outage: Sendable, Equatable, Identifiable {
    /// Timestamp of the first OFF sample. Stable across recomputation, so it is used as the identity.
    public var firstOffSampleAt: Date
    /// Best estimate of when the grid went down: midpoint between the last ON and the first OFF sample.
    public var startedAt: Date
    /// ± seconds around `startedAt`. `nil` means data starts mid-outage and the real start is earlier.
    public var startUncertainty: TimeInterval?
    /// `nil` while the outage is ongoing.
    public var endedAt: Date?
    public var endUncertainty: TimeInterval?
    public var startSOC: Double?
    public var endSOC: Double?
    /// Load energy consumed during the outage, kWh.
    public var energyKWh: Double
    /// Time-weighted average load during the outage, W.
    public var averagePowerW: Double?
    public var maxPowerW: Double?
    /// True when some part of the outage had no data for longer than `maxGap`.
    public var hasDataGaps: Bool

    public var id: Date { firstOffSampleAt }
    public var isOngoing: Bool { endedAt == nil }

    public func duration(now: Date) -> TimeInterval {
        max(0, (endedAt ?? now).timeIntervalSince(startedAt))
    }

    public func interval(now: Date) -> DateInterval {
        DateInterval(start: startedAt, end: max(startedAt, endedAt ?? now))
    }
}

/// Detects outages as GRID ON → OFF → ON transitions in a sample series.
///
/// It is a pure function of the samples, so the whole history can be recomputed after a backfill
/// from the cloud (this is how outages missed while iOS kept the app suspended get recovered).
public struct OutageTracker: Sendable {
    /// Longer silence than this counts as a data gap.
    public var maxGap: TimeInterval
    /// Consecutive OFF samples needed to confirm an outage, per source.
    /// Local polling is frequent (10–30 s) so one OFF reading may be a glitch; cloud samples are ~5 min apart.
    public var requiredOffSamples: [SourceKind: Int]
    public var integrator: EnergyIntegrator

    public init(
        maxGap: TimeInterval = 15 * 60,
        requiredOffSamples: [SourceKind: Int] = [.cloud: 1, .local: 2]
    ) {
        self.maxGap = maxGap
        self.requiredOffSamples = requiredOffSamples
        self.integrator = EnergyIntegrator(maxGap: maxGap)
    }

    public func outages(from rawSamples: [TelemetrySample], now: Date) -> [Outage] {
        let samples = SampleSeries.normalize(rawSamples)
        let runs = confirmedRuns(samples.filter { $0.gridState != .unknown })

        var result: [Outage] = []
        for (index, run) in runs.enumerated() where run.state == .off {
            let previous = index > 0 ? runs[index - 1] : nil
            let next = index + 1 < runs.count ? runs[index + 1] : nil
            result.append(makeOutage(run: run, previous: previous, next: next, allSamples: samples, now: now))
        }
        return result
    }

    // MARK: - Runs

    struct Run {
        var state: GridState
        var samples: [TelemetrySample]
        var first: TelemetrySample { samples[0] }
        var last: TelemetrySample { samples[samples.count - 1] }
    }

    func confirmedRuns(_ known: [TelemetrySample]) -> [Run] {
        var runs: [Run] = []
        for sample in known {
            if runs.last?.state == sample.gridState {
                runs[runs.count - 1].samples.append(sample)
            } else {
                runs.append(Run(state: sample.gridState, samples: [sample]))
            }
        }

        // Short OFF blips: in the middle they are flicker (→ ON); at the end they are pending (dropped for now).
        var cleaned: [Run] = []
        for (index, run) in runs.enumerated() {
            var run = run
            if run.state == .off, run.samples.count < (requiredOffSamples[run.first.source] ?? 1) {
                let isLast = index == runs.count - 1
                if isLast && index > 0 { continue }
                run.state = .on
            }
            if cleaned.last?.state == run.state {
                cleaned[cleaned.count - 1].samples += run.samples
            } else {
                cleaned.append(run)
            }
        }
        return cleaned
    }

    // MARK: - Outage

    private func makeOutage(run: Run, previous: Run?, next: Run?, allSamples: [TelemetrySample], now: Date) -> Outage {
        let start: Date
        let startUncertainty: TimeInterval?
        if let previous {
            let gap = run.first.timestamp.timeIntervalSince(previous.last.timestamp)
            start = previous.last.timestamp.addingTimeInterval(gap / 2)
            startUncertainty = gap / 2
        } else {
            start = run.first.timestamp
            startUncertainty = nil
        }

        var end: Date?
        var endUncertainty: TimeInterval?
        if let next {
            let gap = next.first.timestamp.timeIntervalSince(run.last.timestamp)
            end = run.last.timestamp.addingTimeInterval(gap / 2)
            endUncertainty = gap / 2
        }

        // Gap check over the known samples bracketing the outage.
        var bracket = run.samples
        if let previous { bracket.insert(previous.last, at: 0) }
        if let next { bracket.append(next.first) }
        var hasGaps = zip(bracket, bracket.dropFirst()).contains {
            $1.timestamp.timeIntervalSince($0.timestamp) > maxGap
        }
        if end == nil, now.timeIntervalSince(run.last.timestamp) > maxGap { hasGaps = true }

        let interval = DateInterval(start: start, end: max(start, end ?? now))
        let stats = integrator.loadStats(allSamples, over: interval)

        return Outage(
            firstOffSampleAt: run.first.timestamp,
            startedAt: start,
            startUncertainty: startUncertainty,
            endedAt: end,
            endUncertainty: endUncertainty,
            startSOC: run.samples.first(where: { $0.batterySOC != nil })?.batterySOC ?? previous?.last.batterySOC,
            endSOC: run.samples.last(where: { $0.batterySOC != nil })?.batterySOC,
            energyKWh: stats.energyKWh,
            averagePowerW: stats.averagePowerW,
            maxPowerW: stats.maxPowerW,
            hasDataGaps: hasGaps
        )
    }
}
