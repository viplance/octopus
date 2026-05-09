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
        // The input source this Mac should activate when it gains focus (SmartThings mode).
        var myInputSource: String
    }

    @Published var config: Config {
        didSet { saveConfig() }
    }

    @Published var availableInputSources: [String] = ["HDMI1", "HDMI2", "USB-C"]
    @Published var isQuerying = false
    @Published var lastError: String?
    @Published var detectedDevices: [SmartThingsDevice] = []

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
    }

    // MARK: - Toggle entry points

    /// Called when THIS Mac gains focus (peer just gave us control).
    /// Wakes the external display so the monitor shows this Mac's signal.
    func switchToThisMac() {
        guard config.enabled else { return }

        switch config.monitorMode {
        case .direct:
            wakeDisplay()
        case .smartThings:
            guard !config.personalAccessToken.isEmpty,
                  !config.deviceId.isEmpty,
                  !config.myInputSource.isEmpty
            else { return }
            Task { await setInputSource(config.myInputSource) }
        }
    }

    /// Called when THIS Mac gives focus to the peer.
    /// In Direct mode: sleep the external display so the monitor auto-switches.
    /// In SmartThings mode: the peer calls its own switchToThisMac via gainFocus.
    func switchToPeer() {
        guard config.enabled else { return }
        guard config.monitorMode == .direct else { return }
        sleepDisplay()
    }

    // MARK: - Direct mode display control

    private var disabledDisplayIDs: [CGDirectDisplayID] = []

    private func setExternalDisplaysEnabled(_ enabled: Bool) {
        let RTLD_DEFAULT = UnsafeMutableRawPointer(bitPattern: -2)
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

                    if let sources = parseInputSources(from: data) {
                        await MainActor.run { self.availableInputSources = sources }
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

    private func parseInputSources(from data: Data) -> [String]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let key = root["inputSource"] as? [String: Any]
        if let supported = key?["supportedValues"] as? [String], !supported.isEmpty { return supported }
        if let supported = key?["supportedInputSources"] as? [String], !supported.isEmpty { return supported }
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
