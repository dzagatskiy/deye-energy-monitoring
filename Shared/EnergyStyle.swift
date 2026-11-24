import EnergyCore
import SwiftUI

/// Visual language shared by the app and widgets.
enum EnergyStyle {
    static func gridColor(_ state: GridState, stale: Bool) -> Color {
        if stale { return .gray }
        switch state {
        case .on: return .green
        case .off: return .red
        case .unknown: return .gray
        }
    }

    static func socColor(_ soc: Double?, minimum: Double = 20) -> Color {
        guard let soc else { return .secondary }
        if soc <= minimum { return .red }
        if soc <= minimum + 15 { return .orange }
        return .green
    }

    static func flowColor(_ flow: BatteryFlow) -> Color {
        switch flow {
        case .charging: return .blue
        case .discharging: return .orange
        case .idle: return .secondary
        }
    }

    static func flowSymbol(_ flow: BatteryFlow) -> String {
        switch flow {
        case .charging: return "arrow.down.circle.fill"
        case .discharging: return "arrow.up.circle.fill"
        case .idle: return "pause.circle"
        }
    }

    static func gridLabel(_ state: GridState, stale: Bool) -> String {
        if stale { return "НЕМАЄ ДАНИХ" }
        switch state {
        case .on: return "GRID ON"
        case .off: return "GRID OFF"
        case .unknown: return "GRID ?"
        }
    }

    /// Short autonomy text for small spaces.
    static func autonomyShort(_ estimate: AutonomyEstimate) -> String {
        switch estimate {
        case .estimate(let t): return EnergyFormat.clock(t)
        case .unstable(let lo, let hi): return "\(EnergyFormat.clock(lo))–\(EnergyFormat.clock(hi))"
        case .insufficientData: return "—"
        case .gridAvailable: return "—"
        case .charging: return "—"
        case .belowMinimum: return "мін. SOC"
        case .negligibleLoad: return "∞"
        }
    }

    /// Caption under the short autonomy value in widgets.
    static func autonomyCaption(_ estimate: AutonomyEstimate) -> String {
        switch estimate {
        case .estimate: return "прогноз"
        case .unstable: return "нестабільно"
        case .insufficientData: return "мало даних"
        case .gridAvailable: return "мережа є"
        case .charging: return "заряд"
        case .belowMinimum: return "нижче мін."
        case .negligibleLoad: return "мін. навантаж."
        }
    }
}

struct GridBadge: View {
    let state: GridState
    let stale: Bool

    var body: some View {
        let color = EnergyStyle.gridColor(state, stale: stale)
        Text(EnergyStyle.gridLabel(state, stale: stale))
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
    }
}

/// Counts up from the outage start without timeline reloads (`Text` timer style).
struct OutageTimer: View {
    let start: Date

    var body: some View {
        Text(timerInterval: start...Date.distantFuture, countsDown: false)
            .monospacedDigit()
    }
}

extension EnergySnapshot {
    var updatedText: String {
        guard let measuredAt else { return "немає даних" }
        return measuredAt.formatted(date: .omitted, time: .shortened)
    }
}
