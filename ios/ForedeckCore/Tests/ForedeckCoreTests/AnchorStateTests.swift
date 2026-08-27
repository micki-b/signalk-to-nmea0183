import XCTest
@testable import ForedeckCore

final class AnchorStateTests: XCTestCase {
    private let bay = GeoPoint(latitude: 54.3210, longitude: 10.1234)

    private func makeStates() -> (AnchorState, LamportClock, LamportClock) {
        let base = AnchorState.initial(deviceID: "AAA")
        return (base, LamportClock(deviceID: "AAA"), LamportClock(deviceID: "BBB"))
    }

    func testMergeIsCommutative() {
        let (base, helm, bow) = makeStates()
        var atHelm = base
        var atBow = base
        atHelm.rodeMeters = atHelm.rodeMeters.setting(35, using: helm)
        atBow.anchorDrop = atBow.anchorDrop.setting(bay, using: bow)

        XCTAssertEqual(atHelm.merged(with: atBow), atBow.merged(with: atHelm))
    }

    func testConcurrentEditsToDifferentFieldsBothSurvive() {
        let (base, helm, bow) = makeStates()
        var atHelm = base
        var atBow = base
        atHelm.rodeMeters = atHelm.rodeMeters.setting(35, using: helm)
        atBow.anchorDrop = atBow.anchorDrop.setting(bay, using: bow)

        let merged = atHelm.merged(with: atBow)
        XCTAssertEqual(merged.rodeMeters.value, 35)
        XCTAssertEqual(merged.anchorDrop.value, bay)
    }

    func testConcurrentEditsToTheSameFieldResolveIdentically() {
        let (base, helm, bow) = makeStates()
        var atHelm = base
        var atBow = base
        atHelm.rodeMeters = atHelm.rodeMeters.setting(30, using: helm)
        atBow.rodeMeters = atBow.rodeMeters.setting(40, using: bow)

        let one = atHelm.merged(with: atBow)
        let other = atBow.merged(with: atHelm)
        XCTAssertEqual(one, other)
        // Same logical time, so the device id decides -- arbitrary, but the
        // same arbitrary answer on every phone, which is the point.
        XCTAssertEqual(one.rodeMeters.value, 40)
    }

    func testLaterEditWinsRegardlessOfMergeOrder() {
        let (base, helm, bow) = makeStates()
        var atBow = base
        atBow.rodeMeters = atBow.rodeMeters.setting(40, using: bow)

        var atHelm = base
        helm.observe(atBow.rodeMeters.stamp)
        atHelm.rodeMeters = atHelm.rodeMeters.setting(55, using: helm)

        XCTAssertEqual(atHelm.merged(with: atBow).rodeMeters.value, 55)
        XCTAssertEqual(atBow.merged(with: atHelm).rodeMeters.value, 55)
    }

    func testMergeIsIdempotentAndAssociative() {
        let (base, helm, bow) = makeStates()
        let third = LamportClock(deviceID: "CCC")

        var a = base
        var b = base
        var c = base
        a.rodeMeters = a.rodeMeters.setting(30, using: helm)
        b.alarmRadiusMeters = b.alarmRadiusMeters.setting(60, using: bow)
        c.alarmEnabled = c.alarmEnabled.setting(true, using: third)

        XCTAssertEqual(a.merged(with: a), a)
        XCTAssertEqual(a.merged(with: b).merged(with: c), a.merged(with: b.merged(with: c)))
    }

    func testHighestStampCoversEveryField() {
        let (base, _, bow) = makeStates()
        var state = base
        state.alarmRadiusMeters = state.alarmRadiusMeters.setting(75, using: bow)
        XCTAssertEqual(state.highestStamp, state.alarmRadiusMeters.stamp)
    }

    func testDragDistanceIsNilUntilTheAnchorIsDown() {
        let (base, _, _) = makeStates()
        XCTAssertNil(base.dragDistance(from: bay))
    }

    func testAlarmFiresOnlyOutsideTheRadiusAndOnlyWhenArmed() {
        let (base, helm, _) = makeStates()
        var state = base
        state.anchorDrop = state.anchorDrop.setting(bay, using: helm)
        state.alarmRadiusMeters = state.alarmRadiusMeters.setting(40, using: helm)

        let nearby = Geo.offset(from: bay, bearingDegrees: 0, distanceMeters: 20)
        let dragged = Geo.offset(from: bay, bearingDegrees: 180, distanceMeters: 120)

        // Disarmed: no alarm even well outside.
        XCTAssertFalse(state.isOutsideAlarmRadius(dragged))

        state.alarmEnabled = state.alarmEnabled.setting(true, using: helm)
        XCTAssertFalse(state.isOutsideAlarmRadius(nearby))
        XCTAssertTrue(state.isOutsideAlarmRadius(dragged))
    }

    func testSuggestedAlarmRadiusAllowsForRodeBoatLengthAndGPSWander() {
        XCTAssertEqual(AnchorState.suggestedAlarmRadius(rodeMeters: 30, boatLengthMeters: 12), 52)
        // Never suggest something so tight it cries wolf all night.
        XCTAssertEqual(AnchorState.suggestedAlarmRadius(rodeMeters: 0, boatLengthMeters: 5), 25)
    }

    func testStateSurvivesAJSONRoundTrip() throws {
        let (base, helm, _) = makeStates()
        var state = base
        state.anchorDrop = state.anchorDrop.setting(bay, using: helm)
        state.anchorDropTime = state.anchorDropTime.setting(Date(timeIntervalSince1970: 1_700_000_000), using: helm)
        state.mode = state.mode.setting(.dock, using: helm)

        let envelope = ControlEnvelope(
            sender: CrewIdentity(deviceID: "AAA", displayName: "Skipper", role: .helm),
            stamp: helm.tick(),
            message: .anchorState(state)
        )
        let decoded = try ControlEnvelope(decoding: envelope.encoded())
        XCTAssertEqual(decoded, envelope)
    }
}
