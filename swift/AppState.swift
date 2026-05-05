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

    init() {
        setupBindings()
        deviceManager.refreshDevices()
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

        deviceManager.$devices
            .receive(on: RunLoop.main)
            .assign(to: \.availableDevices, on: self)
            .store(in: &cancellables)

        networkManager.onEventReceived = { [weak self] event in
            guard let self = self else { return }
            
            // Handle explicit focus request from peer
            if event.control == "gainFocus" {
                Task { @MainActor in
                    self.monitorManager.switchToThisMac()
                }
                return
            }

            self.inputManager.injectEvent(event)
            
            // Fallback: If we are receiving events but didn't get a control message,
            // still ensure monitor is on this Mac (with cooldown).
            let now = Date().timeIntervalSince1970
            if now - self.lastReceiveTime > 10.0 { // 10 second cooldown
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
        guard connectionStatus == .connected else { return }
        isSharingActive.toggle()

        if isSharingActive {
            // Moving focus to peer — tell them to switch the monitor.
            let focusEvent = InputEvent(type: .mouseMove, dx: 0, dy: 0, button: 0, keyCode: 0, isDown: false, flags: 0, rawData: nil, control: "gainFocus")
            networkManager.sendEvent(focusEvent)
            inputManager.startCapture(devices: availableDevices.filter { $0.isSelected })
        } else {
            // Returning focus to this Mac — switch the monitor back.
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
