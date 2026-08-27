import XCTest
@testable import ForedeckCore

final class BoatKeyTests: XCTestCase {
    func testDerivationIsDeterministic() {
        let a = BoatKey.derive(code: "K7M2QP4X9A", boatName: "Halcyon")
        let b = BoatKey.derive(code: "K7M2QP4X9A", boatName: "Halcyon")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.material.count, 32)
    }

    func testBoatNameIsPartOfTheKey() {
        let a = BoatKey.derive(code: "K7M2QP4X9A", boatName: "Halcyon")
        let b = BoatKey.derive(code: "K7M2QP4X9A", boatName: "Windrose")
        XCTAssertNotEqual(a, b)
    }

    func testBoatNameMatchingIgnoresCase() {
        XCTAssertEqual(
            BoatKey.derive(code: "K7M2QP4X9A", boatName: "Halcyon"),
            BoatKey.derive(code: "K7M2QP4X9A", boatName: "HALCYON")
        )
    }

    /// The code gets read aloud across a cockpit and typed with cold hands.
    func testNormalisationFoldsTheObviousMistypings() {
        XCTAssertEqual(BoatKey.normalise(code: "ilo"), "110")
        XCTAssertEqual(BoatKey.normalise(code: "u"), "V")
        XCTAssertEqual(BoatKey.normalise(code: "k7m2-qp4x9a"), "K7M2QP4X9A")
        XCTAssertEqual(BoatKey.normalise(code: "k7 m2"), "K7M2")
    }

    func testMistypedAndCleanCodesDeriveTheSameKey() {
        XCTAssertEqual(
            BoatKey.derive(code: "K7M2-QP4X9A", boatName: "Halcyon"),
            BoatKey.derive(code: "k7m2 qp4x9a", boatName: "Halcyon")
        )
    }

    func testGeneratedCodesUseOnlyTheUnambiguousAlphabet() {
        for _ in 0..<200 {
            let code = BoatKey.randomCode()
            XCTAssertEqual(code.count, 10)
            for character in code {
                XCTAssertTrue(BoatKey.alphabet.contains(character), "unexpected character \(character)")
            }
        }
    }

    func testFormattingSplitsTheCodeForReadingAloud() {
        XCTAssertEqual(BoatKey.formatted(code: "K7M2QP4X9A"), "K7M2Q-P4X9A")
    }

    func testAdvertisementTokenMatchesOnlyTheRightKeyAndDevice() {
        let key = BoatKey.derive(code: "K7M2QP4X9A", boatName: "Halcyon")
        let other = BoatKey.derive(code: "ZZZZZZZZZZ", boatName: "Halcyon")
        let token = key.advertisementToken(for: "device-1")

        XCTAssertTrue(key.matches(token: token, deviceID: "device-1"))
        XCTAssertFalse(key.matches(token: token, deviceID: "device-2"))
        XCTAssertFalse(other.matches(token: token, deviceID: "device-1"))
    }

    func testTokenIsSafeToPutInADiscoveryDictionary() {
        let key = BoatKey.derive(code: "K7M2QP4X9A", boatName: "Halcyon")
        let token = key.advertisementToken(for: "device-1")
        XCTAssertFalse(token.contains("+"))
        XCTAssertFalse(token.contains("/"))
        XCTAssertFalse(token.contains("="))
    }

    func testFingerprintIsStableAndShort() {
        let key = BoatKey.derive(code: "K7M2QP4X9A", boatName: "Halcyon")
        XCTAssertEqual(key.fingerprint.count, 3)
        XCTAssertEqual(key.fingerprint, key.fingerprint)
    }

    func testInvitationSurvivesAQRCodeRoundTrip() throws {
        let invitation = BoatInvitation(boatName: "Halcyon", code: "K7M2QP4X9A")
        let url = try XCTUnwrap(invitation.url)
        let decoded = try XCTUnwrap(BoatInvitation(url: url))
        XCTAssertEqual(decoded.boatName, "Halcyon")
        XCTAssertEqual(decoded.code, "K7M2QP4X9A")
        XCTAssertEqual(decoded.key, invitation.key)
    }

    func testInvitationHandlesBoatNamesWithSpaces() throws {
        let invitation = BoatInvitation(boatName: "Mary Rose", code: "K7M2QP4X9A")
        let url = try XCTUnwrap(invitation.url)
        XCTAssertEqual(BoatInvitation(url: url)?.boatName, "Mary Rose")
    }

    func testRejectsUnrelatedURLs() {
        XCTAssertNil(BoatInvitation(url: URL(string: "https://example.com/join?boat=x&code=y")!))
        XCTAssertNil(BoatInvitation(url: URL(string: "foredeck://join?boat=x")!))
        XCTAssertNil(BoatInvitation(url: URL(string: "foredeck://leave?boat=x&code=y")!))
    }
}
