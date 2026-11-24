import Foundation

/// Stable inverter identity across sources: the device serial number.
/// Deye Cloud `deviceSn` and the Solarman logger both refer to it, so one ID covers local + cloud data.
public struct InverterID: Hashable, Sendable, Codable, CustomStringConvertible {
    public var rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// An inverter discovered in the account (Deye Cloud `/station/listWithDevice`).
/// The widget configuration offers these as choices; each widget instance stores one `InverterID`.
public struct InverterDescriptor: Identifiable, Hashable, Sendable, Codable {
    public var id: InverterID
    public var stationId: String?
    public var stationName: String?
    /// Time zone configured in Deye for the station. Shown for reference only; statistics use the profile's zone.
    public var stationTimeZone: String?
    public var productId: String?
    /// `connectStatus == 1` in Deye Cloud.
    public var isOnline: Bool
    public var lastCollectionAt: Date?

    public init(
        id: InverterID, stationId: String? = nil, stationName: String? = nil, stationTimeZone: String? = nil,
        productId: String? = nil, isOnline: Bool = false, lastCollectionAt: Date? = nil
    ) {
        self.id = id
        self.stationId = stationId
        self.stationName = stationName
        self.stationTimeZone = stationTimeZone
        self.productId = productId
        self.isOnline = isOnline
        self.lastCollectionAt = lastCollectionAt
    }

    /// Text for the widget's inverter picker: station name, or the SN tail if the station is unnamed.
    public var displayName: String {
        if let stationName, !stationName.isEmpty { return stationName }
        return "Інвертор …\(id.rawValue.suffix(4))"
    }
}

/// Per-inverter user settings. Two inverters can have different batteries, thresholds and loggers.
public struct InverterProfile: Identifiable, Hashable, Sendable, Codable {
    public var id: InverterID
    /// User-facing name override ("Дача"); falls back to the descriptor's display name.
    public var customName: String?
    public var battery: BatteryConfiguration
    public var gridVoltageThreshold: Double
    /// Time zone for "today"/daily statistics (IANA id).
    public var timeZoneIdentifier: String
    /// Solarman logger on the LAN for local mode; nil disables local polling for this inverter.
    public var localLogger: LocalLoggerConfiguration?
    /// Optional so profiles saved by earlier builds still decode; nil means `NotificationSettings.default`.
    public var notifications: NotificationSettings?

    public init(
        id: InverterID,
        customName: String? = nil,
        battery: BatteryConfiguration = .default,
        gridVoltageThreshold: Double = 170,
        timeZoneIdentifier: String = "Europe/Kyiv",
        localLogger: LocalLoggerConfiguration? = nil,
        notifications: NotificationSettings? = nil
    ) {
        self.id = id
        self.customName = customName
        self.battery = battery
        self.gridVoltageThreshold = gridVoltageThreshold
        self.timeZoneIdentifier = timeZoneIdentifier
        self.localLogger = localLogger
        self.notifications = notifications
    }

    /// Non-optional accessor for UI bindings.
    public var notificationSettings: NotificationSettings {
        get { notifications ?? .default }
        set { notifications = newValue }
    }

    public var timeZone: TimeZone { TimeZone(identifier: timeZoneIdentifier) ?? .current }
    public var detector: GridStateDetector { GridStateDetector(voltageThreshold: gridVoltageThreshold) }
}

public struct LocalLoggerConfiguration: Hashable, Sendable, Codable {
    public var host: String
    public var port: Int
    public var loggerSerial: UInt32

    public init(host: String, port: Int = 8899, loggerSerial: UInt32) {
        self.host = host
        self.port = port
        self.loggerSerial = loggerSerial
    }
}

public extension SampleSeries {
    /// Splits a mixed list into per-inverter series. Samples without an inverter id are dropped.
    static func grouped(_ samples: [TelemetrySample]) -> [InverterID: [TelemetrySample]] {
        Dictionary(grouping: samples.filter { $0.inverterId != nil }) { $0.inverterId! }
            .mapValues { normalize($0) }
    }
}
