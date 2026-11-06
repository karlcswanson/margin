import SwiftUI
import UIKit
import UserNotifications

@main
struct MarginApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onAppear {
                    delegate.model = model
                    model.startAll()
                    #if DEBUG
                    // Simulator runs: `simctl launch` with SIMCTL_CHILD_MARGIN_ADD=margin://add?…
                    // pairs without the confirmation sheet; MARGIN_OPEN=slug/session/<id> or
                    // slug/proposal/<id> or slug/ideas/<project> opens a screen (for screenshots).
                    let env = ProcessInfo.processInfo.environment
                    if let s = env["MARGIN_ADD"], let u = URL(string: s) { _ = model.handle(url: u) }
                    if let s = env["MARGIN_OPEN"] {
                        let p = s.split(separator: "/").map(String.init)
                        if p.count == 3, p[1] == "ideas", let ws = model.workspace(slug: p[0]) {
                            model.openRequest = .ideas(workspace: ws.id, project: p[2])
                        } else if p.count == 3 {
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                model.open(slug: p[0], proposalId: p[1] == "proposal" ? p[2] : nil,
                                           sessionId: p[1] == "session" ? p[2] : nil)
                            }
                        }
                    }
                    #endif
                }
                .onOpenURL { _ = model.handle(url: $0) }
                .onChange(of: phase) { _, now in
                    if now == .active { model.workspaces.forEach { $0.wake() } }
                    else { model.workspaces.forEach { $0.saveNow() } }     // keep what's on screen for offline
                }
        }
    }
}

/// Push registration and notification actions (Allow / Deny from the banner or lock screen).
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var model: AppModel?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let allow = UNNotificationAction(identifier: "ALLOW", title: "Allow", options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: "DENY", title: "Deny", options: [.destructive])
        let approval = UNNotificationCategory(identifier: "APPROVAL", actions: [allow, deny], intentIdentifiers: [])
        let result = UNNotificationCategory(identifier: "RESULT", actions: [], intentIdentifiers: [])
        let proposal = UNNotificationCategory(identifier: "PROPOSAL", actions: [], intentIdentifiers: [])
        center.setNotificationCategories([approval, result, proposal])

        #if DEBUG
        // Simulator screenshots: MARGIN_NO_PUSH=1 skips the permission prompt.
        if ProcessInfo.processInfo.environment["MARGIN_NO_PUSH"] != nil { return true }
        #endif
        center.requestAuthorization(options: [.alert, .sound, .badge, .timeSensitive]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async { application.registerForRemoteNotifications() }
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in self.model?.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("APNs registration failed: \(error)")
    }

    // Show banners while the app is open too.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        if action == UNNotificationDefaultActionIdentifier, let slug = info["workspace"] as? String {
            // Tapped the notification: open the proposal or session it's about.
            let proposalId = info["proposal_id"] as? String
            let sessionId = info["session_id"] as? String
            Task { @MainActor in
                self.model?.open(slug: slug, proposalId: proposalId, sessionId: sessionId)
                completionHandler()
            }
            return
        }
        guard let slug = info["workspace"] as? String,
              let requestId = info["request_id"] as? String,
              action == "ALLOW" || action == "DENY" else {
            completionHandler()
            return
        }
        Task { @MainActor in
            // The model may not exist yet if iOS launched us in the background for the action.
            let model = self.model ?? AppModel()
            await model.resolveFromNotification(slug: slug, requestId: requestId, allow: action == "ALLOW")
            completionHandler()
        }
    }
}
