import Foundation
import Testing
@testable import EnergyCore

@Suite("AutonomyEstimator")
struct AutonomyEstimatorTests {
    let estimator = AutonomyEstimator(battery: BatteryConfiguration(capacityKWh: 16, minimumSOC: 20))

    @Test("16 kWh at 82% down to 20% with a steady 1.86 kW drain ≈ 5 h 20 min")
    func steadyLoad() throws {
        let history = series(from: 0, to: 60, step: 5, .off, load: 1860, soc: 82, battery: -1860)
        let result = estimator.estimate(latest: history.last, history: history, now: at(minutes: 60))
        guard case .estimate(let seconds) = result else { Issue.record("got \(result)"); return }
        // 16 × 0.62 = 9.92 kWh / 1.86 kW = 5.333 h
        #expect(abs(seconds - 9920.0 / 1860 * 3600) < 1)
        #expect(EnergyFormat.autonomy(result) == "Орієнтовно залишилося 5 год 20 хв")
    }

    @Test("Battery drain, not house load, drives the estimate (PV covers part of the load)")
    func usesBatteryDrain() throws {
        let history = series(from: 0, to: 60, step: 5, .off, load: 2000, soc: 60, battery: -1000)
        let result = estimator.estimate(latest: history.last, history: history, now: at(minutes: 60))
        // 16 × 0.4 = 6.4 kWh / 1 kW
        let expected: TimeInterval = 6.4 * 3600
        #expect(result == .estimate(expected))
    }

    @Test("Only the 15-min window is required")
    func shortHistory() {
        let history = series(from: 45, to: 60, step: 5, .off, soc: 50, battery: -800)
        let result = estimator.estimate(latest: history.last, history: history, now: at(minutes: 60))
        // 16 kWh × 30% = 4.8 kWh / 0.8 kW = 6 h
        let expected: TimeInterval = 6 * 3600
        #expect(result == .estimate(expected))
    }

    @Test("Not enough data in the last 15 minutes")
    func insufficient() {
        let history = [sample(55, .off, soc: 80, battery: -900), sample(60, .off, soc: 80, battery: -900)]
        let late = estimator.estimate(latest: history.last, history: history, now: at(minutes: 80))
        #expect(late == .insufficientData)
        #expect(estimator.estimate(latest: nil, history: [], now: t0) == .insufficientData)
        let noSOC = sample(60, .off, soc: nil)
        #expect(estimator.estimate(latest: noSOC, history: [noSOC], now: at(minutes: 60)) == .insufficientData)
    }

    @Test("Unstable load gives a range instead of a single number")
    func unstable() {
        let history = series(from: 0, to: 44, step: 2, .off, soc: 70, battery: -300)
            + series(from: 46, to: 60, step: 2, .off, soc: 70, battery: -3000)
        let result = estimator.estimate(latest: history.last, history: history, now: at(minutes: 60))
        guard case .unstable(let lo, let hi) = result else { Issue.record("got \(result)"); return }
        #expect(lo < hi)
        #expect(EnergyFormat.autonomy(result).hasPrefix("Навантаження нестабільне"))
    }

    @Test("Grid on, charging, below minimum, negligible load")
    func specialStates() {
        let on = sample(60, .on, soc: 90, battery: 500)
        #expect(estimator.estimate(latest: on, history: [on], now: at(minutes: 60)) == .gridAvailable)

        let charging = sample(60, .off, soc: 50, battery: 400)
        #expect(estimator.estimate(latest: charging, history: [charging], now: at(minutes: 60)) == .charging)

        let low = sample(60, .off, soc: 19, battery: -500)
        #expect(estimator.estimate(latest: low, history: [low], now: at(minutes: 60)) == .belowMinimum)

        let idle = series(from: 0, to: 60, step: 5, .off, soc: 90, battery: -10)
        #expect(estimator.estimate(latest: idle.last, history: idle, now: at(minutes: 60)) == .negligibleLoad)
    }

    @Test("300 Ah × 51.2 V = 15.36 kWh; usable energy respects minimum SOC")
    func batteryConfig() {
        let config = BatteryConfiguration.fromAmpHours(300)
        #expect(abs(config.capacityKWh - 15.36) < 1e-9)
        #expect(BatteryConfiguration.default.usableEnergyWh(atSOC: 20) == 0)
        #expect(BatteryConfiguration.default.usableEnergyWh(atSOC: 10) == 0)
        #expect(BatteryConfiguration.default.usableEnergyWh(atSOC: 100) == 12_800)
    }
}
