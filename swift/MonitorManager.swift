import Foundation
import Combine
import CoreGraphics

// Manages monitor input switching with two modes:
//
// .direct      — sleeps this Mac's external display output when giving focus to
//                the peer so the monitor auto-switches to the peer's active signal.
//                No cloud account required. Works with any monitor that auto-switches.
//
// .smartThings — sends an explicit setInputSource command via the SmartThings REST
//                API. Use when the monitor does not auto-switch (e.g. Samsung M7/M8).
//
// SmartThings master/slave model:
//   Only ONE Mac (the master) ever sends SmartThings API commands. The master is
//   the Mac where the user originally configured the token. When the slave connects,
//   the master pushes its full config to the slave via `monitorConfigSync:`. The
//   slave uses the synced token to auto-detect its own input source and reports it
//   back via `inputSourceSync:`. From then on, the master switches the monitor in
//   BOTH directions — to the peer's input when giving focus, and back to its own
//   input when regaining focus.
@MainActor
class MonitorManager: ObservableObject {

    // MARK: - Mode

    enum MonitorMode: String, CaseIterable, Codable, Identifiable {
        case direct      = "direct"
        case smartThings = "smartthings"

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .direct:      return "Direct (auto-switch)"
            case .smartThings: return "Samsung SmartThings"
            }
        }
    }

    // MARK: - Persisted configuration

    struct Config: Codable {
        var enabled: Bool
        var monitorMode: MonitorMode
        var personalAccessToken: String
        var deviceId: String
        // This Mac's input source (auto-detected from the monitor on startup).
        var myInputSource: String
        // The peer Mac's input source (received via inputSourceSync: message from slave,
        // or set to master's myInputSource when slave receives monitorConfigSync:).
        var peerInputSource: String
        // True on the Mac that originally configured SmartThings.
        // Set to false when this Mac receives a monitorConfigSync: from the peer.
        // Persisted so it survives restarts without requiring re-sync.
        var isMasterForSmartThings: Bool
        // Auto-refresh via Safari automation against account.smartthings.com/tokens.
        var autoRefreshTokenEnabled: Bool
        var tokenIssuedAt: Date?
        var googleAccountEmail: String

        enum CodingKeys: String, CodingKey {
            case enabled, monitorMode, personalAccessToken, deviceId
            case myInputSource, peerInputSource, isMasterForSmartThings
            case autoRefreshTokenEnabled, tokenIssuedAt, googleAccountEmail
        }

        init(enabled: Bool, monitorMode: MonitorMode, personalAccessToken: String,
             deviceId: String, myInputSource: String, peerInputSource: String = "",
             isMasterForSmartThings: Bool = true,
             autoRefreshTokenEnabled: Bool = false, tokenIssuedAt: Date? = nil,
             googleAccountEmail: String = "") {
            self.enabled = enabled
            self.monitorMode = monitorMode
            self.personalAccessToken = personalAccessToken
            self.deviceId = deviceId
            self.myInputSource = myInputSource
            self.peerInputSource = peerInputSource
            self.isMasterForSmartThings = isMasterForSmartThings
            self.autoRefreshTokenEnabled = autoRefreshTokenEnabled
            self.tokenIssuedAt = tokenIssuedAt
            self.googleAccountEmail = googleAccountEmail
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled                 = try c.decode(Bool.self,        forKey: .enabled)
            monitorMode             = try c.decode(MonitorMode.self, forKey: .monitorMode)
            personalAccessToken     = try c.decode(String.self,      forKey: .personalAccessToken)
            deviceId                = try c.decode(String.self,      forKey: .deviceId)
            myInputSource           = try c.decode(String.self,      forKey: .myInputSource)
            peerInputSource         = try c.decodeIfPresent(String.self, forKey: .peerInputSource) ?? ""
            isMasterForSmartThings  = try c.decodeIfPresent(Bool.self,  forKey: .isMasterForSmartThings) ?? true
            autoRefreshTokenEnabled = try c.decodeIfPresent(Bool.self,  forKey: .autoRefreshTokenEnabled) ?? false
            tokenIssuedAt           = try c.decodeIfPresent(Date.self,  forKey: .tokenIssuedAt)
            googleAccountEmail      = try c.decodeIfPresent(String.self, forKey: .googleAccountEmail) ?? ""
        }
    }

    // MARK: - Config for network sync

    // Sent master→slave via `monitorConfigSync:`. Contains everything the slave needs
    // to detect its own input and know which Mac is the master.
    struct SharedConfig: Codable, Equatable {
        var enabled: Bool
        var monitorMode: MonitorMode
        var personalAccessToken: String
        var deviceId: String
        var myInputSource: String       // sender's input → becomes receiver's peerInputSource
        var autoRefreshTokenEnabled: Bool
        var tokenIssuedAt: Date?
        var googleAccountEmail: String
    }

    var sharedConfig: SharedConfig {
        SharedConfig(
            enabled: config.enabled,
            monitorMode: config.monitorMode,
            personalAccessToken: config.personalAccessToken,
            deviceId: config.deviceId,
            myInputSource: config.myInputSource,
            autoRefreshTokenEnabled: config.autoRefreshTokenEnabled,
            tokenIssuedAt: config.tokenIssuedAt,
            googleAccountEmail: config.googleAccountEmail
        )
    }

    // True while a network sync is being applied — suppresses the outbound
    // sync Combine sink so we don't echo back what we just received.
    var isSyncApply = false

    // MARK: - Published state

    @Published var config: Config {
        didSet { saveConfig() }
    }

    @Published var availableInputSources: [String] = ["HDMI1", "HDMI2", "USB-C"]
    @Published var isQuerying = false
    @Published var lastError: String?
    @Published var detectedDevices: [SmartThingsDevice] = []

    // Lazy because SmartThingsTokenAutomation captures `self`; we can't init
    // it as a stored property without referencing `self` before init completes.
    lazy var tokenAutomation: SmartThingsTokenAutomation = SmartThingsTokenAutomation(monitor: self)

    struct SmartThingsDevice: Identifiable, Codable {
        let id: String
        let name: String
        let label: String
    }

    private let configURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("OctopusSync", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("monitor_config.json")
    }()

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 10
        return URLSession(configuration: cfg)
    }()

    init() {
        config = Self.loadConfig() ?? Config(
            enabled: false,
            monitorMode: .direct,
            personalAccessToken: "",
            deviceId: "",
            myInputSource: "HDMI1"
        )
        // Force-instantiate the token automation so its scheduler binding to
        // $config fires (it watches autoRefreshTokenEnabled). Without this,
        // the lazy stays dormant until UI first reads it.
        _ = tokenAutomation

        if config.enabled && config.monitorMode == .smartThings
            && !config.personalAccessToken.isEmpty && !config.deviceId.isEmpty {
            fetchSupportedInputSources()
        }
    }

    // MARK: - Toggle entry points

    /// Called when THIS Mac gains focus (peer just gave us control).
    /// Master: switches monitor to its own input via SmartThings.
    /// Slave: no-op (master already switched the monitor when giving focus).
    func switchToThisMac() {
        guard config.enabled else { return }

        switch config.monitorMode {
        case .direct:
            wakeDisplay()
        case .smartThings:
            guard config.isMasterForSmartThings,
                  !config.personalAccessToken.isEmpty,
                  !config.deviceId.isEmpty,
                  !config.myInputSource.isEmpty
            else { return }
            Task { await setInputSource(config.myInputSource) }
        }
    }

    /// Called when THIS Mac gives focus to the peer.
    /// Direct mode: sleep display so monitor auto-switches.
    /// SmartThings master: explicitly switch monitor to the peer's input.
    /// SmartThings slave: no-op (master handles all switching on its gainFocus event).
    func switchToPeer() {
        guard config.enabled else { return }

        switch config.monitorMode {
        case .direct:
            sleepDisplay()
        case .smartThings:
            guard config.isMasterForSmartThings,
                  !config.personalAccessToken.isEmpty,
                  !config.deviceId.isEmpty,
                  !config.peerInputSource.isEmpty
            else { return }
            Task { await setInputSource(config.peerInputSource) }
        }
    }

    // MARK: - Network sync application

    /// Apply a full config received from the master Mac. Marks this Mac as slave
    /// so it never sends SmartThings commands.
    func applySharedConfig(_ shared: SharedConfig) {
        isSyncApply = true
        var newConfig = config
        newConfig.enabled = shared.enabled
        newConfig.monitorMode = shared.monitorMode
        newConfig.personalAccessToken = shared.personalAccessToken
        newConfig.deviceId = shared.deviceId
        newConfig.peerInputSource = shared.myInputSource   // master's input = our peer's input
        newConfig.isMasterForSmartThings = false
        newConfig.autoRefreshTokenEnabled = shared.autoRefreshTokenEnabled
        newConfig.tokenIssuedAt = shared.tokenIssuedAt
        newConfig.googleAccountEmail = shared.googleAccountEmail
        config = newConfig
        isSyncApply = false

        // Detect own input using the synced credentials so we can report it back.
        if config.enabled && config.monitorMode == .smartThings
            && !config.personalAccessToken.isEmpty && !config.deviceId.isEmpty {
            fetchSupportedInputSources()
        }
    }

    /// Update the peer's input source when an `inputSourceSync:` message arrives.
    /// Ignored if it matches our own input (detection artifact from wrong monitor state).
    func setPeerInputSource(_ source: String) {
        guard !source.isEmpty, source != config.myInputSource else { return }
        config.peerInputSource = source
    }

    // MARK: - Direct mode display control

    private var disabledDisplayIDs: [CGDirectDisplayID] = []

    private func setExternalDisplaysEnabled(_ enabled: Bool) {
        guard let coreDisplayHandle = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_NOW) else { return }

        typealias CGSConfigureDisplayEnabledType = @convention(c) (CGDisplayConfigRef, CGDirectDisplayID, Bool) -> CGError
        guard let sym = dlsym(coreDisplayHandle, "CGSConfigureDisplayEnabled") else { return }
        let CGSConfigureDisplayEnabled = unsafeBitCast(sym, to: CGSConfigureDisplayEnabledType.self)

        var configRef: CGDisplayConfigRef? = nil
        CGBeginDisplayConfiguration(&configRef)
        guard let config = configRef else { return }

        var changed = false

        if !enabled {
            let maxDisplays: UInt32 = 10
            var onlineDisplays = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
            var displayCount: UInt32 = 0
            CGGetOnlineDisplayList(maxDisplays, &onlineDisplays, &displayCount)

            disabledDisplayIDs.removeAll()
            for i in 0..<Int(displayCount) {
                let id = onlineDisplays[i]
                if CGDisplayIsBuiltin(id) == 0 { // External display
                    _ = CGSConfigureDisplayEnabled(config, id, false)
                    disabledDisplayIDs.append(id)
                    changed = true
                }
            }
        } else {
            for id in disabledDisplayIDs {
                _ = CGSConfigureDisplayEnabled(config, id, true)
                changed = true
            }
            disabledDisplayIDs.removeAll()
        }

        if changed {
            CGCompleteDisplayConfiguration(config, .forSession)
        } else {
            CGCancelDisplayConfiguration(config)
        }
    }

    private func sleepDisplay() {
        // Soft-disable only external monitors by dropping their signal programmatically.
        // The monitor sees no active signal and auto-switches to the peer's active signal.
        // By avoiding `pmset displaysleepnow`, we keep the internal screen on and prevent the Mac from locking.
        DispatchQueue.main.async {
            self.setExternalDisplaysEnabled(false)
        }
    }

    private func wakeDisplay() {
        // Re-enable external monitors to wake them up and regain their focus.
        DispatchQueue.main.async {
            self.setExternalDisplaysEnabled(true)
        }
    }

    // MARK: - SmartThings API

    private static let baseURL = "https://api.smartthings.com/v1"

    func discoverDevices() {
        guard !config.personalAccessToken.isEmpty else {
            lastError = "Enter your SmartThings Personal Access Token first."
            return
        }
        isQuerying = true
        lastError = nil

        Task {
            defer { Task { @MainActor in self.isQuerying = false } }
            do {
                let url = URL(string: "\(Self.baseURL)/devices")!
                var req = URLRequest(url: url)
                req.setValue("Bearer \(config.personalAccessToken)", forHTTPHeaderField: "Authorization")

                let (data, resp) = try await session.data(for: req)
                if let http = resp as? HTTPURLResponse, http.statusCode == 401 {
                    await MainActor.run {
                        self.lastError = "Token invalid or expired. Generate a new token at account.smartthings.com/tokens."
                    }
                    return
                }

                let root = try JSONDecoder().decode(DevicesResponse.self, from: data)
                let monitors = root.items.filter { device in
                    device.components?.contains(where: { component in
                        component.capabilities?.contains(where: {
                            $0.id == "samsungvd.mediaInputSource" || $0.id == "mediaInputSource"
                        }) == true
                    }) == true
                }.map { d in
                    SmartThingsDevice(id: d.deviceId, name: d.name, label: d.label ?? d.name)
                }

                await MainActor.run {
                    self.detectedDevices = monitors
                    if monitors.isEmpty {
                        self.lastError = "No monitor devices found. Make sure your Samsung M7/M8 is added to SmartThings and connected to Wi-Fi."
                    }
                }
            } catch {
                await MainActor.run { self.lastError = "Discovery failed: \(error.localizedDescription)" }
            }
        }
    }

    func fetchSupportedInputSources() {
        guard !config.personalAccessToken.isEmpty, !config.deviceId.isEmpty else { return }
        isQuerying = true
        lastError = nil

        Task {
            defer { Task { @MainActor in self.isQuerying = false } }
            do {
                let capabilities = ["samsungvd.mediaInputSource", "mediaInputSource"]
                for cap in capabilities {
                    let urlStr = "\(Self.baseURL)/devices/\(config.deviceId)/components/main/capabilities/\(cap)/status"
                    guard let url = URL(string: urlStr) else { continue }
                    var req = URLRequest(url: url)
                    req.setValue("Bearer \(config.personalAccessToken)", forHTTPHeaderField: "Authorization")

                    let (data, resp) = try await session.data(for: req)
                    guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { continue }

                    if let status = parseInputSourceStatus(from: data) {
                        await MainActor.run {
                            self.availableInputSources = status.supported
                            if let current = status.current, !current.isEmpty {
                                self.config.myInputSource = current
                            }
                        }
                        return
                    }
                }
                await MainActor.run {
                    self.lastError = "Could not fetch input sources — using defaults."
                }
            } catch {
                await MainActor.run { self.lastError = "Fetch sources failed: \(error.localizedDescription)" }
            }
        }
    }

    // MARK: - Private helpers

    private func setInputSource(_ source: String) async {
        let capabilities = ["samsungvd.mediaInputSource", "mediaInputSource"]
        for cap in capabilities {
            let urlStr = "\(Self.baseURL)/devices/\(config.deviceId)/commands"
            guard let url = URL(string: urlStr) else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("Bearer \(config.personalAccessToken)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let body: [String: Any] = [
                "commands": [[
                    "component": "main",
                    "capability": cap,
                    "command": "setInputSource",
                    "arguments": [source]
                ]]
            ]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)

            do {
                let (_, resp) = try await session.data(for: req)
                if let http = resp as? HTTPURLResponse {
                    if http.statusCode == 401 {
                        await MainActor.run {
                            self.lastError = "Token invalid or expired. Generate a new token at account.smartthings.com/tokens."
                        }
                        return
                    }
                    if http.statusCode == 200 { return }
                }
            } catch {
                await MainActor.run { self.lastError = "Switch failed: \(error.localizedDescription)" }
            }
        }
    }

    struct InputSourceStatus {
        let current: String?
        let supported: [String]
    }

    private func parseInputSourceStatus(from data: Data) -> InputSourceStatus? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let key = root["inputSource"] as? [String: Any]
        let current = key?["value"] as? String
        if let supported = key?["supportedValues"] as? [String], !supported.isEmpty {
            return InputSourceStatus(current: current, supported: supported)
        }
        if let supported = key?["supportedInputSources"] as? [String], !supported.isEmpty {
            return InputSourceStatus(current: current, supported: supported)
        }
        return nil
    }

    // MARK: - Persistence

    private func saveConfig() {
        if let data = try? JSONEncoder().encode(config) {
            try? data.write(to: configURL)
        }
    }

    private static func loadConfig() -> Config? {
        let url: URL = {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            return support.appendingPathComponent("OctopusSync/monitor_config.json")
        }()
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Config.self, from: data)
    }

    // MARK: - SmartThings API response models

    private struct DevicesResponse: Codable {
        let items: [STDevice]
    }
    private struct STDevice: Codable {
        let deviceId: String
        let name: String
        let label: String?
        let components: [STComponent]?
    }
    private struct STComponent: Codable {
        let capabilities: [STCapability]?
    }
    private struct STCapability: Codable {
        let id: String
    }
}
