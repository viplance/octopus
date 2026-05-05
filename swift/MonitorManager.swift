import Foundation
import Combine

// Manages Samsung M7/M8 monitor input switching via the SmartThings cloud API.
// DDC/CI is not supported on M7 hardware, so we use the SmartThings REST API.
class MonitorManager: ObservableObject {

    // MARK: - Persisted configuration

    struct Config: Codable {
        var enabled: Bool
        var personalAccessToken: String
        var deviceId: String
        // The input source this Mac should activate when it gains focus.
        // e.g. "HDMI1", "HDMI2", "USB-C"
        var myInputSource: String
    }

    @Published var config: Config {
        didSet { saveConfig() }
    }

    /// All supported input source names (queried live from SmartThings; fallback list used until queried).
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
            personalAccessToken: "",
            deviceId: "",
            myInputSource: "HDMI1"
        )
    }

    // MARK: - Toggle entry point

    /// Called by AppState when the user toggles sync ON (this Mac gains focus).
    /// Switches the monitor to `myInputSource`.
    func switchToThisMac() {
        guard config.enabled,
              !config.personalAccessToken.isEmpty,
              !config.deviceId.isEmpty,
              !config.myInputSource.isEmpty
        else { return }

        Task {
            await setInputSource(config.myInputSource)
        }
    }

    // MARK: - SmartThings API

    private static let baseURL = "https://api.smartthings.com/v1"

    /// Lists all SmartThings devices. Populates `detectedDevices` with monitors
    /// that expose the mediaInputSource capability.
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

                let (data, _) = try await session.data(for: req)
                let root = try JSONDecoder().decode(DevicesResponse.self, from: data)

                // Filter to devices that advertise a media input source capability
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

    /// Fetches the list of supported input source names for the configured device.
    func fetchSupportedInputSources() {
        guard !config.personalAccessToken.isEmpty, !config.deviceId.isEmpty else { return }
        isQuerying = true
        lastError = nil

        Task {
            defer { Task { @MainActor in self.isQuerying = false } }
            do {
                // Try samsungvd.mediaInputSource first (M7/M8), fall back to mediaInputSource
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
                if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                    return // success
                }
            } catch {
                await MainActor.run { self.lastError = "Switch failed: \(error.localizedDescription)" }
            }
        }
    }

    private func parseInputSources(from data: Data) -> [String]? {
        // The status response looks like:
        // { "inputSource": { "value": "HDMI1", "supportedValues": ["HDMI1","HDMI2","USB-C"] } }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let key = root["inputSource"] as? [String: Any]
        if let supported = key?["supportedValues"] as? [String], !supported.isEmpty {
            return supported
        }
        // Some firmware uses "supportedInputSources"
        if let supported = key?["supportedInputSources"] as? [String], !supported.isEmpty {
            return supported
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
