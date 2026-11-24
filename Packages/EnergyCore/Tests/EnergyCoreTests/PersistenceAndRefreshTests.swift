import Foundation
import Testing
@testable import EnergyCore

func tempDir() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("energy-tests-\(UUID().uuidString)")
}

func tagged(_ samples: [TelemetrySample], _ id: InverterID) -> [TelemetrySample] {
    samples.map { var s = $0; s.inverterId = id; return s }
}

@Suite("TelemetryStore")
struct TelemetryStoreTests {
    let id = InverterID("INV1")

    @Test("Samples survive a restart (new store over the same directory)")
    func persistence() async throws {
        let dir = tempDir()
        let samples = tagged(series(from: 0, to: 60, step: 5, .on) + series(from: 65, to: 120, step: 5, .off), id)
        try await TelemetryStore(root: dir).append(samples)

        let reopened = TelemetryStore(root: dir)
        let restored = await reopened.samples(id, in: interval(0, 120))
        #expect(restored == samples)
        let outages = OutageTracker().outages(from: restored, now: at(minutes: 120))
        #expect(outages.count == 1 && outages[0].isOngoing)
    }

    @Test("Duplicates are merged across writes; local sample wins")
    func dedup() async throws {
        let store = TelemetryStore(root: tempDir())
        let cloud = tagged(series(from: 0, to: 30, step: 5, .on), id)
        try await store.append(cloud)
        try await store.append(cloud)
        try await store.append(tagged([sample(10, .on, load: 1500, source: .local)], id))
        let stored = await store.samples(id, in: interval(0, 30))
        #expect(stored.count == 7)
        #expect(stored.first { $0.timestamp == at(minutes: 10) }?.source == .local)
    }

    @Test("Ranges spanning UTC midnight read both day files; inverters are isolated")
    func dayFiles() async throws {
        let store = TelemetryStore(root: tempDir())
        // t0 is 08:00 UTC; minutes 900…1020 cross 00:00 UTC.
        try await store.append(tagged(series(from: 900, to: 1020, step: 10, .on), id))
        try await store.append(tagged(series(from: 900, to: 1020, step: 10, .off), InverterID("INV2")))
        let stored = await store.samples(id, in: interval(900, 1020))
        #expect(stored.count == 13)
        #expect(stored.allSatisfy { $0.gridState == .on })
        #expect(await store.latest(id, now: at(minutes: 1030))?.timestamp == at(minutes: 1020))
    }

    @Test("Retention removes old day files")
    func prune() async throws {
        let store = TelemetryStore(root: tempDir())
        try await store.append(tagged([sample(0)], id))
        try await store.prune(olderThan: 90, now: at(minutes: 91 * 1440))
        #expect(await store.samples(id, in: interval(-10, 10)).isEmpty)
    }
}

/// Mock source that returns scripted latest/history values.
actor ScriptedSource: InverterDataSource {
    nonisolated let kind: SourceKind = .cloud
    var latestResults: [Result<TelemetrySample, DataSourceError>]
    var history: [TelemetrySample]
    private(set) var historyCalls: [DateInterval] = []
    private(set) var latestCalls = 0

    init(latest: [Result<TelemetrySample, DataSourceError>], history: [TelemetrySample] = []) {
        self.latestResults = latest
        self.history = history
    }

    func fetchLatest() async throws -> TelemetrySample {
        latestCalls += 1
        return try (latestResults.isEmpty ? .failure(.emptyResponse) : latestResults.removeFirst()).get()
    }

    func fetchHistory(_ range: DateInterval) async throws -> [TelemetrySample] {
        historyCalls.append(range)
        return history.filter { range.contains($0.timestamp) }
    }
}

@Suite("RefreshService")
struct RefreshServiceTests {
    let id = InverterID("DACHA")
    var settings: AccountSettings {
        AccountSettings(inverters: [InverterDescriptor(id: id, stationName: "Дача", isOnline: true)],
                        profiles: [InverterProfile(id: id, battery: BatteryConfiguration(capacityKWh: 16, minimumSOC: 20))])
    }

    @Test("History backfill recovers an outage the phone never saw live")
    func backfillRecoversOutage() async throws {
        let now = at(minutes: 180)
        // The app only sees the current sample (grid back on), but history contains the outage.
        let history = series(from: 0, to: 60, step: 5, .on, soc: 95)
            + series(from: 65, to: 120, step: 5, .off, load: 900, soc: 80, battery: -900)
            + series(from: 125, to: 175, step: 5, .on, soc: 85)
        let source = ScriptedSource(latest: [.success(sample(180, .on, soc: 86))], history: history)
        let service = RefreshService(store: TelemetryStore(root: tempDir())) { _ in [source] }

        let snapshot = try #require(await service.refresh([id], settings: settings, now: now)[id])
        #expect(snapshot.gridState == .on)
        #expect(snapshot.currentOutage == nil)
        #expect(snapshot.lastOutage?.startedAt == at(minutes: 62.5))
        #expect(snapshot.lastOutage?.endedAt == at(minutes: 122.5))
        #expect(snapshot.todayOutageCount == 1)
        #expect(abs(snapshot.todayOutageDuration - 3600) < 1e-6)
        #expect(snapshot.name == "Дача")
        #expect(snapshot.lastError == nil)
        #expect(await source.historyCalls.count == 1)
    }

    @Test("History is not re-fetched within the interval; latest still is")
    func historyThrottle() async throws {
        let source = ScriptedSource(latest: [.success(sample(0)), .success(sample(6))])
        let service = RefreshService(store: TelemetryStore(root: tempDir())) { _ in [source] }
        await service.refresh([id], settings: settings, now: at(minutes: 0))
        // 6 min later the next Deye frame is due (~5.8 min), so latest is fetched; history is not (30 min).
        let s = await service.refresh([id], settings: settings, now: at(minutes: 6))
        #expect(await source.historyCalls.count == 1)
        #expect(await source.latestCalls == 2)
        #expect(s[id]?.measuredAt == at(minutes: 6))
    }

    @Test("Ongoing outage drives the live timer and autonomy")
    func ongoing() async throws {
        let history = series(from: 0, to: 30, step: 5, .on) + series(from: 35, to: 90, step: 5, .off, load: 1860, soc: 82, battery: -1860)
        let source = ScriptedSource(latest: [.success(sample(95, .off, load: 1860, soc: 82, battery: -1860))], history: history)
        let service = RefreshService(store: TelemetryStore(root: tempDir())) { _ in [source] }
        let snapshot = try #require(await service.refresh([id], settings: settings, now: at(minutes: 95))[id])
        #expect(snapshot.gridState == .off)
        #expect(snapshot.currentOutage?.startedAt == at(minutes: 32.5))
        #expect(snapshot.autonomy == .estimate(9920.0 / 1860 * 3600))
    }

    @Test("API failure keeps the last data, marks it stale and reports the error")
    func failureKeepsData() async throws {
        let store = TelemetryStore(root: tempDir())
        let source = ScriptedSource(latest: [.success(sample(0, .on, soc: 90)), .failure(.network("timeout"))])
        let service = RefreshService(store: store) { _ in [source] }
        await service.refresh([id], settings: settings, now: at(minutes: 0))
        let snapshot = try #require(await service.refresh([id], settings: settings, now: at(minutes: 40), includeHistory: false)[id])
        #expect(snapshot.batterySOC == 90)
        #expect(snapshot.isStale)
        #expect(snapshot.lastError == "Немає зв'язку: timeout")
        // Persisted snapshot is readable by the widget process.
        #expect(await store.load(EnergySnapshot.self, from: RefreshService.snapshotFileName(id)) == snapshot)
    }

    @Test("Settings resolve the widget's inverter choice and keep profiles on rediscovery")
    func settingsResolution() {
        var s = AccountSettings()
        let a = InverterDescriptor(id: InverterID("A"), isOnline: true)
        let b = InverterDescriptor(id: InverterID("B"))
        s.updateInverters([a, b], suggestedBattery: [InverterID("A"): .fromAmpHours(300)])
        #expect(s.resolve(nil) == a.id)
        #expect(s.resolve(b.id) == b.id)
        #expect(s.resolve(InverterID("gone")) == a.id)
        s.selectedInverter = b.id
        #expect(s.resolve(nil) == b.id)
        s.profiles[0].customName = "Дача"
        s.updateInverters([a, b])
        #expect(s.profile(for: a.id).customName == "Дача")
        #expect(abs(s.profile(for: a.id).battery.capacityKWh - 15.36) < 1e-9)
    }
}
