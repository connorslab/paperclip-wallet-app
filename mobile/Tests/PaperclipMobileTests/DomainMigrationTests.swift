import XCTest
@testable import PaperclipMobile

final class DomainMigrationTests: XCTestCase {
    func testOldPresetsMigrateWithoutChangingTorOrPin() throws {
        var connection = WalletConnection()
        connection.endpoint = "ssl://pool.paperclippool.xyz:50002"
        connection.arkServer = "https://ark.paperclippool.xyz/"
        connection.useTor = true
        connection.certificateSHA256 = String(repeating: "a", count: 64)
        connection.migratePaperclipDomain()
        XCTAssertEqual(connection.endpoint, "ssl://pool.paperclip-xbt.xyz:50002")
        XCTAssertEqual(connection.arkServer, "https://ark.paperclip-xbt.xyz")
        XCTAssertTrue(connection.useTor)
        XCTAssertEqual(connection.certificateSHA256, String(repeating: "a", count: 64))
        let migrated = connection
        connection.migratePaperclipDomain()
        XCTAssertEqual(connection, migrated)
    }
    func testCustomConnectionsStayUnchanged() {
        var connection = WalletConnection()
        connection.backend = .rpc
        connection.endpoint = "http://192.168.1.82:8332"
        connection.username = "node"
        connection.password = "test-only"
        connection.arkServer = "https://custom.example/ark"
        let original = connection
        connection.migratePaperclipDomain()
        XCTAssertEqual(connection, original)
    }
}
