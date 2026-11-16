package xyz.paperclip.wallet

import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class PaymentReviewSessionTest {
	@Test fun delayedReviewCannotAuthorizeAfterLockOrNavigation() = runBlocking {
		val session = PaymentReviewSession()
		val started = CompletableDeferred<Unit>()
		val response = CompletableDeferred<Unit>()
		var approvals = 0
		val old = async {
			val ticket = session.capture()
			started.complete(Unit)
			response.await()
			session.check(ticket)
			approvals++
		}
		started.await()
		session.invalidate()
		val current = session.capture()
		response.complete(Unit)
		try { old.await(); fail("A delayed response restored authorization") } catch (_: CancellationException) { }
		assertEquals(0, approvals)
		session.check(current)
	}

	@Test fun lockDuringFinalPreflightStopsBeforeTheSubmissionJournal() = runBlocking {
		val session = PaymentReviewSession()
		val reviewed = session.capture()
		val started = CompletableDeferred<Unit>()
		val nodeReply = CompletableDeferred<Unit>()
		var journaled = false
		var sent = false
		val submit = async {
			session.check(reviewed)
			started.complete(Unit)
			nodeReply.await()
			session.check(reviewed)
			journaled = true
			sent = true
		}
		started.await(); session.invalidate(); nodeReply.complete(Unit)
		try { submit.await(); fail("Stale review submitted") } catch (_: CancellationException) { }
		assertFalse(journaled); assertFalse(sent)
	}

	@Test fun queuedReviewUsesTheSessionAtTheTimeOfTheTap() = runBlocking {
		val session = PaymentReviewSession()
		val entered = CompletableDeferred<Unit>()
		val release = CompletableDeferred<Unit>()
		val holder = launch { PaymentGate.run { entered.complete(Unit); release.await() } }
		entered.await()
		val ticket = session.capture()
		var requests = 0
		val queued = async { PaymentGate.run { session.check(ticket); requests++ } }
		session.invalidate(); release.complete(Unit); holder.join()
		try { queued.await(); fail("Queued review survived navigation") } catch (_: CancellationException) { }
		assertEquals(0, requests)
	}

	@Test fun oneSessionCannotAuthorizeAnotherScreen() {
		val first = PaymentReviewSession(); val second = PaymentReviewSession()
		try { second.check(first.capture()); fail("Accepted another screen's review") } catch (_: CancellationException) { }
	}
}
