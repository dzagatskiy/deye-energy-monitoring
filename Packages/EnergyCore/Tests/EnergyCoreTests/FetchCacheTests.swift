import Foundation
import Testing
@testable import EnergyCore

@Suite("Fetch cache")
struct FetchCacheTests {
    let id = InverterID("DACHA")
    let settings = AccountSettings(inverters: [InverterDescriptor(id: InverterID("DACHA"), isOnline: true)])
    let policy = FetchCachePolicy.default

    @Test("Policy: within 1 min never refetch; before the next Deye frame reuse; after it fetch")
    func policyRules() {
        let measured = sample(0)                 // Deye frame at t0
        let fetched = at(minutes: 1)             // we got it 1 min later
        #expect(policy.shouldFetchLatest(lastFetchAt: nil, latest: nil, now: t0))
        #expect(!policy.shouldFetchLatest(lastFetchAt: fetched, latest: measured, now: at(minutes: 1.5)))
        // 2.5 min since frame, 1.5 min since fetch: next frame expected at ~5.8 min → reuse.
        #expect(!policy.shouldFetchLatest(lastFetchAt: fetched, latest: measured, now: at(minutes: 2.5)))
        // Next frame due → fetch.
        #expect(policy.shouldFetchLatest(lastFetchAt: fetched, latest: measured, now: at(minutes: 5.9)))
        // Frame already old when fetched (logger silent): only the 1-min floor applies.
        #expect(policy.shouldFetchLatest(lastFetchAt: at(minutes: 20), latest: measured, now: at(minutes: 21.5)))
        // Local samples are not tied to Deye's upload cadence.
        #expect(policy.shouldFetchLatest(lastFetchAt: fetched, latest: sample(0, source: .local), now: at(minutes: 2.5)))
        // Bypass (pull-to-refresh) always fetches.
        #expect(FetchCachePolicy.bypass.shouldFetchLatest(lastFetchAt: fetched, latest: measured, now: at(minutes: 1.01)))
        // Clock went backwards (time zone / manual change): don't trust the cache.
        #expect(policy.shouldFetchLatest(lastFetchAt: at(minutes: 10), latest: measured, now: at(minutes: 5)))
    }

    @Test("Second process (widget after app) reuses the shared cache instead of calling Deye")
    func sharedBetweenProcesses() async throws {
        let dir = tempDir()
        let appSource = ScriptedSource(latest: [.success(sample(0, .on, soc: 90))])
        let app = RefreshService(store: TelemetryStore(root: dir)) { _ in [appSource] }
        await app.refresh([id], settings: settings, now: at(minutes: 1))

        let widgetSource = ScriptedSource(latest: [.success(sample(0, .on, soc: 90))])
        let widget = RefreshService(store: TelemetryStore(root: dir), maxBackfillDays: 1) { _ in [widgetSource] }
        let snapshot = try #require(await widget.refresh([id], settings: settings, now: at(minutes: 2))[id])

        #expect(await widgetSource.latestCalls == 0)
        #expect(snapshot.batterySOC == 90)
        #expect(snapshot.checkedAt == at(minutes: 1))
        #expect(snapshot.measuredAt == t0)
    }

    @Test("Polling every minute costs one request per Deye frame, not one per poll")
    func requestsPerFrame() async {
        let source = FrameSource(step: 5.7)
        let service = RefreshService(store: TelemetryStore(root: tempDir())) { _ in [source] }
        for minute in stride(from: 0.5, through: 30, by: 1) {
            await source.setNow(minute)
            await service.refresh([id], settings: settings, now: at(minutes: minute), includeHistory: false)
        }
        // 30 polls; Deye produces 6 frames in 30 min (0, 5.7, …, 28.5).
        let calls = await source.latestCalls
        #expect(calls >= 6 && calls <= 8, "calls = \(calls)")
        // Every frame was still picked up.
        #expect(await source.framesServed == 6)
    }

    @Test("Pull-to-refresh bypasses the cache")
    func bypass() async {
        let source = ScriptedSource(latest: [.success(sample(0)), .success(sample(0.5))])
        let service = RefreshService(store: TelemetryStore(root: tempDir())) { _ in [source] }
        await service.refresh([id], settings: settings, now: at(minutes: 0.2), includeHistory: false)
        await service.refresh([id], settings: settings, now: at(minutes: 0.6), includeHistory: false, cache: .bypass)
        #expect(await source.latestCalls == 2)
    }

    @Test("A cache hit keeps the last known error instead of clearing it")
    func keepsError() async throws {
        let store = TelemetryStore(root: tempDir())
        try await store.save(SyncState(lastSuccessAt: at(minutes: 1), lastError: "Немає зв'язку: timeout"), as: SyncState.fileName(id))
        try await store.append(tagged([sample(0)], id))
        let source = ScriptedSource(latest: [])
        let service = RefreshService(store: store) { _ in [source] }
        let snapshot = await service.refresh([id], settings: settings, now: at(minutes: 1.5), includeHistory: false)[id]
        #expect(await source.latestCalls == 0)
        #expect(snapshot?.lastError == "Немає зв'язку: timeout")
    }
}

/// Behaves like Deye Cloud: the latest frame is the last one produced before "now" (one every `step` min).
actor FrameSource: InverterDataSource {
    nonisolated let kind: SourceKind = .cloud
    let step: Double
    private var nowMinutes: Double = 0
    private(set) var latestCalls = 0
    private var served = Set<Double>()
    var framesServed: Int { served.count }

    init(step: Double) { self.step = step }
    func setNow(_ minutes: Double) { nowMinutes = minutes }

    func fetchLatest() async throws -> TelemetrySample {
        latestCalls += 1
        let frame = (nowMinutes / step).rounded(.down) * step
        served.insert(frame)
        return sample(frame, .on)
    }

    func fetchHistory(_ range: DateInterval) async throws -> [TelemetrySample] { [] }
}
