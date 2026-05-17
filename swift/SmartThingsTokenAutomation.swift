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

        // Auto-start/stop wake/unlock observers. The scheduler runs only on
        // a Mac that (a) has auto-refresh enabled, (b) is the SmartThings
        // master, and (c) actually has local input devices attached.
        //
        // (c) is the catch — a slave Mac receives the config from master
        // via monitorConfigSync, including autoRefreshTokenEnabled=true.
        // Without the hasLocalInputDevices guard, the slave would race the
        // master to mint tokens and invalidate the master's.
        Publishers.CombineLatest(
            monitor.$config.map { ($0.autoRefreshTokenEnabled, $0.isMasterForSmartThings) },
            monitor.$hasLocalInputDevices
        )
        .map { configFlags, hasDevices in
            configFlags.0 && configFlags.1 && hasDevices
        }
        .removeDuplicates()
        .sink { [weak self] shouldRun in
            guard let self else { return }
            if shouldRun { self.startScheduler() } else { self.stopScheduler() }
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
        // Only the master Mac touches SmartThings — slave receives the
        // token via monitorConfigSync from master. Without this guard both
        // Macs would race to mint tokens, each invalidating the other's.
        guard monitor.config.isMasterForSmartThings else {
            AutomationLog.log("refreshIfDue trigger=\(trigger): skipped — this Mac is slave for SmartThings")
            return
        }
        // Belt-and-suspenders against (a): a Mac with no local input devices
        // is by definition a receive-only slave, even if the config flag
        // says master (e.g. between launch and the first sync).
        guard monitor.hasLocalInputDevices else {
            AutomationLog.log("refreshIfDue trigger=\(trigger): skipped — no local input devices")
            return
        }

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
    /// No-op on the slave — see refreshIfDue for the same guard.
    func refreshNow() async {
        guard monitor.config.isMasterForSmartThings else {
            lastError = "This Mac is a SmartThings slave — token is managed by the master Mac."
            AutomationLog.log("refreshNow: skipped — slave")
            return
        }
        guard monitor.hasLocalInputDevices else {
            lastError = "This Mac has no local input devices — token refresh is for the master Mac."
            AutomationLog.log("refreshNow: skipped — no local input devices")
            return
        }
        guard !isRunning else { return }
        isRunning = true
        lastError = nil
        lastStep = "starting"
        defer { isRunning = false }

        do {
            // Step reporter — captured into the nonisolated flow via a
            // MainActor-hopping closure. Without this we can't see where the
            // automation is stuck; the previous version was completely opaque.
            let report: @Sendable (String) -> Void = { [weak self] step in
                let weakSelf = self
                Task { @MainActor in weakSelf?.lastStep = step }
            }
            let token = try await Self.executeFlow(report: report)
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
        report: @Sendable (String) -> Void = { _ in }
    ) async throws -> String {
        AutomationLog.log("=== executeFlow start ===")
        report("opening tokens page")
        AutomationLog.log("step: opening tokens page (\(tokensURL))")
        try await SafariAutomation.openURL(tokensURL)

        // If SmartThings bounced us to Samsung IAM, surface a clear error
        // and stop — Google SSO automation under Apple Events is unreliable
        // (Google's gsi-web SDK silently drops the storage event that should
        // hand the id_token to Samsung's opener). User must sign in once
        // manually, then we'll continue minting tokens.
        report("checking login")
        AutomationLog.log("step: checking login")
        try await ensureLoggedIn()

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


    // MARK: - Login detection

    // Confirms we're on account.smartthings.com/tokens with the SPA mounted.
    // If SmartThings bounced us to Samsung IAM (session expired), throws a
    // clear error asking the user to sign in once. Earlier versions tried to
    // automate the Google SSO popup; under Apple Events automation Google's
    // gsi-web SDK silently drops the storage event that should hand the
    // id_token back to Samsung's opener, so the parent never advances. After
    // many iterations we decided the only reliable path is to require one
    // manual login and then refresh autonomously while that session lasts.
    nonisolated private static func ensureLoggedIn() async throws {
        // The SmartThings SPA may take a beat to mount even when we're
        // already logged in. Poll for up to 10 seconds.
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let url = (try? SafariAutomation.frontURL()) ?? ""

            // Happy path: on the tokens page with the SPA rendered.
            if SafariAutomation.urlHostIs(url, host: "account.smartthings.com"),
               url.contains("/tokens"),
               let v = try? SafariAutomation.runJS("""
                   return document.querySelector('button.token-new-btn')
                       || document.querySelector('input[name="inputTokenName"]') ? '1' : '';
               """), v == "1" {
                AutomationLog.log("ensureLoggedIn: already logged in")
                return
            }

            // Bounced to Samsung IAM → user must sign in manually.
            if SafariAutomation.urlHostIs(url, host: "account.samsung.com") {
                AutomationLog.log("ensureLoggedIn: redirected to Samsung IAM — manual login required")
                throw SafariAutomation.AutomationError.scriptError(
                    "SmartThings session expired. Safari is open on the Samsung login page — please sign in once, then click Refresh again.",
                    -1
                )
            }

            try await Task.sleep(nanoseconds: 500_000_000)
        }

        let finalURL = (try? SafariAutomation.frontURL()) ?? "<unknown>"
        AutomationLog.log("ensureLoggedIn: timed out on \(finalURL)")
        throw SafariAutomation.AutomationError.scriptError(
            "Could not reach \(tokensURL). Front URL after 10s: \(finalURL)",
            -1
        )
    }
}
