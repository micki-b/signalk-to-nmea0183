import Foundation

/// A logical timestamp that totally orders edits without needing the crew's
/// phones to agree on wall-clock time -- which they will not, and which would
/// be the wrong thing to trust anyway.
public struct LamportStamp: Codable, Hashable, Comparable, Sendable {
    public var counter: UInt64
    /// Breaks ties when two devices edit at the same logical time. Arbitrary
    /// but consistent, which is all convergence requires.
    public var deviceID: String

    public init(counter: UInt64, deviceID: String) {
        self.counter = counter
        self.deviceID = deviceID
    }

    public static func < (lhs: LamportStamp, rhs: LamportStamp) -> Bool {
        if lhs.counter != rhs.counter { return lhs.counter < rhs.counter }
        return lhs.deviceID < rhs.deviceID
    }

    public static let zero = LamportStamp(counter: 0, deviceID: "")
}

public final class LamportClock {
    public let deviceID: String
    public private(set) var counter: UInt64

    public init(deviceID: String, counter: UInt64 = 0) {
        self.deviceID = deviceID
        self.counter = counter
    }

    /// Issue a stamp for a local edit.
    public func tick() -> LamportStamp {
        counter &+= 1
        return LamportStamp(counter: counter, deviceID: deviceID)
    }

    /// Fold in a stamp seen from another device so our next edit sorts after it.
    public func observe(_ stamp: LamportStamp) {
        counter = max(counter, stamp.counter)
    }
}

/// A last-writer-wins register.
///
/// Merging is commutative, associative and idempotent, which is what lets any
/// crew member edit the anchor state from any phone with no designated host.
/// That matters more than it sounds: a host-based design puts the anchor alarm
/// on one particular phone, and that phone is the one that goes flat at 0300.
public struct Registered<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public var value: Value
    public var stamp: LamportStamp

    public init(_ value: Value, stamp: LamportStamp) {
        self.value = value
        self.stamp = stamp
    }

    public func merged(with other: Registered<Value>) -> Registered<Value> {
        other.stamp > stamp ? other : self
    }

    public func setting(_ newValue: Value, using clock: LamportClock) -> Registered<Value> {
        Registered(newValue, stamp: clock.tick())
    }
}
