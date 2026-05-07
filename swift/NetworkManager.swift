import Foundation
import Network
import Combine

class NetworkManager: ObservableObject {
    @Published var connectionStatus: AppState.ConnectionStatus = .disconnected

    var onEventReceived: ((InputEvent) -> Void)?

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connection: NWConnection?

    private let serviceType = "_octopussync._tcp"
    private let myName: String = Host.current().localizedName ?? ProcessInfo.processInfo.hostName

    // Length-prefix framing state for incoming data
    private var recvBuffer = Data()

    func start() {
        startListening()
        startBrowsing()
    }

    func stop() {
        listener?.cancel()
        browser?.cancel()
        connection?.cancel()
        listener = nil
        browser = nil
        connection = nil
        DispatchQueue.main.async { self.connectionStatus = .disconnected }
    }

    // MARK: - Listening (we are the server)

    private func startListening() {
        let params = NWParameters.tcp
        params.includePeerToPeer = true

        do {
            listener = try NWListener(using: params)
            listener?.service = NWListener.Service(name: myName, type: serviceType)

            listener?.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        if self?.connectionStatus == .disconnected {
                            self?.connectionStatus = .hosting
                        }
                    case .failed(let err):
                        print("Listener failed:", err)
                        self?.connectionStatus = .disconnected
                    default:
                        break
                    }
                }
            }

            listener?.newConnectionHandler = { [weak self] newConn in
                guard let self, self.connection == nil else {
                    newConn.cancel()
                    return
                }
                print("Incoming connection from listener")
                self.setupConnection(newConn)
            }

            listener?.start(queue: .main)
        } catch {
            print("Failed to create listener:", error)
        }
    }

    // MARK: - Browsing (we are the client)

    private func startBrowsing() {
        let params = NWParameters()
        params.includePeerToPeer = true

        browser = NWBrowser(for: .bonjour(type: serviceType, domain: "local."), using: params)

        browser?.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    if self?.connectionStatus == .disconnected {
                        self?.connectionStatus = .lookingForHost
                    }
                case .failed(let err):
                    print("Browser failed:", err)
                default:
                    break
                }
            }
        }

        browser?.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, self.connection == nil else { return }

            for result in results {
                // Skip our own service
                if case .service(let name, _, _, _) = result.endpoint {
                    if name == self.myName { continue }
                }
                print("Discovered peer:", result.endpoint)
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

    // MARK: - Connecting

    private func connectToEndpoint(_ endpoint: NWEndpoint) {
        // Use TCP with peer-to-peer so AWDL/Wi-Fi Direct paths are included
        let params = NWParameters.tcp
        params.includePeerToPeer = true

        let conn = NWConnection(to: endpoint, using: params)
        setupConnection(conn)
    }

    private func setupConnection(_ conn: NWConnection) {
        connection = conn
        recvBuffer = Data()

        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    print("Connection ready:", conn.endpoint)
                    self.connectionStatus = .connected
                    self.receiveNextFrame()
                case .failed(let err):
                    print("Connection failed:", err)
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
        if connectionStatus != .disconnected {
            connectionStatus = .disconnected
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.startBrowsing()
            }
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

    // MARK: - Receiving (length-prefixed frames)

    private func receiveNextFrame() {
        guard let conn = connection else { return }

        // Read at least 4 bytes (the length header)
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
