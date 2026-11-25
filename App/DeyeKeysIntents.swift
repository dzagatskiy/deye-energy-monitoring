import AppIntents
import EnergyCore
import Foundation

/// "Зберегти ключі Deye": a Shortcuts action that finds AppId / AppSecret in any text and stores them
/// in the Keychain. Deye has no API that creates or returns developer keys (docs/deye-app-credentials.md),
/// so the automation reads them from what the user already sees: the application page on
/// developer.deyecloud.com (Safari → Share → shortcut with "Run JavaScript on Web Page"),
/// the clipboard, or a note. Setup: docs/shortcuts.md.
struct ImportDeyeKeysIntent: AppIntent {
    static let title: LocalizedStringResource = "Зберегти ключі Deye"
    static let description = IntentDescription(
        "Знаходить AppId і AppSecret у тексті (сторінка застосунку на developer.deyecloud.com, буфер обміну, нотатка) і зберігає їх у Energy Monitor.",
        categoryName: "Deye Cloud"
    )
    static let openAppWhenRun = false

    @Parameter(
        title: "Текст з ключами",
        description: "Текст сторінки порталу, буфер обміну або будь-який текст, де є AppId і AppSecret.",
        requestValueDialog: "Вставте текст, де є AppId і AppSecret",
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Зберегти ключі Deye з \(\.$text)")
    }

    init() {}

    init(text: String) {
        self.text = text
    }

    /// Returns the masked AppId (`…1234`), never the keys themselves, so they do not end up
    /// in Shortcuts history or in the next action's input.
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let keys: DeyeAppCredentials
        do {
            keys = try DeyeAppCredentialsParser.credentials(from: text)
        } catch {
            throw ImportDeyeKeysError(error)
        }
        let masked = keys.appId.maskedTail

        if let current = Keychain.loadAppKeys(), current.source == .keychain {
            if current.keys == keys {
                return .result(value: masked, dialog: "Ці ключі вже збережено (AppId \(masked)).")
            }
            // Replacing keys drops the token bound to the old application.
            let question = IntentDialog("Замінити ключі Deye (AppId \(current.keys.appId.maskedTail)) на AppId \(masked)?")
            if #available(iOS 18, *) {
                try await requestConfirmation(actionName: .set, dialog: question)
            } else {
                // iOS 17: generic "Continue?" prompt (the dialog-taking variant is deprecated).
                try await requestConfirmation()
            }
        }

        Keychain.saveAppKeys(keys)
        return .result(value: masked, dialog: "Ключі Deye збережено (AppId \(masked)). Відкрийте Energy Monitor, щоб увійти.")
    }
}

struct ImportDeyeKeysError: Error, CustomLocalizedStringResourceConvertible {
    let reason: DeyeAppCredentialsParser.ImportError

    init(_ reason: DeyeAppCredentialsParser.ImportError) {
        self.reason = reason
    }

    var localizedStringResource: LocalizedStringResource {
        switch reason {
        case .emptyInput:
            "Текст порожній. Передайте в дію текст сторінки застосунку з developer.deyecloud.com або скопійовані ключі."
        case .missingAppId:
            "AppId не знайдено. Відкрийте сторінку свого застосунку на developer.deyecloud.com (не сторінку входу чи список) і запустіть команду ще раз."
        case .missingAppSecret:
            "AppId знайдено, а AppSecret ні. Якщо на порталі секрет приховано, спершу натисніть «показати», а тоді запустіть команду ще раз."
        case .implausible:
            "Знайдені значення не схожі на ключі Deye. Нічого не збережено."
        }
    }
}

struct EnergyMonitorShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ImportDeyeKeysIntent(),
            phrases: [
                "Зберегти ключі Deye в \(.applicationName)",
                "Save Deye keys in \(.applicationName)",
            ],
            shortTitle: "Ключі Deye",
            systemImageName: "key.fill"
        )
    }
}
