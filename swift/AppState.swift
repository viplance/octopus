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
            self?.inputManager.injectEvent(event)
        }

        inputManager.onEventCaptured = { [weak self] event in
            self?.networkManager.sendEvent(event)
        }
    }

    func toggleSharing() {
        guard connectionStatus == .connected else { return }
        isSharingActive.toggle()

        if isSharingActive {
            // This Mac is gaining input focus — switch monitor to this Mac's input source.
            monitorManager.switchToThisMac()
            inputManager.startCapture(devices: availableDevices.filter { $0.isSelected })
        } else {
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
