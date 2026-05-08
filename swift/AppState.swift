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
    private var accessibilityTimer: Timer?

    init() {
        setupBindings()
        deviceManager.refreshDevices()
        startAccessibilityPolling()
    }

    // Poll AXIsProcessTrusted every second until granted, then stop.
    // This auto-dismisses the warning as soon as the user enables access
    // in System Settings without requiring an app restart.
    private func startAccessibilityPolling() {
        guard !isAccessibilityGranted else { return }
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if AXIsProcessTrusted() {
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
            .assign(to: \.availableDevices, on: self)
            .store(in: &cancellables)

        networkManager.onEventReceived = { [weak self] event in
            guard let self = self else { return }

            if event.control == "gainFocus" {
                Task { @MainActor in
                    self.monitorManager.switchToThisMac()
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
