import CoreLocation
import Combine
import ForedeckCore

/// Position, and the breadcrumb that actually tells you whether you are dragging.
///
/// A single distance-from-anchor number is ambiguous: a boat sailing around her
/// hook in a wind shift produces the same reading as one slowly losing ground.
/// The track over the last hour distinguishes them at a glance, which is why it
/// is kept here rather than derived in the view.
@MainActor
final class LocationProvider: NSObject, ObservableObject {
    @Published private(set) var position: GeoPoint?
    @Published private(set) var horizontalAccuracy: Double = -1
    @Published private(set) var courseOverGround: Double?
    @Published private(set) var speedOverGround: Double?
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var track: [GeoPoint] = []

    /// An hour of breadcrumbs at the rate we actually record them.
    private static let maximumTrackPoints = 600
    /// Ignore movement below this: GPS wander would otherwise fill the track
    /// with a fuzzy blob centred on the boat.
    private static let minimumTrackSpacing: Double = 2.0

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .otherNavigation
        // Pausing would silently kill the anchor alarm on a boat that is, by
        // definition, not moving much.
        manager.pausesLocationUpdatesAutomatically = false
        authorization = manager.authorizationStatus
    }

    func requestAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    /// Asked for only when the anchor alarm is armed, where it is the
    /// difference between an alarm that works overnight and one that does not.
    func requestAlwaysAuthorization() {
        manager.requestAlwaysAuthorization()
    }

    func start() {
        guard authorization != .denied, authorization != .restricted else { return }
        manager.startUpdatingLocation()
        manager.startUpdatingHeading()
        enableBackgroundUpdatesIfPermitted()
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        manager.allowsBackgroundLocationUpdates = false
    }

    func clearTrack() {
        track.removeAll()
    }

    private func enableBackgroundUpdatesIfPermitted() {
        // Setting this without the background mode in Info.plist throws an
        // exception rather than failing quietly, so it is gated on having an
        // authorisation that actually permits it.
        guard authorization == .authorizedAlways || authorization == .authorizedWhenInUse else { return }
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
    }
}

extension LocationProvider: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let point = GeoPoint(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude
        )
        let accuracy = location.horizontalAccuracy
        let course = location.course >= 0 ? location.course : nil
        let speed = location.speed >= 0 ? location.speed : nil

        Task { @MainActor in
            self.position = point
            self.horizontalAccuracy = accuracy
            self.courseOverGround = course
            self.speedOverGround = speed
            self.appendToTrack(point, accuracy: accuracy)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            if status == .authorizedAlways || status == .authorizedWhenInUse {
                self.start()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // A transient failure to fix is normal below decks and not worth
        // surfacing; the position simply stops updating.
    }

    @MainActor
    private func appendToTrack(_ point: GeoPoint, accuracy: Double) {
        // A fix worse than 50 m would drag the track across the anchorage.
        guard accuracy >= 0, accuracy < 50 else { return }
        if let last = track.last, Geo.distance(from: last, to: point) < Self.minimumTrackSpacing {
            return
        }
        track.append(point)
        if track.count > Self.maximumTrackPoints {
            track.removeFirst(track.count - Self.maximumTrackPoints)
        }
    }
}
