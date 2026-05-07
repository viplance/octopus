import Foundation
import ApplicationServices

class PermissionsHelper {
    static func checkAndPromptAccessibilityPermission() -> Bool {
        // Check without prompting first — only show the system prompt if not yet granted.
        let trusted = AXIsProcessTrusted()
        if !trusted {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
            AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
        return trusted
    }
}
