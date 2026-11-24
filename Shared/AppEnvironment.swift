import EnergyCore
import Foundation
import Security

/// Wiring shared by the app and the widget extension: App Group storage, Keychain, refresh service.
enum AppEnvironment {
    static let appGroup = "group.ua.energymonitor"
    static let backgroundTaskId = "ua.energymonitor.refresh"
    static let widgetKind = "EnergyMonitorWidget"
    static let developerPortalURL = URL(string: "https://developer.deyecloud.com/app")!

    /// App Group container; falls back to the process's own Application Support if the entitlement is missing
    /// (then the widget cannot see the app's data, but the app still works).
    static var containerURL: URL {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            return url.appendingPathComponent("EnergyMonitor", isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("EnergyMonitor", isDirectory: true)
    }

    static let store = TelemetryStore(root: containerURL)

    static func loadSettings() async -> AccountSettings {
        await store.load(AccountSettings.self, from: AccountSettings.fileName) ?? AccountSettings()
    }

    static func saveSettings(_ settings: AccountSettings) async {
        try? await store.save(settings, as: AccountSettings.fileName)
    }

    /// - Parameter forWidget: widgets get a short history backfill (they have a few seconds per update).
    static func refreshService(settings: AccountSettings, forWidget: Bool = false) -> RefreshService? {
        guard let credentials = Keychain.cloudCredentials() else { return nil }
        let client = cloudClient(region: settings.region, credentials: credentials, limiter: forWidget ? widgetLimiter : .shared)
        return RefreshService(store: store, maxBackfillDays: forWidget ? 1 : 7, notifier: { await NotificationDelivery.deliver($0) }) { profile in
            // Local Solarman source goes first here once implemented (ADR: local first, cloud fallback).
            [DeyeCloudSource(client: client, profile: profile)]
        }
    }

    static func cloudClient(region: DeyeRegion, credentials: DeyeCloudCredentials, limiter: RequestRateLimiter = .shared) -> DeyeCloudClient {
        DeyeCloudClient(region: region, credentials: credentials, tokenStore: KeychainTokenStore(), limiter: limiter)
    }

    /// The widget has seconds per update: give up quickly instead of waiting for a free request slot.
    /// Smaller budget than the app's, since both processes share Deye's 60/min per application.
    static let widgetLimiter = RequestRateLimiter(limit: 10, maxWait: 5)
}

/// Where the developer keys come from (see docs/deye-app-credentials.md).
enum AppKeysSource: Equatable {
    /// Entered or pasted by the user, stored in the Keychain.
    case keychain
    /// Compiled into this build from Config/Secrets.xcconfig (personal builds only).
    case bundled
}

/// Keychain items in the App Group access group, readable after first unlock
/// (so background refresh and the widget work while the phone is locked).
///
/// Items: `app` (AppId/AppSecret), `account` (email + optional SHA-256 of the password), `token`.
/// The pre-split `credentials` item is migrated on first read.
enum Keychain {
    private static let service = "ua.energymonitor.deye"
    static let appAccount = "app"
    static let userAccount = "account"
    static let tokenAccount = "token"
    private static let legacyAccount = "credentials"

    // MARK: Developer keys

    static func loadAppKeys() -> (keys: DeyeAppCredentials, source: AppKeysSource)? {
        migrateLegacyIfNeeded()
        if let keys = decode(DeyeAppCredentials.self, appAccount) { return (keys, .keychain) }
        if let keys = bundledAppKeys { return (keys, .bundled) }
        return nil
    }

    static func saveAppKeys(_ keys: DeyeAppCredentials?) {
        encode(keys, appAccount)
        // A token is bound to the application that issued it.
        delete(tokenAccount)
    }

    /// `DeyeAppId` / `DeyeAppSecret` from Info.plist, filled from Config/Secrets.xcconfig at build time.
    static var bundledAppKeys: DeyeAppCredentials? {
        let id = Bundle.main.object(forInfoDictionaryKey: "DeyeAppId") as? String ?? ""
        let secret = Bundle.main.object(forInfoDictionaryKey: "DeyeAppSecret") as? String ?? ""
        let keys = DeyeAppCredentials(appId: id, appSecret: secret)
        return keys.isPlausible ? keys : nil
    }

    // MARK: Account

    static func loadAccount() -> DeyeAccount? {
        migrateLegacyIfNeeded()
        return decode(DeyeAccount.self, userAccount)
    }

    static func saveAccount(_ account: DeyeAccount?) {
        encode(account, userAccount)
    }

    static func cloudCredentials() -> DeyeCloudCredentials? {
        guard let app = loadAppKeys()?.keys, let account = loadAccount() else { return nil }
        return DeyeCloudCredentials(app: app, account: account)
    }

    // MARK: Token

    static func loadToken() -> DeyeToken? { decode(DeyeToken.self, tokenAccount) }
    static func saveToken(_ token: DeyeToken?) { encode(token, tokenAccount) }

    static var hasValidToken: Bool { (loadToken()?.expiresAt ?? .distantPast) > Date() }

    static func signOut() {
        delete(userAccount)
        delete(tokenAccount)
    }

    // MARK: Migration

    private static func migrateLegacyIfNeeded() {
        guard let legacy = decode(DeyeCloudCredentials.self, legacyAccount) else { return }
        if decode(DeyeAppCredentials.self, appAccount) == nil { encode(legacy.app, appAccount) }
        if decode(DeyeAccount.self, userAccount) == nil {
            encode(DeyeAccount(email: legacy.email, passwordSHA256: legacy.passwordSHA256), userAccount)
        }
        delete(legacyAccount)
    }

    // MARK: Primitives

    private static func decode<T: Decodable>(_ type: T.Type, _ account: String) -> T? {
        read(account).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    private static func encode<T: Encodable>(_ value: T?, _ account: String) {
        if let value, let data = try? JSONEncoder().encode(value) { write(data, account: account) } else { delete(account) }
    }

    static func read(_ account: String) -> Data? {
        for group in [AppEnvironment.appGroup, nil] as [String?] {
            var query = baseQuery(account, group: group)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecSuccess { return result as? Data }
            if status != errSecMissingEntitlement { return nil }
        }
        return nil
    }

    static func write(_ data: Data, account: String) {
        for group in [AppEnvironment.appGroup, nil] as [String?] {
            SecItemDelete(baseQuery(account, group: group) as CFDictionary)
            var item = baseQuery(account, group: group)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let status = SecItemAdd(item as CFDictionary, nil)
            if status != errSecMissingEntitlement { return }
        }
    }

    static func delete(_ account: String) {
        for group in [AppEnvironment.appGroup, nil] as [String?] {
            SecItemDelete(baseQuery(account, group: group) as CFDictionary)
        }
    }

    private static func baseQuery(_ account: String, group: String?) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let group { q[kSecAttrAccessGroup as String] = group }
        return q
    }
}

struct KeychainTokenStore: DeyeTokenStore {
    func load() async -> DeyeToken? { Keychain.loadToken() }
    func save(_ token: DeyeToken?) async { Keychain.saveToken(token) }
}

extension String {
    /// "…1234" — enough to recognize a key without showing it.
    var maskedTail: String { isEmpty ? "—" : "…\(suffix(4))" }
}
