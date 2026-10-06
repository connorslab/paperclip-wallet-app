import XCTest
@testable import PaperclipMobile

final class ConnectionTests: XCTestCase {
    func testPaperclipDefaultAndTorDNSPolicy() throws {
        let connection = WalletConnection()
        XCTAssertEqual(connection.backend, .electrum)
        XCTAssertEqual(connection.endpoint, "ssl://pool.paperclippool.xyz:50002")
        try connection.validate()
        XCTAssertThrowsError(try EndpointPolicy.validate("tcp://example.onion:50001", tor: false, electrum: true))
        XCTAssertNoThrow(try EndpointPolicy.validate("tcp://example.onion:50001", tor: true, electrum: true))
        XCTAssertThrowsError(try EndpointPolicy.proxy("socks5://localhost:9050"))
        XCTAssertThrowsError(try EndpointPolicy.proxy("socks5h://localhost:0"))
        XCTAssertNoThrow(try EndpointPolicy.proxy("socks5h://127.0.0.1:9050"))
    }
    func testCredentialsCannotLeakIntoEndpointsOrCleartext() {
        for endpoint in ["https://user:secret@host", "https://host?token=secret", "https://host#token", "http://node.example"] {
            XCTAssertThrowsError(try EndpointPolicy.validate(endpoint, tor: false, credentials: true))
        }
        XCTAssertNoThrow(try EndpointPolicy.validate("http://node.onion", tor: true, credentials: true))
        XCTAssertThrowsError(try EndpointPolicy.validate("ssl://host:50002/path", tor: false, electrum: true))
    }
    func testSeedVerificationSupportsOnlyTwelveAndTwentyFourWords() {
        for count in [12, 24] {
            let phrase = Array(repeating: "abandon", count: count).joined(separator: " ")
            XCTAssertTrue(SeedVerification.matches(phrase: phrase, confirmation: "  \(phrase.uppercased())\n"))
            XCTAssertFalse(SeedVerification.matches(phrase: phrase, confirmation: phrase + " extra"))
            XCTAssertFalse(SeedVerification.matches(phrase: phrase, confirmation: "wrong " + phrase.dropFirst(8)))
        }
        for count in [0, 11, 15, 18, 21, 25] {
            let phrase = Array(repeating: "word", count: count).joined(separator: " ")
            XCTAssertFalse(SeedVerification.matches(phrase: phrase, confirmation: phrase))
        }
    }
    func testSeparateArkRPCRequiresTLSAndNeverBypassesTor() throws {
        var connection = WalletConnection()
        var rpc = ArkRPCConnection()
        rpc.endpoint = "http://rpc.example"
        connection.arkRPC = rpc
        XCTAssertThrowsError(try connection.validate())
        rpc.endpoint = "https://rpc.example"
        connection.arkRPC = rpc
        XCTAssertNoThrow(try connection.validate())
        XCTAssertEqual(connection.endpoint, "ssl://pool.paperclippool.xyz:50002")
        connection.useTor = true
        XCTAssertThrowsError(try connection.validate())
        connection.useTor = false
        let encoded = try JSONEncoder().encode(connection)
        XCTAssertEqual(try JSONDecoder().decode(WalletConnection.self, from: encoded), connection)
        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacy.removeValue(forKey: "arkRPC")
        XCTAssertNil(try JSONDecoder().decode(WalletConnection.self, from: JSONSerialization.data(withJSONObject: legacy)).arkRPC)
    }
    func testLightningCredentialAndPinValidation() {
        var config = LightningConnection()
        config.endpoint = "https://node.example"
        config.credential = "rune\nInjected: header"
        XCTAssertThrowsError(try config.validate())
        config.implementation = .lnd
        config.credential = "not-hex"
        XCTAssertThrowsError(try config.validate())
        config.credential = "abcd0123"
        config.certificateSHA256 = String(repeating: "a", count: 64)
        XCTAssertNoThrow(try config.validate())
        config.certificateSHA256 = "invalid"
        XCTAssertThrowsError(try config.validate())
    }
}
