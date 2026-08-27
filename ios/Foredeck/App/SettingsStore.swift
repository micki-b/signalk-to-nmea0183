import Foundation
import Combine
import ForedeckCore
#if canImport(UIKit)
import UIKit
#endif

/// User preferences, plus the one piece of durable identity the app has.
@MainActor
final class SettingsStore: ObservableObject {
    private enum Key {
        static let deviceID = "foredeck.deviceID"
        static let displayName = "foredeck.displayName"
        static let role = "foredeck.role"
        static let talkMode = "foredeck.talkMode"
        static let vadSensitivity = "foredeck.vadSensitivity"
        static let codec = "foredeck.codec"
        static let boatLength = "foredeck.boatLength"
        static let signalKEnabled = "foredeck.signalK.enabled"
        static let signalKHost = "foredeck.signalK.host"
        static let signalKPort = "foredeck.signalK.port"
        static let nightMode = "foredeck.nightMode"
    }

    private let defaults: UserDefaults

    /// Stable across launches and display-name changes. The Lamport tiebreak
    /// and the pairing tokens both key off it, so it must never be regenerated.
    let deviceID: String

    @Published var displayName: String { didSet { defaults.set(displayName, forKey: Key.displayName) } }
    @Published var role: CrewRole { didSet { defaults.set(role.rawValue, forKey: Key.role) } }
    @Published var talkMode: TalkMode { didSet { defaults.set(talkMode.rawValue, forKey: Key.talkMode) } }
    @Published var vadSensitivity: Double { didSet { defaults.set(vadSensitivity, forKey: Key.vadSensitivity) } }
    @Published var codec: CodecID { didSet { defaults.set(Int(codec.rawValue), forKey: Key.codec) } }
    @Published var boatLengthMeters: Double { didSet { defaults.set(boatLengthMeters, forKey: Key.boatLength) } }
    @Published var signalKEnabled: Bool { didSet { defaults.set(signalKEnabled, forKey: Key.signalKEnabled) } }
    @Published var signalKHost: String { didSet { defaults.set(signalKHost, forKey: Key.signalKHost) } }
    @Published var signalKPort: Int { didSet { defaults.set(signalKPort, forKey: Key.signalKPort) } }
    @Published var nightMode: Bool { didSet { defaults.set(nightMode, forKey: Key.nightMode) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let existing = defaults.string(forKey: Key.deviceID) {
            deviceID = existing
        } else {
            let generated = UUID().uuidString
            defaults.set(generated, forKey: Key.deviceID)
            deviceID = generated
        }

        displayName = defaults.string(forKey: Key.displayName) ?? Self.defaultDisplayName()
        role = CrewRole(rawValue: defaults.string(forKey: Key.role) ?? "") ?? .crew
        talkMode = TalkMode(rawValue: defaults.string(forKey: Key.talkMode) ?? "") ?? .openMic
        vadSensitivity = defaults.object(forKey: Key.vadSensitivity) as? Double ?? 0.5
        codec = CodecID(rawValue: UInt8(clamping: defaults.object(forKey: Key.codec) as? Int ?? 2)) ?? .pcmuLaw
        boatLengthMeters = defaults.object(forKey: Key.boatLength) as? Double ?? 12
        signalKEnabled = defaults.bool(forKey: Key.signalKEnabled)
        signalKHost = defaults.string(forKey: Key.signalKHost) ?? "signalk.local"
        signalKPort = defaults.object(forKey: Key.signalKPort) as? Int ?? 3000
        nightMode = defaults.bool(forKey: Key.nightMode)
    }

    var identity: CrewIdentity {
        CrewIdentity(deviceID: deviceID, displayName: displayName, role: role)
    }

    private static func defaultDisplayName() -> String {
        #if canImport(UIKit)
        let name = UIDevice.current.name
        return name.isEmpty ? "Crew" : name
        #else
        return "Crew"
        #endif
    }
}
