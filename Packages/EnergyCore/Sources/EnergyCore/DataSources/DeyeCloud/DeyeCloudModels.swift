import Foundation

// DTOs for Deye Cloud OpenAPI (v1.0). Shapes are taken from real responses recorded by
// scripts/deye_spike.py (Tests/EnergyCoreTests/Fixtures/DeyeCloud), not from guesses.

/// Common envelope: every response carries `code`/`msg`/`success`, HTTP status is 200 even on errors.
public struct DeyeEnvelope: Decodable, Sendable {
    public var code: String
    public var msg: String?
    public var success: Bool
    public var requestId: String?
}

public struct DeyeTokenResponse: Decodable, Sendable {
    public var code: String
    public var msg: String?
    public var success: Bool
    public var accessToken: String?
    public var refreshToken: String?
    /// Seconds, sent as a string ("5183999" ≈ 60 days).
    public var expiresIn: String?
}

/// `/device/latest`
public struct DeyeDeviceLatestResponse: Decodable, Sendable {
    public var code: String
    public var msg: String?
    public var success: Bool
    public var deviceDataList: [DeyeDeviceData]?
}

public struct DeyeDeviceData: Decodable, Sendable {
    public var deviceSn: String
    public var deviceType: String?
    /// Meaning of the values is not documented (1 was observed on a working inverter).
    public var deviceState: Int?
    /// Unix seconds of the measurement.
    public var collectionTime: TimeInterval
    public var dataList: [DeyeDataPoint]
}

public struct DeyeDataPoint: Decodable, Sendable, Equatable {
    public var key: String
    /// Always a string in responses: "52.95", "Break", "0000F004".
    public var value: String?
    public var unit: String?
}

/// `/device/history` with `granularity: 1` — frames of one day.
public struct DeyeDeviceHistoryResponse: Decodable, Sendable {
    public var code: String
    public var msg: String?
    public var success: Bool
    public var deviceSn: String?
    public var dataList: [DeyeHistoryFrame]?
}

public struct DeyeHistoryFrame: Decodable, Sendable {
    /// Unix seconds as a string, e.g. "1795384839".
    public var time: String
    public var itemList: [DeyeDataPoint]
}

/// `/station/listWithDevice` — the way to discover inverters on personal accounts
/// (`/device/list` returns "auth invalid token" for them).
public struct DeyeStationListWithDeviceResponse: Decodable, Sendable {
    public var code: String
    public var msg: String?
    public var success: Bool
    public var stationTotal: Int?
    public var stationList: [Station]?

    public struct Station: Decodable, Sendable {
        public var id: DeyeLooseID
        public var name: String?
        public var regionTimezone: String?
        public var deviceListItems: [Device]?
    }

    public struct Device: Decodable, Sendable {
        public var deviceSn: String
        public var deviceType: String?
        public var connectStatus: Int?
        public var collectionTime: TimeInterval?
        public var productId: String?
    }
}

/// Deye returns ids sometimes as numbers, sometimes as strings.
public struct DeyeLooseID: Decodable, Sendable, Hashable {
    public var value: String
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s }
        else if let i = try? c.decode(Int64.self) { value = String(i) }
        else { value = String(try c.decode(Double.self)) }
    }
}

/// Known Deye Cloud result codes (observed in real responses).
public enum DeyeResultCode {
    public static let success = "1000000"
    /// "auth invalid token" — also returned by `/device/list` for personal (non-business) accounts.
    public static let invalidToken = "2101019"
    /// "list too long" — too many `measurePoints` in `/device/history`.
    public static let listTooLong = "2101007"

    public static func error(code: String, message: String?) -> DataSourceError {
        switch code {
        case invalidToken: .unauthorized
        default: .invalidResponse("\(code): \(message ?? "")")
        }
    }
}
