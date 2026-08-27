import Foundation

/// Where someone is standing. Not decoration: during a docking manoeuvre the
/// helm needs to know at a glance whether the voice in their ear is at the bow
/// or on the spring line, and half the crew will not have named themselves
/// usefully.
public enum CrewRole: String, Codable, CaseIterable, Sendable, Identifiable {
    case helm
    case bow
    case midships
    case stern
    case crew

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .helm: return "Helm"
        case .bow: return "Bow"
        case .midships: return "Midships"
        case .stern: return "Stern"
        case .crew: return "Crew"
        }
    }
}

public struct CrewIdentity: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// Stable per-install UUID string. Survives display-name changes, which is
    /// what the roster and the Lamport tiebreak key off.
    public var deviceID: String
    public var displayName: String
    public var role: CrewRole

    public var id: String { deviceID }

    public init(deviceID: String, displayName: String, role: CrewRole = .crew) {
        self.deviceID = deviceID
        self.displayName = displayName
        self.role = role
    }

    /// What the transport advertises. Multipeer display names are capped at 63
    /// UTF-8 bytes and an over-long one throws at MCPeerID construction, so
    /// clamp here rather than crashing on a device someone named expansively.
    public var advertisedName: String {
        let composed = "\(displayName) · \(role.label)"
        return String(composed.prefix(40))
    }
}
