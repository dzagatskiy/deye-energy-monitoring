import EnergyCore
import SwiftUI

/// Step-by-step way to get AppId/AppSecret. Deye has no API to create an application,
/// so the user creates it on the portal once and pastes the keys back (docs/deye-app-credentials.md).
struct DeveloperKeysView: View {
    enum Mode { case onboarding, edit }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let mode: Mode

    @State private var appId = ""
    @State private var appSecret = ""
    @State private var showSecret = false
    @State private var pasteHint: String?

    private var keys: DeyeAppCredentials { DeyeAppCredentials(appId: appId, appSecret: appSecret) }

    var body: some View {
        Form {
            Section {
                Step(number: 1, text: "Відкрийте портал розробника Deye і увійдіть тим самим акаунтом, що й у застосунку Deye Cloud.")
                Button {
                    openURL(AppEnvironment.developerPortalURL)
                } label: {
                    Label("Відкрити developer.deyecloud.com", systemImage: "safari")
                }
                Step(number: 2, text: "Створіть Application (назва довільна, наприклад «Energy Monitor»).")
                Step(number: 3, text: "Скопіюйте AppId і AppSecret (можна разом, одним шматком тексту), поверніться сюди й натисніть «Вставити».")
            } header: {
                Text("Ключі розробника — один раз")
            } footer: {
                Text("Deye видає ключі лише через портал: створити їх автоматично з застосунку неможливо.")
            }

            Section {
                PasteButton(payloadType: String.self) { strings in
                    applyPasted(strings.joined(separator: "\n"))
                }
                .labelStyle(.titleAndIcon)
                if let pasteHint {
                    Text(pasteHint).font(.footnote).foregroundStyle(.secondary)
                }
                TextField("AppId", text: $appId)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.body.monospaced())
                HStack {
                    Group {
                        if showSecret {
                            TextField("AppSecret", text: $appSecret)
                        } else {
                            SecureField("AppSecret", text: $appSecret)
                        }
                    }
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.body.monospaced())
                    Button {
                        showSecret.toggle()
                    } label: {
                        Image(systemName: showSecret ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(showSecret ? "Сховати" : "Показати")
                }
            } header: {
                Text("AppId і AppSecret")
            } footer: {
                if !appId.isEmpty || !appSecret.isEmpty, !keys.isPlausible {
                    Text("Схоже, ключі неповні: AppId — щонайменше 6 символів, AppSecret — щонайменше 16, без пробілів.")
                        .foregroundStyle(.orange)
                } else {
                    Text("Зберігаються в Keychain цього iPhone і доступні віджету. Перевіряються під час входу.")
                }
            }

            Section {
                Button("Зберегти ключі") {
                    model.saveAppKeys(keys)
                    if mode == .edit { dismiss() }
                }
                .disabled(!keys.isPlausible)
                if mode == .edit, model.appKeysSource == .keychain {
                    Button("Видалити збережені ключі", role: .destructive) {
                        model.resetAppKeys()
                        dismiss()
                    }
                }
            } footer: {
                if model.appKeysSource == .bundled {
                    Text("У цю збірку вже вбудовані ключі (Config/Secrets.xcconfig). Збережені тут ключі матимуть пріоритет.")
                }
            }
        }
        .navigationTitle(mode == .onboarding ? "Підключення Deye" : "Ключі розробника")
        .onAppear {
            if appId.isEmpty, let current = model.appKeys, model.appKeysSource == .keychain {
                appId = current.appId
                appSecret = current.appSecret
            }
        }
    }

    private func applyPasted(_ text: String) {
        let parsed = DeyeAppCredentialsParser.parse(text)
        if let id = parsed.appId { appId = id }
        if let secret = parsed.appSecret { appSecret = secret }
        switch (parsed.appId, parsed.appSecret) {
        case (.some, .some): pasteHint = "Знайдено AppId і AppSecret. Перевірте й збережіть."
        case (.some, nil): pasteHint = "Знайдено лише AppId. Скопіюйте ще AppSecret і вставте знову."
        case (nil, .some): pasteHint = "Знайдено лише AppSecret. Скопіюйте ще AppId і вставте знову."
        case (nil, nil): pasteHint = "У скопійованому тексті ключів не знайдено."
        }
    }
}

private struct Step: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.accentColor, in: Circle())
            Text(text).font(.subheadline)
        }
    }
}

/// Deye Cloud account login. Developer keys live in their own screen (Settings → Ключі розробника).
struct LoginView: View {
    @Environment(AppModel.self) private var model
    @State private var email = ""
    @State private var password = ""
    @State private var region = DeyeRegion.eu
    @State private var remember = true
    @State private var busy = false
    @State private var editingKeys = false

    var body: some View {
        Form {
            if model.needsLogin {
                Section {
                    Label("Сесія Deye Cloud завершилась. Введіть пароль, щоб продовжити оновлення даних і віджетів.",
                          systemImage: "clock.badge.exclamationmark")
                        .font(.subheadline)
                }
            }
            Section("Акаунт Deye Cloud") {
                TextField("Email", text: $email)
                    .keyboardType(.emailAddress).textContentType(.username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Пароль", text: $password).textContentType(.password)
                Picker("Регіон", selection: $region) {
                    Text("Європа").tag(DeyeRegion.eu)
                    Text("Америка").tag(DeyeRegion.us)
                    Text("Індія").tag(DeyeRegion.india)
                }
            }
            Section {
                Toggle("Запам'ятати пароль", isOn: $remember)
            } footer: {
                Text(remember
                     ? "У Keychain зберігається лише SHA-256 пароля (у такому вигляді його приймає Deye). Застосунок і віджет самі поновлюють доступ."
                     : "Зберігається лише токен доступу (~60 днів). Коли він закінчиться, застосунок попросить пароль знову, а віджет до того часу показуватиме останні дані.")
            }
            Section {
                Button {
                    busy = true
                    Task {
                        await model.login(email: email, password: password, region: region, remember: remember)
                        password = ""
                        busy = false
                    }
                } label: {
                    HStack {
                        Text("Увійти")
                        if busy { Spacer(); ProgressView() }
                    }
                }
                .disabled(busy || email.trimmed.isEmpty || password.isEmpty)
            } footer: {
                if let message = model.message { Text(message).foregroundStyle(.red) }
            }
            Section {
                Button {
                    editingKeys = true
                } label: {
                    LabeledContent("Ключі розробника", value: "AppId \(model.appKeys?.appId.maskedTail ?? "—")")
                }
            }
        }
        .navigationTitle("Вхід")
        .onAppear {
            if email.isEmpty, let account = model.account { email = account.email }
            region = model.settings.region
            remember = model.account?.remembersPassword ?? true
        }
        .sheet(isPresented: $editingKeys) {
            NavigationStack { DeveloperKeysView(mode: .edit) }
        }
    }
}

/// Settings section: what is stored and how to change it.
struct CredentialsSection: View {
    @Environment(AppModel.self) private var model
    @State private var confirmSignOut = false

    var body: some View {
        Section {
            LabeledContent("Акаунт", value: model.account?.email ?? "—")
            LabeledContent("Пароль", value: model.account?.remembersPassword == true ? "збережено (SHA-256)" : "не збережено")
            if model.account?.remembersPassword == true {
                Button("Забути пароль") { model.forgetPassword() }
            }
            NavigationLink {
                DeveloperKeysView(mode: .edit)
            } label: {
                LabeledContent("Ключі розробника",
                               value: "AppId \(model.appKeys?.appId.maskedTail ?? "—")" + (model.appKeysSource == .bundled ? " · вбудовані" : ""))
            }
            Button("Вийти з акаунта", role: .destructive) { confirmSignOut = true }
        } header: {
            Text("Deye Cloud")
        } footer: {
            Text("Ключі розробника лишаються після виходу з акаунта, тож для повторного входу потрібні лише email і пароль.")
        }
        .confirmationDialog("Вийти з акаунта Deye Cloud на цьому iPhone?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Вийти", role: .destructive) { Task { await model.signOut() } }
        }
    }
}
