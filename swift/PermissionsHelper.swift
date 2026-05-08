import Foundation
import ApplicationServices
import IOKit.hid

class PermissionsHelper {
    static func checkAndPromptAccessibilityPermission() -> Bool {
        let trusted = AXIsProcessTrusted()
        if !trusted {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
            AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
        return trusted
    }

    // Input Monitoring is REQUIRED for cghidEventTap to actually receive
    // events on macOS 10.15+. Accessibility alone allows tap creation but not
    // event delivery — silently breaking shortcuts and the input capture.
    static func isInputMonitoringGranted() -> Bool {
        let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        return access == kIOHIDAccessTypeGranted
    }

    // Triggers the macOS system prompt for Input Monitoring on first call.
    // Subsequent calls just return the current grant state. The user may need
    // to relaunch the app after granting, because IOKit caches the deny result.
    @discardableResult
    static func requestInputMonitoring() -> Bool {
        return IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }
}
