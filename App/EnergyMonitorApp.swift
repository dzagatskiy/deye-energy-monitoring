import EnergyCore
import SwiftUI
import UserNotifications

@main
struct EnergyMonitorApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    private let notificationDelegate = ForegroundNotificationDelegate()

    init() {
        UNUserNotificationCenter.current().delegate = notificationDelegate
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { AppModel.scheduleBackgroundRefresh() }
        }
        .backgroundTask(.appRefresh(AppEnvironment.backgroundTaskId)) {
            await AppModel.backgroundRefresh()
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch model.phase {
            case .setupKeys:
                NavigationStack { DeveloperKeysView(mode: .onboarding) }
            case .login:
                NavigationStack { LoginView() }
            case .ready:
                TabView {
                    NavigationStack { DashboardView() }
                        .tabItem { Label("Огляд", systemImage: "bolt.fill") }
                    NavigationStack { OutagesView() }
                        .tabItem { Label("Відключення", systemImage: "bolt.slash") }
                    NavigationStack { SettingsView() }
                        .tabItem { Label("Налаштування", systemImage: "gearshape") }
                }
            }
        }
        .task { await model.load() }
        // Ask for notification permission once the user has data to be notified about.
        .task(id: model.phase) {
            if model.phase == .ready { await model.requestNotificationsIfNeeded() }
        }
        // Foreground polling; stops when the app leaves the foreground.
        .task(id: "\(scenePhase)-\(model.phase)") {
            guard scenePhase == .active, model.phase == .ready else { return }
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(model.settings.effectiveRefreshInterval))
            }
        }
    }
}

/// Shows banners even while the app is open (otherwise iOS silently drops them in the foreground).
final class ForegroundNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
