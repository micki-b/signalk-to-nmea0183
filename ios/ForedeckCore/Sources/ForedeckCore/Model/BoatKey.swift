import Foundation
import CryptoKit

/// The shared secret that decides which phones are "this boat".
///
/// Pairing has to survive being done once, badly, on a pontoon in the rain by
/// someone who has never seen the app. So: one crew member creates the boat and
/// the others either scan a QR code or type a ten-character code. Both paths
/// end at the same 256-bit key, which then lives in the Keychain so nobody ever
/// does it again.
///
/// Honest limitation, also stated in the README: the typed code carries about
/// 50 bits of entropy and peers are not certificate-pinned. This keeps the
/// neighbouring boat's phones out of your intercom. It is not a defence against
/// a determined attacker who is already on your network and actively trying --
/// and for a channel that carries "fender forward" and "two metres", that is
/// the proportionate trade.
public struct BoatKey: Equatable, Sendable {
    public static let derivationInfo = "foredeck-boat-key-v1"
    /// Crockford base32: no I, L, O or U, so nothing is ambiguous when read
    /// aloud across a cockpit or mistyped as a one/ell.
    public static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    public let material: Data

    public init(material: Data) {
        self.material = material
    }

    // MARK: - Pairing codes

    public static func randomCode(length: Int = 10) -> String {
        var characters: [Character] = []
        characters.reserveCapacity(length)
        // 256 is a whole multiple of the 32-character alphabet, so the modulo
        // introduces no bias.
        for _ in 0..<length {
            characters.append(alphabet[Int(UInt8.random(in: 0...255)) % alphabet.count])
        }
        return String(characters)
    }

    /// Fold the ways people mistype a code back onto the alphabet.
    public static func normalise(code: String) -> String {
        var out: [Character] = []
        for raw in code.uppercased() {
            let mapped: Character
            switch raw {
            case "I", "L": mapped = "1"
            case "O": mapped = "0"
            case "U": mapped = "V"
            default: mapped = raw
            }
            if alphabet.contains(mapped) { out.append(mapped) }
        }
        return String(out)
    }

    public static func formatted(code: String) -> String {
        let normalised = normalise(code: code)
        guard normalised.count > 5 else { return normalised }
        let split = normalised.index(normalised.startIndex, offsetBy: 5)
        return "\(normalised[..<split])-\(normalised[split...])"
    }

    public static func derive(code: String, boatName: String) -> BoatKey {
        let normalised = normalise(code: code)
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(normalised.utf8)),
            salt: Data(boatName.lowercased().utf8),
            info: Data(derivationInfo.utf8),
            outputByteCount: 32
        )
        return BoatKey(material: derived.withUnsafeBytes { Data($0) })
    }

    // MARK: - Discovery tokens

    /// Proves membership to a browsing peer without putting the key on the air.
    /// Goes in the advertiser's discovery info, which every device in range can
    /// read, so it must be a MAC over the peer's own ID rather than anything
    /// reusable.
    public func advertisementToken(for deviceID: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(
            for: Data(deviceID.utf8),
            using: SymmetricKey(data: material)
        )
        return Data(code).prefix(16).base64URLEncodedString()
    }

    public func matches(token: String, deviceID: String) -> Bool {
        Self.constantTimeEquals(token, advertisementToken(for: deviceID))
    }

    /// Short human-readable digest so two crew can confirm out loud that their
    /// phones landed on the same key after a typed pairing.
    public var fingerprint: String {
        let digest = SHA256.hash(data: material)
        let characters = Data(digest).prefix(3).map { Self.alphabet[Int($0) % Self.alphabet.count] }
        return String(characters)
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in 0..<a.count { difference |= a[index] ^ b[index] }
        return difference == 0
    }
}

/// How a boat is handed from one phone to another.
public struct BoatInvitation: Equatable, Sendable {
    public static let scheme = "foredeck"

    public var boatName: String
    public var code: String

    public init(boatName: String, code: String) {
        self.boatName = boatName
        self.code = code
    }

    public var key: BoatKey { BoatKey.derive(code: code, boatName: boatName) }

    /// Encoded into a QR code on the inviting device.
    public var url: URL? {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "join"
        components.queryItems = [
            URLQueryItem(name: "boat", value: boatName),
            URLQueryItem(name: "code", value: BoatKey.normalise(code: code))
        ]
        return components.url
    }

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              url.host?.lowercased() == "join",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems,
              let boat = items.first(where: { $0.name == "boat" })?.value,
              let code = items.first(where: { $0.name == "code" })?.value,
              !boat.isEmpty, !code.isEmpty
        else { return nil }
        self.boatName = boat
        self.code = BoatKey.normalise(code: code)
    }
}

extension Data {
    /// Base64 without the characters that need escaping in a discovery-info
    /// dictionary or a URL.
    public func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
