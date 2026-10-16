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
        let task = application.beginBackgroundTask(withName: "Tasker sync")
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
