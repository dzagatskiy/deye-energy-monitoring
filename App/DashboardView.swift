import EnergyCore
import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let s = model.selectedSnapshot {
                    EnergyCard(s: s, minimumSOC: model.settings.profile(for: s.inverterId).battery.minimumSOC)
                } else {
                    ContentUnavailableView("Завантаження…", systemImage: "bolt.horizontal")
                }
                if let message = model.message {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
        .navigationTitle("Energy Monitor")
        .toolbar {
            if model.settings.inverters.count > 1 {
                ToolbarItem(placement: .topBarLeading) { InverterPicker() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if model.isRefreshing { ProgressView() }
            }
        }
        .refreshable { await model.refresh(force: true) }
    }
}

struct InverterPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            ForEach(model.settings.inverters) { d in
                Button {
                    model.select(d.id)
                } label: {
                    if d.id == model.selectedId { Label(model.name(for: d.id), systemImage: "checkmark") }
                    else { Text(model.name(for: d.id)) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(model.selectedId.map(model.name(for:)) ?? "Інвертор").fontWeight(.semibold)
                Image(systemName: "chevron.down").font(.caption.weight(.semibold))
            }
        }
    }
}

/// Layout from the reference mock-up: badge, Battery/Load, outage timer/autonomy, footer stats.
struct EnergyCard: View {
    let s: EnergySnapshot
    let minimumSOC: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(s.name).font(.title2.weight(.semibold))
                Spacer()
                GridBadge(state: s.gridState, stale: s.isStale)
            }

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 24) {
                GridRow {
                    BigMetric(title: "Battery", value: EnergyFormat.percent(s.batterySOC),
                              color: EnergyStyle.socColor(s.batterySOC, minimum: minimumSOC), caption: batteryCaption)
                    BigMetric(title: "Load", value: EnergyFormat.power(s.loadPowerW), caption: "PV \(EnergyFormat.power(s.pvPowerW))")
                }
                GridRow {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Без електрики").font(.subheadline).foregroundStyle(.secondary)
                        if let outage = s.currentOutage {
                            OutageTimer(start: outage.startedAt).font(.title.weight(.semibold))
                            Text(outage.isApproximate ? "Поточне відключення (≈)" : "Поточне відключення")
                                .font(.subheadline).foregroundStyle(.secondary)
                        } else {
                            Text("—").font(.title.weight(.semibold))
                            Text("Мережа є").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    BigMetric(title: "Автономність", value: EnergyStyle.autonomyShort(s.autonomy),
                              caption: EnergyFormat.autonomy(s.autonomy))
                }
            }

            Divider()

            VStack(spacing: 12) {
                FooterRow(title: "Спожито за відключення", value: EnergyFormat.energy(s.currentOutage?.energyKWh ?? s.todayOutageEnergyKWh))
                FooterRow(title: "Відключень сьогодні", value: "\(s.todayOutageCount)")
                FooterRow(title: "Без світла сьогодні", value: EnergyFormat.clock(s.todayOutageDuration))
                FooterRow(title: "Макс. навантаження", value: EnergyFormat.power(s.todayMaxLoadW))
                FooterRow(title: "Дані Deye", value: s.updatedText + (s.isStale ? " ⚠︎" : ""))
                if let checked = s.checkedAt {
                    FooterRow(title: "Перевірено", value: checked.formatted(date: .omitted, time: .shortened))
                }
            }
        }
        .padding(20)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 24))
    }

    private var batteryCaption: String {
        let power = EnergyFormat.power(s.batteryPowerW.map(abs))
        switch s.batteryFlow {
        case .charging: return "Заряд \(power)"
        case .discharging: return "Розряд \(power)"
        case .idle: return "LiFePO4"
        }
    }
}

private struct BigMetric: View {
    let title: String
    let value: String
    var color: Color = .primary
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.largeTitle.weight(.semibold)).foregroundStyle(color).minimumScaleFactor(0.5).lineLimit(1)
            Text(caption).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FooterRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.headline).monospacedDigit()
        }
    }
}

#Preview {
    EnergyCard(s: .placeholder(), minimumSOC: 20).padding()
}
