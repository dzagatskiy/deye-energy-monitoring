import Foundation
import Testing
@testable import EnergyCore

@Suite("Multiple inverters")
struct MultiInverterTests {
    func fixtureResponse(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/DeyeCloud"))
        let wrapper = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return try JSONSerialization.data(withJSONObject: try #require(wrapper?["response"]))
    }

    @Test("Real /station/listWithDevice yields both inverters, online one first")
    func discovery() throws {
        let inverters = try DeyeCloudMapper.inverters(fromStationList: fixtureResponse("pinned_station_list_with_device"))
        #expect(inverters.count == 2)
        #expect(Set(inverters.map(\.id)).count == 2)
        #expect(inverters[0].isOnline && !inverters[1].isOnline)
        #expect(inverters[0].stationTimeZone == "Asia/Beirut")
        #expect(inverters[1].stationTimeZone == "Europe/Helsinki")
        #expect(inverters[0].lastCollectionAt == Date(timeIntervalSince1970: 1_795_450_885))
        #expect(inverters.allSatisfy { $0.productId == "0_5407_1" })
    }

    @Test("Samples carry the inverter id from latest and history responses")
    func samplesTagged() throws {
        let latest = try #require(try DeyeCloudMapper.samples(fromLatest: fixtureResponse("pinned_latest_grid_on")).first)
        #expect(latest.inverterId != nil)
        let history = try DeyeCloudMapper.samples(fromHistory: [fixtureResponse("pinned_history_grid_on_day")])
        #expect(history.allSatisfy { $0.inverterId == latest.inverterId })
    }

    @Test("Outages are tracked per inverter: one inverter's outage does not leak into another")
    func perInverterOutages() {
        let a = InverterID("A"), b = InverterID("B")
        func tag(_ s: [TelemetrySample], _ id: InverterID) -> [TelemetrySample] {
            s.map { var x = $0; x.inverterId = id; return x }
        }
        let dacha = tag(series(from: 0, to: 30, step: 5, .on) + series(from: 35, to: 60, step: 5, .off), a)
        let home = tag(series(from: 0, to: 60, step: 5, .on), b)
        let grouped = SampleSeries.grouped(dacha + home)
        let tracker = OutageTracker()
        #expect(tracker.outages(from: grouped[a]!, now: at(minutes: 60)).count == 1)
        #expect(tracker.outages(from: grouped[b]!, now: at(minutes: 60)).isEmpty)
    }

    @Test("Each inverter has its own profile and display name")
    func profiles() {
        let named = InverterDescriptor(id: InverterID("2401234567"), stationName: "Дача")
        let unnamed = InverterDescriptor(id: InverterID("2401234567"))
        #expect(named.displayName == "Дача")
        #expect(unnamed.displayName == "Інвертор …4567")
        let p = InverterProfile(id: named.id, battery: .fromAmpHours(300), gridVoltageThreshold: 180)
        #expect(p.detector.detect(gridVoltage: 175) == .off)
        #expect(p.timeZone.identifier == "Europe/Kyiv")
    }
}
