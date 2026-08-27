import Foundation
import ForedeckCore

/// A peer as the roster sees them.
struct CrewMember: Identifiable, Equatable {
    let handle: PeerHandle
    var identity: CrewIdentity
    var isSpeaking = false
    var position: GeoPoint?
    var positionUpdatedAt: Date?
    var quality: LinkQuality?
    var isMuted = false
    var volume: Float = 1.0

    var id: String { identity.deviceID }

    /// Falls back to the peer handle until the hello message lands, which is
    /// usually well under a second but should not render as an empty tile.
    var displayName: String {
        identity.displayName.isEmpty ? handle.rawValue : identity.displayName
    }
}
