import Foundation

/// A review belongs to the screen/session that requested it. Invalidate on lock,
/// navigation or edits. Once submission is journaled, reconcile it independently.
@MainActor public final class PaymentReviewSession {
    public struct Ticket: Equatable, Sendable { fileprivate let id: UUID }
    private var ticket = Ticket(id: UUID())
    public init() {}
    public func capture() -> Ticket { ticket }
    public func invalidate() { ticket = Ticket(id: UUID()) }
    public func check(_ candidate: Ticket) throws {
        guard candidate == ticket else { throw CancellationError() }
    }
}
