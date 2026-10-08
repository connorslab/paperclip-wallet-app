import XCTest
@testable import PaperclipMobile

final class WalletRemovalTests: XCTestCase {
    func testRemovingUnselectedWalletPreservesSelection() throws {
        let a = WalletProfile(name: "A", kind: .hot, network: "xbt-mainnet")
        let b = WalletProfile(name: "B", kind: .watch, network: "xbt-mainnet")
        var catalog = WalletCatalog(wallets: [a, b], selectedID: a.id)
        try catalog.remove(id: b.id)
        XCTAssertEqual(catalog.selected, a)
        XCTAssertEqual(catalog.wallets, [a])
        XCTAssertThrowsError(try catalog.remove(id: b.id))
        XCTAssertEqual(catalog.wallets, [a])
    }
    func testSelectedAndLastWalletRemoval() throws {
        let a = WalletProfile(name: "Same name", kind: .hot, network: "xbt-mainnet")
        let b = WalletProfile(name: "Same name", kind: .hardware, network: "xbt-mainnet")
        var catalog = WalletCatalog(wallets: [a, b], selectedID: a.id)
        try catalog.remove(id: a.id)
        XCTAssertEqual(catalog.selected, b)
        try catalog.remove(id: b.id)
        XCTAssertNil(catalog.selectedID)
        XCTAssertTrue(catalog.wallets.isEmpty)
        let restored = try JSONDecoder().decode(WalletCatalog.self, from: JSONEncoder().encode(catalog))
        XCTAssertNil(restored.selected)
    }
}
