import Foundation

/// User-configurable battery parameters (Settings).
public struct BatteryConfiguration: Sendable, Hashable, Codable {
    /// Usable nameplate capacity, kWh.
    public var capacityKWh: Double
    /// SOC below which the battery must not be discharged, %.
    public var minimumSOC: Double

    public static let `default` = BatteryConfiguration(capacityKWh: 16, minimumSOC: 20)

    public init(capacityKWh: Double, minimumSOC: Double) {
        self.capacityKWh = max(0, capacityKWh)
        self.minimumSOC = min(100, max(0, minimumSOC))
    }

    /// Builds the configuration from amp-hours. 48V LiFePO4 (16S) has a 51.2V nominal voltage.
    public static func fromAmpHours(_ ampHours: Double, nominalVoltage: Double = 51.2, minimumSOC: Double = 20) -> Self {
        BatteryConfiguration(capacityKWh: ampHours * nominalVoltage / 1000, minimumSOC: minimumSOC)
    }

    /// Energy left above the minimum SOC, Wh.
    public func usableEnergyWh(atSOC soc: Double) -> Double {
        max(0, capacityKWh * 1000 * (soc - minimumSOC) / 100)
    }
}
