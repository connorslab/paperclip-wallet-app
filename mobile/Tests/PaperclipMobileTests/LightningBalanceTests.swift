import XCTest
@testable import PaperclipMobile

final class LightningBalanceTests: XCTestCase {
    func testOfferAmountsUseMillisatoshisAndOptionalAmounts() throws {
        XCTAssertEqual(try LightningNode.offerParameters(amount: 21, description: "Test")["amount"] as? String, "21000msat")
        XCTAssertEqual(try LightningNode.offerParameters(amount: nil, description: "Test")["amount"] as? String, "any")
        XCTAssertThrowsError(try LightningNode.offerParameters(amount: 0, description: "Test"))
        XCTAssertThrowsError(try LightningNode.offerParameters(amount: UInt64.max, description: "Test"))
        XCTAssertThrowsError(try LightningNode.offerParameters(amount: 1, description: "  "))
    }

    func testCLNExcludesOfflineAndOpeningChannels() throws {
        let data = Data(#"{"channels":[{"state":"CHANNELD_NORMAL","peer_connected":true,"spendable_msat":123456,"receivable_msat":"789000msat"},{"state":"CHANNELD_NORMAL","peer_connected":false,"spendable_msat":999999},{"state":"CHANNELD_AWAITING_LOCKIN","peer_connected":true}]}"#.utf8)
        let result = try LightningBalance.decode(data, implementation: .cln)
        XCTAssertEqual(result.sendableMsat, 123456)
        XCTAssertEqual(result.receivableMsat, 789000)
        XCTAssertEqual(result.activeChannels, 1)
    }
    func testLNDReservesAndOfflineChannels() throws {
        let data = Data(#"{"channels":[{"active":true,"local_balance":"10000","remote_balance":"5000","local_constraints":{"chan_reserve_sat":"1000"},"remote_constraints":{"chan_reserve_sat":"6000"}},{"active":false}]}"#.utf8)
        let result = try LightningBalance.decode(data, implementation: .lnd)
        XCTAssertEqual(result.sendableMsat, 9000000)
        XCTAssertEqual(result.receivableMsat, 0)
        XCTAssertEqual(result.activeChannels, 1)
    }
    func testMissingMalformedAndOverflowAmountsAreNotZeroBalances() throws {
        for amount in ["null", "true", "-1", "1.5", "\"invalid\""] {
            let data = Data("{\"channels\":[{\"state\":\"CHANNELD_NORMAL\",\"peer_connected\":true,\"spendable_msat\":\(amount),\"receivable_msat\":1}]}".utf8)
            XCTAssertThrowsError(try LightningBalance.decode(data, implementation: .cln))
        }
        let overflow = Data(#"{"channels":[{"state":"CHANNELD_NORMAL","peer_connected":true,"spendable_msat":"18446744073709551615","receivable_msat":0},{"state":"CHANNELD_NORMAL","peer_connected":true,"spendable_msat":1,"receivable_msat":0}]}"#.utf8)
        XCTAssertThrowsError(try LightningBalance.decode(overflow, implementation: .cln))
        XCTAssertThrowsError(try LightningBalance.decode(Data("{}".utf8), implementation: .cln))
        XCTAssertEqual(try LightningBalance.decode(Data(#"{"channels":[]}"#.utf8), implementation: .cln).sendableMsat, 0)
    }
}
