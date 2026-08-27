import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct GeoPoint: Codable, Equatable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

public enum Geo {
    /// IUGG mean Earth radius. At anchor-swing scale the choice of ellipsoid
    /// model is irrelevant; at 50 m a spherical approximation is good to
    /// millimetres.
    public static let earthRadiusMeters = 6_371_008.8

    public static func distance(from origin: GeoPoint, to destination: GeoPoint) -> Double {
        let lat1 = origin.latitude * .pi / 180
        let lat2 = destination.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (destination.longitude - origin.longitude) * .pi / 180

        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadiusMeters * atan2(sqrt(a), sqrt(max(0, 1 - a)))
    }

    /// True bearing in degrees, 0..<360.
    public static func bearing(from origin: GeoPoint, to destination: GeoPoint) -> Double {
        let lat1 = origin.latitude * .pi / 180
        let lat2 = destination.latitude * .pi / 180
        let dLon = (destination.longitude - origin.longitude) * .pi / 180

        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        var degrees = (atan2(y, x) * 180 / .pi).truncatingRemainder(dividingBy: 360)
        if degrees < 0 { degrees += 360 }
        return degrees
    }

    public static func offset(from origin: GeoPoint, bearingDegrees: Double, distanceMeters: Double) -> GeoPoint {
        let angular = distanceMeters / earthRadiusMeters
        let bearing = bearingDegrees * .pi / 180
        let lat1 = origin.latitude * .pi / 180
        let lon1 = origin.longitude * .pi / 180

        let lat2 = asin(sin(lat1) * cos(angular) + cos(lat1) * sin(angular) * cos(bearing))
        let lon2 = lon1 + atan2(
            sin(bearing) * sin(angular) * cos(lat1),
            cos(angular) - sin(lat1) * sin(lat2)
        )
        return GeoPoint(latitude: lat2 * 180 / .pi, longitude: lon2 * 180 / .pi)
    }

    public static func metersToFeet(_ meters: Double) -> Double { meters * 3.280839895 }
    public static func metersToNauticalMiles(_ meters: Double) -> Double { meters / 1852.0 }
}
