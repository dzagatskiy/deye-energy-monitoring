import Foundation

/// Where a sample came from. Local samples (Solarman V5 on LAN) win over cloud ones on conflict.
public enum SourceKind: String, Sendable, Codable, CaseIterable {
    case local
    case cloud
}

public enum GridState: String, Sendable, Codable {
    case on
    case off
    case unknown
}

public enum InverterState: String, Sendable, Codable {
    case standby, selfTest, normal, alarm, fault, unknown
}

/// One normalized measurement. All values are in SI units, all timestamps are absolute (UTC-based `Date`).
///
/// Sign conventions:
/// - `gridPower`: + import from grid, − export to grid.
/// - `batteryPower`: + charging, − discharging.
public struct TelemetrySample: Hashable, Sendable, Codable {
    public var timestamp: Date
    public var source: SourceKind
    public var gridState: GridState
    public var gridVoltage: Double?
    public var gridPower: Double?
    public var batterySOC: Double?
    public var batteryVoltage: Double?
    public var batteryCurrent: Double?
    public var batteryPower: Double?
    public var loadPower: Double?
    public var pvPower: Double?
    /// Inverter's own daily load counter, kWh. Used only to cross-check our integration.
    public var dailyLoadEnergy: Double?
    public var inverterState: InverterState?
    /// Which inverter this sample belongs to (`InverterID`). Series, outages and statistics are always per inverter.
    public var inverterId: InverterID?

    public init(
        timestamp: Date,
        source: SourceKind,
        gridState: GridState,
        gridVoltage: Double? = nil,
        gridPower: Double? = nil,
        batterySOC: Double? = nil,
        batteryVoltage: Double? = nil,
        batteryCurrent: Double? = nil,
        batteryPower: Double? = nil,
        loadPower: Double? = nil,
        pvPower: Double? = nil,
        dailyLoadEnergy: Double? = nil,
        inverterState: InverterState? = nil,
        inverterId: InverterID? = nil
    ) {
        self.timestamp = timestamp
        self.source = source
        self.gridState = gridState
        self.gridVoltage = gridVoltage
        self.gridPower = gridPower
        self.batterySOC = batterySOC
        self.batteryVoltage = batteryVoltage
        self.batteryCurrent = batteryCurrent
        self.batteryPower = batteryPower
        self.loadPower = loadPower
        self.pvPower = pvPower
        self.dailyLoadEnergy = dailyLoadEnergy
        self.inverterState = inverterState
        self.inverterId = inverterId
    }

    /// Power drawn from the battery, W (≥ 0). Falls back to load power when battery power is unknown.
    public var batteryDrainPower: Double? {
        if let batteryPower { return max(0, -batteryPower) }
        return loadPower
    }
}

public enum BatteryFlow: String, Sendable, Equatable {
    case charging, discharging, idle

    /// - Parameter threshold: |power| below this is treated as idle, W.
    public init(batteryPower: Double?, threshold: Double = 30) {
        guard let p = batteryPower, abs(p) >= threshold else { self = .idle; return }
        self = p > 0 ? .charging : .discharging
    }
}
