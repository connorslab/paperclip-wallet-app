package xyz.paperclip.wallet

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class NodePaymentStatusTest {
	private val hash = "12".repeat(32)

	private fun payment(state: String, id: String = hash) =
		JSONObject().put("payment_hash", id).put("status", state)

	@Test
	fun absentOrWrongHashPreservesUnknownOutcome() {
		assertNull(NodePaymentStatus.decode(JSONObject().put("pays", JSONArray()), hash))
		assertNull(NodePaymentStatus.decode(payment("SUCCEEDED", "34".repeat(32)), hash))
	}

	@Test
	fun inFlightAndUnrecognizedStatesAreNotFailures() {
		assertEquals("pending", NodePaymentStatus.decode(payment("IN_FLIGHT"), hash))
		assertEquals("pending", NodePaymentStatus.decode(payment("UNKNOWN"), hash))
	}

	@Test
	fun historicalFailuresCannotHideConfirmedSettlement() {
		val response =
			JSONObject()
				.put(
					"pays",
					JSONArray().put(payment("failed")).put(payment("complete")),
				)
		assertEquals("succeeded", NodePaymentStatus.decode(response, hash))
		assertEquals("failed", NodePaymentStatus.decode(payment("FAILED"), hash))
	}
}
