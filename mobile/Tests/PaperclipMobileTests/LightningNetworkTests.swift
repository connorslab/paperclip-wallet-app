import XCTest
@testable import PaperclipMobile

final class LightningNetworkTests: XCTestCase {
    func testNodeReportsItsOwnNetwork() throws {
        XCTAssertEqual(try LightningNetwork.decode(["network": "bitcoin"], implementation: .cln), .mainnet)
        XCTAssertEqual(try LightningNetwork.decode(["network": "regtest"], implementation: .cln), .regtest)
        XCTAssertEqual(try LightningNetwork.decode(["chains": [["chain": "bitcoin", "network": "mainnet"]]], implementation: .lnd), .mainnet)
        XCTAssertEqual(try LightningNetwork.decode(["chains": [["chain": "bitcoin", "network": "regtest"]]], implementation: .lnd), .regtest)
    }
    func testMissingAndUnsupportedNetworksFailClosed() {
        XCTAssertThrowsError(try LightningNetwork.decode([:], implementation: .cln))
        XCTAssertThrowsError(try LightningNetwork.decode(["network": "testnet"], implementation: .cln))
        XCTAssertThrowsError(try LightningNetwork.decode(["chains": [["chain": "litecoin", "network": "mainnet"]]], implementation: .lnd))
        XCTAssertThrowsError(try LightningNetwork.decode(["chains": [["chain": "bitcoin", "network": "signet"]]], implementation: .lnd))
    }
}
