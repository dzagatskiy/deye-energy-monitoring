import EnergyCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        Form {
            Section("Інвертори") {
                ForEach(model.settings.inverters) { d in
                    NavigationLink {
                        InverterProfileView(profile: model.settings.profile(for: d.id), descriptor: d)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(model.name(for: d.id))
                            Text("SN …\(d.id.rawValue.suffix(4))" + (d.isOnline ? " · онлайн" : " · офлайн"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Button("Оновити список інверторів") { Task { await model.rediscover() } }
            }
            Section {
                Picker("Оновлення у застосунку", selection: $model.settings.refreshInterval) {
                    ForEach(AccountSettings.refreshIntervalChoices, id: \.self) { seconds in
                        Text(seconds == AccountSettings.defaultRefreshInterval
                             ? "\(Int(seconds / 60)) хв (рекомендовано)" : "\(Int(seconds / 60)) хв")
                            .tag(seconds)
                    }
                }
                .onChange(of: model.settings.refreshInterval) { _, _ in
                    Task { await AppEnvironment.saveSettings(model.settings) }
                }
            } header: {
                Text("Оновлення")
            } footer: {
                Text("Deye рекомендує опитувати не частіше ніж раз на 1–2 хв і не більше 60 запитів на хвилину; застосунок тримає запас (до 50/хв). Самі дані в Deye оновлюються приблизно раз на 5 хв. У фоні iOS сама вирішує, коли оновлювати застосунок і віджети, тож дані на віджеті можуть запізнюватися. Відключення, пропущені у фоні, відновлюються з історії Deye при наступному оновленні.")
            }
            NotificationStatusSection()
            CredentialsSection()
        }
        .navigationTitle("Налаштування")
    }
}

struct InverterProfileView: View {
    @Environment(AppModel.self) private var model
    @State var profile: InverterProfile
    let descriptor: InverterDescriptor

    var body: some View {
        Form {
            Section("Назва") {
                TextField(descriptor.displayName, text: Binding(
                    get: { profile.customName ?? "" },
                    set: { profile.customName = $0.trimmed.isEmpty ? nil : $0 }
                ))
            }
            Section {
                Stepper(value: $profile.battery.capacityKWh, in: 1...100, step: 0.5) {
                    LabeledContent("Ємність", value: String(format: "%.1f kWh", profile.battery.capacityKWh))
                }
                Button("Розрахувати з Ah (51.2 V)") { showAh = true }
                Stepper(value: $profile.battery.minimumSOC, in: 0...80, step: 5) {
                    LabeledContent("Мінімальний SOC", value: "\(Int(profile.battery.minimumSOC))%")
                }
            } header: {
                Text("Батарея")
            } footer: {
                Text("Прогноз автономності рахується до мінімального SOC.")
            }
            Section {
                Toggle("Світло зникло", isOn: $profile.notificationSettings.gridOff)
                Toggle("Світло повернулось", isOn: $profile.notificationSettings.gridOn)
                Toggle("Низький заряд", isOn: $profile.notificationSettings.lowBattery)
                if profile.notificationSettings.lowBattery {
                    Stepper(value: $profile.notificationSettings.lowBatterySOC,
                            in: (profile.battery.minimumSOC + 5)...90, step: 5) {
                        LabeledContent("Поріг", value: "\(Int(profile.notificationSettings.lowBatterySOC))%")
                    }
                }
                Toggle("Критичний заряд (мінімальний SOC)", isOn: $profile.notificationSettings.criticalBattery)
            } header: {
                Text("Сповіщення")
            } footer: {
                Text("Про заряд сповіщення приходять лише під час роботи від батареї. Повторно — коли заряд підніметься на 5% вище порогу.")
            }
            Section {
                Stepper(value: $profile.gridVoltageThreshold, in: 100...210, step: 5) {
                    LabeledContent("Поріг напруги", value: "\(Int(profile.gridVoltageThreshold)) V")
                }
                Picker("Часовий пояс", selection: $profile.timeZoneIdentifier) {
                    ForEach(["Europe/Kyiv", "Europe/Warsaw", "Europe/Berlin", "UTC"], id: \.self) { Text($0).tag($0) }
                }
            } header: {
                Text("Мережа")
            } footer: {
                Text("Мережа вважається відсутньою, коли реле інвертора розімкнене (Break) або напруга нижча за поріг. Часовий пояс визначає межі «сьогодні».")
            }
            if let tz = descriptor.stationTimeZone, tz != profile.timeZoneIdentifier {
                Section {
                    Text("У Deye для станції вказано \(tz). Застосунок використовує часовий пояс, вибраний вище.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(model.name(for: descriptor.id))
        .onDisappear { model.update(profile) }
        .alert("Ємність в Ah", isPresented: $showAh) {
            TextField("300", text: $ahText).keyboardType(.numberPad)
            Button("Застосувати") {
                if let ah = Double(ahText), ah > 0 { profile.battery = .fromAmpHours(ah, minimumSOC: profile.battery.minimumSOC) }
            }
            Button("Скасувати", role: .cancel) {}
        }
    }

    @State private var showAh = false
    @State private var ahText = ""
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

struct NotificationStatusSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section {
            switch model.notificationStatus {
            case .authorized, .provisional, .ephemeral:
                Label("Сповіщення увімкнено", systemImage: "bell.badge")
                Button("Надіслати тестове сповіщення") {
                    Task {
                        await NotificationDelivery.deliver([EnergyNotification(
                            id: "test-\(Date().timeIntervalSince1970)", kind: .gridOff,
                            inverterId: model.selectedId ?? InverterID("test"),
                            title: "Energy Monitor: тест",
                            body: "Так виглядатимуть сповіщення про світло й заряд батареї.")])
                    }
                }
            case .denied:
                Label("Сповіщення вимкнено в налаштуваннях iOS", systemImage: "bell.slash")
                    .foregroundStyle(.orange)
                Button("Відкрити налаштування iOS") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                }
            default:
                Button("Дозволити сповіщення") { Task { await model.requestNotificationsIfNeeded() } }
            }
        } header: {
            Text("Сповіщення")
        } footer: {
            Text("Без власного сервера сповіщення з'являються, коли iOS запускає застосунок, віджет або фонове оновлення, тож можуть запізнюватися на хвилини чи години. Якщо подію виявлено пізно, у тексті буде її справжній час. Що саме сповіщати, налаштовується для кожного інвертора.")
        }
        .task { await model.refreshNotificationStatus() }
    }
}
