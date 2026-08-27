import Foundation

public enum CrewMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case anchor
    case dock

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .anchor: return "Anchor"
        case .dock: return "Dock"
        }
    }
}

/// The shared picture: where the anchor went in, how much rode is out, how far
/// we are allowed to move before somebody's phone starts shouting.
///
/// Every field is an independent last-writer-wins register, so two crew editing
/// different things at the same moment do not clobber each other, and the merge
/// converges regardless of the order updates arrive in. That property is what
/// makes it safe to broadcast state blindly to every peer and to hand a late
/// joiner a full snapshot without a handshake.
public struct AnchorState: Codable, Equatable, Sendable {
    public var mode: Registered<CrewMode>
    public var anchorDrop: Registered<GeoPoint?>
    public var anchorDropTime: Registered<Date?>
    public var rodeMeters: Registered<Double>
    public var alarmRadiusMeters: Registered<Double>
    public var alarmEnabled: Registered<Bool>
    public var dockTarget: Registered<GeoPoint?>

    public init(
        mode: Registered<CrewMode>,
        anchorDrop: Registered<GeoPoint?>,
        anchorDropTime: Registered<Date?>,
        rodeMeters: Registered<Double>,
        alarmRadiusMeters: Registered<Double>,
        alarmEnabled: Registered<Bool>,
        dockTarget: Registered<GeoPoint?>
    ) {
        self.mode = mode
        self.anchorDrop = anchorDrop
        self.anchorDropTime = anchorDropTime
        self.rodeMeters = rodeMeters
        self.alarmRadiusMeters = alarmRadiusMeters
        self.alarmEnabled = alarmEnabled
        self.dockTarget = dockTarget
    }

    public static func initial(deviceID: String) -> AnchorState {
        let zero = LamportStamp(counter: 0, deviceID: deviceID)
        return AnchorState(
            mode: Registered(.anchor, stamp: zero),
            anchorDrop: Registered(nil, stamp: zero),
            anchorDropTime: Registered(nil, stamp: zero),
            rodeMeters: Registered(0, stamp: zero),
            alarmRadiusMeters: Registered(40, stamp: zero),
            alarmEnabled: Registered(false, stamp: zero),
            dockTarget: Registered(nil, stamp: zero)
        )
    }

    public func merged(with other: AnchorState) -> AnchorState {
        AnchorState(
            mode: mode.merged(with: other.mode),
            anchorDrop: anchorDrop.merged(with: other.anchorDrop),
            anchorDropTime: anchorDropTime.merged(with: other.anchorDropTime),
            rodeMeters: rodeMeters.merged(with: other.rodeMeters),
            alarmRadiusMeters: alarmRadiusMeters.merged(with: other.alarmRadiusMeters),
            alarmEnabled: alarmEnabled.merged(with: other.alarmEnabled),
            dockTarget: dockTarget.merged(with: other.dockTarget)
        )
    }

    /// Highest stamp anywhere in the state, so a receiver can advance its clock
    /// past everything it has just been told about.
    public var highestStamp: LamportStamp {
        [
            mode.stamp, anchorDrop.stamp, anchorDropTime.stamp,
            rodeMeters.stamp, alarmRadiusMeters.stamp,
            alarmEnabled.stamp, dockTarget.stamp
        ].max() ?? .zero
    }

    // MARK: - Derived

    /// How far the boat has moved from where the anchor went in.
    public func dragDistance(from position: GeoPoint) -> Double? {
        guard let drop = anchorDrop.value else { return nil }
        return Geo.distance(from: drop, to: position)
    }

    public func isOutsideAlarmRadius(_ position: GeoPoint) -> Bool {
        guard alarmEnabled.value, let distance = dragDistance(from: position) else { return false }
        return distance > alarmRadiusMeters.value
    }

    /// A starting point for the alarm radius, not a rule. The boat can lie
    /// anywhere on a circle of roughly the rode length plus her own length, and
    /// GPS wander adds a good 10 m on top, so a radius tighter than this cries
    /// wolf all night.
    public static func suggestedAlarmRadius(rodeMeters: Double, boatLengthMeters: Double = 12) -> Double {
        max(25, rodeMeters + boatLengthMeters + 10)
    }
}
