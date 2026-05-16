import Foundation
import AppKit

// Thin wrapper around AppleScript / Apple Events used to drive Safari's
// JavaScript context. We use this only for the SmartThings token-refresh
// flow — see SmartThingsTokenAutomation for the actual choreography.
//
// Requires:
//  - Safari → Settings → Advanced → "Show Develop menu in menu bar" → ON
//  - Safari → Develop → "Allow JavaScript from Apple Events" → ON
//  - macOS Automation permission for OctopusSync → Safari (granted on first use)
//  - Entitlement: com.apple.security.automation.apple-events + scripting-targets
enum SafariAutomation {

    enum AutomationError: LocalizedError {
        case scriptError(String, Int)
        case noResult
        case jsThrew(String)

        var errorDescription: String? {
            switch self {
            case let .scriptError(msg, code): return "AppleScript error \(code): \(msg)"
            case .noResult:                   return "AppleScript returned no value."
            case let .jsThrew(msg):           return "JavaScript error: \(msg)"
            }
        }
    }

    /// Activates Safari and navigates the front document to `url`. Creates a
    /// new document if Safari has no windows. Returns once the navigation has
    /// been issued — page load is the caller's problem (use `waitForJS`).
    static func openURL(_ url: String) async throws {
        // `launch` (not `activate`) starts Safari without bringing it forward
        // and crucially blocks until the process is alive. Without it, the
        // very next `set URL of front document` fails with -600 if Safari
        // was not already running. We then `activate` to surface the window
        // and give the launched process a moment to mount its menu/AE port.
        let script = """
        tell application "Safari"
            launch
            activate
        end tell
        """
        _ = try run(script)

        // Wait until Safari is reachable via Apple Events. `launch` returns
        // when the process exists, but the scripting bridge may not respond
        // immediately on a cold start.
        let probe = "tell application \"Safari\" to return (count of windows)"
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if (try? run(probe)) != nil { break }
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        let nav = """
        tell application "Safari"
            if (count of windows) = 0 then
                make new document with properties {URL:\"\(escape(url))\"}
            else
                set URL of front document to \"\(escape(url))\"
            end if
        end tell
        """
        _ = try run(nav)
    }

    /// Executes JavaScript in the front document and returns the result as
    /// a String. Returns nil if the JS evaluated to null/undefined.
    /// Throws if AppleScript itself fails (e.g. no front document, automation
    /// not permitted, JS engine threw).
    @discardableResult
    static func runJS(_ js: String) throws -> String? {
        // Wrap caller's JS so we can distinguish "returned nothing" from
        // "threw" — without this, a JS exception silently becomes nil.
        let wrapped = """
        (function(){
            try {
                var __r = (function(){\(js)})();
                if (__r === undefined || __r === null) return "";
                return String(__r);
            } catch(e) {
                return "__OCTOPUS_JS_ERROR__:" + (e && e.message ? e.message : String(e));
            }
        })();
        """
        let escaped = escape(wrapped)
        let script = """
        tell application "Safari"
            do JavaScript \"\(escaped)\" in front document
        end tell
        """
        let result = try run(script)
        let s = result.stringValue ?? ""
        if s.hasPrefix("__OCTOPUS_JS_ERROR__:") {
            throw AutomationError.jsThrew(String(s.dropFirst("__OCTOPUS_JS_ERROR__:".count)))
        }
        return s.isEmpty ? nil : s
    }

    /// Polls a JS predicate until it returns truthy or the deadline expires.
    /// The predicate runs every `interval` seconds. Returns the last truthy
    /// string value (often useful as a sentinel). Throws on timeout.
    static func waitForJS(_ predicateJS: String,
                          timeout: TimeInterval = 15,
                          interval: TimeInterval = 0.5) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let s = try runJS(predicateJS), !s.isEmpty, s != "false", s != "0" {
                return s
            }
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        throw AutomationError.scriptError("Timed out waiting for: \(predicateJS.prefix(80))…", -1)
    }

    /// Returns the URL of Safari's front document, or nil if none.
    static func frontURL() throws -> String? {
        let script = """
        tell application "Safari"
            if (count of windows) = 0 then return ""
            return URL of front document
        end tell
        """
        let s = try run(script).stringValue ?? ""
        return s.isEmpty ? nil : s
    }

    /// Returns URLs of all open Safari tabs across all windows (one per tab).
    static func allTabURLs() throws -> [String] {
        let script = """
        tell application "Safari"
            set urls to {}
            repeat with w in windows
                repeat with t in tabs of w
                    set end of urls to URL of t
                end repeat
            end repeat
            return urls
        end tell
        """
        let desc = try run(script)
        guard desc.descriptorType == typeAEList else { return [] }
        var urls: [String] = []
        for i in 1...max(desc.numberOfItems, 0) {
            if let item = desc.atIndex(i), let s = item.stringValue {
                urls.append(s)
            }
        }
        return urls
    }

    /// Brings the tab whose URL contains `match` to the front. Returns false
    /// if no matching tab was found.
    @discardableResult
    static func focusTabContaining(_ match: String) throws -> Bool {
        let escaped = escape(match)
        let script = """
        tell application "Safari"
            repeat with w in windows
                set ti to 0
                repeat with t in tabs of w
                    set ti to ti + 1
                    if URL of t contains \"\(escaped)\" then
                        set current tab of w to t
                        set index of w to 1
                        return "1"
                    end if
                end repeat
            end repeat
            return ""
        end tell
        """
        return (try run(script).stringValue ?? "").isEmpty == false
    }

    /// Closes any tab whose URL contains `match`, across all windows. If
    /// closing the last tab in a window would leave Safari empty, we close
    /// the entire window — Safari handles this gracefully and won't quit
    /// unless it was the last window AND the user has "close last window
    /// quits" enabled (off by default).
    @discardableResult
    static func closeTabsContaining(_ match: String) throws -> Int {
        let escaped = escape(match)
        let script = """
        tell application "Safari"
            set closed to 0
            repeat with w in windows
                set toClose to {}
                repeat with t in tabs of w
                    if URL of t contains \"\(escaped)\" then
                        set end of toClose to t
                    end if
                end repeat
                repeat with t in toClose
                    close t
                    set closed to closed + 1
                end repeat
            end repeat
            return (closed as string)
        end tell
        """
        return Int(try run(script).stringValue ?? "0") ?? 0
    }

    /// Closes the front tab. Used to tidy up the Google consent tab once we've
    /// observed its redirect-back URL.
    static func closeFrontTab() throws {
        _ = try run("""
        tell application "Safari"
            if (count of windows) > 0 then
                tell front window
                    if (count of tabs) > 1 then
                        close current tab
                    end if
                end tell
            end if
        end tell
        """)
    }

    // MARK: - Internals

    private static func run(_ source: String) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: source) else {
            throw AutomationError.scriptError("Failed to compile script", -2)
        }
        var errInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errInfo)
        if let err = errInfo {
            let msg  = err[NSAppleScript.errorMessage] as? String ?? "unknown"
            let code = err[NSAppleScript.errorNumber]  as? Int    ?? -1
            throw AutomationError.scriptError(msg, code)
        }
        return descriptor
    }

    /// Escapes a string for inclusion inside an AppleScript double-quoted literal.
    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
