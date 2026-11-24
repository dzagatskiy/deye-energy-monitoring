import BackgroundTasks
import EnergyCore
import Foundation
import Observation
import UserNotifications
import WidgetKit

@MainActor
@Observable
final class AppModel {
    var settings = AccountSettings()
    var snapshots: [InverterID: EnergySnapshot] = [:]
    var appKeys: DeyeAppCredentials?
    var appKeysSource: AppKeysSource?
    var account: DeyeAccount?
    /// Token expired (or was revoked) and the password is not remembered.
    var needsLogin = false
    var isRefreshing = false
    var message: String?
    var notificationStatus: UNAuthorizationStatus = .notDetermined

    enum Phase { case setupKeys, login, ready }

    var phase: Phase {
        if appKeys == nil { return .setupKeys }
        if account == nil || needsLogin || settings.inverters.isEmpty { return .login }
        return .ready
    }

    var selectedId: InverterID? { settings.resolve(nil) }
    var selectedSnapshot: EnergySnapshot? { selectedId.flatMap { snapshots[$0] } }

    func load() async {
        settings = await AppEnvironment.loadSettings()
        if !AccountSettings.refreshIntervalChoices.contains(settings.refreshInterval) {
            // Older builds allowed 30 s; snap to the nearest allowed value.
            settings.refreshInterval = AccountSettings.refreshIntervalChoices
                .min { abs($0 - settings.effectiveRefreshInterval) < abs($1 - settings.effectiveRefreshInterval) }!
            await AppEnvironment.saveSettings(settings)
        }
        reloadAuth()
        guard let service = AppEnvironment.refreshService(settings: settings) else { return }
        for d in settings.inverters {
            if let cached = await service.cachedSnapshot(d.id, settings: settings) { snapshots[d.id] = cached }
        }
    }

    func reloadAuth() {
        let keys = Keychain.loadAppKeys()
        appKeys = keys?.keys
        appKeysSource = keys?.source
        account = Keychain.loadAccount()
        if let account, !account.remembersPassword, !Keychain.hasValidToken { needsLogin = true }
    }

    /// Refreshes all inverters (one cloud call for latest, history backfill when due) and reloads widgets.
    /// - Parameter force: pull-to-refresh: skip the shared fetch cache (still within Deye's rate limit).
    func refresh(force: Bool = false) async {
        guard !isRefreshing, let service = AppEnvironment.refreshService(settings: settings) else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let ids = settings.inverters.map(\.id)
        let result = await service.refresh(ids, settings: settings, cache: force ? .bypass : .default)
        snapshots.merge(result) { _, new in new }
        message = result.values.compactMap(\.lastError).first
        if message == RefreshService.describe(DataSourceError.loginRequired) { needsLogin = true }
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: Developer keys

    /// Stores AppId/AppSecret in the Keychain. They are verified on the next login (Deye has no endpoint
    /// that checks keys without an account).
    func saveAppKeys(_ keys: DeyeAppCredentials) {
        Keychain.saveAppKeys(keys)
        reloadAuth()
        message = nil
    }

    func resetAppKeys() {
        Keychain.saveAppKeys(nil)
        reloadAuth()
    }

    // MARK: Account

    /// Logs in, discovers inverters and stores the account. With `remember == false` only the token
    /// is kept (~60 days); after that the user is asked for the password again.
    func login(email: String, password: String, region: DeyeRegion, remember: Bool) async {
        guard let appKeys else { return }
        let hash = DeyeAccount.hash(password)
        let credentials = DeyeCloudCredentials(app: appKeys, account: DeyeAccount(email: email, passwordSHA256: hash))
        Keychain.saveToken(nil)
        do {
            let inverters = try await AppEnvironment.cloudClient(region: region, credentials: credentials).inverters()
            guard !inverters.isEmpty else {
                message = "В акаунті не знайдено жодного інвертора"
                return
            }
            Keychain.saveAccount(DeyeAccount(email: email, passwordSHA256: remember ? hash : nil))
            settings.region = region
            settings.updateInverters(inverters)
            await AppEnvironment.saveSettings(settings)
            needsLogin = false
            message = nil
            reloadAuth()
            await refresh()
        } catch DataSourceError.unauthorized {
            message = "Deye Cloud не прийняв дані. Перевірте email, пароль, регіон і ключі AppId/AppSecret."
        } catch {
            message = RefreshService.describe(error)
        }
    }

    /// Keeps the session (token) but removes the stored password hash.
    func forgetPassword() {
        guard var account else { return }
        account.passwordSHA256 = nil
        Keychain.saveAccount(account)
        reloadAuth()
    }

    func rediscover() async {
        guard let credentials = Keychain.cloudCredentials() else { return }
        do {
            let inverters = try await AppEnvironment.cloudClient(region: settings.region, credentials: credentials).inverters()
            settings.updateInverters(inverters)
            await AppEnvironment.saveSettings(settings)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            message = RefreshService.describe(error)
        }
    }

    /// Removes the account and token; developer keys stay (they are not tied to a person).
    func signOut() async {
        Keychain.signOut()
        snapshots = [:]
        needsLogin = false
        settings = AccountSettings(region: settings.region)
        await AppEnvironment.saveSettings(settings)
        reloadAuth()
        WidgetCenter.shared.reloadAllTimelines()
    }

    func select(_ id: InverterID) {
        settings.selectedInverter = id
        Task { await AppEnvironment.saveSettings(settings) }
    }

    func update(_ profile: InverterProfile) {
        if let i = settings.profiles.firstIndex(where: { $0.id == profile.id }) {
            settings.profiles[i] = profile
        } else {
            settings.profiles.append(profile)
        }
        Task {
            await AppEnvironment.saveSettings(settings)
            await load()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    // MARK: Notifications

    func refreshNotificationStatus() async {
        notificationStatus = await NotificationDelivery.authorizationStatus()
    }

    /// Asks once (iOS shows the system prompt only while the status is `.notDetermined`).
    func requestNotificationsIfNeeded() async {
        await refreshNotificationStatus()
        guard notificationStatus == .notDetermined else { return }
        await NotificationDelivery.requestAuthorization()
        await refreshNotificationStatus()
    }

    func outages(for id: InverterID, days: Int) async -> [Outage] {
        guard let service = AppEnvironment.refreshService(settings: settings) else { return [] }
        let now = Date()
        return await service.outages(id, in: DateInterval(start: now.addingTimeInterval(-Double(days) * 86_400), end: now), now: now)
    }

    func name(for id: InverterID) -> String {
        settings.profile(for: id).customName ?? settings.descriptor(for: id)?.displayName ?? id.rawValue
    }

    // MARK: Background

    nonisolated static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: AppEnvironment.backgroundTaskId)
        request.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Runs inside the BGAppRefreshTask; iOS decides when (not guaranteed).
    nonisolated static func backgroundRefresh() async {
        scheduleBackgroundRefresh()
        let settings = await AppEnvironment.loadSettings()
        guard let service = AppEnvironment.refreshService(settings: settings) else { return }
        await service.refresh(settings.inverters.map(\.id), settings: settings)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
