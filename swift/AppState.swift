import SwiftUI
import Combine
import ServiceManagement

@MainActor
class AppState: ObservableObject {
    @Published var isSharingActive = false
    @Published var connectionStatus: ConnectionStatus = .disconnected
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
    private var accessibilityTimer: Timer?

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
                // Restart the process so CGEventTap and other AX-dependent
                // systems initialize with the permission active. macOS does not
                // always deliver the grant to the already-running process.
                let url = Bundle.main.bundleURL
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                task.arguments = [url.path]
                try? task.run()
                NSApplication.shared.terminate(nil)
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

        // When connection drops while sharing is active, return control and alert.
        networkManager.$connectionStatus
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                guard let self = self else { return }
                if status == .disconnected && self.isSharingActive {
                    self.isSharingActive = false
                    self.inputManager.stopCapture()
                    self.monitorManager.switchToThisMac()
                    self.showConnectionLostAlert = true
                }
            }
            .store(in: &cancellables)

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
            }
            .store(in: &cancellables)

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
                                               control: "shortcutSync:\(str)")
                    self.networkManager.sendEvent(syncEvent)
                }
            }
    }

    private var lastReceiveTime: TimeInterval = 0

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
            let focusEvent = InputEvent(type: .mouseMove, dx: 0, dy: 0, button: 0, keyCode: 0, isDown: false, flags: 0, rawData: nil, control: "gainFocus")
            networkManager.sendEvent(focusEvent)
            // Direct mode: sleep our display so the monitor auto-switches to peer.
            monitorManager.switchToPeer()
            inputManager.startCapture(devices: availableDevices.filter { $0.isSelected })
        } else {
            monitorManager.switchToThisMac()
            inputManager.stopCapture()
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
