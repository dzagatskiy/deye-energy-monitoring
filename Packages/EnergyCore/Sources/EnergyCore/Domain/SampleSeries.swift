import Foundation

public enum SampleSeries {
    /// Sorts samples by time and drops duplicates (timestamps closer than `tolerance`).
    /// When a local and a cloud sample collide, the local one is kept: it is more precise and more recent.
    public static func normalize(_ samples: [TelemetrySample], tolerance: TimeInterval = 1) -> [TelemetrySample] {
        let sorted = samples.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return rank($0.source) < rank($1.source)
        }
        var result: [TelemetrySample] = []
        result.reserveCapacity(sorted.count)
        for sample in sorted {
            if let last = result.last, sample.timestamp.timeIntervalSince(last.timestamp) < tolerance {
                if rank(sample.source) < rank(last.source) { result[result.count - 1] = sample }
                continue
            }
            result.append(sample)
        }
        return result
    }

    private static func rank(_ kind: SourceKind) -> Int { kind == .local ? 0 : 1 }
}

/// Whether the latest data can be trusted as "current".
public enum DataFreshness: Sendable, Equatable {
    case fresh
    case stale(age: TimeInterval)
    case noData
}

public struct FreshnessPolicy: Sendable, Equatable {
    /// Cloud data arrives roughly every 5 min (unconfirmed), so 3 missed uploads mean stale.
    public var cloudMaxAge: TimeInterval
    public var localMaxAge: TimeInterval

    public init(cloudMaxAge: TimeInterval = 15 * 60, localMaxAge: TimeInterval = 2 * 60) {
        self.cloudMaxAge = cloudMaxAge
        self.localMaxAge = localMaxAge
    }

    public func evaluate(_ sample: TelemetrySample?, now: Date) -> DataFreshness {
        guard let sample else { return .noData }
        let age = now.timeIntervalSince(sample.timestamp)
        let limit = sample.source == .local ? localMaxAge : cloudMaxAge
        return age > limit ? .stale(age: age) : .fresh
    }
}
