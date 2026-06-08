import Foundation
import Network
import Combine

class NetworkManager: ObservableObject {
    @Published var connectionStatus: AppState.ConnectionStatus = .disconnected
    @Published var networkType: NetworkType = .unknown

    enum NetworkType: Equatable {
        case wifi, wiredEthernet, direct, unknown

        var displayName: String {
            switch self {
            case .wifi: return "WiFi"
            case .wiredEthernet: return "Ethernet"
            case .direct: return "Direct"
            case .unknown: return ""
            }
        }
    }

    var onEventReceived: ((InputEvent) -> Void)?

    // Active transport that won the race to .connected.
    private enum ActiveTransport { case bonjour, multipeer }
    private var activeTransport: ActiveTransport?

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var pathMonitor: NWPathMonitor?
    private let mcPeer = MCPeerManager()
    private var started = false

    // Tracks connections we intentionally cancelled so .cancelled doesn't
    // trigger teardown as if it were an unexpected disconnect.
    private var cancelledConnections = Set<ObjectIdentifier>()

    private let serviceType = "_octopussync._tcp"
    private let myName: String = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    private let instanceID = UUID().uuidString

    private var recvBuffer = Data()
    private var pendingSendCount = 0

    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()

    // MARK: - Lifecycle

    private static let logFile: FileHandle? = {
        let path = "/tmp/octopus-debug.log"
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()

    static func log(_ msg: String) {
        let line = "\(Date()) \(msg)\n"
        logFile?.seekToEndOfFile()
        logFile?.write(line.data(using: .utf8)!)
        print(msg)
    }

    func start() {
        guard !started else { return }
        started = true
        Self.log("[Network] start() — myName: \(myName)")
        startPathMonitor()
        startListening()
        startBrowsing()
        startMCPeer()
    }

    func stop() {
        started = false
        activeTransport = nil
        cancelIntentionally(connection)
        listener?.cancel()
        browser?.cancel()
        pathMonitor?.cancel()
        mcPeer.stop()
        connection = nil
        listener = nil
        browser = nil
        pathMonitor = nil
        DispatchQueue.main.async { self.connectionStatus = .disconnected }
    }

    // Cancel a connection without triggering teardown recovery.
    private func cancelIntentionally(_ conn: NWConnection?) {
        guard let conn else { return }
        cancelledConnections.insert(ObjectIdentifier(conn))
        conn.cancel()
    }

    // MARK: - Path monitoring

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let type = Self.networkType(from: path)
            DispatchQueue.main.async {
                self.networkType = type
                // Network came back while we're disconnected — kick reconnection.
                if type != .unknown && self.started && self.activeTransport == nil {
                    Self.log("[PathMonitor] network restored, restarting discovery")
                    self.startBrowsing()
                    self.startMCPeer()
                }
            }
        }
        monitor.start(queue: .main)
    }

    private static func networkType(from path: NWPath?) -> NetworkType {
        guard let path, path.status == .satisfied else { return .unknown }
        if path.usesInterfaceType(.other) { return .direct }
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.wiredEthernet) { return .wiredEthernet }
        return .unknown
    }

    // MARK: - Multipeer (Direct / AWDL)

    private func startMCPeer() {
        mcPeer.onConnected = { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                guard self.activeTransport == nil else {
                    Self.log("[MC] connected but Bonjour already won — stopping MC")
                    self.mcPeer.stop()
                    return
                }
                Self.log("[MC] CONNECTED (Direct)")
                self.activeTransport = .multipeer
                self.networkType = .direct
                self.connectionStatus = .connected
                // Bonjour outbound connection (if any) is no longer needed.
                self.cancelIntentionally(self.connection)
                self.connection = nil
            }
        }

        mcPeer.onDisconnected = { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                guard self.activeTransport == .multipeer else { return }
                Self.log("[MC] disconnected — waiting 3s before teardown (AWDL may recover)")
                // AWDL (Direct) sessions drop briefly when the radio is busy with
                // AirDrop, Handoff, or BLE scans. Give MCSession time to reconnect
                // before falling back to WiFi — otherwise a 200ms blip causes a
                // full transport switch and the user sees Direct→WiFi flicker.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self, self.activeTransport == .multipeer else { return }
                    Self.log("[MC] still disconnected after grace period — tearing down")
                    self.teardown()
                }
            }
        }

        mcPeer.onDataReceived = { [weak self] data in
            guard let self, self.activeTransport == .multipeer else { return }
            self.recvBuffer.append(data)
            self.drainFrames()
        }

        mcPeer.start()
    }

    // MARK: - Listening (Bonjour/TCP)

    private func startListening() {
        listener?.cancel()

        let params = NWParameters.tcp
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 2
            tcp.keepaliveInterval = 2
            tcp.keepaliveCount = 3
        }

        do {
            let l = try NWListener(using: params)
            listener = l
            let txtRecord = NWTXTRecord(["id": instanceID])
            l.service = NWListener.Service(name: myName, type: serviceType, txtRecord: txtRecord)

            l.stateUpdateHandler = { [weak self, weak l] state in
                Self.log("[Listener] state: \(state)")
                DispatchQueue.main.async {
                    guard let self, self.listener === l else { return }
                    switch state {
                    case .ready:
                        if self.connectionStatus == .disconnected {
                            self.connectionStatus = .hosting
                        }
                    case .failed(let err):
                        Self.log("[Listener] failed: \(err) — will restart in 3s")
                        self.listener = nil
                        // Restart listener when network recovers (e.g. router came back).
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                            guard let self, self.started else { return }
                            self.startListening()
                        }
                    default:
                        break
                    }
                }
            }

            l.newConnectionHandler = { [weak self] newConn in
                guard let self, self.connection == nil, self.activeTransport == nil else {
                    Self.log("[Listener] rejecting inbound (already connected): \(newConn.endpoint)")
                    newConn.cancel()
                    return
                }
                Self.log("[Listener] accepting inbound: \(newConn.endpoint)")
                self.setupConnection(newConn)
            }

            l.start(queue: .main)
        } catch {
            Self.log("[Listener] failed to create: \(error)")
        }
    }

    // MARK: - Browsing (Bonjour/TCP)

    private func startBrowsing() {
        browser?.cancel()

        let b = NWBrowser(for: .bonjour(type: serviceType, domain: "local."), using: .init())
        browser = b

        b.stateUpdateHandler = { [weak self, weak b] state in
            Self.log("[Browser] state: \(state)")
            DispatchQueue.main.async {
                guard let self, self.browser === b else { return }
                switch state {
                case .ready:
                    if self.connectionStatus == .disconnected {
                        self.connectionStatus = .lookingForHost
                    }
                case .failed(let err):
                    Self.log("[Browser] failed: \(err) — will restart in 3s")
                    self.browser = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                        guard let self, self.started, self.activeTransport == nil else { return }
                        self.startBrowsing()
                    }
                default:
                    break
                }
            }
        }

        b.browseResultsChangedHandler = { [weak self] results, _ in
            Self.log("[Browser] results changed: \(results.count) result(s)")
            for r in results { Self.log("[Browser]   endpoint: \(r.endpoint)") }
            guard let self, self.connection == nil, self.activeTransport == nil else {
                Self.log("[Browser] skipped — connection already exists")
                return
            }

            for result in results {
                if self.isOwnResult(result) {
                    Self.log("[Browser] skipping own endpoint: \(result.endpoint)")
                    continue
                }
                // Role election: smaller hostname initiates. Avoids simultaneous-connect
                // race where both sides reject each other's inbound.
                guard self.shouldInitiate(toward: result.endpoint) else {
                    Self.log("[Browser] not initiating to \(result.endpoint) — peer is server")
                    continue
                }
                Self.log("[Browser] connecting to peer: \(result.endpoint)")
                self.connectToEndpoint(result.endpoint)
                break
            }
        }

        b.start(queue: .main)
        if connectionStatus == .disconnected {
            connectionStatus = .lookingForHost
        }
    }

    private func isOwnResult(_ result: NWBrowser.Result) -> Bool {
        if case .bonjour(let txtRecord) = result.metadata {
            if let peerID = txtRecord.dictionary["id"], peerID == instanceID { return true }
        }
        if case .service(let name, _, _, _) = result.endpoint {
            return baseServiceName(name) == myName
        }
        return false
    }

    private func baseServiceName(_ name: String) -> String {
        name.replacingOccurrences(of: #" \(\d+\)$"#, with: "", options: .regularExpression)
    }

    private func shouldInitiate(toward endpoint: NWEndpoint) -> Bool {
        guard case .service(let name, _, _, _) = endpoint else { return true }
        return myName < baseServiceName(name)
    }

    // MARK: - Connecting (Bonjour/TCP)

    private func connectToEndpoint(_ endpoint: NWEndpoint) {
        let params = NWParameters.tcp
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 2
            tcp.keepaliveInterval = 2
            tcp.keepaliveCount = 3
        }
        setupConnection(NWConnection(to: endpoint, using: params))
    }

    private func setupConnection(_ conn: NWConnection) {
        connection = conn
        recvBuffer = Data()
        Self.log("[Connection] setting up to \(conn.endpoint)")

        conn.stateUpdateHandler = { [weak self] state in
            Self.log("[Connection] state: \(state) for \(conn.endpoint)")
            guard let self else { return }
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    guard self.activeTransport == nil else {
                        Self.log("[Connection] Bonjour ready but MC already won — cancelling")
                        self.cancelIntentionally(conn)
                        return
                    }
                    Self.log("[Connection] READY (Bonjour): \(conn.endpoint)")
                    self.activeTransport = .bonjour
                    self.networkType = Self.networkType(from: conn.currentPath)
                    self.connectionStatus = .connected
                    self.mcPeer.stop()
                    self.receiveNextFrame()
                case .preparing:
                    Self.log("[Connection] PREPARING: \(conn.endpoint)")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak conn] in
                        guard let self, let conn, self.connection === conn else { return }
                        if conn.state == .preparing || conn.state == .setup {
                            Self.log("[Connection] stuck in preparing, tearing down")
                            self.teardown()
                        }
                    }
                case .failed(let err):
                    Self.log("[Connection] FAILED: \(err)")
                    self.teardown()
                case .cancelled:
                    // Only treat as unexpected disconnect if this wasn't our own cancel.
                    let key = ObjectIdentifier(conn)
                    if self.cancelledConnections.remove(key) != nil {
                        Self.log("[Connection] cancelled intentionally — no teardown")
                    } else {
                        Self.log("[Connection] cancelled externally — tearing down")
                        self.teardown()
                    }
                default:
                    break
                }
            }
        }

        conn.start(queue: .main)
    }

    private func teardown() {
        activeTransport = nil
        cancelIntentionally(connection)
        connection = nil
        recvBuffer = Data()
        pendingSendCount = 0
        guard connectionStatus != .disconnected else { return }
        connectionStatus = .disconnected
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.started else { return }
            self.startListening()
            self.startBrowsing()
            self.startMCPeer()
        }
    }

    // MARK: - Sending

    func sendEvent(_ event: InputEvent) {
        let isMove = event.type == .mouseMove
        if isMove && pendingSendCount > 3 { return }
        guard let frame = encodeFrame(event) else { return }

        switch activeTransport {
        case .bonjour:
            guard let conn = connection, conn.state == .ready else { return }
            pendingSendCount += 1
            conn.send(content: frame, completion: .contentProcessed({ [weak self] _ in
                self?.pendingSendCount -= 1
            }))
        case .multipeer:
            // mouseMove: unreliable (no head-of-line blocking, stale deltas are useless).
            // Everything else: reliable (clicks, keys, control messages must not be lost).
            mcPeer.send(frame, reliable: !isMove, isMove: isMove)
        case .none:
            break
        }
    }

    private func encodeFrame(_ event: InputEvent) -> Data? {
        guard let payload = try? jsonEncoder.encode(event) else { return nil }
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(payload)
        return frame
    }

    // MARK: - Receiving

    private func receiveNextFrame() {
        guard let conn = connection else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.recvBuffer.append(data)
                self.drainFrames()
            }
            if let error {
                Self.log("Receive error: \(error)")
                DispatchQueue.main.async { self.teardown() }
                return
            }
            if isComplete {
                DispatchQueue.main.async { self.teardown() }
                return
            }
            self.receiveNextFrame()
        }
    }

    private func drainFrames() {
        while recvBuffer.count >= 4 {
            let length = recvBuffer.prefix(4).withUnsafeBytes {
                UInt32(bigEndian: $0.load(as: UInt32.self))
            }
            let total = 4 + Int(length)
            guard recvBuffer.count >= total else { break }
            let start = recvBuffer.startIndex
            let payload = recvBuffer.subdata(in: start + 4 ..< start + total)
            recvBuffer.removeFirst(total)
            if let event = try? jsonDecoder.decode(InputEvent.self, from: payload) {
                onEventReceived?(event)
            }
        }
    }
}
