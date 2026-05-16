import Foundation
import Combine
import AppKit

// Drives the account.smartthings.com/tokens page through Safari to mint a
// fresh 24-hour Personal Access Token, then writes it into MonitorManager's
// config. The user must already be logged into Samsung Account in Safari —
// we don't touch credentials.
//
// Flow (matches the live DOM as of 2026-05):
//  1. Open the tokens page in Safari.
//  2. Wait for the "Generate new token" button (`button.token-new-btn` in
//     the page-level header) and click it. This transitions the SPA to the
//     New Access Token form.
//  3. Wait for `input[name="inputTokenName"]`, fill it with our label.
//  4. Tick the two scope checkboxes we need:
//        #r:devices:*-flexCheckDefault   (See all devices)
//        #x:devices:*-flexCheckDefault   (Control all devices)
//     and dispatch a 'change' event so the React form registers the value.
//  5. Click `button#submit.token-new-btn[type="submit"]`.
//  6. Wait for the result card (`div.w-75.m-3` containing a button with
//     data-testid="copy-token") and extract the token from its first text
//     node.
//
// If anything times out we surface the error and bail — we do *not* leave
// Safari in a half-filled state silently.
@MainActor
final class SmartThingsTokenAutomation: ObservableObject {

    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastRefreshAt: Date?
    // Surface the current step of the flow so the UI shows the user where
    // it's stuck if anything hangs. Cleared on success.
    @Published private(set) var lastStep: String = ""

    private let monitor: MonitorManager
    private var cancellables = Set<AnyCancellable>()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []

    nonisolated static let tokensURL          = "https://account.smartthings.com/tokens"
    nonisolated static let tokenName          = "OctopusSync auto-refresh"
    nonisolated static let requiredScopeIDs   = ["r:devices:*", "x:devices:*"]
    // SmartThings PATs last 24h. We use this only for the expired-token
    // fallback inside refreshIfDue — see that method for the policy.
    nonisolated static let tokenLifetime:    TimeInterval = 24 * 60 * 60

    init(monitor: MonitorManager) {
        self.monitor = monitor

        // Auto-start/stop wake/unlock observers based on the user's preference.
        monitor.$config
            .map(\.autoRefreshTokenEnabled)
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled { self.startScheduler() } else { self.stopScheduler() }
            }
            .store(in: &cancellables)
    }

    deinit {
        // Detach observers from background queues — both NotificationCenter
        // and DistributedNotificationCenter need explicit removal even with
        // ARC, since they retain the token-based observer block.
        let workspace = workspaceObservers
        let distributed = distributedObservers
        let nc = NSWorkspace.shared.notificationCenter
        let dnc = DistributedNotificationCenter.default()
        for obs in workspace { nc.removeObserver(obs) }
        for obs in distributed { dnc.removeObserver(obs) }
    }

    // MARK: - Scheduler

    // Wake/unlock-driven refresh instead of a periodic timer. Rationale:
    // popping Safari open at random points during the workday is disruptive
    // (steals focus, breaks Spaces, etc.). We refresh exactly once per
    // calendar day, on the first wake-from-sleep or screen-unlock event.
    // Apple's NSWorkspace events fire reliably on lid open / Touch ID
    // unlock; the distributed-notification center delivers the lock-screen
    // unlock events on macOS 10.7+.
    func startScheduler() {
        stopScheduler()

        let nc = NSWorkspace.shared.notificationCenter
        let handler: @Sendable (Notification) -> Void = { [weak self] _ in
            let weakSelf = self
            Task { @MainActor in await weakSelf?.refreshIfDue(trigger: "wake/unlock") }
        }
        workspaceObservers.append(nc.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: handler
        ))
        workspaceObservers.append(nc.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main, using: handler
        ))

        // Distributed notifications for screen lock/unlock. Names are stable
        // strings in com.apple.loginwindow; they don't have Swift constants.
        let dnc = DistributedNotificationCenter.default()
        distributedObservers.append(dnc.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil, queue: .main, using: handler
        ))

        // Also run an opportunistic check right now — if the token is missing
        // or expired and the user just enabled the feature, refresh
        // immediately rather than waiting for the next wake.
        Task { await refreshIfDue(trigger: "scheduler started") }
    }

    func stopScheduler() {
        let nc = NSWorkspace.shared.notificationCenter
        for obs in workspaceObservers { nc.removeObserver(obs) }
        workspaceObservers.removeAll()

        let dnc = DistributedNotificationCenter.default()
        for obs in distributedObservers { dnc.removeObserver(obs) }
        distributedObservers.removeAll()
    }

    // MARK: - Refresh

    // Policy:
    //  • If there's no token at all → refresh.
    //  • If the token is already expired (>24h since issued) → refresh
    //    regardless of when last refreshed today. Without this, a missed
    //    morning event leaves the app silently broken.
    //  • Otherwise, refresh only if we haven't refreshed since the start of
    //    the local calendar day. So: first wake/unlock of the day triggers
    //    one refresh; subsequent wakes the same day are no-ops.
    func refreshIfDue(trigger: String) async {
        guard monitor.config.autoRefreshTokenEnabled else { return }

        let issued = monitor.config.tokenIssuedAt
        let now = Date()
        let calendar = Calendar.current

        let hasToken = (issued != nil) && !monitor.config.personalAccessToken.isEmpty
        let isExpired = issued.map { now.timeIntervalSince($0) >= Self.tokenLifetime } ?? true
        let refreshedToday = issued.map { calendar.isDate($0, inSameDayAs: now) } ?? false

        let shouldRefresh: Bool
        let reason: String
        if !hasToken {
            shouldRefresh = true
            reason = "no token stored"
        } else if isExpired {
            shouldRefresh = true
            reason = "token expired (>24h since issue)"
        } else if !refreshedToday {
            shouldRefresh = true
            reason = "first wake/unlock of the day"
        } else {
            shouldRefresh = false
            reason = "already refreshed today"
        }

        AutomationLog.log("refreshIfDue trigger=\(trigger): \(reason) -> shouldRefresh=\(shouldRefresh)")
        guard shouldRefresh else { return }
        await refreshNow()
    }

    /// Forces a refresh regardless of token age. Wired up to the "Refresh now"
    /// button in the UI so the user can test the flow without waiting.
    func refreshNow() async {
        guard !isRunning else { return }
        isRunning = true
        lastError = nil
        lastStep = "starting"
        defer { isRunning = false }

        do {
            let preferredEmail = monitor.config.googleAccountEmail
            // Step reporter — captured into the nonisolated flow via a
            // MainActor-hopping closure. Without this we can't see where the
            // automation is stuck; the previous version was completely opaque.
            let report: @Sendable (String) -> Void = { [weak self] step in
                // Capture weak self once, hand it to the Task. Avoids the
                // Swift 6 "captured var in concurrently-executing code" warn.
                let weakSelf = self
                Task { @MainActor in weakSelf?.lastStep = step }
            }
            let token = try await Self.executeFlow(
                googleAccountEmail: preferredEmail,
                report: report
            )
            monitor.config.personalAccessToken = token
            monitor.config.tokenIssuedAt = Date()
            lastRefreshAt = Date()
            lastStep = ""
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Page flow

    // The DOM-level dance. nonisolated so we can call it from any context —
    // it only touches SafariAutomation (which is itself non-actor-bound).
    nonisolated static func executeFlow(
        googleAccountEmail: String = "",
        report: @Sendable (String) -> Void = { _ in }
    ) async throws -> String {
        AutomationLog.log("=== executeFlow start (googleAccountEmail=\(googleAccountEmail.isEmpty ? "<empty>" : googleAccountEmail)) ===")
        report("opening tokens page")
        AutomationLog.log("step: opening tokens page (\(tokensURL))")
        try await SafariAutomation.openURL(tokensURL)

        // SmartThings may bounce us through Samsung's IAM if the session
        // expired. Detect that and run the Google SSO flow before continuing.
        report("checking login")
        AutomationLog.log("step: checking login")
        try await ensureLoggedIn(googleAccountEmail: googleAccountEmail)

        // Even if we're already on a /tokens/new from a previous half-done
        // run, force navigation back to /tokens. Operating on a stale form
        // gives random results — better to re-enter the flow cleanly.
        report("navigating to /tokens")
        AutomationLog.log("step: navigating to /tokens (clean entry)")
        try await SafariAutomation.openURL(tokensURL)

        // Wait for the LIST page to mount. Indicator: a top-level Generate
        // button that's not part of the create form (i.e. no id="submit").
        report("waiting for list page")
        AutomationLog.log("step: waiting for list page")
        _ = try await SafariAutomation.waitForJS("""
            var btns = document.querySelectorAll('button.token-new-btn');
            for (var i = 0; i < btns.length; i++) {
                if (btns[i].id !== 'submit' && btns[i].id !== 'cancel') return '1';
            }
            return '';
        """, timeout: 20)

        // Snapshot what's on the page before we click — helps me diagnose
        // when the click silently no-ops.
        let preClickDebug = try SafariAutomation.runJS("""
            var btns = document.querySelectorAll('button.token-new-btn');
            var info = [];
            for (var i = 0; i < btns.length; i++) {
                info.push((btns[i].id || '<noid>') + '|' + (btns[i].textContent || '').trim().slice(0, 30));
            }
            return 'url=' + location.href + ' btns=[' + info.join(';') + ']';
        """) ?? ""
        AutomationLog.log("pre-click snapshot: \(preClickDebug)")

        report("clicking Generate new token")
        // Try the click up to 5 times with a short wait between, because
        // React's onClick handler may not be attached the instant the DOM
        // mounts. Stop as soon as the URL or the form indicator changes.
        var clickedAt: String? = nil
        for attempt in 0..<5 {
            let clickResult = try SafariAutomation.runJS("""
                var btns = document.querySelectorAll('button.token-new-btn');
                for (var i = 0; i < btns.length; i++) {
                    if (btns[i].id !== 'submit' && btns[i].id !== 'cancel') {
                        try { btns[i].click(); } catch(e) { return 'CLICK_THREW:' + e.message; }
                        return 'CLICKED';
                    }
                }
                return 'NO_BUTTON';
            """) ?? ""
            AutomationLog.log("click attempt \(attempt + 1): \(clickResult)")

            // Did anything change?
            try await Task.sleep(nanoseconds: 700_000_000)
            let progressed = try SafariAutomation.runJS("""
                if (document.querySelector('input[name="inputTokenName"]')) return 'FORM';
                if (location.pathname.indexOf('/new') >= 0) return 'URL';
                return '';
            """) ?? ""
            if progressed == "FORM" || progressed == "URL" {
                clickedAt = "attempt=\(attempt + 1) progressed=\(progressed)"
                break
            }
        }
        if clickedAt == nil {
            AutomationLog.log("ERROR: clicked Generate but page didn't progress")
            throw SafariAutomation.AutomationError.scriptError(
                "Clicked 'Generate new token' but the page didn't change. Check ~/Library/Logs/OctopusSync/automation.log for details.",
                -1
            )
        }
        AutomationLog.log("click succeeded: \(clickedAt!)")

        report("waiting for create form")
        AutomationLog.log("step: waiting for create form")
        _ = try await SafariAutomation.waitForJS("""
            return document.querySelector('input[name="inputTokenName"]') ? '1' : '';
        """, timeout: 10)

        // Fill the name field via React-friendly setter, then dispatch input
        // event. A naive `.value =` is silently dropped by React-controlled
        // inputs because React caches the prior value in its fiber.
        report("filling token name")
        let nameLiteral = escapeJSString(tokenName)
        _ = try SafariAutomation.runJS("""
            var el = document.querySelector('input[name="inputTokenName"]');
            var setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
            setter.call(el, "\(nameLiteral)");
            el.dispatchEvent(new Event('input', { bubbles: true }));
            return '1';
        """)

        // Tick required scope checkboxes. The ids contain dots, colons and
        // asterisks (e.g. "r:devices:*-flexCheckDefault",
        // "create_token.groups.devices-checkbox") which need careful escaping
        // for querySelector — but getElementById has been unreliable for some
        // of these in Safari too. Instead, enumerate all checkboxes and match
        // by literal id string; no CSS or DOM-id quirks involved.
        let scopesJSON: String = {
            // Build JS array literal of "<scope>-flexCheckDefault" ids.
            let ids = requiredScopeIDs.map { "\($0)-flexCheckDefault" }
            let escaped = ids.map { "\"\(escapeJSString($0))\"" }.joined(separator: ",")
            return "[\(escaped)]"
        }()

        report("checking scopes")
        AutomationLog.log("step: checking scopes")
        let scopeResult = try SafariAutomation.runJS("""
            var wanted = \(scopesJSON);
            var parentId = 'create_token.groups.devices-checkbox';
            var all = document.querySelectorAll('input[type="checkbox"]');
            var byId = {};
            for (var i = 0; i < all.length; i++) {
                if (all[i].id) byId[all[i].id] = all[i];
            }
            // Expand the Devices group if it's collapsed/unchecked. On some
            // account variants the leaf checkboxes are interactive only after
            // the parent is ticked.
            var parent = byId[parentId];
            if (parent && !parent.checked) parent.click();

            var missing = [];
            var ticked = [];
            for (var j = 0; j < wanted.length; j++) {
                var el = byId[wanted[j]];
                if (!el) { missing.push(wanted[j]); continue; }
                if (!el.checked) el.click();
                if (el.checked) ticked.push(wanted[j]); else missing.push(wanted[j] + '(click-no-op)');
            }
            if (missing.length) {
                var present = Object.keys(byId);
                return 'PARTIAL ticked=' + ticked.join(',') +
                       ' missing=' + missing.join(',') +
                       ' available=' + present.join(',');
            }
            return 'OK';
        """) ?? ""

        AutomationLog.log("scope result: \(scopeResult)")
        guard scopeResult == "OK" else {
            throw SafariAutomation.AutomationError.scriptError(
                "Scope checkbox failure: \(scopeResult)", -1
            )
        }

        // Submit. Two #submit buttons exist (top + bottom). Either works;
        // grab the first. We throw if neither is present — that means our
        // earlier form-mount detection lied and there's nothing to submit.
        report("submitting form")
        let submitResult = try SafariAutomation.runJS("""
            var btns = document.querySelectorAll('button.token-new-btn');
            for (var i = 0; i < btns.length; i++) {
                if (btns[i].id === 'submit') {
                    btns[i].click();
                    return 'CLICKED';
                }
            }
            return 'NO_SUBMIT_FOUND';
        """) ?? ""
        guard submitResult == "CLICKED" else {
            throw SafariAutomation.AutomationError.scriptError(
                "Could not submit token form: \(submitResult)", -1
            )
        }

        // Wait for the result card. The token sits as the first text node
        // inside `div.w-75.m-3` which also contains the Copy button. The
        // sibling card with the success message ("Make sure to copy your new
        // personal access token now…") is the visual cue but the token-bearing
        // node is more specific.
        report("waiting for token result")
        _ = try await SafariAutomation.waitForJS("""
            var nodes = document.querySelectorAll('div.w-75.m-3');
            for (var i = 0; i < nodes.length; i++) {
                if (nodes[i].querySelector('button[data-testid="copy-token"]')) return '1';
            }
            return '';
        """, timeout: 30)

        // Extract the token — the textContent of the container minus the
        // button label "Copy token". Use a UUID regex as a guard against
        // grabbing surrounding whitespace or unexpected DOM rearrangement.
        report("reading token")
        let token = try SafariAutomation.runJS("""
            var nodes = document.querySelectorAll('div.w-75.m-3');
            for (var i = 0; i < nodes.length; i++) {
                if (!nodes[i].querySelector('button[data-testid="copy-token"]')) continue;
                var txt = nodes[i].textContent || '';
                var m = txt.match(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i);
                if (m) return m[0];
            }
            return '';
        """)

        guard let token, !token.isEmpty else {
            throw SafariAutomation.AutomationError.scriptError(
                "Token element found but value could not be parsed.", -1
            )
        }

        // Tidy up: close every Safari tab on account.smartthings.com so the
        // user isn't left with a stray window after a background refresh.
        // Done after we've already captured the token, so a closing failure
        // doesn't lose work.
        let closed = (try? SafariAutomation.closeTabsContaining("account.smartthings.com")) ?? 0
        AutomationLog.log("closed \(closed) account.smartthings.com tab(s) after success")

        return token
    }

    // Escapes a Swift string for safe embedding inside a JS double-quoted literal.
    nonisolated private static func escapeJSString(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: "\\n")
    }

    // MARK: - Login flow

    // Detects whether SmartThings bounced us to Samsung's IAM. If so, clicks
    // "Sign in with Google" and waits for the redirect back to smartthings.com.
    //
    // Samsung's button opens Google in a NEW Safari window (title="New Window
    // Opens"). Google, if the user is already logged in, immediately POSTs the
    // SAML/OIDC response back to account.smartthings.com/ssoCallback in that
    // new window. The original window then receives a postMessage and reloads
    // — but we don't rely on that. We:
    //   1. Click the Google button → new tab/window opens.
    //   2. Wait for ANY tab whose URL is the smartthings ssoCallback or the
    //      eventual /tokens URL.
    //   3. Focus that tab and verify we landed on /tokens.
    nonisolated private static func ensureLoggedIn(googleAccountEmail: String) async throws {
        // Quick check: if the front page already has the tokens button, we're
        // logged in and there's nothing to do. We give the SPA a beat to mount.
        for _ in 0..<3 {
            if let url = try SafariAutomation.frontURL(),
               url.contains("account.smartthings.com/tokens") {
                // Page is on the right domain — check if the SPA rendered.
                if let _ = try? SafariAutomation.runJS("""
                    return document.querySelector('button.token-new-btn') ? '1' : '';
                """), let v = try? SafariAutomation.runJS("""
                    return document.querySelector('button.token-new-btn') ? '1' : '';
                """), v == "1" {
                    return
                }
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        // Are we on Samsung IAM? URL contains 'account.samsung.com/iam' when
        // SmartThings redirected to login.
        let url = (try? SafariAutomation.frontURL()) ?? ""
        guard url.contains("account.samsung.com") else {
            // Some other state — let the caller's waitForJS surface a real
            // error. Either page is still loading, or we hit an unexpected
            // intermediate page (TOS update, etc.).
            return
        }

        // Wait for Samsung's IAM page to render the Google button. The page
        // is a React app and the button mounts after auth-options load.
        _ = try await SafariAutomation.waitForJS("""
            return document.querySelector('button[data-log-id="signin-with-google"]') ? '1' : '';
        """, timeout: 15)

        // Snapshot existing tab URLs so we can detect the new Google window/tab.
        let initialTabs = Set((try? SafariAutomation.allTabURLs()) ?? [])

        // Click. Samsung opens this in a new window because the button has
        // title="New Window Opens".
        _ = try SafariAutomation.runJS("""
            var el = document.querySelector('button[data-log-id="signin-with-google"]');
            if (!el) return '';
            el.click();
            return '1';
        """)

        // Wait for either:
        //  - a new tab to appear that contains accounts.google.com or
        //    smartthings.com/ssoCallback, OR
        //  - the front URL to navigate to smartthings.com on its own (Google
        //    sometimes redirects so fast we never see the accounts.google.com URL).
        let callbackTab = try await waitForCallbackTab(initialTabs: initialTabs, timeout: 30)

        // Focus that tab. If it's still on accounts.google.com we might need
        // to wait — Google's consent screen sometimes asks "Continue as X".
        try SafariAutomation.focusTabContaining(callbackTab)

        // If we landed on a Google consent screen, drive it forward.
        if callbackTab.contains("accounts.google.com") {
            try? await handleGoogleSSO(preferredEmail: googleAccountEmail)
            // After consent, Google posts the SSO callback in this same popup
            // and then a window.opener-driven script usually closes it. We
            // can't watchForJS in a tab that's about to vanish — it returns
            // -600. Instead poll all-tab URLs:
            //   - success if any tab contains smartthings.com/ssoCallback or /tokens
            //   - also success if the popup tab simply closed (page-side script
            //     calls window.close() right after posting the callback)
            try await waitForGoogleSSOCompletion(popupURL: callbackTab, timeout: 60)
        }

        // The popup is either closed or on smartthings.com. Either way, the
        // ORIGINAL Samsung tab is now stale (still showing the IAM page) and
        // never received the redirect. Bring it to the front and explicitly
        // navigate it to /tokens — now that Samsung's session cookie is set,
        // it'll pass through cleanly.
        try await SafariAutomation.openURL(tokensURL)
    }

    // After Google consent, the popup either (a) navigates to
    // account.smartthings.com/ssoCallback and stays open, or (b) does the
    // callback and immediately closes itself. We accept either as success.
    nonisolated private static func waitForGoogleSSOCompletion(popupURL: String, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let tabs = (try? SafariAutomation.allTabURLs()) ?? []
            // (a) Any tab on smartthings.com means the callback succeeded.
            if tabs.contains(where: { $0.contains("smartthings.com") }) {
                return
            }
            // (b) The popup vanished — popup script called window.close()
            // after posting the SSO callback. That's also success.
            //
            // We detect this by checking whether ANY tab still has the
            // accounts.google.com URL we started from. Popups don't change
            // URL after consent → if it's gone, it closed itself.
            let popupStillOpen = tabs.contains { tab in
                tab.contains("accounts.google.com")
            }
            if !popupStillOpen {
                return
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw SafariAutomation.AutomationError.scriptError(
            "Google SSO popup did not complete within \(Int(timeout))s. If the consent screen requires manual confirmation, click it and try Refresh again.",
            -1
        )
    }

    nonisolated private static func waitForCallbackTab(initialTabs: Set<String>, timeout: TimeInterval) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let tabs = (try? SafariAutomation.allTabURLs()) ?? []
            for tab in tabs where !initialTabs.contains(tab) {
                if tab.contains("smartthings.com") || tab.contains("accounts.google.com") {
                    return tab
                }
            }
            // Also: if the original samsung tab navigated directly to smartthings
            // (without spawning a popup), accept that too.
            if let front = try? SafariAutomation.frontURL(), front.contains("smartthings.com") {
                return front
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw SafariAutomation.AutomationError.scriptError(
            "Google SSO did not redirect back to SmartThings within \(Int(timeout))s. You may need to sign in to Google in Safari first.",
            -1
        )
    }

    // Drives Google's OAuth screens forward. Returns when we've either
    // clicked everything we can or hit something we don't recognise — caller
    // does the final wait for the redirect to smartthings.com.
    //
    // Sequence we may see:
    //   1. Account chooser. Rows have `div[data-email="..."]`. If the user
    //      configured a preferred email, pick that one; otherwise pick the
    //      first row.
    //   2. After the chooser, Google sometimes renders an interstitial
    //      "Continue" / "Allow" screen — handled by the second pass.
    //   3. Occasionally an extra "Confirm you're you" or scope-consent screen
    //      shows up; we click the primary button if it matches known selectors.
    nonisolated private static func handleGoogleSSO(preferredEmail: String) async throws {
        // Give the chooser a beat to mount. Google's page is a SPA so the
        // accounts often render after first paint.
        try await Task.sleep(nanoseconds: 1_500_000_000)

        // Step 1: account chooser.
        _ = try? await clickGoogleAccount(preferredEmail: preferredEmail)

        // Step 2: consent / continue screen. Loop a few times since the
        // chooser → consent transition isn't instant and sometimes there are
        // two consent pages back to back ("Continue" then "Allow").
        for _ in 0..<3 {
            try await Task.sleep(nanoseconds: 1_500_000_000)
            // Stop if Google already bounced us back to SmartThings.
            if let url = try? SafariAutomation.frontURL(), url.contains("smartthings.com") {
                return
            }
            let clicked = (try? SafariAutomation.runJS("""
                var sel = [
                    '#confirm',
                    'button[jsname="LgbsSe"]',
                    'button[jsname="V67aGc"]',
                    'div[role="button"][jsname="LgbsSe"]'
                ];
                for (var i = 0; i < sel.length; i++) {
                    var el = document.querySelector(sel[i]);
                    if (el && el.offsetParent !== null) { el.click(); return '1'; }
                }
                return '';
            """)) ?? nil
            if clicked != "1" { break }
        }
    }

    // Clicks an account row in Google's chooser. If `preferredEmail` is
    // non-empty, only clicks the row matching that email and throws if not
    // found (so user sees a clear "configure this email" error instead of
    // signing in to the wrong account). If empty, clicks the first row.
    nonisolated private static func clickGoogleAccount(preferredEmail: String) async throws {
        // Wait for at least one account row to mount.
        _ = try await SafariAutomation.waitForJS("""
            return document.querySelector('[data-email]') ? '1' : '';
        """, timeout: 15)

        let emailJS = escapeJSString(preferredEmail)
        let result = try SafariAutomation.runJS("""
            var preferred = "\(emailJS)";
            var rows = document.querySelectorAll('[data-email]');
            if (rows.length === 0) return 'NO_ROWS';
            var target = null;
            if (preferred) {
                for (var i = 0; i < rows.length; i++) {
                    if ((rows[i].getAttribute('data-email') || '').toLowerCase() === preferred.toLowerCase()) {
                        target = rows[i];
                        break;
                    }
                }
                if (!target) return 'EMAIL_NOT_LISTED';
            } else {
                target = rows[0];
            }
            // The clickable element may be an ancestor. Walk up until we find
            // something with role="link" or a parent <li>/<div role="button">.
            var el = target;
            for (var depth = 0; depth < 5 && el; depth++) {
                if (el.getAttribute && (el.getAttribute('role') === 'link' || el.getAttribute('role') === 'button')) break;
                el = el.parentElement;
            }
            (el || target).click();
            return 'OK';
        """) ?? ""

        switch result {
        case "OK":
            return
        case "EMAIL_NOT_LISTED":
            throw SafariAutomation.AutomationError.scriptError(
                "Google account '\(preferredEmail)' is not signed in to this Safari. Sign in to it first, or clear the email field to use the first available account.",
                -1
            )
        case "NO_ROWS":
            throw SafariAutomation.AutomationError.scriptError(
                "Google account chooser had no accounts to pick from.",
                -1
            )
        default:
            throw SafariAutomation.AutomationError.scriptError(
                "Unexpected response from Google chooser: \(result)",
                -1
            )
        }
    }
}
