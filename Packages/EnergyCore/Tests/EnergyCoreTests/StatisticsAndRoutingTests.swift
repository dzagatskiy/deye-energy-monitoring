import Foundation
import Testing
@testable import EnergyCore

@Suite("OutageStatistics")
struct OutageStatisticsTests {
    let kyiv = TimeZone(identifier: "Europe/Kyiv")!

    func outage(start: Date, end: Date?, energy: Double = 0) -> Outage {
        Outage(
            firstOffSampleAt: start, startedAt: start, startUncertainty: 0, endedAt: end, endUncertainty: 0,
            startSOC: nil, endSOC: nil, energyKWh: energy, averagePowerW: nil, maxPowerW: nil, hasDataGaps: false
        )
    }

    func kyivDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        OutageStatistics.calendar(in: kyiv).date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    @Test("An outage crossing midnight is split between days, energy proportionally")
    func midnightSplit() {
        // 22:00 → 02:00 Kyiv time, 4 kWh.
        let o = outage(start: kyivDate(2026, 11, 22, 22), end: kyivDate(2026, 11, 23, 2), energy: 4)
        let days = OutageStatistics.dailySummaries(
            of: [o], from: kyivDate(2026, 11, 22, 12), to: kyivDate(2026, 11, 23, 12), timeZone: kyiv, now: kyivDate(2026, 11, 23, 12)
        )
        #expect(days.count == 2)
        #expect(days[0].totalDuration == 2 * 3600)
        #expect(days[1].totalDuration == 2 * 3600)
        #expect(abs(days[0].energyKWh - 2) < 1e-9)
        #expect(days[0].count == 1 && days[1].count == 1)
    }

    @Test("DST end day (2026-10-25) in Kyiv is 25 hours long")
    func dstDay() {
        let day = OutageStatistics.day(containing: kyivDate(2026, 10, 25, 12), timeZone: kyiv)
        #expect(day.duration == 25 * 3600)
        // Whole-day outage counts all 25 hours.
        let o = outage(start: day.start, end: day.end)
        #expect(OutageStatistics.summary(of: [o], in: day, now: day.end).totalDuration == 25 * 3600)
    }

    @Test("Changing the display time zone moves the day boundary, not the outages")
    func timeZoneChange() {
        // 23:30 → 00:30 UTC. In UTC it straddles midnight; in Kyiv (UTC+2) it is 01:30–02:30, one day.
        let utc = TimeZone(identifier: "UTC")!
        let start = Date(timeIntervalSince1970: 1_795_390_200) // 2026-11-22 23:30 UTC
        let o = outage(start: start, end: start.addingTimeInterval(3600))
        let inUTC = OutageStatistics.dailySummaries(of: [o], from: start, to: start.addingTimeInterval(3600), timeZone: utc, now: start)
        let inKyiv = OutageStatistics.dailySummaries(of: [o], from: start, to: start.addingTimeInterval(3600), timeZone: kyiv, now: start)
        #expect(inUTC.map(\.totalDuration) == [1800, 1800])
        #expect(inKyiv.map(\.totalDuration) == [3600])
    }

    @Test("Ongoing outage counts up to now")
    func ongoing() {
        let start = kyivDate(2026, 11, 23, 13)
        let now = kyivDate(2026, 11, 23, 16, 42)
        let day = OutageStatistics.day(containing: now, timeZone: kyiv)
        let summary = OutageStatistics.summary(of: [outage(start: start, end: nil)], in: day, now: now)
        #expect(summary.totalDuration == 3 * 3600 + 42 * 60)
        #expect(EnergyFormat.clock(summary.totalDuration) == "03:42")
    }
}

@Suite("SourceRouter")
struct SourceRouterTests {
    @Test("Local source is preferred when it works")
    func prefersLocal() async throws {
        let router = SourceRouter(sources: [
            MockSource(kind: .local, latest: .success(sample(0, source: .local))),
            MockSource(kind: .cloud, latest: .success(sample(0))),
        ])
        let result = try await router.fetchLatest()
        #expect(result.sample.source == .local)
        #expect(result.failures.isEmpty)
    }

    @Test("Falls back to cloud when the logger is unreachable")
    func fallback() async throws {
        let router = SourceRouter(sources: [
            MockSource(kind: .local, latest: .failure(.unavailable)),
            MockSource(kind: .cloud, latest: .success(sample(0))),
        ])
        let result = try await router.fetchLatest()
        #expect(result.sample.source == .cloud)
        #expect(result.failures == [SourceFailure(source: .local, error: .unavailable)])
    }

    @Test("Missing/empty API responses from all sources surface as an error")
    func allFail() async {
        let router = SourceRouter(sources: [
            MockSource(kind: .local, latest: .failure(.unavailable)),
            MockSource(kind: .cloud, latest: .failure(.emptyResponse)),
        ])
        await #expect(throws: SourceRouterError.allSourcesFailed([
            SourceFailure(source: .local, error: .unavailable),
            SourceFailure(source: .cloud, error: .emptyResponse),
        ])) {
            try await router.fetchLatest()
        }
        await #expect(throws: SourceRouterError.noSourcesConfigured) {
            try await SourceRouter(sources: []).fetchLatest()
        }
    }

    @Test("History comes from the first source that supports it")
    func history() async throws {
        let router = SourceRouter(sources: [
            MockSource(kind: .local, latest: .failure(.unavailable)),
            MockSource(kind: .cloud, latest: .failure(.unavailable), history: .success([sample(0), sample(5)])),
        ])
        #expect(try await router.fetchHistory(interval(0, 5)).count == 2)
    }
}

@Suite("Freshness and formatting")
struct FreshnessFormatTests {
    @Test func freshness() {
        let policy = FreshnessPolicy()
        #expect(policy.evaluate(nil, now: t0) == .noData)
        #expect(policy.evaluate(sample(0), now: at(minutes: 10)) == .fresh)
        #expect(policy.evaluate(sample(0), now: at(minutes: 20)) == .stale(age: 1200))
        #expect(policy.evaluate(sample(0, source: .local), now: at(minutes: 3)) == .stale(age: 180))
    }

    @Test func formats() {
        #expect(EnergyFormat.power(1250) == "1.25 kW")
        #expect(EnergyFormat.power(850) == "850 W")
        #expect(EnergyFormat.power(nil) == "—")
        #expect(EnergyFormat.energy(4.654) == "4.65 kWh")
        #expect(EnergyFormat.percent(82) == "82%")
        #expect(EnergyFormat.clock(27 * 3600 + 5 * 60) == "27:05")
        #expect(EnergyFormat.hoursMinutes(45 * 60) == "45 хв")
        #expect(EnergyFormat.hoursMinutes(3 * 3600) == "3 год")
    }

    @Test func batteryFlow() {
        #expect(BatteryFlow(batteryPower: 500) == .charging)
        #expect(BatteryFlow(batteryPower: -500) == .discharging)
        #expect(BatteryFlow(batteryPower: 10) == .idle)
        #expect(BatteryFlow(batteryPower: nil) == .idle)
    }
}
