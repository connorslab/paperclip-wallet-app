package xyz.paperclip.wallet

import org.json.JSONObject

/** An absent or unrelated result cannot turn a saved payment into a failure. */
internal object NodePaymentStatus {
	fun decode(response: JSONObject, hash: String): String? {
		require(hash.matches(Regex("[0-9a-f]{64}")))
		val payments = response.optJSONArray("pays")
		val rows =
			if (payments == null) listOf(response)
			else (0 until payments.length()).map { payments.getJSONObject(it) }
		val states =
			rows
				.filter { it.optString("payment_hash").lowercase() == hash }
				.map { it.optString("status").lowercase() }
		if (states.isEmpty()) return null
		// A confirmed successful attempt is sufficient even when older attempts failed.
		if (states.any { it in setOf("complete", "succeeded") }) return "succeeded"
		if (states.all { it == "failed" }) return "failed"
		return "pending"
	}
}
