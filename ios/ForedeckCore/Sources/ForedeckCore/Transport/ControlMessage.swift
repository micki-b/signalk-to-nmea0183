import Foundation

/// Everything that is not audio. Sent reliably and ordered, so these can assume
/// delivery in a way audio frames never can.
public enum ControlMessage: Codable, Equatable, Sendable {
    /// Sent on connect so the other side can put a name and a role on the voice.
    case hello(CrewIdentity)
    /// Voice-activity state, so the roster can show who is talking. Carried
    /// separately from the audio flags because a listener needs it even when
    /// the audio path is struggling.
    case speaking(Bool)
    case position(GeoPoint, accuracyMeters: Double, at: Date)
    case anchorState(AnchorState)
    /// A late joiner asking for the current picture.
    case requestSnapshot
    case anchorAlarm(distanceMeters: Double, at: Date)
    case anchorAlarmCleared
    case goodbye
}

public struct ControlEnvelope: Codable, Equatable, Sendable {
    public var sender: CrewIdentity
    public var stamp: LamportStamp
    public var message: ControlMessage

    public init(sender: CrewIdentity, stamp: LamportStamp, message: ControlMessage) {
        self.sender = sender
        self.stamp = stamp
        self.message = message
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public init(decoding data: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self = try decoder.decode(ControlEnvelope.self, from: data)
    }
}
