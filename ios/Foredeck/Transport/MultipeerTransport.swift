import Foundation
import MultipeerConnectivity
import ForedeckCore

/// Multipeer Connectivity implementation of `CrewTransport`.
///
/// Multipeer earns its place here by working when the boat's network does not.
/// It will use the marina WiFi, the boat's own router, Apple's peer-to-peer
/// WiFi, or Bluetooth, whichever is available, and it needs no router, no
/// server, no IP configuration and no multicast entitlement. A plain UDP design
/// would be simpler to reason about and would fail outright on any access point
/// with client isolation switched on -- which is most of the cheap ones.
///
/// What it costs us: a hard ceiling of eight devices in a session, and no audio
/// pipeline of its own, which is why `JitterBuffer` exists.
public final class MultipeerTransport: NSObject, CrewTransport, @unchecked Sendable {
    /// Bonjour service type. Must be 1-15 characters of lowercase letters,
    /// digits and hyphens, and must also appear in Info.plist's
    /// NSBonjourServices or iOS 14+ blocks discovery outright.
    public static let serviceType = "foredeck-v1"
    /// MCSession tops out at eight participants including ourselves.
    public static let maximumPeers = 7

    public weak var delegate: CrewTransportDelegate?
    public private(set) var state: TransportState = .idle {
        didSet {
            guard state != oldValue else { return }
            delegate?.transport(self, didChange: state)
        }
    }

    public var connectedPeers: [PeerHandle] {
        queue.sync { session?.connectedPeers.map { PeerHandle($0.displayName) } ?? [] }
    }

    private let queue = DispatchQueue(label: "com.foredeck.transport")
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var localPeerID: MCPeerID?
    private var identity: CrewIdentity?
    private var boatKey: BoatKey?
    /// Device ids of peers we have vetted at discovery time, so we can apply
    /// the invitation tie-break without re-deriving tokens.
    private var discoveredDeviceIDs: [MCPeerID: String] = [:]

    public override init() {
        super.init()
    }

    // MARK: - Lifecycle

    public func start(identity: CrewIdentity, boatName: String, key: BoatKey) {
        queue.async {
            self.teardown()
            self.identity = identity
            self.boatKey = key

            // MCPeerID names must be unique or two identically named phones
            // collapse into one handle. The suffix guarantees that; the roster
            // never shows it, because display names come from the hello
            // message rather than from the peer id.
            let name = "\(identity.advertisedName)#\(identity.deviceID.prefix(4))"
            let peerID = MCPeerID(displayName: String(name.prefix(60)))
            self.localPeerID = peerID

            let session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
            session.delegate = self
            self.session = session

            let discoveryInfo = [
                "d": identity.deviceID,
                "t": key.advertisementToken(for: identity.deviceID),
                "f": key.fingerprint
            ]
            let advertiser = MCNearbyServiceAdvertiser(
                peer: peerID,
                discoveryInfo: discoveryInfo,
                serviceType: Self.serviceType
            )
            advertiser.delegate = self
            advertiser.startAdvertisingPeer()
            self.advertiser = advertiser

            let browser = MCNearbyServiceBrowser(peer: peerID, serviceType: Self.serviceType)
            browser.delegate = self
            browser.startBrowsingForPeers()
            self.browser = browser

            self.state = .searching
        }
    }

    public func stop() {
        queue.async {
            if let session = self.session, !session.connectedPeers.isEmpty,
               let identity = self.identity {
                let envelope = ControlEnvelope(
                    sender: identity,
                    stamp: LamportStamp(counter: 0, deviceID: identity.deviceID),
                    message: .goodbye
                )
                if let data = try? envelope.encoded() {
                    try? session.send(
                        WireFrame.framedControl(data),
                        toPeers: session.connectedPeers,
                        with: .reliable
                    )
                }
            }
            self.teardown()
            self.state = .idle
        }
    }

    private func teardown() {
        advertiser?.stopAdvertisingPeer()
        advertiser?.delegate = nil
        advertiser = nil
        browser?.stopBrowsingForPeers()
        browser?.delegate = nil
        browser = nil
        session?.disconnect()
        session?.delegate = nil
        session = nil
        discoveredDeviceIDs.removeAll()
    }

    // MARK: - Sending

    public func sendAudio(_ data: Data) {
        queue.async {
            guard let session = self.session, !session.connectedPeers.isEmpty else { return }
            // Unreliable on purpose. A late voice frame is worse than a missing
            // one -- the jitter buffer would discard it anyway -- and retrying
            // it would delay everything queued behind it.
            try? session.send(data, toPeers: session.connectedPeers, with: .unreliable)
        }
    }

    public func sendControl(_ envelope: ControlEnvelope) {
        queue.async {
            guard let session = self.session, !session.connectedPeers.isEmpty else { return }
            self.send(envelope, to: session.connectedPeers, on: session)
        }
    }

    public func sendControl(_ envelope: ControlEnvelope, to peer: PeerHandle) {
        queue.async {
            guard let session = self.session,
                  let target = session.connectedPeers.first(where: { $0.displayName == peer.rawValue })
            else { return }
            self.send(envelope, to: [target], on: session)
        }
    }

    private func send(_ envelope: ControlEnvelope, to peers: [MCPeerID], on session: MCSession) {
        guard let payload = try? envelope.encoded() else { return }
        try? session.send(WireFrame.framedControl(payload), toPeers: peers, with: .reliable)
    }

    private func refreshState() {
        guard let session else { return }
        state = session.connectedPeers.isEmpty ? .searching : .connected(peerCount: session.connectedPeers.count)
    }
}

// MARK: - MCSessionDelegate

extension MultipeerTransport: MCSessionDelegate {
    public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        queue.async {
            switch state {
            case .connected:
                self.delegate?.transport(self, didConnect: PeerHandle(peerID.displayName))
            case .notConnected:
                self.discoveredDeviceIDs.removeValue(forKey: peerID)
                self.delegate?.transport(self, didDisconnect: PeerHandle(peerID.displayName))
            case .connecting:
                break
            @unknown default:
                break
            }
            self.refreshState()
        }
    }

    public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        // Timestamp before anything else. The jitter buffer's whole adaptation
        // rests on this being when the packet arrived, not when a queue got
        // round to it. systemUptime is monotonic, so a GPS time fix mid-session
        // cannot make it jump.
        let arrivalTime = ProcessInfo.processInfo.systemUptime
        let handle = PeerHandle(peerID.displayName)

        guard let frame = WireFrame.classify(data) else { return }
        switch frame {
        case .audio(let payload):
            delegate?.transport(self, didReceiveAudio: payload, from: handle, arrivalTime: arrivalTime)
        case .control(let payload):
            guard let envelope = try? ControlEnvelope(decoding: payload) else { return }
            queue.async {
                self.delegate?.transport(self, didReceiveControl: envelope, from: handle)
            }
        }
    }

    public func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
        // Unused. Streams are TCP-like and head-of-line block, so one lost
        // voice frame would stall everything behind it.
    }

    public func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}

    public func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - Advertising

extension MultipeerTransport: MCNearbyServiceAdvertiserDelegate {
    public func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        queue.async {
            guard let session = self.session,
                  let key = self.boatKey,
                  session.connectedPeers.count < Self.maximumPeers,
                  let context,
                  let credentials = try? JSONDecoder().decode(PeerCredentials.self, from: context),
                  key.matches(token: credentials.token, deviceID: credentials.deviceID)
            else {
                invitationHandler(false, nil)
                return
            }
            self.discoveredDeviceIDs[peerID] = credentials.deviceID
            invitationHandler(true, session)
        }
    }

    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        queue.async { self.state = .failed(Self.describe(error)) }
    }
}

// MARK: - Browsing

extension MultipeerTransport: MCNearbyServiceBrowserDelegate {
    public func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        queue.async {
            guard let session = self.session,
                  let identity = self.identity,
                  let key = self.boatKey,
                  let info,
                  let peerDeviceID = info["d"],
                  let token = info["t"],
                  key.matches(token: token, deviceID: peerDeviceID)
            else { return }

            self.discoveredDeviceIDs[peerID] = peerDeviceID

            guard session.connectedPeers.count < Self.maximumPeers else { return }
            guard !session.connectedPeers.contains(peerID) else { return }

            // Both sides discover each other, so both would invite, and
            // colliding invitations leave half-open sessions. Lowest device id
            // does the inviting: deterministic, and needs no leader election.
            guard identity.deviceID < peerDeviceID else { return }

            let credentials = PeerCredentials(
                deviceID: identity.deviceID,
                token: key.advertisementToken(for: identity.deviceID)
            )
            let context = try? JSONEncoder().encode(credentials)
            browser.invitePeer(peerID, to: session, withContext: context, timeout: 15)
        }
    }

    public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        queue.async { self.discoveredDeviceIDs.removeValue(forKey: peerID) }
    }

    public func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        queue.async { self.state = .failed(Self.describe(error)) }
    }
}

// MARK: - Helpers

private struct PeerCredentials: Codable {
    let deviceID: String
    let token: String
}

extension MultipeerTransport {
    /// The failure people actually hit is denying the local network prompt, and
    /// the raw error for it is unreadable. Say what to do about it.
    static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain || nsError.code == -72008 {
            return "Local network access is off. Settings › Foredeck › Local Network."
        }
        return nsError.localizedDescription
    }
}
