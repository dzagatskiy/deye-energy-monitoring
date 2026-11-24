import Foundation
@testable import EnergyCore

/// 2026-11-23 08:00:00 UTC (10:00 Europe/Kyiv).
let t0 = Date(timeIntervalSince1970: 1_795_420_800)

func at(minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

func sample(
    _ minutes: Double,
    _ grid: GridState = .on,
    load: Double? = 1000,
    soc: Double? = nil,
    battery: Double? = nil,
    source: SourceKind = .cloud
) -> TelemetrySample {
    TelemetrySample(
        timestamp: at(minutes: minutes),
        source: source,
        gridState: grid,
        batterySOC: soc,
        batteryPower: battery,
        loadPower: load
    )
}

/// Evenly spaced samples every `step` minutes in [from, to].
func series(
    from: Double, to: Double, step: Double, _ grid: GridState,
    load: Double = 1000, soc: Double? = nil, battery: Double? = nil, source: SourceKind = .cloud
) -> [TelemetrySample] {
    stride(from: from, through: to, by: step).map {
        sample($0, grid, load: load, soc: soc, battery: battery, source: source)
    }
}

func interval(_ fromMinutes: Double, _ toMinutes: Double) -> DateInterval {
    DateInterval(start: at(minutes: fromMinutes), end: at(minutes: toMinutes))
}

struct MockSource: InverterDataSource {
    var kind: SourceKind
    var latest: Result<TelemetrySample, DataSourceError>
    var history: Result<[TelemetrySample], DataSourceError> = .failure(.historyNotSupported)

    func fetchLatest() async throws -> TelemetrySample { try latest.get() }
    func fetchHistory(_ range: DateInterval) async throws -> [TelemetrySample] { try history.get() }
}
