import Foundation
import Testing
@testable import EnergyCore

@Suite("OutageTracker")
struct OutageTrackerTests {
    let tracker = OutageTracker()

    @Test("ON → OFF starts an ongoing outage at the midpoint")
    func detectsStart() throws {
        let samples = series(from: 0, to: 60, step: 5, .on) + series(from: 65, to: 90, step: 5, .off, soc: 80)
        let outages = tracker.outages(from: samples, now: at(minutes: 92))
        let outage = try #require(outages.first)
        #expect(outages.count == 1)
        #expect(outage.startedAt == at(minutes: 62.5))
        #expect(outage.startUncertainty == 150)
        #expect(outage.isOngoing)
        #expect(outage.duration(now: at(minutes: 92)) == 29.5 * 60)
    }

    @Test("OFF → ON ends the outage and records duration")
    func detectsEnd() throws {
        let samples = series(from: 0, to: 60, step: 5, .on)
            + series(from: 65, to: 300, step: 5, .off)
            + series(from: 305, to: 360, step: 5, .on)
        let outage = try #require(tracker.outages(from: samples, now: at(minutes: 400)).first)
        #expect(outage.endedAt == at(minutes: 302.5))
        #expect(outage.endUncertainty == 150)
        #expect(outage.duration(now: at(minutes: 400)) == 240 * 60)
        #expect(!outage.isOngoing)
        #expect(!outage.hasDataGaps)
    }

    @Test("Energy, average and max load during the outage")
    func outageEnergy() throws {
        var off = series(from: 65, to: 300, step: 5, .off, load: 800)
        off[10].loadPower = 3000
        let samples = series(from: 0, to: 60, step: 5, .on, load: 800) + off
            + series(from: 305, to: 360, step: 5, .on, load: 800)
        let outage = try #require(tracker.outages(from: samples, now: at(minutes: 400)).first)
        // 0.8 kW × 4 h = 3.2 kWh plus one 3 kW spike (triangle of 10 min, +2200 W peak).
        let spikeKWh = 2200.0 * (10.0 / 60) / 2 / 1000
        #expect(abs(outage.energyKWh - (3.2 + spikeKWh)) < 1e-9)
        #expect(outage.maxPowerW == 3000)
        #expect(abs((outage.averagePowerW ?? 0) - (3.2 + spikeKWh) * 1000 / 4) < 1e-6)
    }

    @Test("Start and end SOC come from the outage samples")
    func socBounds() throws {
        var off = series(from: 65, to: 120, step: 5, .off)
        for i in off.indices { off[i].batterySOC = 90 - Double(i) }
        let samples = series(from: 0, to: 60, step: 5, .on, soc: 95) + off + [sample(125, .on, soc: 79)]
        let outage = try #require(tracker.outages(from: samples, now: at(minutes: 130)).first)
        #expect(outage.startSOC == 90)
        #expect(outage.endSOC == 79)
    }

    @Test("Single local OFF reading is treated as flicker")
    func localFlicker() {
        let samples = series(from: 0, to: 5, step: 0.25, .on, source: .local)
            + [sample(5.25, .off, source: .local)]
            + series(from: 5.5, to: 10, step: 0.25, .on, source: .local)
        #expect(tracker.outages(from: samples, now: at(minutes: 10)).isEmpty)
    }

    @Test("Two consecutive local OFF readings confirm an outage")
    func localConfirmed() {
        let samples = series(from: 0, to: 5, step: 0.25, .on, source: .local)
            + series(from: 5.25, to: 5.5, step: 0.25, .off, source: .local)
        #expect(tracker.outages(from: samples, now: at(minutes: 6)).count == 1)
    }

    @Test("A pending (unconfirmed) local OFF at the end is not reported yet")
    func pendingOff() {
        let samples = series(from: 0, to: 5, step: 0.25, .on, source: .local) + [sample(5.25, .off, source: .local)]
        #expect(tracker.outages(from: samples, now: at(minutes: 5.3)).isEmpty)
    }

    @Test("A single cloud OFF sample is enough (samples are ~5 min apart)")
    func cloudSingle() {
        let samples = [sample(0, .on), sample(5, .off), sample(10, .on)]
        let outages = tracker.outages(from: samples, now: at(minutes: 10))
        #expect(outages.count == 1)
        #expect(abs((outages.first?.duration(now: at(minutes: 10)) ?? 0) - 5 * 60) < 1e-6)
    }

    @Test("Several outages in one day")
    func multiple() {
        let samples = series(from: 0, to: 30, step: 5, .on)
            + series(from: 35, to: 60, step: 5, .off)
            + series(from: 65, to: 120, step: 5, .on)
            + series(from: 125, to: 200, step: 5, .off)
            + series(from: 205, to: 240, step: 5, .on)
        #expect(tracker.outages(from: samples, now: at(minutes: 240)).count == 2)
    }

    @Test("Missing measurements inside an outage are flagged, the outage is not split")
    func gapInsideOutage() throws {
        let samples = series(from: 0, to: 30, step: 5, .on)
            + series(from: 35, to: 60, step: 5, .off)
            + series(from: 120, to: 150, step: 5, .off)
            + series(from: 155, to: 170, step: 5, .on)
        let outages = tracker.outages(from: samples, now: at(minutes: 170))
        let outage = try #require(outages.first)
        #expect(outages.count == 1)
        #expect(outage.hasDataGaps)
        #expect(outage.duration(now: at(minutes: 170)) == 120 * 60)
    }

    @Test("Unknown grid state samples do not open or close outages")
    func unknownIgnored() {
        let samples = [sample(0, .on), sample(5, .unknown), sample(10, .on)]
        #expect(tracker.outages(from: samples, now: at(minutes: 10)).isEmpty)
    }

    @Test("Ongoing outage with stale data is flagged")
    func staleOngoing() throws {
        let samples = [sample(0, .on), sample(5, .off)]
        let outage = try #require(tracker.outages(from: samples, now: at(minutes: 120)).first)
        #expect(outage.isOngoing)
        #expect(outage.hasDataGaps)
    }

    @Test("Data starting mid-outage has an unknown start precision")
    func startsMidOutage() throws {
        let outage = try #require(tracker.outages(from: [sample(0, .off), sample(5, .off)], now: at(minutes: 6)).first)
        #expect(outage.startUncertainty == nil)
        #expect(outage.startedAt == t0)
    }

    @Test("Duplicate local + cloud samples do not break detection; local wins")
    func duplicates() {
        let cloud = series(from: 0, to: 30, step: 5, .on)
        let local = [sample(10, .on, load: 1500, source: .local)]
        let normalized = SampleSeries.normalize(cloud + local + cloud)
        #expect(normalized.count == 7)
        #expect(normalized[2].source == .local)
        #expect(normalized[2].loadPower == 1500)
    }

    @Test("Recomputation after restart from persisted samples gives the same outages")
    func restoresFromHistory() {
        let samples = series(from: 0, to: 60, step: 5, .on)
            + series(from: 65, to: 120, step: 5, .off)
            + series(from: 125, to: 150, step: 5, .on)
        let now = at(minutes: 150)
        let before = tracker.outages(from: samples, now: now)
        // Simulate a restart: samples come back from storage via JSON in random order.
        let data = try! JSONEncoder().encode(samples.shuffled())
        let restored = try! JSONDecoder().decode([TelemetrySample].self, from: data)
        #expect(tracker.outages(from: restored, now: now) == before)
    }
}

@Suite("GridStateDetector")
struct GridStateDetectorTests {
    let detector = GridStateDetector(voltageThreshold: 170)

    @Test func explicitWins() {
        #expect(detector.detect(explicit: .off, gridVoltage: 230) == .off)
    }

    @Test func voltageThreshold() {
        #expect(detector.detect(gridVoltage: 229.8) == .on)
        #expect(detector.detect(gridVoltage: 0) == .off)
        #expect(detector.detect(gridVoltage: 169.9) == .off)
        #expect(detector.detect(explicit: .unknown, gridVoltage: 230) == .on)
    }

    @Test func missingData() {
        #expect(detector.detect(gridVoltage: nil) == .unknown)
    }
}
