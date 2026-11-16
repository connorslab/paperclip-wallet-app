import Foundation

/// A review is usable only when its displayed extra debit equals the actual fee increase.
public struct FeeReplacementReview: Decodable {
    public struct Recipient: Decodable { public let address: String; public let amount_sat: UInt64 }
    public let original_txid: String
    public let replacement_txid: String
    public let old_fee_sat: UInt64
    public let new_fee_sat: UInt64
    public let additional_fee_sat: UInt64
    public let recipients: [Recipient]
    public enum InvalidReview: Error { case inconsistent }
    public static func validate(_ data: Data, expectedTransaction: String) throws {
        let review = try JSONDecoder().decode(Self.self, from: data)
        func txid(_ value: String) -> Bool { value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
        guard txid(review.original_txid), txid(review.replacement_txid), review.original_txid == expectedTransaction,
              review.replacement_txid != review.original_txid, review.new_fee_sat > review.old_fee_sat,
              review.new_fee_sat <= 1_000_000, review.additional_fee_sat == review.new_fee_sat - review.old_fee_sat,
              !review.recipients.isEmpty, review.recipients.allSatisfy({ !$0.address.isEmpty && $0.address.count <= 128 && $0.amount_sat > 0 && $0.amount_sat <= 2_100_000_000_000_000 }) else {
            throw InvalidReview.inconsistent
        }
    }
}
