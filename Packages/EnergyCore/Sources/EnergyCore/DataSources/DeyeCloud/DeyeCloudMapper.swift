import Foundation

/// Maps Deye Cloud measure points to a normalized `TelemetrySample`.
///
/// Mapping is based on a real `/device/latest` response from a SUN-6K-SG03LP1 recorded during
/// a grid outage (see docs/deye-cloud-mapping.md for the evidence behind each decision).
public enum DeyeCloudMapper {
    public enum Key {
        public static let soc = "SOC"
        public static let batteryVoltage = "BatteryVoltage"
        public static let batteryCurrent = "BatteryCurrent"
        public static let batteryPower = "BatteryPower"
        public static let batteryRatedCapacity = "BatteryRatedCapacity"
        public static let loadPower = "TotalConsumptionPower"
        public static let upsLoadPower = "UPSLoadPower"
        public static let pvPower = "TotalDCInputPower"
        public static let pvStringPowers = ["DCPowerPV1", "DCPowerPV2", "DCPowerPV3", "DCPowerPV4"]
        public static let gridVoltage = "GridVoltageL1L2"
        public static let gridPower = "TotalGridPower"
        public static let gridRelayStatus = "GridRelayStatus"
        public static let gridStatus = "GridStatus"
        public static let dailyConsumption = "DailyConsumption"

        /// History requests are split into batches: 10 points were rejected ("list too long"), 5 accepted.
        /// `GridStatus` is accepted in the request but never returned in frames, so it is not requested.
        public static let historyBatches: [[String]] = [
            [soc, batteryPower, loadPower, gridRelayStatus, pvPower],
            [gridVoltage, gridPower, dailyConsumption],
        ]
        public static let maxHistoryPointsPerRequest = 5
    }

    /// `GridRelayStatus` values observed in real responses: "Break" while the grid was down
    /// (4.5 V, 0 Hz), "Pull-in" while it was present (230.5 V, 50.03 Hz).
    public static let relayOpenValue = "Break"
    public static let relayClosedValue = "Pull-in"

    public static func sample(
        from device: DeyeDeviceData,
        detector: GridStateDetector = GridStateDetector()
    ) -> TelemetrySample {
        sample(points: device.dataList, collectionTime: device.collectionTime,
               inverterId: InverterID(device.deviceSn), detector: detector)
    }

    static func sample(
        points dataList: [DeyeDataPoint],
        collectionTime: TimeInterval,
        inverterId: InverterID?,
        detector: GridStateDetector
    ) -> TelemetrySample {
        let points = Dictionary(dataList.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })

        func number(_ key: String) -> Double? {
            guard let p = points[key], let raw = p.value?.trimmingCharacters(in: .whitespaces),
                  let v = Double(raw) else { return nil }
            return normalize(v, unit: p.unit)
        }
        func text(_ key: String) -> String? { points[key]?.value?.trimmingCharacters(in: .whitespaces) }

        let gridVoltage = number(Key.gridVoltage)
        let relay = text(Key.gridRelayStatus)
        // "Break" is trusted on its own. "Pull-in" is trusted only without a contradicting voltage reading.
        let explicit: GridState?
        if relay?.caseInsensitiveCompare(relayOpenValue) == .orderedSame {
            explicit = .off
        } else if relay?.caseInsensitiveCompare(relayClosedValue) == .orderedSame, gridVoltage == nil {
            explicit = .on
        } else {
            explicit = nil
        }

        let pvStrings = Key.pvStringPowers.compactMap(number)
        let pv = number(Key.pvPower) ?? (pvStrings.isEmpty ? nil : pvStrings.reduce(0, +))

        return TelemetrySample(
            timestamp: Date(timeIntervalSince1970: collectionTime),
            source: .cloud,
            gridState: detector.detect(explicit: explicit, gridVoltage: gridVoltage),
            gridVoltage: gridVoltage,
            gridPower: number(Key.gridPower),
            batterySOC: number(Key.soc),
            batteryVoltage: number(Key.batteryVoltage),
            // Deye reports discharge as positive; our convention is + charge / − discharge.
            batteryCurrent: number(Key.batteryCurrent).map { -$0 },
            batteryPower: number(Key.batteryPower).map { -$0 },
            loadPower: number(Key.loadPower) ?? number(Key.upsLoadPower),
            pvPower: pv,
            dailyLoadEnergy: number(Key.dailyConsumption),
            inverterState: nil,
            inverterId: inverterId
        )
    }

    /// Converts to W / kWh / V / A based on the unit string returned by the API.
    static func normalize(_ value: Double, unit: String?) -> Double {
        switch unit?.lowercased() {
        case "kw": value * 1000
        case "wh": value / 1000
        case "mwh": value * 1000
        default: value
        }
    }

    /// Parses `/device/latest` JSON and returns one sample per device.
    public static func samples(
        fromLatest data: Data,
        detector: GridStateDetector = GridStateDetector()
    ) throws -> [TelemetrySample] {
        let response: DeyeDeviceLatestResponse
        do {
            response = try JSONDecoder().decode(DeyeDeviceLatestResponse.self, from: data)
        } catch {
            throw DataSourceError.invalidResponse("Undecodable /device/latest: \(error)")
        }
        guard response.success, response.code == DeyeResultCode.success else {
            throw DeyeResultCode.error(code: response.code, message: response.msg)
        }
        guard let devices = response.deviceDataList, !devices.isEmpty else {
            throw DataSourceError.emptyResponse
        }
        return devices.map { sample(from: $0, detector: detector) }
    }

    /// Parses one or more `/device/history` responses (one per measure-point batch) for the same day
    /// and merges frames with equal timestamps into one sample each.
    public static func samples(
        fromHistory responses: [Data],
        detector: GridStateDetector = GridStateDetector()
    ) throws -> [TelemetrySample] {
        var byTime: [TimeInterval: [DeyeDataPoint]] = [:]
        var inverterId: InverterID?
        for data in responses {
            let response: DeyeDeviceHistoryResponse
            do {
                response = try JSONDecoder().decode(DeyeDeviceHistoryResponse.self, from: data)
            } catch {
                throw DataSourceError.invalidResponse("Undecodable /device/history: \(error)")
            }
            guard response.success, response.code == DeyeResultCode.success else {
                throw DeyeResultCode.error(code: response.code, message: response.msg)
            }
            if let sn = response.deviceSn { inverterId = InverterID(sn) }
            for frame in response.dataList ?? [] {
                guard let time = TimeInterval(frame.time) else { continue }
                byTime[time, default: []] += frame.itemList
            }
        }
        return byTime.keys.sorted().map { time in
            sample(points: byTime[time]!, collectionTime: time, inverterId: inverterId, detector: detector)
        }
    }

    /// All inverters in the account, online and freshest first (for the widget picker and Settings).
    public static func inverters(fromStationList data: Data) throws -> [InverterDescriptor] {
        let response: DeyeStationListWithDeviceResponse
        do {
            response = try JSONDecoder().decode(DeyeStationListWithDeviceResponse.self, from: data)
        } catch {
            throw DataSourceError.invalidResponse("Undecodable /station/listWithDevice: \(error)")
        }
        guard response.success, response.code == DeyeResultCode.success else {
            throw DeyeResultCode.error(code: response.code, message: response.msg)
        }
        var seen = Set<InverterID>()
        var result: [InverterDescriptor] = []
        for station in response.stationList ?? [] {
            for device in station.deviceListItems ?? [] where (device.deviceType ?? "INVERTER").uppercased() == "INVERTER" {
                let id = InverterID(device.deviceSn)
                guard seen.insert(id).inserted else { continue }
                result.append(InverterDescriptor(
                    id: id,
                    stationId: station.id.value,
                    stationName: station.name,
                    stationTimeZone: station.regionTimezone,
                    productId: device.productId,
                    isOnline: device.connectStatus == 1,
                    lastCollectionAt: device.collectionTime.map { Date(timeIntervalSince1970: $0) }
                ))
            }
        }
        return result.sorted {
            if $0.isOnline != $1.isOnline { return $0.isOnline }
            return ($0.lastCollectionAt ?? .distantPast) > ($1.lastCollectionAt ?? .distantPast)
        }
    }

    /// Battery capacity from `BatteryRatedCapacity` (Ah) at 51.2 V nominal, to prefill Settings.
    public static func suggestedBattery(from device: DeyeDeviceData) -> BatteryConfiguration? {
        guard let p = device.dataList.first(where: { $0.key == Key.batteryRatedCapacity }),
              p.unit?.lowercased() == "ah", let ah = p.value.flatMap(Double.init), ah > 0 else { return nil }
        return .fromAmpHours(ah)
    }
}
