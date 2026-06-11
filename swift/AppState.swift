import SwiftUI
import Combine
import ServiceManagement
import IOKit.pwr_mgt

@MainActor
class AppState: ObservableObject {
    @Published var isSharingActive = false
    @Published var connectionStatus: ConnectionStatus = .disconnected
    @Published var networkType: NetworkManager.NetworkType = .unknown
    @Published var directIsThrottled = false
    @Published var connectedDeviceName: String?
    @Published var availableDevices: [BluetoothDevice] = []
    @Published var launchAtLogin = false
    @Published var showConnectionLostAlert = false
    @Published var isAccessibilityGranted: Bool = AXIsProcessTrusted()
    @Published var isInputMonitoringGranted: Bool = PermissionsHelper.isInputMonitoringGranted()

    enum ConnectionStatus: String {
        case disconnected = "Disconnected"
        case lookingForHost = "Looking for Host"
        case hosting = "Waiting for Client"
        case connected = "Connected"
    }

    let networkManager = NetworkManager()
    let deviceManager = DeviceManager()
    let inputManager = InputManager()
    let shortcutManager = ShortcutManager()
    let monitorManager = MonitorManager()

    private var cancellables = Set<AnyCancellable>()
    private var shortcutSyncCancellable: AnyCancellable?
    private var monitorSyncCancellable: AnyCancellable?
    private var accessibilityTimer: Timer?
    private var permissionWatchdog: Timer?
    private var sleepAssertionID: IOPMAssertionID = 0

    private static let selectedDevicesKey = "selectedDeviceNames"

    private func savedSelectedNames() -> Set<String> {
        let arr = UserDefaults.standard.stringArray(forKey: Self.selectedDevicesKey) ?? []
        return Set(arr)
    }

    private func persistSelectedNames() {
        let names = availableDevices.filter(\.isSelected).map(\.name)
        UserDefaults.standard.set(names, forKey: Self.selectedDevicesKey)
    }

    init() {
        setupBindings()
        deviceManager.refreshDevices()
        // Trigger the Input Monitoring system prompt on first launch.
        // Without this, cghidEventTap creates successfully but receives zero
        // events — shortcuts and input capture silently do nothing.
        PermissionsHelper.requestInputMonitoring()
        startPermissionPolling()
        networkManager.start()

        // Without explicit teardown on quit, the CGEventTap mach port and the
        // IOPMAssertion stay registered with the kernel after the process exits,
        // which leaves the process in an unreapable 'E' state. Over many runs
        // these zombies accumulate and break `open` with errAETimeout (-1712)
        // because LaunchServices keeps trying to AppleEvent the dead PSNs.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
    }

    // Schedules an out-of-process relaunch and quits. The earlier inline
    // version (`Process()` + `terminate(nil)`) raced: `open` ran while our
    // PID was still dying, which Launch Services rejected with -600 and
    // sometimes wedged the bundle slot until logout. A detached shell that
    // waits for our PID to disappear before invoking `open` removes the race.
    private func relaunchAfterPermissionGrant() {
        let bundlePath = Bundle.main.bundleURL.path
        let pid = getpid()
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done; sleep 0.5; /usr/bin/open \"\(bundlePath)\""
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        try? task.run()
        NSApplication.shared.terminate(nil)
    }

    @objc private func handleTerminate() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = nil
        stopPermissionWatchdog()
        inputManager.stopCapture()
        networkManager.stop()
        shortcutManager.teardown()
        if sleepAssertionID != 0 {
            IOPMAssertionRelease(sleepAssertionID)
            sleepAssertionID = 0
        }
    }

    // Poll both Accessibility and Input Monitoring grants every second.
    // Once either flips from denied to granted, restart the process so
    // CGEventTap and other AX/IOKit-dependent subsystems initialize with
    // the permission active. macOS does not deliver the new grant to the
    // already-running process for these particular permissions.
    private func startPermissionPolling() {
        guard !isAccessibilityGranted || !isInputMonitoringGranted else { return }
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let ax = AXIsProcessTrusted()
            let im = PermissionsHelper.isInputMonitoringGranted()
            Task { @MainActor in
                self.isAccessibilityGranted = ax
                self.isInputMonitoringGranted = im
            }
            if ax && im {
                timer.invalidate()
                Task { @MainActor in self.relaunchAfterPermissionGrant() }
            }
        }
    }

    private func setupBindings() {
        shortcutManager.onToggleShortcut = { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                self.toggleSharing()
            }
        }

        networkManager.$connectionStatus
            .receive(on: RunLoop.main)
            .assign(to: \.connectionStatus, on: self)
            .store(in: &cancellables)

        networkManager.$directIsThrottled
            .receive(on: RunLoop.main)
            .assign(to: \.directIsThrottled, on: self)
            .store(in: &cancellables)

        networkManager.$networkType
            .receive(on: RunLoop.main)
            .sink { [weak self] type in
                guard let self else { return }
                self.networkType = type
                // Low-latency links (Direct/AWDL, wired Ethernet) send deltas
                // immediately. WiFi batches at 8ms to avoid flooding TCP.
                self.inputManager.mouseBatchInterval = (type == .direct || type == .wiredEthernet) ? 0 : 0.008
            }
            .store(in: &cancellables)

        // When connection drops while sharing is active, return control and alert.
        // When connected, immediately push the SmartThings config to the peer.
        networkManager.$connectionStatus
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                guard let self = self else { return }
                if status == .disconnected {
                    // Release any injected mouse buttons so the slave doesn't stay
                    // stuck with a phantom "button held" state after the connection drops.
                    self.inputManager.releaseAllButtons()
                    if self.isSharingActive {
                        self.restoreLocalControl()
                    }
                }
                if status == .connected {
                    self.sendMonitorSync(config: self.monitorManager.config)
                }
            }
            .store(in: &cancellables)

        // If the event tap dies mid-capture (permission revoked at runtime),
        // hand control back immediately. Without this, the dead tap keeps
        // swallowing keys/clicks and the user cannot use their machine.
        inputManager.onTapBroken = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                guard self.isSharingActive else { return }
                self.restoreLocalControl()
            }
        }

        deviceManager.$devices
            .receive(on: RunLoop.main)
            .sink { [weak self] devices in
                guard let self else { return }
                let saved = self.savedSelectedNames()
                self.availableDevices = devices.map { device in
                    var d = device
                    d.isSelected = saved.contains(d.name)
                    return d
                }
                // Mirror to MonitorManager so SmartThingsTokenAutomation's
                // scheduler knows whether this Mac has any input devices and
                // therefore whether it should ever refresh tokens.
                self.monitorManager.hasLocalInputDevices = !devices.isEmpty
            }
            .store(in: &cancellables)

        // When this Mac is the receiver, forward diagnostic lines to the master
        // via the existing event channel so both sides appear in one log file.
        // Only when debug logging is on: these per-second control messages ride
        // the same reliable channel as clicks/keys.
        let sendDiag: (String) -> Void = { [weak self] line in
            guard NetworkManager.debugLoggingEnabled else { return }
            guard let self, self.connectionStatus == .connected else { return }
            let event = InputEvent(type: .keyDown, dx: nil, dy: nil, button: nil,
                                   keyCode: nil, isDown: nil, flags: nil, rawData: nil,
                                   control: "peerLog:\(line)", clickCount: nil)
            self.networkManager.sendEvent(event)
        }
        inputManager.onDiagnosticLog = sendDiag
        networkManager.onPeerDiagnosticLog = sendDiag

        networkManager.onEventReceived = { [weak self] event in
            guard let self = self else { return }

            if event.control == "gainFocus" {
                Task { @MainActor in
                    self.monitorManager.switchToThisMac()
                }
                return
            }

            if let ctrl = event.control, ctrl.hasPrefix("shortcutSync:") {
                let json = String(ctrl.dropFirst("shortcutSync:".count))
                if let data = json.data(using: .utf8),
                   let config = try? JSONDecoder().decode(ShortcutConfig.self, from: data) {
                    Task { @MainActor in
                        self.shortcutManager.config = config
                    }
                }
                return
            }

            // Full SmartThings config pushed from the master Mac.
            if let ctrl = event.control, ctrl.hasPrefix("monitorConfigSync:") {
                let json = String(ctrl.dropFirst("monitorConfigSync:".count))
                if let data = json.data(using: .utf8),
                   let shared = try? JSONDecoder().decode(MonitorManager.SharedConfig.self, from: data) {
                    Task { @MainActor in
                        self.monitorManager.applySharedConfig(shared)
                    }
                }
                return
            }

            if let ctrl = event.control, ctrl.hasPrefix("peerLog:") {
                let line = String(ctrl.dropFirst("peerLog:".count))
                NetworkManager.log("[PEER] \(line)")
                return
            }

            // Slave reporting its auto-detected input back to the master.
            if let ctrl = event.control, ctrl.hasPrefix("inputSourceSync:") {
                let source = String(ctrl.dropFirst("inputSourceSync:".count))
                Task { @MainActor in
                    self.monitorManager.setPeerInputSource(source)
                }
                return
            }

            self.inputManager.injectEvent(event)

            let now = Date().timeIntervalSince1970
            if now - self.lastReceiveTime > 10.0 {
                self.lastReceiveTime = now
                Task { @MainActor in
                    self.monitorManager.switchToThisMac()
                }
            }
        }

        inputManager.onEventCaptured = { [weak self] event in
            self?.networkManager.sendEvent(event)
        }

        inputManager.shortcutConfig = shortcutManager.config
        inputManager.onToggleShortcut = { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                self.toggleSharing()
            }
        }

        shortcutManager.$config
            .sink { [weak self] config in
                self?.inputManager.shortcutConfig = config
            }
            .store(in: &cancellables)

        shortcutSyncCancellable = shortcutManager.$config
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] config in
                guard let self, self.connectionStatus == .connected else { return }
                if let json = try? JSONEncoder().encode(config),
                   let str = String(data: json, encoding: .utf8) {
                    let syncEvent = InputEvent(type: .keyDown, dx: nil, dy: nil, button: nil,
                                               keyCode: nil, isDown: nil, flags: nil, rawData: nil,
                                               control: "shortcutSync:\(str)", clickCount: nil)
                    self.networkManager.sendEvent(syncEvent)
                }
            }

        monitorSyncCancellable = monitorManager.$config
            .dropFirst()
            .sink { [weak self] config in
                guard let self,
                      !self.monitorManager.isSyncApply,
                      self.connectionStatus == .connected
                else { return }
                self.sendMonitorSync(config: config)
            }
    }

    private var lastReceiveTime: TimeInterval = 0

    // Master pushes its full SmartThings config to the slave.
    // Slave reports only its detected input source back to the master.
    private func sendMonitorSync(config: MonitorManager.Config) {
        if config.isMasterForSmartThings && !config.personalAccessToken.isEmpty {
            guard let json = try? JSONEncoder().encode(monitorManager.sharedConfig),
                  let str = String(data: json, encoding: .utf8)
            else { return }
            let event = InputEvent(type: .keyDown, dx: nil, dy: nil, button: nil,
                                   keyCode: nil, isDown: nil, flags: nil, rawData: nil,
                                   control: "monitorConfigSync:\(str)", clickCount: nil)
            networkManager.sendEvent(event)
        } else if !config.isMasterForSmartThings && !config.myInputSource.isEmpty {
            let event = InputEvent(type: .keyDown, dx: nil, dy: nil, button: nil,
                                   keyCode: nil, isDown: nil, flags: nil, rawData: nil,
                                   control: "inputSourceSync:\(config.myInputSource)", clickCount: nil)
            networkManager.sendEvent(event)
        }
    }

    // Single recovery path used when sharing must end against the user's
    // wishes — connection lost, tap killed, permission revoked. Stops the
    // tap, returns the cursor to this Mac, alerts, and re-checks permissions
    // so a re-grant will trigger the relaunch flow.
    private func restoreLocalControl() {
        guard isSharingActive else { return }
        isSharingActive = false
        inputManager.stopCapture()
        monitorManager.switchToThisMac()
        showConnectionLostAlert = true
        stopPermissionWatchdog()
        if sleepAssertionID != 0 {
            IOPMAssertionRelease(sleepAssertionID)
            sleepAssertionID = 0
        }
        isAccessibilityGranted = AXIsProcessTrusted()
        isInputMonitoringGranted = PermissionsHelper.isInputMonitoringGranted()
        startPermissionPolling()
    }

    // While sharing is active, poll permissions so revocation is caught
    // before the user notices a freeze. macOS does not deliver a callback
    // when the user toggles these off in System Settings.
    private func startPermissionWatchdog() {
        stopPermissionWatchdog()
        permissionWatchdog = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let ax = AXIsProcessTrusted()
            let im = PermissionsHelper.isInputMonitoringGranted()
            Task { @MainActor in
                self.isAccessibilityGranted = ax
                self.isInputMonitoringGranted = im
                if (!ax || !im) && self.isSharingActive {
                    self.restoreLocalControl()
                }
            }
        }
    }

    private func stopPermissionWatchdog() {
        permissionWatchdog?.invalidate()
        permissionWatchdog = nil
    }

    func toggleSharing() {
        // Block toggle if peer is not connected.
        guard connectionStatus == .connected else {
            if isSharingActive {
                // Was active, now lost — already handled by the connectionStatus sink.
                return
            }
            showConnectionLostAlert = true
            return
        }

        isSharingActive.toggle()

        if isSharingActive {
            let focusEvent = InputEvent(type: .mouseMove, dx: 0, dy: 0, button: nil, keyCode: 0, isDown: false, flags: 0, rawData: nil, control: "gainFocus", clickCount: nil)
            networkManager.sendEvent(focusEvent)
            // Direct mode: sleep our display so the monitor auto-switches to peer.
            monitorManager.switchToPeer()
            inputManager.startCapture(devices: availableDevices.filter { $0.isSelected })
            startPermissionWatchdog()
            
            // Prevent this Mac from entering idle sleep while sharing, 
            // especially since its display is asleep and it appears idle.
            if sleepAssertionID == 0 {
                IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                            IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                            "OctopusSync is actively sharing input" as CFString,
                                            &sleepAssertionID)
            }
        } else {
            monitorManager.switchToThisMac()
            inputManager.stopCapture()
            stopPermissionWatchdog()
            
            if sleepAssertionID != 0 {
                IOPMAssertionRelease(sleepAssertionID)
                sleepAssertionID = 0
            }
        }
    }

    func toggleDeviceSelection(_ device: BluetoothDevice) {
        if let index = availableDevices.firstIndex(where: { $0.id == device.id }) {
            availableDevices[index].isSelected.toggle()
            persistSelectedNames()
            if isSharingActive {
                inputManager.stopCapture()
                inputManager.startCapture(devices: availableDevices.filter { $0.isSelected })
            }
        }
    }

    func toggleLaunchAtLogin() {
        if launchAtLogin {
            try? ServiceManagement.SMAppService.mainApp.unregister()
            launchAtLogin = false
        } else {
            try? ServiceManagement.SMAppService.mainApp.register()
            launchAtLogin = true
        }
    }
}
