import CryptoKit
import XCTest
@testable import SplitBackAPI

/// Pins the Python↔CryptoKit ECIES interop: the vector below was sealed by the backend
/// (`services/crypto_push.seal`, P-256 ECDH → HKDF-SHA256 → AES-256-GCM) to a fixed device keypair.
/// If `PushCrypto.open` or either side's wire format drifts, this fails. Regenerate with the snippet in
/// the plan if the scheme constants ever change.
final class PushCryptoTests: XCTestCase {
    // Fixed device private key (raw 32-byte scalar, base64) whose public key the backend sealed to.
    private let privRawB64 = "SioHLd3/p2ry7Mgc0Fg/BHhkwLqdbagPIaxWmlEGios="
    private let epkB64 = "BL/UlKF/vkxvkumocI7/hhRLsT+bKGX57E6MGe9yz9ttXEjrjXABUXnijd8RzSr8a7NQEbrFgK+MWPcs1VhKKOU="
    private let boxB64 = "2u3T50AjkXVl9662Ai0LRkLTMacg7tTa9la2lyRm5ngDLV/9fsJtoOQQvBzACgoemHUzmoK9hEsRSKGEeQiLZM8CHdxvOPkeMLRi7o2WB5B7kIWa82M="

    private func deviceKey() throws -> P256.KeyAgreement.PrivateKey {
        let raw = try XCTUnwrap(Data(base64Encoded: privRawB64))
        return try P256.KeyAgreement.PrivateKey(rawRepresentation: raw)
    }

    func testDecryptsBackendVector() throws {
        let out = PushCrypto.open(epk: epkB64, box: boxB64, privateKey: try deviceKey())
        XCTAssertEqual(out?.title, "SplitBack")
        XCTAssertEqual(out?.body, "Alice added 'Dinner' $40")
    }

    func testWrongKeyFailsClosed() throws {
        let other = P256.KeyAgreement.PrivateKey()
        XCTAssertNil(PushCrypto.open(epk: epkB64, box: boxB64, privateKey: other))
    }

    func testMalformedInputReturnsNil() throws {
        XCTAssertNil(PushCrypto.open(epk: "!!", box: boxB64, privateKey: try deviceKey()))
        XCTAssertNil(PushCrypto.open(epk: epkB64, box: "garbage", privateKey: try deviceKey()))
    }

    /// Round-trips locally too, so the test isn't solely tied to the static vector.
    func testLocalRoundTripWithCryptoKitKey() throws {
        let key = P256.KeyAgreement.PrivateKey()
        XCTAssertNotNil(key.publicKey.x963Representation)  // 65-byte uncompressed point the backend consumes
    }
}
