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
    // Called with true when AWDL appears throttled (sent < 5/s for 3+ consecutive
    // seconds while active), false when rate recovers. Used to show a warning.
    var onThrottleChanged: ((Bool) -> Void)?

    private let serviceType = "octopussync"   // max 15 chars, lowercase alphanumeric + hyphen
    private let myPeerID = MCPeerID(displayName: Host.current().localizedName ?? ProcessInfo.processInfo.hostName)

    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    private var started = false

    // Send-side diagnostics
    private var movesSentThisSecond = 0
    private var movesDroppedThisSecond = 0
    private var diagWindowStart: CFTimeInterval = 0

    // Receive-side gap diagnostics
    private var lastRecvTime: CFTimeInterval = 0
    private var recvCount = 0
    private var recvWindowStart: CFTimeInterval = 0
    private var recvGapMax: Double = 0
    private var recvGapSum: Double = 0
    private var recvGapSamples = 0

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

    // Consecutive low-rate seconds counter for throttle detection.
    private var lowRateSeconds = 0
    private var isThrottled = false

    // mouseMove frames are sent unreliable — no head-of-line blocking, stale
    // deltas are worthless anyway. Everything else (clicks, keys, control) uses
    // reliable so it is never silently dropped.
    func send(_ data: Data, reliable: Bool, isMove: Bool = false) {
        guard let session, !session.connectedPeers.isEmpty else { return }
        let mode: MCSessionSendDataMode = reliable ? .reliable : .unreliable
        let result = Result { try session.send(data, toPeers: session.connectedPeers, with: mode) }

        if isMove {
            let now = CFAbsoluteTimeGetCurrent()
            if diagWindowStart == 0 { diagWindowStart = now }
            switch result {
            case .success: movesSentThisSecond += 1
            case .failure: movesDroppedThisSecond += 1
            }
            if now - diagWindowStart >= 1.0 {
                NetworkManager.log("[MC] mouseMove sent=\(movesSentThisSecond) dropped=\(movesDroppedThisSecond) /s")
                // AWDL throttle detection: if user is actively moving (we got events
                // to send) but rate is < 5/s, AWDL radio is being starved by WiFi.
                // 3 consecutive low-rate seconds → throttled.
                let wasMoving = movesSentThisSecond + movesDroppedThisSecond > 0
                if wasMoving && movesSentThisSecond < 5 {
                    lowRateSeconds += 1
                } else {
                    lowRateSeconds = 0
                }
                let nowThrottled = lowRateSeconds >= 3
                if nowThrottled != isThrottled {
                    isThrottled = nowThrottled
                    DispatchQueue.main.async { self.onThrottleChanged?(nowThrottled) }
                }
                movesSentThisSecond = 0; movesDroppedThisSecond = 0; diagWindowStart = now
            }
        }
    }

    var isConnected: Bool {
        !(session?.connectedPeers.isEmpty ?? true)
    }
}

// MARK: - MCSessionDelegate

extension MCPeerManager: MCSessionDelegate {

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let stateName = state == .connected ? "connected" : state == .notConnected ? "notConnected" : "connecting"
        NetworkManager.log("[MC] peer \(peerID.displayName) → \(stateName)")
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
        let now = CFAbsoluteTimeGetCurrent()
        if lastRecvTime > 0 {
            let gapMs = (now - lastRecvTime) * 1000
            recvGapMax = max(recvGapMax, gapMs)
            recvGapSum += gapMs
            recvGapSamples += 1
        }
        lastRecvTime = now
        recvCount += 1
        if recvWindowStart == 0 { recvWindowStart = now }
        if now - recvWindowStart >= 1.0 {
            let avgGap = recvGapSamples > 0 ? recvGapSum / Double(recvGapSamples) : 0
            NetworkManager.log(String(format: "[MC-recv] %d frames/s  gap avg=%.1fms max=%.1fms",
                                      recvCount, avgGap, recvGapMax))
            recvCount = 0; recvGapSum = 0; recvGapMax = 0
            recvGapSamples = 0; recvWindowStart = now
        }
        // MCSession delivers on its own internal queue — dispatch to main to
        // keep recvBuffer access single-threaded with the rest of NetworkManager.
        DispatchQueue.main.async { self.onDataReceived?(data) }
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
