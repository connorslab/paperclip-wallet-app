package xyz.paperclip.wallet

import java.util.UUID
import kotlinx.coroutines.CancellationException

/** Main-thread review scope. Journaled submissions finish outside this scope. */
internal class PaymentReviewSession {
	private var ticket = UUID.randomUUID()
	fun capture(): UUID = ticket
	fun invalidate() { ticket = UUID.randomUUID() }
	fun check(candidate: UUID) {
		if (candidate != ticket) throw CancellationException("Payment review changed. Review again.")
	}
}
