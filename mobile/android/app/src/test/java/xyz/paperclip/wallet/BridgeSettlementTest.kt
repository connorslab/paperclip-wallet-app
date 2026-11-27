package xyz.paperclip.wallet

import java.io.IOException
import java.security.MessageDigest
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class BridgeSettlementTest {
	@Test fun onlyDefinitiveArkRejectionReleasesSubmission() {
		fun submitted(state: String, receive: Boolean = false, source: String = "ark"): Boolean {
			val saved = JSONObject().put("source", source).put("receive", receive)
				.put("submitted", true).put("funding", state)
			BridgeSettlement.applyDefinitiveArkRejection(saved)
			return saved.getBoolean("submitted")
		}
		assertFalse(submitted("not_sent"))
		assertTrue(submitted("not_sent", receive = true))
		assertTrue(submitted("not_sent", source = "node"))
		for (state in listOf("unknown", "pending", "paid")) assertTrue(submitted(state))
	}

	private fun record(receive: Boolean) = JSONObject().put("receive", receive).put("hash", "01".repeat(32)).put("bridge", "quoted").put("verified", false)

	@Test fun bridgeOutageCannotHideAPaidNodeInvoice() = runBlocking {
		val result = BridgeSettlement.observe(record(true), { throw IOException("unavailable") }, { NodeInvoiceReceipt.PAID }, { fail("Receive must not fund") })
		assertTrue(result.record.getBoolean("verified"))
		assertEquals("paid", result.record.getString("node_state"))
		assertEquals("quoted", result.record.getString("bridge"))
		assertEquals("Bridge status unavailable.", result.message)
	}

	@Test fun nodeReceiptIsRequiredEvenWhenBridgeReportsSettlement() = runBlocking {
		val result = BridgeSettlement.observe(record(true), { JSONObject().put("state", "settled") }, { NodeInvoiceReceipt.ACCEPTED }, { fail("Receive must not fund") })
		assertFalse(result.record.getBoolean("verified"))
		assertEquals("accepted", result.record.getString("node_state"))
		val unavailable = BridgeSettlement.observe(record(true), { JSONObject().put("state", "settled") }, { throw IOException("unavailable") }, { fail("Receive must not fund") })
		assertFalse(unavailable.record.getBoolean("verified"))
		assertTrue(unavailable.message.contains("Node receipt is not confirmed"))
	}

	@Test fun fundingIsStillObservedWhenBridgeIsUnavailable() = runBlocking {
		var checks = 0
		val result = BridgeSettlement.observe(record(false), { throw IOException("unavailable") }, { error("Not a receive") }, { checks++; it.put("funding", "complete") })
		assertEquals(1, checks)
		assertEquals("complete", result.record.getString("funding"))
		assertFalse(result.record.getBoolean("verified"))
	}

	@Test fun onlyValidSettlementProofCompletesAnOutgoingBridgePayment() = runBlocking {
		val bytes = ByteArray(32) { 7 }
		val preimage = bytes.joinToString("") { "%02x".format(it) }
		val hash = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
		val original = record(false).put("hash", hash)
		val result = BridgeSettlement.observe(original, { JSONObject().put("state", "settled").put("preimage", preimage) }, { error("Not a receive") }, { fail("Verified settlement does not depend on node availability") })
		assertTrue(result.record.getBoolean("verified"))
		assertFalse("Input snapshot remains unchanged", original.getBoolean("verified"))
		var checks = 0
		val invalid = BridgeSettlement.observe(original, { JSONObject().put("state", "settled").put("preimage", "00".repeat(32)) }, { error("Not a receive") }, { checks++ })
		assertFalse(invalid.record.getBoolean("verified"))
		assertTrue(invalid.message.contains("payment proof is unavailable"))
		assertEquals(1, checks)
	}

	@Test fun cancellationStopsObservationWithoutAReplacementAttempt() = runBlocking {
		try {
			BridgeSettlement.observe(record(true), { throw CancellationException() }, { fail("Cancelled request must stop"); NodeInvoiceReceipt.WAITING }, { fail("Never fund during a check") })
			fail("Cancellation must propagate")
		} catch (_: CancellationException) {}
	}
}
