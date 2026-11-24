import Foundation

/// Per-inverter notification preferences (stored in `InverterProfile`).
public struct NotificationSettings: Sendable, Codable, Hashable {
    public var gridOff: Bool
    public var gridOn: Bool
    public var lowBattery: Bool
    public var criticalBattery: Bool
    /// "Low battery" threshold, %. "Critical" is the profile's minimum SOC.
    public var lowBatterySOC: Double
    /// SOC must rise this much above a threshold before the same alert can fire again (no flapping).
    public var rearmMarginSOC: Double
    /// Events found later than this (e.g. recovered from history after a long background pause)
    /// are recorded silently instead of notified.
    public var maxEventAge: TimeInterval

    public init(
        gridOff: Bool = true, gridOn: Bool = true, lowBattery: Bool = true, criticalBattery: Bool = true,
        lowBatterySOC: Double = 30, rearmMarginSOC: Double = 5, maxEventAge: TimeInterval = 3 * 3600
    ) {
        self.gridOff = gridOff
        self.gridOn = gridOn
        self.lowBattery = lowBattery
        self.criticalBattery = criticalBattery
        self.lowBatterySOC = lowBatterySOC
        self.rearmMarginSOC = rearmMarginSOC
        self.maxEventAge = maxEventAge
    }

    public static let `default` = NotificationSettings()
}

public struct EnergyNotification: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        case gridOff, gridOn, outageSummary, lowBattery, criticalBattery
    }

    /// Stable per event. iOS replaces a notification with the same identifier, so if the app and the
    /// widget detect the same event at the same moment, the user still sees it once.
    public var id: String
    public var kind: Kind
    public var inverterId: InverterID
    public var title: String
    public var body: String

    public init(id: String, kind: Kind, inverterId: InverterID, title: String, body: String) {
        self.id = id
        self.kind = kind
        self.inverterId = inverterId
        self.title = title
        self.body = body
    }
}

/// What has already been notified, per inverter (JSON in the App Group).
public struct NotificationState: Sendable, Codable, Equatable {
    /// `Outage.id` (first OFF sample time) values.
    public var notifiedOutageStarts: Set<Date> = []
    public var notifiedOutageEnds: Set<Date> = []
    public var lowBatteryArmed = true
    public var criticalBatteryArmed = true
    /// False until the first evaluation: then existing history is recorded without notifying.
    public var initialized = false

    public init() {}

    public static func fileName(_ id: InverterID) -> String { "notify-\(id.rawValue).json" }
}

/// Decides which notifications to show. Pure: same input → same output, so it is unit-tested
/// and safe to run from the app, the widget and the background task alike.
public struct NotificationEvaluator: Sendable {
    /// Ongoing outage detected later than this gets "(≈N хв тому)" in the text.
    public var lateThreshold: TimeInterval = 10 * 60
    /// Battery alerts are skipped when the latest sample is older than this.
    public var batteryDataMaxAge: TimeInterval = 30 * 60
    /// Notified-outage ids older than this are forgotten.
    public var memory: TimeInterval = 7 * 86_400

    public init() {}

    public func evaluate(
        snapshot: EnergySnapshot,
        outages: [Outage],
        profile: InverterProfile,
        state previous: NotificationState,
        now: Date
    ) -> (notifications: [EnergyNotification], state: NotificationState) {
        var state = previous
        let settings = profile.notifications ?? .default
        let name = snapshot.name
        let id = profile.id
        let clock = Self.timeFormatter(profile.timeZone)
        let recent = outages.filter { ($0.endedAt ?? now) > now.addingTimeInterval(-memory) }

        // Forget old ids so the state file stays small.
        let cutoff = now.addingTimeInterval(-memory)
        state.notifiedOutageStarts = state.notifiedOutageStarts.filter { $0 > cutoff }
        state.notifiedOutageEnds = state.notifiedOutageEnds.filter { $0 > cutoff }

        guard state.initialized else {
            for o in recent {
                state.notifiedOutageStarts.insert(o.id)
                if !o.isOngoing { state.notifiedOutageEnds.insert(o.id) }
            }
            if let soc = snapshot.batterySOC {
                state.lowBatteryArmed = soc > settings.lowBatterySOC
                state.criticalBatteryArmed = soc > profile.battery.minimumSOC
            }
            state.initialized = true
            return ([], state)
        }

        var result: [EnergyNotification] = []
        func key(_ kind: EnergyNotification.Kind, _ date: Date) -> String {
            "\(kind.rawValue)-\(id.rawValue)-\(Int(date.timeIntervalSince1970))"
        }

        for o in recent.sorted(by: { $0.startedAt < $1.startedAt }) {
            let startKnown = state.notifiedOutageStarts.contains(o.id)
            let endKnown = state.notifiedOutageEnds.contains(o.id)

            if let end = o.endedAt {
                guard !endKnown else { continue }
                let fresh = now.timeIntervalSince(end) <= settings.maxEventAge
                if fresh && settings.gridOn {
                    let range = "\(clock.string(from: o.startedAt))–\(clock.string(from: end))"
                    let duration = EnergyFormat.hoursMinutes(end.timeIntervalSince(o.startedAt))
                    let energy = EnergyFormat.energy(o.energyKWh)
                    if startKnown {
                        result.append(EnergyNotification(
                            id: key(.gridOn, o.id), kind: .gridOn, inverterId: id,
                            title: "\(name): світло є",
                            body: "Не було \(duration) (\(range)). Спожито \(energy)."))
                    } else {
                        // The whole outage happened while iOS kept us suspended: one summary instead of two alerts.
                        result.append(EnergyNotification(
                            id: key(.outageSummary, o.id), kind: .outageSummary, inverterId: id,
                            title: "\(name): було відключення",
                            body: "\(range), \(duration). Спожито \(energy)."))
                    }
                }
                state.notifiedOutageStarts.insert(o.id)
                state.notifiedOutageEnds.insert(o.id)
            } else if !startKnown {
                if settings.gridOff {
                    let ago = now.timeIntervalSince(o.startedAt)
                    let late = ago > lateThreshold ? " (≈\(EnergyFormat.hoursMinutes(ago)) тому)" : ""
                    var body = "З \(clock.string(from: o.startedAt))\(late)."
                    if let soc = snapshot.batterySOC { body += " Батарея \(EnergyFormat.percent(soc))." }
                    if case .estimate = snapshot.autonomy { body += " \(EnergyFormat.autonomy(snapshot.autonomy))." }
                    result.append(EnergyNotification(
                        id: key(.gridOff, o.id), kind: .gridOff, inverterId: id,
                        title: "\(name): немає світла", body: body))
                }
                state.notifiedOutageStarts.insert(o.id)
            }
        }

        // Battery: only while running on battery and with fresh data.
        if let soc = snapshot.batterySOC {
            if soc >= settings.lowBatterySOC + settings.rearmMarginSOC { state.lowBatteryArmed = true }
            if soc >= profile.battery.minimumSOC + settings.rearmMarginSOC { state.criticalBatteryArmed = true }

            let fresh = snapshot.measuredAt.map { now.timeIntervalSince($0) <= batteryDataMaxAge } ?? false
            let onBattery = snapshot.gridState != .on
            if fresh && onBattery, let measured = snapshot.measuredAt {
                if soc <= profile.battery.minimumSOC, state.criticalBatteryArmed {
                    state.criticalBatteryArmed = false
                    state.lowBatteryArmed = false
                    if settings.criticalBattery {
                        result.append(EnergyNotification(
                            id: key(.criticalBattery, measured), kind: .criticalBattery, inverterId: id,
                            title: "\(name): критичний заряд",
                            body: "Батарея \(EnergyFormat.percent(soc)): досягнуто мінімуму \(EnergyFormat.percent(profile.battery.minimumSOC))."))
                    }
                } else if soc <= settings.lowBatterySOC, state.lowBatteryArmed {
                    state.lowBatteryArmed = false
                    if settings.lowBattery {
                        var body = "Батарея \(EnergyFormat.percent(soc))."
                        if case .estimate = snapshot.autonomy { body += " \(EnergyFormat.autonomy(snapshot.autonomy))." }
                        result.append(EnergyNotification(
                            id: key(.lowBattery, measured), kind: .lowBattery, inverterId: id,
                            title: "\(name): низький заряд", body: body))
                    }
                }
            }
        }
        return (result, state)
    }

    static func timeFormatter(_ timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "uk_UA")
        f.timeZone = timeZone
        f.dateFormat = "HH:mm"
        return f
    }
}
