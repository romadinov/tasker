import Foundation
import Security

public enum TaskerConfig {
    public static let cloudContainer = "iCloud.com.romadinov.tasker"
    /// CloudKit environment this build talks to. Xcode Debug builds use Development; archived builds
    /// (TestFlight, App Store, Developer ID) use Production. They are separate databases.
    public static var cloudEnvironment: String {
        #if DEBUG
        return "Development"
        #else
        return "Production"
        #endif
    }
    public static let appGroup = "group.com.romadinov.tasker"
    /// Posted (Darwin notification) by extensions after writing to the shared database.
    public static let externalChangeNotification = "com.romadinov.tasker.external-change"

    /// iOS: the app group container, shared with the share extension.
    /// macOS: ~/Library/Application Support/Throughline.
    public static func databaseURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["TASKER_DB"] { return URL(fileURLWithPath: override) }
        #if os(iOS)
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            return group.appendingPathComponent("Tasker/tasker.sqlite")
        }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Tasker/tasker.sqlite")
    }

    /// CKContainer traps when the iCloud entitlement is missing (unsigned/ad-hoc builds),
    /// so sync is only started when the binary is actually entitled.
    public static var cloudKitAvailable: Bool {
        if ProcessInfo.processInfo.environment["TASKER_NO_SYNC"] != nil { return false }
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil) != nil
        #else
        // iOS can't read its own entitlements, but the app group and iCloud entitlements are always
        // signed in together: an unsigned (e.g. simulator CI) build has neither, and CKContainer would trap.
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) != nil
        #endif
    }

    public static func postExternalChange() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(externalChangeNotification as CFString), nil, nil, true)
    }
}
