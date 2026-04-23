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
    
    func start() {
        // Start discovering and listening
        startListening()
        startBrowsing()
    }
    
    func stop() {
        listener?.cancel()
        browser?.cancel()
        connection?.cancel()
        connectionStatus = .disconnected
    }
    
    private func startListening() {
        do {
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            listener = try NWListener(using: parameters)
            listener?.service = NWListener.Service(name: Host.current().localizedName, type: serviceType)
            
            listener?.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    DispatchQueue.main.async { self?.connectionStatus = .hosting }
                case .failed(let error):
                    print("Listener failed: \(error)")
                    DispatchQueue.main.async { self?.connectionStatus = .disconnected }
                default:
                    break
                }
            }
            
            listener?.newConnectionHandler = { [weak self] newConnection in
                self?.setupConnection(newConnection)
            }
            
            listener?.start(queue: .main)
        } catch {
            print("Failed to create listener: \(error)")
        }
    }
    
    private func startBrowsing() {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        
        browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: parameters)
        
        browser?.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                DispatchQueue.main.async {
                    if self?.connectionStatus == .disconnected {
                        self?.connectionStatus = .lookingForHost
                    }
                }
            }
        }
        
        browser?.browseResultsChangedHandler = { [weak self] results, changes in
            guard let self = self, self.connection == nil else { return }
            
            for result in results {
                if case .service(let name, _, _, _) = result.endpoint, name != Host.current().localizedName {
                    let newConnection = NWConnection(to: result.endpoint, using: .tcp)
                    self.setupConnection(newConnection)
                    break // Connect to the first discovered peer for now
                }
            }
        }
        
        browser?.start(queue: .main)
    }
    
    private func setupConnection(_ connection: NWConnection) {
        self.connection = connection
        
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                DispatchQueue.main.async { self?.connectionStatus = .connected }
                self?.receiveMessage()
            case .failed(let error):
                print("Connection failed: \(error)")
                DispatchQueue.main.async { self?.connectionStatus = .disconnected }
                self?.connection = nil
            case .cancelled:
                DispatchQueue.main.async { self?.connectionStatus = .disconnected }
                self?.connection = nil
            default:
                break
            }
        }
        
        connection.start(queue: .main)
    }
    
    func sendEvent(_ event: InputEvent) {
        guard let connection = connection, connection.state == .ready else { return }
        
        do {
            let data = try JSONEncoder().encode(event)
            let lengthData = withUnsafeBytes(of: UInt32(data.count).bigEndian) { Data($0) }
            
            connection.send(content: lengthData + data, completion: .contentProcessed({ error in
                if let error = error {
                    print("Failed to send event: \(error)")
                }
            }))
        } catch {
            print("Failed to encode event: \(error)")
        }
    }
    
    private func receiveMessage() {
        guard let connection = connection else { return }
        
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self = self, let data = data, data.count == 4 else {
                if error == nil && !isComplete { self?.receiveMessage() }
                return
            }
            
            let length = UInt32(bigEndian: data.withUnsafeBytes { $0.load(as: UInt32.self) })
            
            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { payload, _, _, _ in
                if let payload = payload {
                    do {
                        let event = try JSONDecoder().decode(InputEvent.self, from: payload)
                        self.onEventReceived?(event)
                    } catch {
                        print("Failed to decode event: \(error)")
                    }
                }
                self.receiveMessage()
            }
        }
    }
}
