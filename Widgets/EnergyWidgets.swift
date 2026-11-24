import AppIntents
import EnergyCore
import SwiftUI
import WidgetKit

@main
struct EnergyWidgetsBundle: WidgetBundle {
    var body: some Widget {
        EnergyMonitorWidget()
    }
}

struct EnergyMonitorWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: AppEnvironment.widgetKind, intent: SelectInverterIntent.self, provider: EnergyProvider()) { entry in
            EnergyWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Energy Monitor")
        .description("Мережа, батарея, навантаження та відключення. Інвертор обирається в «Редагувати віджет».")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryCircular, .accessoryRectangular, .accessoryInline,
        ])
    }
}

struct EnergyEntry: TimelineEntry {
    enum State { case ready(EnergySnapshot), notConfigured, noData(String) }
    let date: Date
    let state: State
}

struct EnergyProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> EnergyEntry {
        EnergyEntry(date: .now, state: .ready(.placeholder()))
    }

    func snapshot(for configuration: SelectInverterIntent, in context: Context) async -> EnergyEntry {
        if context.isPreview { return placeholder(in: context) }
        let settings = await AppEnvironment.loadSettings()
        guard let id = settings.resolve(configuration.inverter.map { InverterID($0.id) }) else {
            return EnergyEntry(date: .now, state: .notConfigured)
        }
        let service = AppEnvironment.refreshService(settings: settings, forWidget: true)
        if let cached = await service?.cachedSnapshot(id, settings: settings) {
            return EnergyEntry(date: .now, state: .ready(cached))
        }
        return EnergyEntry(date: .now, state: .noData("Відкрийте застосунок"))
    }

    func timeline(for configuration: SelectInverterIntent, in context: Context) async -> Timeline<EnergyEntry> {
        let now = Date()
        let next = now.addingTimeInterval(15 * 60)
        let settings = await AppEnvironment.loadSettings()
        guard let id = settings.resolve(configuration.inverter.map { InverterID($0.id) }),
              let service = AppEnvironment.refreshService(settings: settings, forWidget: true) else {
            return Timeline(entries: [EnergyEntry(date: now, state: .notConfigured)], policy: .after(next))
        }
        // Network refresh within the widget's budget; on failure the snapshot still carries the last data + error.
        let snapshot = await service.refresh([id], settings: settings, now: now)[id]
        guard let snapshot else {
            return Timeline(entries: [EnergyEntry(date: now, state: .noData("Немає даних"))], policy: .after(next))
        }
        // A second entry re-renders the same data as stale if no refresh happens in time.
        var entries = [EnergyEntry(date: now, state: .ready(snapshot))]
        if let measured = snapshot.measuredAt, !snapshot.isStale {
            let staleAt = measured.addingTimeInterval(FreshnessPolicy().cloudMaxAge + 1)
            if staleAt > now {
                var stale = snapshot
                stale.isStale = true
                entries.append(EnergyEntry(date: staleAt, state: .ready(stale)))
            }
        }
        return Timeline(entries: entries, policy: .after(next))
    }
}

// MARK: - Views

struct EnergyWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: EnergyEntry

    var body: some View {
        switch entry.state {
        case .ready(let s):
            switch family {
            case .systemSmall: SmallView(s: s)
            case .systemMedium: MediumView(s: s)
            case .systemLarge: LargeView(s: s)
            case .accessoryCircular: CircularView(s: s)
            case .accessoryRectangular: RectangularView(s: s)
            case .accessoryInline: InlineView(s: s)
            default: SmallView(s: s)
            }
        case .notConfigured:
            MessageView(text: "Налаштуйте Deye Cloud у застосунку")
        case .noData(let text):
            MessageView(text: text)
        }
    }
}

private struct MessageView: View {
    let text: String
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "bolt.slash")
            Text(text).font(.caption).multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
    }
}

private struct Header: View {
    let s: EnergySnapshot
    var body: some View {
        HStack {
            Text(s.name).font(.headline).lineLimit(1)
            Spacer(minLength: 4)
            GridBadge(state: s.gridState, stale: s.isStale)
        }
    }
}

private struct Metric: View {
    let title: String
    let value: String
    var color: Color = .primary
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).foregroundStyle(color).minimumScaleFactor(0.6).lineLimit(1)
            if let detail { Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
        }
    }
}

private struct OutageLine: View {
    let s: EnergySnapshot
    var body: some View {
        if let outage = s.currentOutage {
            HStack(spacing: 4) {
                Image(systemName: "bolt.slash.fill").foregroundStyle(.red)
                Text("Без світла")
                OutageTimer(start: outage.startedAt).fontWeight(.semibold)
            }
            .font(.caption)
        } else {
            Label("Мережа є", systemImage: "bolt.fill")
                .font(.caption)
                .foregroundStyle(s.isStale ? .secondary : Color.green)
        }
    }
}

private struct UpdatedLine: View {
    let s: EnergySnapshot
    var body: some View {
        HStack(spacing: 4) {
            if s.isStale { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            Text("Оновлено \(s.updatedText)")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

struct SmallView: View {
    let s: EnergySnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: s.gridState == .off ? "bolt.slash.fill" : "bolt.fill")
                    .foregroundStyle(EnergyStyle.gridColor(s.gridState, stale: s.isStale))
                Text(s.name).font(.caption.weight(.semibold)).lineLimit(1)
            }
            Text(EnergyFormat.percent(s.batterySOC))
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(EnergyStyle.socColor(s.batterySOC))
            Text("Load \(EnergyFormat.power(s.loadPowerW))").font(.caption)
            Spacer(minLength: 0)
            OutageLine(s: s)
            UpdatedLine(s: s)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MediumView: View {
    let s: EnergySnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Header(s: s)
            HStack(alignment: .top) {
                Metric(title: "Battery", value: EnergyFormat.percent(s.batterySOC), color: EnergyStyle.socColor(s.batterySOC),
                       detail: batteryDetail)
                Spacer()
                Metric(title: "Load", value: EnergyFormat.power(s.loadPowerW), detail: "PV \(EnergyFormat.power(s.pvPowerW))")
                Spacer()
                Metric(title: "Автономність", value: EnergyStyle.autonomyShort(s.autonomy), detail: EnergyStyle.autonomyCaption(s.autonomy))
            }
            Spacer(minLength: 0)
            HStack {
                OutageLine(s: s)
                Spacer()
                UpdatedLine(s: s)
            }
        }
    }

    private var batteryDetail: String {
        let flow = s.batteryFlow
        let power = EnergyFormat.power(s.batteryPowerW.map(abs))
        switch flow {
        case .charging: return "↓ \(power)"
        case .discharging: return "↑ \(power)"
        case .idle: return "очікування"
        }
    }
}

struct LargeView: View {
    let s: EnergySnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MediumView(s: s).frame(maxHeight: 150)
            Divider()
            row("Без світла сьогодні", EnergyFormat.clock(s.todayOutageDuration))
            row("Відключень сьогодні", "\(s.todayOutageCount)")
            row("Спожито за відключення", EnergyFormat.energy(s.todayOutageEnergyKWh))
            row("Макс. навантаження", EnergyFormat.power(s.todayMaxLoadW))
            if let last = s.lastOutage, let end = last.endedAt {
                row("Останнє відключення", (last.isApproximate ? "≈ " : "") + EnergyFormat.clock(end.timeIntervalSince(last.startedAt)))
            }
            if let error = s.lastError {
                Text(error).font(.caption2).foregroundStyle(.orange).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.semibold).monospacedDigit()
        }
        .font(.subheadline)
    }
}

struct CircularView: View {
    let s: EnergySnapshot
    var body: some View {
        Gauge(value: (s.batterySOC ?? 0) / 100) {
            Image(systemName: s.gridState == .off ? "bolt.slash.fill" : "bolt.fill")
        } currentValueLabel: {
            Text(s.batterySOC.map { "\(Int($0))" } ?? "—")
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .widgetAccentable()
    }
}

struct RectangularView: View {
    let s: EnergySnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: s.gridState == .off ? "bolt.slash.fill" : "bolt.fill")
                if let outage = s.currentOutage {
                    OutageTimer(start: outage.startedAt).fontWeight(.semibold)
                } else {
                    Text(s.isStale ? "Немає даних" : "Мережа є").fontWeight(.semibold)
                }
            }
            Text("🔋 \(EnergyFormat.percent(s.batterySOC)) · \(EnergyFormat.power(s.loadPowerW))")
            Text(s.name).foregroundStyle(.secondary)
        }
        .font(.caption)
        .widgetAccentable()
    }
}

struct InlineView: View {
    let s: EnergySnapshot
    var body: some View {
        if let outage = s.currentOutage {
            Text("\(EnergyFormat.percent(s.batterySOC)) · без світла ") + Text(outage.startedAt, style: .timer)
        } else {
            Text("\(EnergyFormat.percent(s.batterySOC)) · \(EnergyFormat.power(s.loadPowerW))")
        }
    }
}

#Preview(as: .systemMedium) {
    EnergyMonitorWidget()
} timeline: {
    EnergyEntry(date: .now, state: .ready(.placeholder()))
}
