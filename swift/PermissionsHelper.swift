import Foundation
import ApplicationServices

class PermissionsHelper {
    static func checkAndPromptAccessibilityPermission() -> Bool {
        let checkOptPrompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
        let options = [checkOptPrompt: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
