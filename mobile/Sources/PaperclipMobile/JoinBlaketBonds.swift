import Foundation

public struct JoinBlaketBondCoin: Decodable, Sendable, Identifiable {
    public let outpoint: String
    public let value_sat: UInt64, confirmations: UInt32
    public let locktime: Int64
    public let frozen: Bool, signable: Bool
    public var id: String { outpoint }
    public func canWithdraw(chainTime: Int64) -> Bool { locktime < chainTime && confirmations > 0 && !frozen && signable }
    public var unlockDescription: String {
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        return format.string(from: Date(timeIntervalSince1970: Double(locktime)))
    }
    static func validOutpoint(_ point: String) -> Bool {
        let parts = point.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 2 && JoinBlaketPayment.validID(String(parts[0])) && UInt32(parts[1]).map { String($0) == parts[1] } == true
    }
}
public struct JoinBlaketBondInventory: Decodable, Sendable {
    public let wallet: String, identity: String
    public let chain_time: Int64
    public let bonds: [JoinBlaketBondCoin]
    func validate(wallet: String) throws {
        let parts = identity.split(separator: ":", omittingEmptySubsequences: false)
        guard self.wallet == wallet, parts.count == 2, ["xbt-mainnet","xbt-testnet","xbt-signet","xbt-regtest"].contains(String(parts[0])), JoinBlaketPayment.validID(String(parts[1])),
              (1_577_836_800...4_294_967_295).contains(chain_time), bonds.count <= 100, Set(bonds.map(\.outpoint)).count == bonds.count else { throw JoinBlaketError.invalidResponse }
        var total: UInt64 = 0
        for bond in bonds {
            guard JoinBlaketBondCoin.validOutpoint(bond.outpoint), bond.value_sat > 0, bond.value_sat <= 2_100_000_000_000_000 - total, (1_577_836_800...4_099_766_400).contains(bond.locktime) else { throw JoinBlaketError.invalidResponse }
            total += bond.value_sat
        }
    }
}
extension JoinBlaketClient {
    public func bonds(_ authorization: JoinBlaketAuthorization) async throws -> JoinBlaketBondInventory {
        _ = try await status(authorization)
        let value = try JSONDecoder().decode(JoinBlaketBondInventory.self, from: await request(["wallet", authorization.wallet, "paperclip", "bonds"], authorization: authorization))
        try value.validate(wallet: authorization.wallet)
        return value
    }
}
