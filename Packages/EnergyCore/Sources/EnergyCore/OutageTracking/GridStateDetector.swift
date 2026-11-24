import Foundation

/// Derives grid presence from what a data source provides.
///
/// Priority: an explicit status from the source (if it has one) → grid voltage below threshold → unknown.
/// The threshold is configurable because neither Deye Cloud nor the Solarman register map
/// documents a reliable "grid lost" flag (see architecture risk R2).
public struct GridStateDetector: Sendable, Equatable {
    public var voltageThreshold: Double

    public init(voltageThreshold: Double = 170) {
        self.voltageThreshold = voltageThreshold
    }

    public func detect(explicit: GridState? = nil, gridVoltage: Double?) -> GridState {
        if let explicit, explicit != .unknown { return explicit }
        guard let gridVoltage else { return .unknown }
        return gridVoltage < voltageThreshold ? .off : .on
    }
}
