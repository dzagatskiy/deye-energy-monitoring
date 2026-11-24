import Foundation

public struct OutagePeriodSummary: Sendable, Equatable {
    public var period: DateInterval
    /// Outages overlapping the period.
    public var count: Int
    /// Time without grid inside the period (outages are clipped to period bounds), s.
    public var totalDuration: TimeInterval
    /// Energy attributed to the period, split proportionally to the overlap, kWh.
    public var energyKWh: Double
    public var longestDuration: TimeInterval
}

/// Aggregates outages per calendar period. Calendar days are computed in the configured
/// time zone, so a 23h/25h DST day and a midnight-crossing outage are handled correctly.
public enum OutageStatistics {
    public static func calendar(in timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    public static func day(containing date: Date, timeZone: TimeZone) -> DateInterval {
        // `dateInterval(of:for:)` always succeeds for `.day` in the Gregorian calendar.
        calendar(in: timeZone).dateInterval(of: .day, for: date)!
    }

    public static func summary(of outages: [Outage], in period: DateInterval, now: Date) -> OutagePeriodSummary {
        var count = 0
        var total: TimeInterval = 0
        var energy = 0.0
        var longest: TimeInterval = 0

        for outage in outages {
            let full = outage.interval(now: now)
            guard let overlap = full.intersection(with: period), overlap.duration > 0 else { continue }
            count += 1
            total += overlap.duration
            longest = max(longest, overlap.duration)
            if full.duration > 0 {
                energy += outage.energyKWh * overlap.duration / full.duration
            }
        }
        return OutagePeriodSummary(
            period: period, count: count, totalDuration: total, energyKWh: energy, longestDuration: longest
        )
    }

    /// One summary per calendar day from the day containing `from` through the day containing `to`.
    public static func dailySummaries(
        of outages: [Outage], from: Date, to: Date, timeZone: TimeZone, now: Date
    ) -> [OutagePeriodSummary] {
        guard from <= to else { return [] }
        var result: [OutagePeriodSummary] = []
        var day = day(containing: from, timeZone: timeZone)
        while day.start <= to {
            result.append(summary(of: outages, in: day, now: now))
            day = self.day(containing: day.end, timeZone: timeZone)
        }
        return result
    }
}
