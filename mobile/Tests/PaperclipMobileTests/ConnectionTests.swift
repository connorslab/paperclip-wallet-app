import XCTest
@testable import PaperclipMobile

final class ConnectionTests: XCTestCase {
    func testBuiltInTorSelectionAndExternalProxyValidation() throws {
        var node = LightningConnection()
        node.endpoint = "http://node.onion"
        node.credential = "test-rune"
        node.useTor = true
        XCTAssertEqual(node.torProxy, "builtin")
        XCTAssertNoThrow(try node.validate())
        XCTAssertEqual(try JSONDecoder().decode(LightningConnection.self, from: JSONEncoder().encode(node)), node)
        node.torProxy = "http://node.onion"
        XCTAssertThrowsError(try node.validate())
        node.torProxy = "socks5h://192.168.1.2:9050"
        XCTAssertNoThrow(try node.validate())
        // The HTTP client must resolve built-in selection to a running loopback proxy first.
        node.torProxy = "builtin"
        XCTAssertThrowsError(try LightningNode(connection: node))
        var chain = WalletConnection()
        chain.useTor = true
        XCTAssertNoThrow(try chain.validate())
    }

    func testLocalElectrumAndFieldSpecificErrors() throws {
        var connection = WalletConnection()
        for endpoint in ["tcp://192.168.1.10:50001", "ssl://node.local:50002", "tcp://[::1]:50001"] {
            connection.endpoint = endpoint
            XCTAssertNoThrow(try connection.validate())
        }
        for endpoint in ["192.168.1.20:50001", "http://192.168.1.20:50001"] {
            connection.endpoint = endpoint
            XCTAssertThrowsError(try connection.validate()) { error in
                XCTAssertTrue(error.localizedDescription.hasPrefix("On-chain endpoint:"))
                XCTAssertTrue(error.localizedDescription.contains("tcp://"))
                XCTAssertFalse(error.localizedDescription.contains(endpoint))
            }
        }
        connection = WalletConnection()
        connection.arkServer = "invalid"
        XCTAssertThrowsError(try connection.validate()) { error in
            XCTAssertTrue(error.localizedDescription.hasPrefix("Ark server:"))
        }
    }

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
    func testSeparateArkRPCSupportsHTTPAndIndependentTor() throws {
        var connection = WalletConnection()
        var rpc = ArkRPCConnection()
        rpc.username = "wallet"; rpc.password = "test-credential"
        rpc.endpoint = "http://192.168.1.10:8332"
        connection.arkRPC = rpc
        XCTAssertNoThrow(try connection.validate())
        rpc.endpoint = "https://rpc.example"
        connection.arkRPC = rpc
        XCTAssertNoThrow(try connection.validate())
        XCTAssertEqual(connection.endpoint, "ssl://pool.paperclippool.xyz:50002")
        connection.useTor = true
        XCTAssertNoThrow(try connection.validate())
        connection.useTor = false
        let encoded = try JSONEncoder().encode(connection)
        XCTAssertEqual(try JSONDecoder().decode(WalletConnection.self, from: encoded), connection)
        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacy.removeValue(forKey: "arkRPC")
        XCTAssertNil(try JSONDecoder().decode(WalletConnection.self, from: JSONSerialization.data(withJSONObject: legacy)).arkRPC)
    }
    func testIndependentRPCTorRoutesAndLegacySettings() throws {
        var connection = WalletConnection()
        connection.backend = .rpc
        connection.endpoint = "http://chain.onion:8332"
        connection.username = "chain-user"; connection.password = "chain-password"
        connection.useTor = true; connection.torProxy = "socks5h://192.168.1.2:9050"
        var ark = ArkRPCConnection()
        ark.endpoint = "http://ark-node.onion:8332"
        ark.username = "ark-user"; ark.password = "ark-password"
        ark.useTor = true; ark.torProxy = "socks5h://192.168.1.3:9050"
        connection.arkServer = "http://ark.onion"
        connection.arkRPC = ark
        XCTAssertNoThrow(try connection.validate())
        let restored = try JSONDecoder().decode(WalletConnection.self, from: JSONEncoder().encode(connection))
        XCTAssertEqual(restored, connection)
        XCTAssertNotEqual(restored.torProxy, restored.arkRPC?.torProxy)
        connection.useTor = false
        XCTAssertThrowsError(try connection.validate())
        connection.endpoint = "http://192.168.1.4:8332"
        XCTAssertNoThrow(try connection.validate())
        connection.arkRPC?.useTor = false
        XCTAssertThrowsError(try connection.validate())
        connection.arkRPC?.useTor = true
        connection.arkRPC?.torProxy = "socks5://192.168.1.3:9050"
        XCTAssertThrowsError(try connection.validate())
        let legacy = Data(#"{"endpoint":"http://192.168.1.4:8332","username":"user","password":"pass"}"#.utf8)
        let old = try JSONDecoder().decode(ArkRPCConnection.self, from: legacy)
        XCTAssertFalse(old.useTor)
        XCTAssertEqual(old.torProxy, "socks5h://127.0.0.1:9050")
    }
    func testOnchainRPCHTTPStillValidatesCredentialsAndEndpoint() throws {
        var connection = WalletConnection()
        connection.backend = .rpc
        connection.username = "wallet"
        connection.password = "test-credential"
        for endpoint in ["http://192.168.1.10:8332", "http://node.local:8332", "http://127.0.0.1:18443", "http://[::1]:18443", "https://rpc.example"] {
            connection.endpoint = endpoint
            XCTAssertNoThrow(try connection.validate())
        }
        for endpoint in ["http://user:password@node.local:8332", "http://node.local:8332?secret=value", "http://node.onion:8332"] {
            connection.endpoint = endpoint
            XCTAssertThrowsError(try connection.validate())
        }
        connection.endpoint = "http://node.local:8332"
        connection.password = ""
        XCTAssertThrowsError(try connection.validate())
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
