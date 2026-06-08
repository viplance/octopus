import Foundation
import MultipeerConnectivity

// Manages a single peer-to-peer (AWDL/Direct) connection via MultipeerConnectivity.
// Runs in parallel with the Bonjour/TCP transport in NetworkManager — whichever
// reaches .connected first wins; the other is torn down.
//
// Thread-safety: all callbacks are dispatched to DispatchQueue.main.
final class MCPeerManager: NSObject {

    // Called when a p2p session is established and data arrives.
    var onConnected: (() -> Void)?
    var onDisconnected: (() -> Void)?
    var onDataReceived: ((Data) -> Void)?

    private let serviceType = "octopussync"   // max 15 chars, lowercase alphanumeric + hyphen
    private let myPeerID = MCPeerID(displayName: Host.current().localizedName ?? ProcessInfo.processInfo.hostName)

    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    private var started = false

    func start() {
        guard !started else { return }
        started = true

        let s = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .required)
        s.delegate = self
        session = s

        let adv = MCNearbyServiceAdvertiser(peer: myPeerID, discoveryInfo: nil, serviceType: serviceType)
        adv.delegate = self
        adv.startAdvertisingPeer()
        advertiser = adv

        let br = MCNearbyServiceBrowser(peer: myPeerID, serviceType: serviceType)
        br.delegate = self
        br.startBrowsingForPeers()
        browser = br

        NetworkManager.log("[MC] started, peerID: \(myPeerID.displayName)")
    }

    func stop() {
        guard started else { return }
        started = false
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session?.disconnect()
        advertiser = nil
        browser = nil
        session = nil
        NetworkManager.log("[MC] stopped")
    }

    func send(_ data: Data) {
        guard let session, !session.connectedPeers.isEmpty else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }

    var isConnected: Bool {
        !(session?.connectedPeers.isEmpty ?? true)
    }
}

// MARK: - MCSessionDelegate

extension MCPeerManager: MCSessionDelegate {

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        NetworkManager.log("[MC] peer \(peerID.displayName) state: \(state.rawValue)")
        DispatchQueue.main.async {
            switch state {
            case .connected:
                self.onConnected?()
            case .notConnected:
                self.onDisconnected?()
            default:
                break
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        onDataReceived?(data)
    }

    // Unused stream/resource callbacks — required by protocol.
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension MCPeerManager: MCNearbyServiceAdvertiserDelegate {

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        NetworkManager.log("[MC] invitation from \(peerID.displayName)")
        // Accept only if we have no connected peers yet.
        guard let session, session.connectedPeers.isEmpty else {
            invitationHandler(false, nil)
            return
        }
        invitationHandler(true, session)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        NetworkManager.log("[MC] advertiser error: \(error)")
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension MCPeerManager: MCNearbyServiceBrowserDelegate {

    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        NetworkManager.log("[MC] found peer: \(peerID.displayName)")
        guard let session, session.connectedPeers.isEmpty else { return }
        // Role election identical to Bonjour transport: smaller name invites.
        guard myPeerID.displayName < peerID.displayName else {
            NetworkManager.log("[MC] skipping invite to \(peerID.displayName) — we are server")
            return
        }
        NetworkManager.log("[MC] inviting \(peerID.displayName)")
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 10)
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        NetworkManager.log("[MC] lost peer: \(peerID.displayName)")
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        NetworkManager.log("[MC] browser error: \(error)")
    }
}
