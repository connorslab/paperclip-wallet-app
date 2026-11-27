package xyz.paperclip.wallet

import java.security.MessageDigest
import kotlinx.coroutines.CancellationException
import org.json.JSONObject

internal data class BridgeObservation(val record: JSONObject, val message: String)

/** Bridge settlement, node receipt and funding status are independent observations. */
internal object BridgeSettlement {
	// Older journals kept submitted=true even when native Ark rejected before sending.
	// A receive request also starts with funding=not_sent and must stay observable.
	fun applyDefinitiveArkRejection(record: JSONObject) {
		if (record.optString("source") == "ark" && !record.optBoolean("receive") &&
			record.optString("funding") == "not_sent" && !record.optBoolean("verified")) {
			record.put("submitted", false)
		}
	}

	suspend fun observe(
		record: JSONObject,
		bridge: suspend () -> JSONObject,
		receive: suspend () -> NodeInvoiceReceipt,
		funding: suspend (JSONObject) -> Unit,
	): BridgeObservation {
		val next = JSONObject(record.toString())
		val issues = mutableListOf<String>()
		try {
			val status = bridge()
			val state = status.getString("state")
			require(state in setOf("quoted", "offered", "funded", "paid", "paying", "settled", "failing", "aborting", "expiring", "failed", "aborted", "expired", "lost"))
			next.put("bridge", state)
			if (!record.optBoolean("receive") && state == "settled") {
				val verified = proof(status.optString("preimage"), record.getString("hash"))
				next.put("verified", verified)
				if (!verified) issues += "The bridge reports settlement, but payment proof is unavailable. Check the recipient before another attempt."
			}
		} catch (e: CancellationException) { throw e }
		catch (_: Exception) { issues += "Bridge status unavailable." }

		if (record.optBoolean("receive")) {
			try {
				val state = receive()
				next.put("node_state", state.name.lowercase())
				next.put("verified", state == NodeInvoiceReceipt.PAID)
			} catch (e: CancellationException) { throw e }
			catch (_: Exception) { issues += "Node receipt is not confirmed. Check the original node connection and invoice-read permission." }
		} else if (!next.optBoolean("verified")) {
			try { funding(next) }
			catch (e: CancellationException) { throw e }
			catch (_: Exception) { issues += "Funding status unavailable. The saved payment has not been resent." }
		}
		return BridgeObservation(next, issues.joinToString(" "))
	}

	private fun proof(preimage: String, hash: String): Boolean {
		if (!preimage.matches(Regex("[0-9a-fA-F]{64}"))) return false
		val bytes = preimage.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
		return try {
			MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) } == hash.lowercase()
		} finally { bytes.fill(0) }
	}
}
