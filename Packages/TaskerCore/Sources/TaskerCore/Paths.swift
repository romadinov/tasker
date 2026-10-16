import Foundation
import Security

public enum TaskerConfig {
    public static let cloudContainer = "iCloud.com.romadinov.tasker"
    public static let appGroup = "group.com.romadinov.tasker"
    /// Posted (Darwin notification) by extensions after writing to the shared database.
    public static let externalChangeNotification = "com.romadinov.tasker.external-change"

    /// iOS: the app group container, shared with the share extension.
    /// macOS: ~/Library/Application Support/Tasker.
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
        return true
        #endif
    }

    public static func postExternalChange() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(externalChangeNotification as CFString), nil, nil, true)
    }
}
