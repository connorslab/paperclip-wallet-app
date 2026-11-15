import Foundation

/// A successful API response can still describe a payment awaiting settlement.
public struct PaymentReceipt: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let title: String
    public let message: String
    public let transactionID: String?
    public let completed: Bool
    public init(state: String, transactionID: String? = nil, boarding: Bool = false) {
        self.transactionID = transactionID
        completed = state == "completed" || state == "confirmed"
        if boarding {
            title = completed ? "Ark deposit ready" : "Ark deposit started"
            message = completed ? "Your deposit is available in Ark." : "Your deposit is not yet available in Ark. It needs network confirmations and registration with the Ark server. Check Activity for progress and save an updated encrypted backup. Do not make another deposit to retry this one."
        } else if completed {
            title = "Payment completed"
            message = "Your payment is complete. You can find its details in Activity."
        } else if state == "submitted" {
            title = "Transaction sent"
            message = "Your transaction was submitted to the network. It is waiting for confirmation."
        } else if state == "pending_broadcast" {
            title = "Broadcast needs checking"
            message = "The transaction is signed, but broadcast is not confirmed. Check Activity before trying again."
        } else {
            title = "Payment pending"
            message = "Your payment request is recorded. Check Activity for its final outcome before making another attempt."
        }
    }
}
