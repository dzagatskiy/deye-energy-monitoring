import Foundation
import Testing
@testable import EnergyCore

@Suite("EnergyIntegrator")
struct EnergyIntegratorTests {
    let integrator = EnergyIntegrator(maxGap: 15 * 60)

    @Test("0.8 kW for 4 h is 3.2 kWh (power vs energy)")
    func constantPower() {
        let samples = series(from: 0, to: 240, step: 5, .off, load: 800)
        let stats = integrator.loadStats(samples, over: interval(0, 240))
        #expect(abs(stats.energyKWh - 3.2) < 1e-9)
        #expect(abs((stats.averagePowerW ?? 0) - 800) < 1e-9)
        #expect(stats.maxPowerW == 800)
        #expect(stats.isComplete)
    }

    @Test("Linear ramp uses the trapezoidal rule")
    func trapezoid() {
        let samples = [sample(0, load: 0), sample(60, load: 1000)]
        let stats = integrator.integrate(samples, over: interval(0, 60)) { $0.loadPower }
        // maxGap must allow a 60-min segment here.
        let wide = EnergyIntegrator(maxGap: 3600).integrate(samples, over: interval(0, 60)) { $0.loadPower }
        #expect(stats.coveredDuration == 0)
        #expect(abs(wide.energyWh - 500) < 1e-9)
    }

    @Test("Uneven sampling intervals are weighted by time")
    func unevenIntervals() {
        // 1 min at 2000 W, then 9 min at 500 W (step changes encoded as trapezoids between equal points).
        let samples = [
            sample(0, load: 2000), sample(1, load: 2000),
            sample(1.0001, load: 500), sample(10, load: 500),
        ]
        let stats = integrator.loadStats(samples, over: interval(0, 10))
        let expectedWh = 2000.0 / 60 + 500.0 * 9 / 60
        #expect(abs(stats.energyWh - expectedWh) < 0.1)
        // Time-weighted average, not the mean of the 4 samples (1250 W).
        #expect(abs((stats.averagePowerW ?? 0) - expectedWh * 6) < 1)
        #expect(stats.maxPowerW == 2000)
    }

    @Test("Gaps longer than maxGap are not integrated")
    func gapsExcluded() {
        let samples = series(from: 0, to: 30, step: 5, .on, load: 1200)
            + series(from: 90, to: 120, step: 5, .on, load: 1200)
        let stats = integrator.loadStats(samples, over: interval(0, 120))
        #expect(abs(stats.coveredDuration - 60 * 60) < 1e-6)
        #expect(abs(stats.energyKWh - 1.2) < 1e-9)
        #expect(!stats.isComplete)
        #expect(abs(stats.uncoveredDuration - 60 * 60) < 1e-6)
    }

    @Test("Interval boundaries between samples are interpolated")
    func clipping() {
        let samples = [sample(0, load: 0), sample(10, load: 1000)]
        let stats = integrator.loadStats(samples, over: interval(5, 10))
        // From 500 W to 1000 W over 5 min.
        #expect(abs(stats.energyWh - 750.0 * 5 / 60) < 1e-9)
        #expect(stats.sampleCount == 1)
    }

    @Test("Edges past the last sample hold the value only within maxGap")
    func trailingHold() {
        let samples = [sample(0, load: 600), sample(5, load: 600)]
        let near = integrator.loadStats(samples, over: interval(0, 15))
        #expect(abs(near.energyWh - 150) < 1e-9)
        let far = integrator.loadStats(samples, over: interval(0, 60))
        #expect(abs(far.energyWh - 50) < 1e-9)
    }

    @Test("No samples gives zero energy and no average")
    func empty() {
        let stats = integrator.loadStats([], over: interval(0, 60))
        #expect(stats.energyWh == 0)
        #expect(stats.averagePowerW == nil)
        #expect(stats.maxPowerW == nil)
    }

    @Test("Deviation from the inverter counter")
    func counterDeviation() {
        #expect(EnergyIntegrator.counterDeviation(integratedKWh: 11, counterKWh: 10) == 0.1)
        #expect(EnergyIntegrator.counterDeviation(integratedKWh: 11, counterKWh: nil) == nil)
        #expect(EnergyIntegrator.counterDeviation(integratedKWh: 11, counterKWh: 0) == nil)
    }
}
