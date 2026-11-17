package xyz.paperclip.wallet

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class PendingPaymentRecoveryTest {
	@Test fun confirmedReceiptShowsTheWinnerNotTheLatestReplacement() {
		val original = "ab".repeat(32); val replacement = "cd".repeat(32)
		val result = JSONObject().put("state", "submitted").put("txid", original)
			.put("replacement_txids", org.json.JSONArray().put(replacement))
		assertEquals(replacement, PendingPaymentRecovery.transactionID(result))
		result.put("state", "completed")
		assertNull(PendingPaymentRecovery.transactionID(result))
		for (winner in listOf(original, replacement)) {
			result.put("confirmed_txid", winner)
			assertEquals(winner, PendingPaymentRecovery.transactionID(result))
		}
		result.put("confirmed_txid", "ef".repeat(32))
		assertNull(PendingPaymentRecovery.transactionID(result))
		result.put("confirmed_txid", original).put("state", "unknown")
		assertNull(PendingPaymentRecovery.transactionID(result))
		assertEquals(original, PendingPaymentRecovery.transactionID(JSONObject().put("state", "completed").put("txid", original)))
		assertNull(PendingPaymentRecovery.transactionID(JSONObject().put("state", "pending").put("txid", JSONObject.NULL)))
	}
	private fun attempt(id: String?, state: String) = JSONObject().put("state", state).also {
		if (id != null) it.put("attempt_id", id)
	}
	@Test fun restoreExposesUnknownNativeAttemptWithoutLocalProfileState() {
		val restored = attempt("new", "unknown")
		assertSame(restored, PendingPaymentRecovery.select(null, restored))
		assertSame(restored, PendingPaymentRecovery.select(attempt("old", "paid"), restored))
	}
	@Test fun unrelatedOrLegacyWarningsCannotBeReleasedByAnotherReceipt() {
		for (id in listOf(null, "other")) {
			val legacy = attempt(id, "unknown")
			assertSame(legacy, PendingPaymentRecovery.select(legacy, attempt("new", "paid")))
			assertSame(legacy, PendingPaymentRecovery.select(legacy, attempt("new", "unknown")))
			assertSame(legacy, PendingPaymentRecovery.select(legacy, null))
		}
	}
	@Test fun sameAttemptCanRecoverItsVerifiedResultButAbsenceIsNotFailure() {
		val pending = attempt("same", "pending")
		val paid = attempt("same", "paid")
		assertSame(paid, PendingPaymentRecovery.select(pending, paid))
		assertSame(pending, PendingPaymentRecovery.select(pending, null))
		assertNull(PendingPaymentRecovery.select(null, null))
	}
}
