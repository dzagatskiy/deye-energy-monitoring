import EnergyCore
import SwiftUI

struct OutagesView: View {
    @Environment(AppModel.self) private var model
    @State private var outages: [Outage] = []
    @State private var days = 7

    var body: some View {
        List {
            Picker("Період", selection: $days) {
                Text("7 днів").tag(7)
                Text("30 днів").tag(30)
                Text("90 днів").tag(90)
            }
            .pickerStyle(.segmented)

            if outages.isEmpty {
                ContentUnavailableView("Відключень не зафіксовано", systemImage: "bolt.fill",
                                       description: Text("Історія наповнюється з Deye Cloud і зберігається на iPhone."))
            }
            ForEach(groupedByDay, id: \.day) { group in
                Section(group.day.formatted(date: .complete, time: .omitted)) {
                    ForEach(group.items) { OutageRow(outage: $0) }
                }
            }
        }
        .navigationTitle("Відключення")
        .toolbar {
            if model.settings.inverters.count > 1 {
                ToolbarItem(placement: .topBarLeading) { InverterPicker() }
            }
        }
        .task(id: "\(model.selectedId?.rawValue ?? "")-\(days)-\(model.snapshots.count)") { await reload() }
        .refreshable { await model.refresh(force: true); await reload() }
    }

    private func reload() async {
        guard let id = model.selectedId else { return }
        outages = await model.outages(for: id, days: days).reversed()
    }

    private var groupedByDay: [(day: Date, items: [Outage])] {
        guard let id = model.selectedId else { return [] }
        let calendar = OutageStatistics.calendar(in: model.settings.profile(for: id).timeZone)
        let groups = Dictionary(grouping: outages) { calendar.startOfDay(for: $0.startedAt) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!) }
    }
}

private struct OutageRow: View {
    let outage: Outage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(timeRange).font(.headline).monospacedDigit()
                Spacer()
                if outage.isOngoing {
                    OutageTimer(start: outage.startedAt).font(.headline).foregroundStyle(.red)
                } else {
                    Text(EnergyFormat.clock(outage.duration(now: .now))).font(.headline).monospacedDigit()
                }
            }
            HStack(spacing: 12) {
                Text("⌀ \(EnergyFormat.power(outage.averagePowerW))")
                Text("макс \(EnergyFormat.power(outage.maxPowerW))")
                Text(EnergyFormat.energy(outage.energyKWh))
                if let a = outage.startSOC, let b = outage.endSOC {
                    Text("SOC \(Int(a))→\(Int(b))%")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if outage.hasDataGaps || outage.startUncertainty == nil {
                Label("Є пропуски в даних, межі приблизні", systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
    }

    private var timeRange: String {
        let start = outage.startedAt.formatted(date: .omitted, time: .shortened)
        let end = outage.endedAt?.formatted(date: .omitted, time: .shortened) ?? "зараз"
        let approx = (outage.startUncertainty ?? 0) > 60 ? "≈" : ""
        return "\(approx)\(start) – \(end)"
    }
}
