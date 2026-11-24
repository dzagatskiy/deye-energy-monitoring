import Foundation
import Testing
@testable import EnergyCore

/// Tests run against real (redacted) responses recorded by scripts/deye_spike.py.
@Suite("DeyeCloudMapper")
struct DeyeCloudMapperTests {
    /// Fixture files wrap the API payload: `{"endpoint":…, "response": {…}}`.
    func fixtureResponse(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/DeyeCloud"))
        let wrapper = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let response = try #require(wrapper?["response"])
        return try JSONSerialization.data(withJSONObject: response)
    }

    @Test("Real /device/latest during an outage maps to GRID OFF on battery")
    func latestDuringOutage() throws {
        let sample = try #require(try DeyeCloudMapper.samples(fromLatest: fixtureResponse("pinned_latest_grid_off")).first)
        #expect(sample.source == .cloud)
        #expect(sample.timestamp == Date(timeIntervalSince1970: 1_795_450_705))
        #expect(sample.gridState == .off)
        #expect(sample.gridVoltage == 4.5)
        #expect(sample.batterySOC == 92)
        #expect(sample.batteryVoltage == 52.95)
        #expect(sample.loadPower == 220)
        #expect(sample.pvPower == 0)
        #expect(sample.dailyLoadEnergy == 4.3)
        // 210 W discharge from Deye becomes −210 W in our convention.
        #expect(sample.batteryPower == -210)
        #expect(sample.batteryCurrent == -3.98)
        #expect(BatteryFlow(batteryPower: sample.batteryPower) == .discharging)
    }

    @Test("Real /device/latest with grid present: Pull-in, battery charging, grid import")
    func latestGridOn() throws {
        let sample = try #require(try DeyeCloudMapper.samples(fromLatest: fixtureResponse("pinned_latest_grid_on")).first)
        #expect(sample.gridState == .on)
        #expect(sample.gridVoltage == 230.5)
        #expect(sample.batterySOC == 98)
        // Deye −29 W (negative = charging) → +29 W in our convention.
        #expect(sample.batteryPower == 29)
        #expect(BatteryFlow(batteryPower: sample.batteryPower) == .idle) // below the 30 W idle threshold
        #expect(sample.gridPower == 79)
        #expect(sample.loadPower == 6)
        #expect(sample.dailyLoadEnergy == 5.0)
    }

    @Test("Real /device/history day: frames parse, ~5.7 min step, relay-only grid state works")
    func historyDay() throws {
        let samples = try DeyeCloudMapper.samples(fromHistory: [fixtureResponse("pinned_history_grid_on_day")])
        #expect(samples.count == 106)
        #expect(samples.allSatisfy { $0.gridState == .on })
        #expect(samples.allSatisfy { $0.batterySOC != nil && $0.loadPower != nil })
        #expect(samples.first?.batteryPower == 29)
        let steps = zip(samples, samples.dropFirst()).map { $1.timestamp.timeIntervalSince($0.timestamp) }.sorted()
        #expect(steps[steps.count / 2] == 343)
        // Grid was on all day: no outages.
        #expect(OutageTracker().outages(from: samples, now: samples.last!.timestamp).isEmpty)
    }

    @Test("History batches with the same timestamps are merged into one sample")
    func historyMerge() throws {
        let a = Data(#"{"code":"1000000","success":true,"dataList":[{"time":"100","itemList":[{"key":"SOC","value":"80","unit":"%"},{"key":"GridRelayStatus","value":"Break"}]}]}"#.utf8)
        let b = Data(#"{"code":"1000000","success":true,"dataList":[{"time":"100","itemList":[{"key":"GridVoltageL1L2","value":"3.1","unit":"V"}]},{"time":"400","itemList":[{"key":"GridVoltageL1L2","value":"231","unit":"V"}]}]}"#.utf8)
        let samples = try DeyeCloudMapper.samples(fromHistory: [a, b])
        #expect(samples.count == 2)
        #expect(samples[0].batterySOC == 80 && samples[0].gridVoltage == 3.1 && samples[0].gridState == .off)
        #expect(samples[1].gridState == .on)
        #expect(throws: DataSourceError.invalidResponse("2101007: list too long")) {
            try DeyeCloudMapper.samples(fromHistory: [fixtureResponse("pinned_error_list_too_long")])
        }
    }

    @Test("Battery capacity is suggested from BatteryRatedCapacity (300 Ah → 15.36 kWh)")
    func suggestedBattery() throws {
        let response = try JSONDecoder().decode(DeyeDeviceLatestResponse.self, from: fixtureResponse("pinned_latest_grid_off"))
        let device = try #require(response.deviceDataList?.first)
        let config = try #require(DeyeCloudMapper.suggestedBattery(from: device))
        #expect(abs(config.capacityKWh - 15.36) < 1e-9)
    }

    @Test("Relay closed (unknown value) falls back to grid voltage")
    func relayFallback() {
        func device(relay: String, voltage: String) -> DeyeDeviceData {
            DeyeDeviceData(deviceSn: "x", deviceType: "INVERTER", deviceState: 1, collectionTime: 0, dataList: [
                DeyeDataPoint(key: "GridRelayStatus", value: relay, unit: nil),
                DeyeDataPoint(key: "GridVoltageL1L2", value: voltage, unit: "V"),
            ])
        }
        #expect(DeyeCloudMapper.sample(from: device(relay: "Pull-in", voltage: "231.2")).gridState == .on)
        #expect(DeyeCloudMapper.sample(from: device(relay: "Pull-in", voltage: "0")).gridState == .off)
        #expect(DeyeCloudMapper.sample(from: device(relay: "Break", voltage: "231.2")).gridState == .off)
    }

    @Test("Units are normalized to W and kWh")
    func units() {
        #expect(DeyeCloudMapper.normalize(1.25, unit: "kW") == 1250)
        #expect(DeyeCloudMapper.normalize(4300, unit: "Wh") == 4.3)
        #expect(DeyeCloudMapper.normalize(220, unit: "W") == 220)
    }

    @Test("Error envelopes map to typed errors")
    func errors() throws {
        // Real response: /device/list on a personal account.
        #expect(throws: DataSourceError.unauthorized) {
            try DeyeCloudMapper.samples(fromLatest: fixtureResponse("pinned_error_invalid_token"))
        }
        // Real response: /device/history with too many measure points.
        #expect(throws: DataSourceError.invalidResponse("2101007: list too long")) {
            try DeyeCloudMapper.samples(fromLatest: fixtureResponse("pinned_error_list_too_long"))
        }
        let empty = Data(#"{"code":"1000000","msg":"success","success":true,"deviceDataList":[]}"#.utf8)
        #expect(throws: DataSourceError.emptyResponse) { try DeyeCloudMapper.samples(fromLatest: empty) }
        #expect(throws: DataSourceError.self) { try DeyeCloudMapper.samples(fromLatest: Data("<html>".utf8)) }
    }
}
