import Foundation
import Network
import Combine

class NetworkManager: ObservableObject {
    @Published var connectionStatus: AppState.ConnectionStatus = .disconnected

    var onEventReceived: ((InputEvent) -> Void)?

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var started = false

    private let serviceType = "_octopussync._tcp"
    private let myName: String = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    private let instanceID = UUID().uuidString

    private var recvBuffer = Data()

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
        // Guard against being called multiple times (e.g. on every menu open).
        guard !started else { return }
        started = true
        Self.log("[Network] start() — myName: \(myName)")
        startListening()
        startBrowsing()
    }

    func stop() {
        started = false
        listener?.cancel()
        browser?.cancel()
        connection?.cancel()
        listener = nil
        browser = nil
        connection = nil
        DispatchQueue.main.async { self.connectionStatus = .disconnected }
    }

    // MARK: - Listening

    private func startListening() {
        let params = NWParameters.tcp
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }

        do {
            listener = try NWListener(using: params)
            let txtRecord = NWTXTRecord(["id": instanceID])
            listener?.service = NWListener.Service(name: myName, type: serviceType, txtRecord: txtRecord)

            listener?.stateUpdateHandler = { [weak self] state in
                Self.log("[Listener] state: \(state)")
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        if self?.connectionStatus == .disconnected {
                            self?.connectionStatus = .hosting
                        }
                    case .failed(let err):
                        Self.log("[Listener] failed: \(err)")
                        self?.connectionStatus = .disconnected
                    default:
                        break
                    }
                }
            }

            listener?.newConnectionHandler = { [weak self] newConn in
                guard let self, self.connection == nil else {
                    Self.log("[Listener] rejecting inbound (already connected): \(newConn.endpoint)")
                    newConn.cancel()
                    return
                }
                Self.log("[Listener] accepting inbound: \(newConn.endpoint)")
                self.setupConnection(newConn)
            }

            listener?.start(queue: .main)
        } catch {
            print("Failed to create listener:", error)
        }
    }

    // MARK: - Browsing

    private func startBrowsing() {
        browser?.cancel()

        browser = NWBrowser(for: .bonjour(type: serviceType, domain: "local."), using: .init())

        browser?.stateUpdateHandler = { [weak self] state in
            Self.log("[Browser] state: \(state)")
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    if self?.connectionStatus == .disconnected {
                        self?.connectionStatus = .lookingForHost
                    }
                case .failed(let err):
                    Self.log("[Browser] failed: \(err)")
                default:
                    break
                }
            }
        }

        browser?.browseResultsChangedHandler = { [weak self] results, _ in
            Self.log("[Browser] results changed: \(results.count) result(s)")
            for r in results {
                Self.log("[Browser]   endpoint: \(r.endpoint)")
            }
            guard let self, self.connection == nil else {
                Self.log("[Browser] skipped — connection already exists")
                return
            }

            for result in results {
                if self.isOwnResult(result) {
                    Self.log("[Browser] skipping own endpoint: \(result.endpoint)")
                    continue
                }
                // Role election: only the peer with the lexicographically smaller
                // name initiates the outbound connection. The other side waits for
                // its listener to accept the incoming connection. This avoids the
                // simultaneous-connect race where both sides dial each other and
                // both reject the inbound (because their own outbound is already
                // pending), leaving both stuck in .preparing.
                guard self.shouldInitiate(toward: result.endpoint) else {
                    Self.log("[Browser] not initiating to \(result.endpoint) — peer is server")
                    continue
                }
                Self.log("[Browser] connecting to peer: \(result.endpoint)")
                self.connectToEndpoint(result.endpoint)
                break
            }
        }

        browser?.start(queue: .main)
        DispatchQueue.main.async {
            if self.connectionStatus == .disconnected {
                self.connectionStatus = .lookingForHost
            }
        }
    }

    // Checks if a discovered endpoint belongs to this Mac.
    private func isOwnResult(_ result: NWBrowser.Result) -> Bool {
        if case .bonjour(let txtRecord) = result.metadata {
            if let peerID = txtRecord.dictionary["id"], peerID == instanceID {
                return true
            }
        }
        if case .service(let name, _, _, _) = result.endpoint {
            return baseServiceName(name) == myName
        }
        return false
    }

    private func baseServiceName(_ name: String) -> String {
        name.replacingOccurrences(of: #" \(\d+\)$"#, with: "", options: .regularExpression)
    }

    // Returns true if this Mac should initiate the outbound connection to the
    // given peer. We compare hostnames lexicographically — the smaller name wins
    // the "client" role. Without this tie-breaker, both peers dial each other
    // simultaneously and both inbounds get rejected, leaving both stuck in .preparing.
    private func shouldInitiate(toward endpoint: NWEndpoint) -> Bool {
        guard case .service(let name, _, _, _) = endpoint else { return true }
        let peerName = baseServiceName(name)
        return myName < peerName
    }

    // MARK: - Connecting

    private func connectToEndpoint(_ endpoint: NWEndpoint) {
        let params = NWParameters.tcp
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
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
                    Self.log("[Connection] READY: \(conn.endpoint)")
                    self.connectionStatus = .connected
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
                    self.teardown()
                default:
                    break
                }
            }
        }

        conn.start(queue: .main)
    }

    private func teardown() {
        connection?.cancel()
        connection = nil
        recvBuffer = Data()
        guard connectionStatus != .disconnected else { return }
        connectionStatus = .disconnected
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.started else { return }
            self.startBrowsing()
        }
    }

    // MARK: - Sending

    func sendEvent(_ event: InputEvent) {
        guard let conn = connection, conn.state == .ready else { return }
        guard let frame = encodeFrame(event) else { return }
        conn.send(content: frame, completion: .contentProcessed({ _ in }))
    }

    private func encodeFrame(_ event: InputEvent) -> Data? {
        guard let payload = try? JSONEncoder().encode(event) else { return nil }
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
                print("Receive error:", error)
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
            let payload = recvBuffer.subdata(in: 4..<total)
            recvBuffer.removeFirst(total)
            if let event = try? JSONDecoder().decode(InputEvent.self, from: payload) {
                onEventReceived?(event)
            }
        }
    }
}
