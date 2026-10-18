import BackgroundTasks
import SwiftUI
import TaskerCore
import UIKit

@main
struct TaskerIOSApp: App {
    @UIApplicationDelegateAdaptor(IOSAppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(AppModel.shared)
                .onOpenURL { url in
                    // tasker://add?… from Scriptorium and other apps.
                    if let r = AddRequest(url: url) { AppModel.shared.handleAdd(r) }
                }
                .overlay(alignment: .top) {
                    if let b = AppModel.shared.banner {
                        Label(b, systemImage: "checkmark.circle.fill")
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(Capsule().fill(.regularMaterial))
                            .padding(.top, 8)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.snappy, value: AppModel.shared.banner)
        }
        .backgroundTask(.appRefresh(IOSAppDelegate.refreshID)) {
            await IOSAppDelegate.scheduleRefresh()
            await AppModel.shared.sync?.syncNow()
        }
    }
}

final class IOSAppDelegate: NSObject, UIApplicationDelegate {
    static let refreshID = "com.romadinov.tasker.refresh"

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        MainActor.assumeIsolated { AppModel.shared.start() }
        application.registerForRemoteNotifications()
        Task { await Self.scheduleRefresh() }
        return true
    }

    /// CloudKit pushes wake the app so changes from the Mac arrive before you open it.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        await AppModel.shared.sync?.syncNow()
        return .newData
    }

    func applicationWillResignActive(_ application: UIApplication) {
        // Give pending uploads a chance to finish when leaving the app.
        let task = application.beginBackgroundTask(withName: "Throughline sync")
        Task {
            await AppModel.shared.sync?.syncNow()
            application.endBackgroundTask(task)
        }
    }

    static func scheduleRefresh() async {
        let req = BGAppRefreshTaskRequest(identifier: refreshID)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(req)
    }
}
