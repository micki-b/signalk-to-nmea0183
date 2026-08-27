import Foundation

/// Opaque handle for a connected peer. The concrete transport decides what the
/// string means -- for Multipeer it is the peer's display name, for a future
/// WebRTC implementation it would be a session id.
public struct PeerHandle: Hashable, Sendable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

public enum TransportState: Equatable, Sendable {
    case idle
    case searching
    case connected(peerCount: Int)
    case failed(String)
}

/// The seam.
///
/// Everything above this protocol -- the audio engine, the roster, the shared
/// anchor state -- is written against these seven calls and nothing else. That
/// is deliberate: Multipeer Connectivity is the right answer for a first
/// version because it needs no router, no server and no configuration, but if
/// audio quality on the water turns out to need Opus, a real congestion
/// controller and WebRTC's jitter handling, the replacement work is one new
/// conformance rather than a rewrite.
public protocol CrewTransport: AnyObject {
    var delegate: CrewTransportDelegate? { get set }
    var state: TransportState { get }
    var connectedPeers: [PeerHandle] { get }

    func start(identity: CrewIdentity, boatName: String, key: BoatKey)
    func stop()

    /// Fire-and-forget, unordered, lossy. Audio only.
    func sendAudio(_ data: Data)
    /// Ordered and retransmitted. Everything that is not audio.
    func sendControl(_ envelope: ControlEnvelope)
    func sendControl(_ envelope: ControlEnvelope, to peer: PeerHandle)
}

public protocol CrewTransportDelegate: AnyObject {
    func transport(_ transport: CrewTransport, didChange state: TransportState)
    func transport(_ transport: CrewTransport, didConnect peer: PeerHandle)
    func transport(_ transport: CrewTransport, didDisconnect peer: PeerHandle)
    /// `arrivalTime` is a monotonic timestamp taken as close to the wire as
    /// possible; the jitter buffer's whole adaptation depends on it not being
    /// measured after a hop through a serial queue.
    func transport(_ transport: CrewTransport, didReceiveAudio data: Data, from peer: PeerHandle, arrivalTime: Double)
    func transport(_ transport: CrewTransport, didReceiveControl envelope: ControlEnvelope, from peer: PeerHandle)
}
