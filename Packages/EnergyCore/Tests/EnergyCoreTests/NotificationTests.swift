import Foundation
import Testing
@testable import EnergyCore

@Suite("NotificationEvaluator")
struct NotificationEvaluatorTests {
    let id = InverterID("DACHA")
    let evaluator = NotificationEvaluator()
    var profile: InverterProfile {
        InverterProfile(id: id, customName: "Дача", battery: BatteryConfiguration(capacityKWh: 16, minimumSOC: 20),
                        timeZoneIdentifier: "UTC")
    }

    /// Initialized state with nothing notified yet.
    var ready: NotificationState { var s = NotificationState(); s.initialized = true; return s }

    func snapshot(_ samples: [TelemetrySample], now: Date, profile: InverterProfile? = nil) -> (EnergySnapshot, [Outage]) {
        let p = profile ?? self.profile
        let snap = SnapshotBuilder().build(descriptorName: "Дача", profile: p, samples: samples, now: now)
        return (snap, OutageTracker().outages(from: samples, now: now))
    }

    func run(_ samples: [TelemetrySample], now: Date, state: NotificationState? = nil, profile: InverterProfile? = nil)
        -> (notifications: [EnergyNotification], state: NotificationState) {
        let (snap, outages) = snapshot(samples, now: now, profile: profile)
        return evaluator.evaluate(snapshot: snap, outages: outages, profile: profile ?? self.profile, state: state ?? ready, now: now)
    }

    // t0 = 08:00 UTC
    let before = series(from: 0, to: 30, step: 5, .on, soc: 95)
    let during = series(from: 35, to: 60, step: 5, .off, load: 1860, soc: 82, battery: -1860)
    let after = series(from: 65, to: 90, step: 5, .on, soc: 83)

    @Test("Grid lost → one 'немає світла' with time, SOC and autonomy; not repeated")
    func gridOff() throws {
        let first = run(before + during, now: at(minutes: 61))
        let n = try #require(first.notifications.first)
        #expect(first.notifications.count == 1)
        #expect(n.kind == .gridOff)
        #expect(n.title == "Дача: немає світла")
        #expect(n.body.hasPrefix("З 08:32 (≈29 хв тому). Батарея 82%. Орієнтовно залишилося"), "\(n.body)")
        #expect(run(before + during, now: at(minutes: 62), state: first.state).notifications.isEmpty)
    }

    @Test("Detected within 10 min → no 'тому' suffix")
    func gridOffOnTime() throws {
        let n = try #require(run(before + series(from: 35, to: 40, step: 5, .off, soc: 90), now: at(minutes: 41)).notifications.first)
        #expect(n.body.hasPrefix("З 08:32."))
    }

    @Test("Grid restored → 'світло є' with duration, range and energy")
    func gridOn() throws {
        let off = run(before + during, now: at(minutes: 61))
        let on = run(before + during + after, now: at(minutes: 66), state: off.state)
        let n = try #require(on.notifications.first)
        #expect(on.notifications.count == 1)
        #expect(n.kind == .gridOn)
        #expect(n.title == "Дача: світло є")
        #expect(n.body.hasPrefix("Не було 30 хв (08:32–09:02). Спожито"))
        #expect(n.id != off.notifications[0].id)
        #expect(run(before + during + after, now: at(minutes: 70), state: on.state).notifications.isEmpty)
    }

    @Test("Outage missed entirely while suspended → one summary instead of two alerts")
    func missedOutageSummary() throws {
        let r = run(before + during + after, now: at(minutes: 90))
        #expect(r.notifications.map(\.kind) == [.outageSummary])
        #expect(r.notifications[0].body.hasPrefix("08:32–09:02, 30 хв."))
    }

    @Test("Events older than maxEventAge are recorded silently")
    func oldEventsSilent() {
        let r = run(before + during + after, now: at(minutes: 90 + 4 * 60))
        #expect(r.notifications.isEmpty)
        #expect(r.state.notifiedOutageEnds.count == 1)
    }

    @Test("First run after install/login does not replay history")
    func firstRunNoSpam() {
        let r = run(before + during, now: at(minutes: 61), state: NotificationState())
        #expect(r.notifications.isEmpty)
        #expect(r.state.initialized)
        // But the end of that ongoing outage is still announced later.
        let later = run(before + during + after, now: at(minutes: 66), state: r.state)
        #expect(later.notifications.map(\.kind) == [.gridOn])
    }

    @Test("Low battery once, re-armed only after +5%")
    func lowBattery() throws {
        let base = before + series(from: 35, to: 55, step: 5, .off, soc: 40, battery: -1000)
        var state = run(base, now: at(minutes: 56)).state   // grid-off notified here
        let low = run(base + [sample(60, .off, soc: 29, battery: -1000)], now: at(minutes: 61), state: state)
        let n = try #require(low.notifications.first)
        #expect(low.notifications.map(\.kind) == [.lowBattery])
        #expect(n.title == "Дача: низький заряд")
        #expect(n.body.hasPrefix("Батарея 29%."))
        state = low.state
        // Flapping 29→31→29: no repeat (needs ≥ 35% to re-arm).
        state = run(base + [sample(65, .off, soc: 31, battery: -1000)], now: at(minutes: 66), state: state).state
        #expect(run(base + [sample(70, .off, soc: 29, battery: -1000)], now: at(minutes: 71), state: state).notifications.isEmpty)
        // Charged to 36% by PV, then low again → notifies again.
        state = run(base + [sample(75, .off, soc: 36, battery: 500)], now: at(minutes: 76), state: state).state
        #expect(run(base + [sample(80, .off, soc: 30, battery: -1000)], now: at(minutes: 81), state: state).notifications.map(\.kind) == [.lowBattery])
    }

    @Test("Reaching minimum SOC → critical (and no separate 'low' alert)")
    func critical() throws {
        let base = before + series(from: 35, to: 55, step: 5, .off, soc: 40, battery: -1000)
        let state = run(base, now: at(minutes: 56)).state
        let r = run(base + [sample(60, .off, soc: 19, battery: -1000)], now: at(minutes: 61), state: state)
        let n = try #require(r.notifications.first)
        #expect(r.notifications.map(\.kind) == [.criticalBattery])
        #expect(n.body == "Батарея 19%: досягнуто мінімуму 20%.")
        #expect(!r.state.lowBatteryArmed && !r.state.criticalBatteryArmed)
    }

    @Test("No battery alerts while the grid is on or data is stale")
    func batteryGuards() {
        let gridOn = series(from: 0, to: 30, step: 5, .on, soc: 15, battery: 800)
        #expect(run(gridOn, now: at(minutes: 31)).notifications.isEmpty)
        let base = before + series(from: 35, to: 55, step: 5, .off, soc: 15, battery: -1000)
        var state = ready
        state.notifiedOutageStarts.insert(at(minutes: 35))
        #expect(run(base, now: at(minutes: 55 + 45), state: state).notifications.isEmpty)
    }

    @Test("Each kind can be switched off")
    func toggles() {
        var p = profile
        p.notifications = NotificationSettings(gridOff: false, gridOn: false, lowBattery: false, criticalBattery: false)
        let off = run(before + during, now: at(minutes: 61), profile: p)
        #expect(off.notifications.isEmpty)
        #expect(off.state.notifiedOutageStarts.count == 1)   // still recorded, so enabling later won't replay it
        #expect(run(before + during + after, now: at(minutes: 66), state: off.state, profile: p).notifications.isEmpty)
    }

    @Test("Custom low threshold")
    func customThreshold() {
        var p = profile
        p.notifications = NotificationSettings(lowBatterySOC: 50)
        let base = before + series(from: 35, to: 55, step: 5, .off, soc: 60, battery: -1000)
        let state = run(base, now: at(minutes: 56), profile: p).state
        #expect(run(base + [sample(60, .off, soc: 49, battery: -1000)], now: at(minutes: 61), state: state, profile: p)
            .notifications.map(\.kind) == [.lowBattery])
    }

    @Test("Old notified ids are forgotten after 7 days")
    func pruning() {
        var state = ready
        state.notifiedOutageStarts = [at(minutes: -8 * 1440), at(minutes: -60)]
        let r = run(series(from: 0, to: 10, step: 5, .on), now: at(minutes: 11), state: state)
        #expect(r.state.notifiedOutageStarts == [at(minutes: -60)])
    }
}

@Suite("Notifications: integration and compatibility")
struct NotificationIntegrationTests {
    let id = InverterID("DACHA")

    @Test("Profiles saved by earlier builds (no 'notifications' key) still decode")
    func backwardCompatibleSettings() throws {
        let old = #"{"region":"eu","inverters":[],"refreshInterval":60,"profiles":[{"id":"SN1","battery":{"capacityKWh":16,"minimumSOC":20},"gridVoltageThreshold":170,"timeZoneIdentifier":"Europe/Kyiv"}]}"#
        let settings = try JSONDecoder().decode(AccountSettings.self, from: Data(old.utf8))
        #expect(settings.profiles.first?.notifications == nil)
        #expect(settings.profiles.first?.notificationSettings == .default)
    }

    @Test("RefreshService delivers each event once across refreshes and processes")
    func deliveredOnce() async throws {
        let dir = tempDir()
        let collected = Collected()
        let settings = AccountSettings(inverters: [InverterDescriptor(id: id, stationName: "Дача", isOnline: true)])
        let on = series(from: 0, to: 30, step: 5, .on, soc: 95)
        let off = series(from: 35, to: 60, step: 5, .off, soc: 80, battery: -900)

        // First run initializes silently.
        let s1 = ScriptedSource(latest: [.success(sample(30, .on, soc: 95))], history: on)
        await RefreshService(store: TelemetryStore(root: dir), notifier: { await collected.add($0) }) { _ in [s1] }
            .refresh([id], settings: settings, now: at(minutes: 31))
        #expect(await collected.all.isEmpty)

        // Grid goes off: app process notices.
        let s2 = ScriptedSource(latest: [.success(sample(60, .off, soc: 80, battery: -900))], history: on + off)
        await RefreshService(store: TelemetryStore(root: dir), historyInterval: 0, notifier: { await collected.add($0) }) { _ in [s2] }
            .refresh([id], settings: settings, now: at(minutes: 61))
        // Widget process a minute later: same event, no second notification.
        let s3 = ScriptedSource(latest: [.success(sample(60, .off, soc: 80, battery: -900))], history: on + off)
        await RefreshService(store: TelemetryStore(root: dir), historyInterval: 0, notifier: { await collected.add($0) }) { _ in [s3] }
            .refresh([id], settings: settings, now: at(minutes: 62))

        #expect(await collected.all.map(\.kind) == [.gridOff])
        #expect(await collected.all.first?.title == "Дача: немає світла")
    }
}

actor Collected {
    private(set) var all: [EnergyNotification] = []
    func add(_ items: [EnergyNotification]) { all += items }
}
