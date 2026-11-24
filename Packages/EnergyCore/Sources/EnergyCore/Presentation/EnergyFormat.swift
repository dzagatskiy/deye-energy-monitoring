import Foundation

/// Formatting shared by the app and widgets, so both show identical text.
public enum EnergyFormat {
    /// "03:42" (hours:minutes); hours may exceed 24 for long outages, e.g. "27:05".
    public static func clock(_ duration: TimeInterval) -> String {
        let minutes = Int(max(0, duration) / 60)
        return String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    /// "5 год 20 хв", "45 хв", "3 год".
    public static func hoursMinutes(_ duration: TimeInterval) -> String {
        let minutes = Int((max(0, duration) / 60).rounded())
        let h = minutes / 60, m = minutes % 60
        switch (h, m) {
        case (0, _): return "\(m) хв"
        case (_, 0): return "\(h) год"
        default: return "\(h) год \(m) хв"
        }
    }

    /// Power: "1.25 kW" from 1250 W; below 1 kW shows watts ("850 W").
    public static func power(_ watts: Double?) -> String {
        guard let watts else { return "—" }
        if abs(watts) < 1000 { return String(format: "%.0f W", watts) }
        return String(format: "%.2f kW", watts / 1000)
    }

    /// Energy: "4.65 kWh".
    public static func energy(_ kWh: Double?) -> String {
        guard let kWh else { return "—" }
        return String(format: "%.2f kWh", kWh)
    }

    public static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f%%", value)
    }

    public static func autonomy(_ estimate: AutonomyEstimate) -> String {
        switch estimate {
        case .estimate(let t): "Орієнтовно залишилося \(hoursMinutes(t))"
        case .unstable(let lo, let hi): "Навантаження нестабільне: від \(hoursMinutes(lo)) до \(hoursMinutes(hi))"
        case .insufficientData: "Недостатньо даних для прогнозу"
        case .gridAvailable: "Живлення від мережі"
        case .charging: "Батарея заряджається"
        case .belowMinimum: "Заряд нижче мінімального рівня"
        case .negligibleLoad: "Навантаження мінімальне"
        }
    }
}
